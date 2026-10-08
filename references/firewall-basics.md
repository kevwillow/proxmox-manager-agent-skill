# Proxmox Firewall Basics

PVE ships with `pve-firewall`, a zone-based firewall managed via the
Proxmox API. It's distinct from iptables/nft — agents should always go
through `pvesh`, never edit `/etc/pve/firewall/*.fw` directly.

## The three levels

`pve-firewall` rules apply at three nested levels. A packet is accepted
only if it's accepted at *every* level it's traversing.

1. **Cluster (datacenter)** — applies to all nodes and VMs. The firewall is
   OFF by default at this level. Once enabled, the default input policy is
   DROP, with SSH (22) and the web UI (8006) allowed from the local network
   through the management IPSet.
2. **Node (host)** — applies to traffic to/from a specific node.
   Per-node VM bridges can be controlled here.
3. **VM/LXC** — applies to traffic to/from a specific VM/container's
   virtual NIC. The most common place to add application rules.

A typical homelab pattern:
- Cluster level: nothing custom (defaults work).
- Node level: nothing custom.
- VM level: add rules per VM as needed (e.g., allow 80/443 on the nginx
  VM from the LAN, allow 22 only from the LAN tailnet).

## Working with rules via pvesh

```bash
# List cluster-level rules
sudo -n pvesh get /cluster/firewall/rules

# List node-level rules
sudo -n pvesh get /nodes/<node>/firewall/rules

# List VM-level rules
sudo -n pvesh get /nodes/<node>/qemu/<vmid>/firewall/rules

# Add a rule (cluster level)
sudo -n pvesh create /cluster/firewall/rules \
    --action ACCEPT \
    --type in \
    --source 192.168.50.0/24 \
    --dest 192.168.50.0/24 \
    --dport 22 \
    --proto tcp \
    --comment "Allow LAN SSH to cluster"

# Add a rule (VM level)
sudo -n pvesh create /nodes/<node>/qemu/<vmid>/firewall/rules \
    --action ACCEPT \
    --type in \
    --source 192.168.50.0/24 \
    --dport 80 \
    --proto tcp \
    --comment "LAN HTTP"

# Delete a rule (find the pos first)
sudo -n pvesh get /nodes/<node>/qemu/<vmid>/firewall/rules
sudo -n pvesh delete /nodes/<node>/qemu/<vmid>/firewall/rules/<pos>
```

Rule fields:
- `--action`: ACCEPT, DROP, REJECT
- `--type`: in (incoming to VM/host), out (outgoing), forward (between VMs)
- `--source` / `--dest`: CIDR
- `--dport` / `--sport`: destination/source port (single or range like `8000:8999`)
- `--proto`: tcp, udp, icmp, all
- `--comment`: free-text

## Enabling the firewall

Default PVE install: firewall is **OFF** at the datacenter level
(`pve-firewall status` prints `disabled/running`), and nothing at node or VM
level is enforced until it is on. Once enabled, the default input policy is
DROP, and the firewall automatically allows cluster traffic, SSH and the web
UI from the `local_network` alias. That alias is auto-detected (usually the
host's subnet); check it with `pve-firewall localnet` before enabling.

Every switch lives under an `/options` path. `pvesh set .../firewall --enable 1`
(without `/options`) fails with `No 'set' handler`.

```bash
# Datacenter: the master switch. Nothing below is enforced while this is off.
sudo -n pvesh set /cluster/firewall/options --enable 1

# Node level (on by default once the datacenter switch is on)
sudo -n pvesh set /nodes/<node>/firewall/options --enable 1

# VM level: enable the VM's firewall AND mark each NIC with firewall=1,
# or the VM's rules never apply to that NIC.
sudo -n pvesh set /nodes/<node>/qemu/<vmid>/firewall/options --enable 1
sudo -n qm set <vmid> --net0 virtio=<MAC>,bridge=vmbr0,firewall=1   # keep the existing MAC
```

**WARNING: enabling the datacenter firewall with only the defaults blocks all
inbound except SSH (22) and the web UI (8006) from `local_network`.** If you
connect from anywhere else (Tailscale, VPN, another subnet), add a rule for
that source BEFORE enabling, and arm a revert first (see SKILL.md, *Changing
host networking with a dead-man switch*; the same timer can run
`pvesh set /cluster/firewall/options --enable 0`).

## Security groups

`pve-firewall` supports security groups — reusable rule sets you can
attach to multiple VMs. Useful for "all web servers get 80/443 from LAN":

```bash
# Create a group
sudo -n pvesh create /cluster/firewall/groups \
    --group web-tier \
    --comment "Web server rules"

# Add rules to the group
sudo -n pvesh create /cluster/firewall/groups/web-tier/rules \
    --action ACCEPT --type in --source 192.168.50.0/24 --dport 80 --proto tcp
sudo -n pvesh create /cluster/firewall/groups/web-tier/rules \
    --action ACCEPT --type in --source 192.168.50.0/24 --dport 443 --proto tcp

# Attach to a VM
sudo -n pvesh set /nodes/<node>/qemu/<vmid>/firewall \
    --groups web-tier
```

## Common patterns

### Single-node homelab, locked down

```bash
# Allow Tailscale CGNAT to everything
sudo -n pvesh create /cluster/firewall/rules \
    --action ACCEPT --type in --source 100.64.0.0/10 --comment "Tailscale"

# Allow LAN SSH
sudo -n pvesh create /cluster/firewall/rules \
    --action ACCEPT --type in --source 192.168.50.0/24 \
    --dport 22 --proto tcp --comment "LAN SSH"
```

### Web server VM

```bash
VMID=100

# LAN HTTP/HTTPS inbound
sudo -n pvesh create /nodes/<node>/qemu/$VMID/firewall/rules \
    --action ACCEPT --type in --source 192.168.50.0/24 --dport 80 --proto tcp
sudo -n pvesh create /nodes/<node>/qemu/$VMID/firewall/rules \
    --action ACCEPT --type in --source 192.168.50.0/24 --dport 443 --proto tcp

# Tailnet SSH (so you can SSH from your phone over tailscale)
sudo -n pvesh create /nodes/<node>/qemu/$VMID/firewall/rules \
    --action ACCEPT --type in --source 100.64.0.0/10 --dport 22 --proto tcp

# Enable firewall for this VM, and on its NIC (keep the MAC from `qm config`)
sudo -n pvesh set /nodes/<node>/qemu/$VMID/firewall/options --enable 1
sudo -n qm set $VMID --net0 virtio=<MAC>,bridge=vmbr0,firewall=1
```

## Pitfalls

### "I enabled the firewall and lost access"

The default behavior is to block all inbound except SSH and the web UI from
`local_network`. If your access comes from another source (Tailscale, public
IP, VPN, etc.) and you didn't add a rule for it, you're locked out.

Recovery: from a machine inside `local_network`, the web UI and its Shell
still work. If nothing can reach the host, use its physical console.

```bash
# Disable the firewall at the datacenter level
pvesh set /cluster/firewall/options --enable 0

# Or at the node level
pvesh set /nodes/<node>/firewall/options --enable 0
```

### "Rules don't take effect immediately"

`pve-firewall` is compiled into iptables rules on a timer (default 5
seconds). A rule added via `pvesh create` may take a few seconds to
become active. To force a reload:

```bash
sudo -n pve-firewall compile
sudo -n pve-firewall restart
```

### "I added a rule for the wrong network"

This is silent — the rule just doesn't match. Verify the rule with
`pvesh get` and check the source/dest CIDR.

### "My VM can reach the internet but can't reach the host"

The default cluster-level ACCEPT for established/related connections
allows VM → host outbound. But host → VM is blocked by default.
Add an explicit rule for the direction you need.

## When NOT to use pve-firewall

For very complex routing scenarios (multiple bridges, VLANs, policy
routing), iptables/nft directly may be cleaner. But the agent should
never edit those without explicit user instruction — the host's primary
firewall is pve-firewall, and bypassing it can cause subtle breakage.

For the agent's own host-protection, the recommended pattern is:
1. `pve-firewall` at the cluster/node level (once enabled, default input
   policy is DROP with local-network access to 22/8006).
2. The host's OS-level firewall (iptables/nft via the host's distro
   config) for additional layers.
3. SSH hardening (the Match block in templates/99-zen-agent-sshd.conf).

Three layers, each with a different attack surface to cover.
