# Proxmox Cluster Operations

When two or more PVE nodes are joined into a cluster, they share
configuration for users, storage, and (with HA) can migrate VMs
between nodes. This file covers the operational side: how to do common
cluster operations safely.

## Single-node vs cluster

A "cluster" can be just one node — running `pvecm create` on a fresh
install is required even if you don't plan to add more nodes. This is
because some PVE features (replication, HA) require cluster mode. The
single-node case is operationally identical to a non-clustered PVE for
most purposes.

## Adding a node to an existing cluster

```bash
# On the new node (must have same PVE version)
pvecm add <existing-node-ip> -link0 <ip>

# Verify
pvecm status
pvecm nodes
```

**Requirements:**
- Both nodes must be running the same PVE version.
- Both nodes must have unique hostnames.
- Both nodes must be reachable on the cluster network (default 5405/UDP
  for corosync).
- The new node's `/etc/hosts` must resolve the existing nodes'
  hostnames, and vice versa.
- The cluster network must be reliable — corosync is sensitive to
  latency and packet loss.

## Corosync configuration

The cluster uses corosync for membership and quorum. The config lives
in `/etc/pve/corosync.conf`. Common adjustments:

```bash
# Add a second link for redundancy (recommended for production)
pvecm addlink <other-node-ip> -link1
```

After any corosync change:
```bash
systemctl restart corsync    # or corosync
pvecm status
```

**Three or more nodes recommended for quorum.** A two-node cluster
loses quorum if either node goes down. The workaround is
`pvecm expected 1` (lower the quorum threshold temporarily), but the
correct fix is three nodes.

## HA (High Availability)

HA groups let VMs automatically restart on another node if their
primary node fails. The fencing mechanism uses
`/etc/pve/ha/fencing.cfg` and the node's BMC/IPMI for power control.

```bash
# Create a HA group (priority list of nodes)
ha-manager groupadd mygroup -nodes "apollo:100,artemis:50,nova:1"

# Add a VM to HA, on group mygroup
ha-manager add vm:100 --group mygroup --max_restart 3 --max_relocate 2

# HA status
ha-manager status
```

**Fencing is critical.** Without it, a failed node can hold VM state
and the surviving nodes can't safely start the VMs. PVE supports
IPMI and SSH-based fencing. Configure it BEFORE relying on HA:

```bash
# Add a fencing device (IPMI example)
ha-manager fence-add ipmi-apollo \
    --type ipmi \
    --host apollo \
    --ipaddr 192.168.50.10 \
    --username admin \
    --password <ipmi-password>

# Bind it to the node
ha-manager fence-add-node apollo ipmi-apollo
```

## Live migration

Move a running VM from one node to another without downtime:

```bash
# Check migration is possible (same CPU type, shared storage, etc.)
pvesh get /nodes/<source>/qemu/<vmid>/migrate

# Live migrate
qm migrate <vmid> <target-node> --online 1

# With a specific target storage (for storage migration)
qm migrate <vmid> <target-node> --online 1 --targetstorage <storage>
```

**Requirements for live migration:**
- Both nodes must support the same CPU features (or the VM must have
  `--cpu kvm64` instead of `--cpu host`).
- VM storage must be on shared storage (NFS, iSCSI, Ceph, ZFS over
  iSCSI) OR you must use storage migration (which copies the disk).
- Network must have enough bandwidth for the VM's RAM size at migration
  speed (typically a few seconds per GB on a LAN).

## Storage replication

ZFS and Ceph storage can be replicated between nodes for redundancy:

```bash
# Schedule replication
pvesr create-local-job <vmid> <target-node> --schedule "*/15" --rate 50

# List replication jobs
pvesr list

# Status
pvesr status
```

A replicated VM can be failed over to the replica node if the primary
fails. With HA + replication, the recovery is automatic (a few minutes
of downtime instead of hours).

## Cluster-wide operations

```bash
# List all VMs across all nodes
pvesh get /cluster/resources --type vm

# List all nodes with status
pvesh get /nodes

# Cluster log
journalctl -u pve-cluster --no-pager -n 50

# Apply a tag to all VMs matching a pattern
for vmid in $(pvesh get /cluster/resources --type vm | jq -r '.data[].vmid'); do
    pvesh set /nodes/<node>/qemu/$vmid/config --tags "homelab,automated"
done
```

## Pitfalls

### Cluster network partitioned (split-brain)

If two nodes lose communication but both think they're the leader,
quorum is lost and the cluster refuses to make changes. Recovery:
- Restore the network.
- If a node is permanently lost, use `pvecm expected 1` on a surviving
  node to lower the threshold, then `pvecm delnode <lost-node>`.

### HA migration loop

A misconfigured HA group (e.g., priority list that points VM back to
the original node after failover) causes a migration loop. Symptom:
VM status flapping every few minutes. Fix: ensure the HA group has
distinct priority values per node and that "always run here" (`:100`)
is set on only one node.

### Quorum lost on a two-node cluster

Expected failure mode. Add a third node OR use a QDevice (an external
arbiter that breaks the tie):

```bash
# On a small always-on host (a Pi, a NAS, etc.)
apt install corosync-qnetd
# Then on an existing PVE node:
pvecm qdevice setup <qdevice-host>
```

### Live migration stuck at 99%

Usually means shared storage isn't actually shared. Check
`pvesh get /nodes/<source>/storage` and `pvesh get /nodes/<target>/storage`
and compare the storage IDs. They must match (same type, same content,
same path/iqn).

### CPU mismatch on migration

Live migration requires the target node's CPU to support all features
the source node exposed. If the VM was created with `--cpu host` on
an AMD node and you migrate to an Intel node, the VM won't run.

Fix: edit the VM to use `--cpu kvm64` (a generic CPU that works on
both Intel and AMD), then live migration becomes possible.
