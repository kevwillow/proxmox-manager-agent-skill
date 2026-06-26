# Proxmox Storage Layouts — When to Pick Which

A Proxmox host can have storage of many types, each with different
trade-offs. This file covers the common homelab patterns and how to
pick between them.

## The four storage types you'll encounter

| Type | Backing | Best for |
|---|---|---|
| `dir` | A filesystem path (ext4, xfs, zfs mountpoint) | Bulk storage, ISOs, backups, templates |
| `lvm` | LVM volume group on a partition or disk | Single-host VM disks (legacy) |
| `lvmthin` | LVM thin provisioning on a volume group | VM disks with overcommit |
| `zfspool` | ZFS pool | Homelab sweet spot — snapshots, compression, redundancy |
| `nfs` | NFS share (typically a NAS) | Shared storage across cluster nodes |
| `cephfs` / `rbd` | Ceph cluster | Production-grade distributed storage |
| `pbs` | Proxmox Backup Server datastore | Backup target only |

For a single-node homelab, the realistic choices are `dir`, `lvmthin`,
and `zfspool`. The right answer depends on what you want.

## `dir` — the simple choice

A `dir` storage is just a directory on a mounted filesystem. Anything
Proxmox supports can live there (ISOs, VM disks as qcow2, backups,
templates).

```bash
# Register a directory as Proxmox storage
sudo -n pvesm add dir mydata \
    --path /mnt/mydata \
    --content images,iso,backup,vztmpl,snippets \
    --is_mountpoint yes
```

**Pros:**
- Trivial to set up (one mount, one `pvesm add`).
- Works on any filesystem.
- Easy to back up with host-level tools (rsync, btrfs send, etc.).
- Easy to migrate to another host (tar/rsync the directory).

**Cons:**
- No native snapshots (qcow2 supports them but they share the
  underlying file and don't survive copy).
- No thin provisioning on ext4 — file size = provisioned size.
- No native redundancy (unless the underlying FS provides it, like
  ZFS or btrfs RAID).

**When to pick:** boot disks on a single drive you don't need
redundancy for, ISO/template/backups storage where atomic snapshots
don't matter.

## `lvmthin` — overcommit-friendly

LVM thin provisioning gives you the ability to provision more storage
than physically exists, on the assumption that not all VMs will be
fully using their disks at the same time.

```bash
# Create a thin pool on a free partition or new disk
sudo -n pvcreate /dev/nvme1n1p1
sudo -n vgcreate vg-data /dev/nvme1n1p1
sudo -n lvcreate -L 100%FREE -T vg-data/thin-data

# Register with Proxmox
sudo -n pvesm add lvmthin vmdata-lvmthin \
    --vgname vg-data \
    --thinpool thin-data \
    --content images,rootdir
```

**Pros:**
- Native LVM snapshots (cheap, atomic).
- Thin provisioning: provision 1TB across 10 VMs on a 200GB drive.
- Fast allocation (no pre-zeroing).

**Cons:**
- No built-in compression (unlike ZFS).
- No native redundancy.
- Thin provisioning + overcommit = out-of-space scenarios that can
  crash VMs (the pool fills up, LVM can't allocate new blocks, the VM
  gets I/O errors and stops).
- Recovery from a full pool is painful.

**When to pick:** many VMs where actual usage << provisioned size,
and you have monitoring on the pool's free space.

## `zfspool` — the homelab sweet spot

ZFS gives you snapshots, compression, and (with mirrors/raidz)
redundancy, all in one. The trade-off is RAM (ZFS loves RAM for
dedup/cache) and slightly more complex setup.

```bash
# Create a mirrored pool (2 drives, survives 1 failure)
sudo -n zpool create -f tank mirror /dev/nvme1n1 /dev/nvme2n1

# Or a single-drive pool (no redundancy but compression + snapshots)
sudo -n zpool create -f tank /dev/nvme1n1

# Register with Proxmox
sudo -n pvesm add zfspool tank \
    --pool tank \
    --content images,rootdir
```

**Pros:**
- Snapshots are cheap, atomic, and survive across pool operations.
- Compression (lz4) typically gives 1.3-1.7x effective storage for
  VMs.
- Native redundancy with mirrors or raidz.
- `zfs send/receive` for backup and migration.
- Self-healing with redundant vdevs (silent corruption detection).

**Cons:**
- Needs RAM (1GB minimum per TB, more for dedup).
- Can't easily shrink a pool.
- Single-drive ZFS is fine; multi-drive ZFS needs you to think about
  vdev layout (mirror vs raidz1 vs raidz2).
- Adding drives to an existing raidz vdev is not supported (you add
  a new vdev, not expand the existing one).

**When to pick:** any homelab where you have at least 2 drives and
16GB+ RAM. This is the default recommendation for homelab VMs.

## Practical patterns

### Pattern 1: Boot on PVE, VMs on a separate pool

The PVE installer creates `local` (backing `/var/lib/vz`, on the boot
disk) and `local-lvm` (thin pool on the boot disk's free space). For
serious VMs, you want them on a separate pool:

- Boot disk: 60-128GB SSD, holds the OS + `local` storage for ISOs.
- VM data: 1-4TB SSD or NVMe, holds the VM disks.
- Backups: another disk or a NAS share.

```bash
# After installing a second disk and partitioning:
sudo -n zpool create -f tank /dev/nvme1n1
sudo -n pvesm add zfspool tank --pool tank --content images,rootdir

# VMs created with --scsi0 tank:32 will land on the new pool.
```

### Pattern 2: Single-drive homelab, ZFS compression

If you only have one large drive and don't need redundancy:

```bash
sudo -n zpool create -f tank /dev/nvme1n1
sudo -n pvesm add zfspool tank --pool tank --content images,rootdir
```

ZFS compression (lz4 is the default, no setup needed) will often
give you 30-50% effective storage increase. Snapshots are cheap.
Single-drive failure = total loss, but for a homelab that's
acceptable.

### Pattern 3: Mirrored VM storage + cold backup disk

For a more production-like setup:

```bash
# Two SSDs in a ZFS mirror for VM storage
sudo -n zpool create -f tank mirror /dev/nvme1n1 /dev/nvme2n1
sudo -n pvesm add zfspool tank --pool tank --content images,rootdir

# A larger HDD for backups
sudo -n pvesm add dir backup \
    --path /mnt/backup \
    --content backup \
    --is_mountpoint yes
```

VMs on the mirror (can survive 1 drive failure). Backups go to the
HDD. Optionally, the backup HDD gets `zfs send`'d offsite weekly.

### Pattern 4: NFS from a NAS

If you have a NAS (Synology, TrueNAS, etc.) on the LAN:

```bash
sudo -n pvesm add nfs nas-vms \
    --server 192.168.50.20 \
    --export /volume1/proxmox \
    --content images,iso,backup,vztmpl \
    --options vers=3
```

**Pros:** shared across cluster nodes for live migration.
**Cons:** network-dependent (an outage of the NAS = VMs can't
start), typically slower than local storage.

## When NOT to use `lvmthin`

If you're going to provision a small number of VMs and want simple
"this VM gets exactly this much disk" semantics, plain LVM (`lvm` not
`lvmthin`) is fine. Thin pools add complexity for overcommit that
single-host homelabs rarely benefit from.

## Snapshot gotchas

- `lvmthin` and `zfspool` snapshots are cheap. Use them liberally
  before risky operations.
- `dir` snapshots (qcow2 internal) are not atomic — a snapshot of a
  running VM may capture the disk in an inconsistent state. For
  consistent backups, use `qm stop` first OR use `vzdump --mode
  snapshot` which uses QEMU's guest-side freeze to quiesce.
- `vzdump --mode suspend` pauses the VM briefly and snapshots at
  rest. Less risky than snapshot, slightly more downtime.
- `vzdump --mode stop` stops the VM, snapshots, restarts. Most
  consistent, most downtime.

For most homelab use cases, `--mode snapshot` is the right default.
