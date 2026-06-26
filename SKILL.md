---
name: proxmox-manager-agent
description: "Manage a Proxmox VE homelab (single-node or small cluster) from an AI agent via scoped SSH access. Covers VM and LXC lifecycle (create, start, stop, snapshot, destroy), storage management (ISO upload, LVM-thin/ZFS/dir pools), backup/restore (vzdump, PBS), network bridges, firewall, cluster operations, and the PVE 9.x gotchas (binary path splits, --is_mountpoint no re-index, NVMe-shuffle, broken DNS on fresh installs). Includes a fully specified sudoers whitelist/blacklist template. Use when the user says 'manage my Proxmox', 'spin up a VM', 'add an ISO', 'backup the VMs', 'add storage', 'create an LXC', 'snapshot before I upgrade', or any task touching qm, pct, pvesh, pvesm, vzdump, or pve-firewall on a PVE host."
version: 1.0.2
author: kevwillow
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [proxmox, pve, virtualization, kvm, lxc, homelab, infrastructure, devops]
    related_skills: [scoped-agent-ssh-access]
---

# Proxmox Manager Agent

Operational skill for managing a Proxmox VE host (single-node or small cluster)
from any AI agent — Hermes, Claude Code, Codex, OpenCode, or any headless
runner — via scoped SSH access. The security model (dedicated agent user,
sudoers allowlist, key-only auth, IP allowlist, audit trail, one-command
revoke) lives in the `scoped-agent-ssh-access` skill. **This skill assumes that
is already set up.** This skill is the *operational* side: which commands to
run, in what order, with what pitfall-avoidance.

## When to Use

- User says "manage my Proxmox," "spin up a VM," "add an ISO," "backup the VMs,"
  "create an LXC," "add storage," "snapshot before I upgrade," "what's running
  on my proxmox," or any equivalent.
- A task touches any of: `qm`, `pct`, `pvesh`, `pvesm`, `vzdump`, `pve-firewall`,
  `ha-manager`, `pvecm`, `qemu-img`, on a PVE 8.x or 9.x host.

**Don't use for:** generic Linux sysadmin (use scoped-agent-ssh-access
directly), non-Proxmox virtualization (KVM/libvirt without PVE wrapper, Xen,
ESXi), or anything where the user has not yet established scoped SSH access —
that's a prerequisite, not a part of this skill.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Agent host (where the AI runs)                                  │
│   ~/.ssh/<agent>-<host>     (private key, 600 perms)            │
│   HERMES_HOME=/home/<agent>/.hermes                             │
│   skill: proxmox-manager-agent  (this file)                     │
└────────────────┬────────────────────────────────────────────────┘
                 │ SSH (key-only, scoped user, IP-restricted)
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ Proxmox VE host (PVE 8.x or 9.x on Debian 12/13)                │
│   user: zen-agent       (or claude-svc, codex-bot, etc.)        │
│   sudoers: /etc/sudoers.d/<agent>  (NOPASSWD allowlist only)    │
│   sshd: /etc/ssh/sshd_config.d/99-<agent>.conf  (Match block)   │
│   audit: /var/log/auth.log   (every sudo invocation logged)     │
└─────────────────────────────────────────────────────────────────┘
```

The agent never logs in as root. It never has a root password. Every action
goes through the scoped user with a sudoers allowlist. A leaked key still
requires the right source IP and the agent user still exists with the same
blast radius.

## The Command Surface

### Binary locations (PVE 8/9)

| Binary | Path | Purpose |
|---|---|---|
| `qm` | `/usr/sbin/qm` | KVM/QEMU VM management |
| `pct` | `/usr/sbin/pct` | LXC container management |
| `pvesh` | **`/usr/bin/pvesh`** | Proxmox API CLI (preferred for scripted ops) |
| `pvesm` | `/usr/sbin/pvesm` | Storage manager |
| `vzdump` | `/usr/sbin/vzdump` | Backup |
| `qemu-img` | `/usr/sbin/qemu-img` | Raw disk image operations |
| `pveum` | `/usr/sbin/pveum` | User/permission manager |
| `pvecm` | `/usr/sbin/pvecm` | Cluster manager |
| `ha-manager` | `/usr/sbin/ha-manager` | HA (high availability) manager |
| `pve-firewall` | `/usr/sbin/pve-firewall` | Firewall rules compiler |
| `pveam` | `/usr/bin/pveam` | Appliance manager (templates, ISOs) |
| `qmrestore` | `/usr/sbin/qmrestore` | Restore from vzdump backup |

**The `pvesh` and `pvesm` paths are the gotcha.** Most Proxmox docs and
tutorials list them in `/usr/sbin/`, but on PVE 8/9 they live in `/usr/bin/`.
A sudoers rule with the wrong path silently falls through to "ask for a
password" — see `scoped-agent-ssh-access` for the diagnose-and-fix recipe.

Always verify on a fresh host before writing sudoers:
```bash
ssh zen-agent@<proxmox> 'for b in qm pct pvesh pvesm vzdump pveam ha-manager pve-firewall qemu-img pveum pvecm; do echo -n "$b: "; command -v $b || echo MISSING; done'
```

### Output formats

`pvesh` returns JSON for nested objects and a tabular format for lists.
Both are stable across PVE 8/9.

```bash
sudo -n pvesh get /version
# {"release":"9.2","repoid":"b9984c6d90a4bd80","version":"9.2.2"}

sudo -n pvesh get /nodes
# ┌────────┬────────┬───────┬─...
# │ node   │ status │   cpu │...
# ╞════════╪════════╪═══════╪═...
# │ apollo │ online │ 0.17% │
# └────────┴────────┴───────┴─...
```

`qm list` and `pct list` return empty when there are no VMs/containers.
Empty output is not an error — verify with `sudo -n -l` to distinguish
"command worked, no VMs yet" from "command was denied."

## Whitelist & Blacklist Commands

This is the core of the safe-by-default design. The agent's blast radius
is determined entirely by what's in its sudoers file. Every command below
is either explicitly allowed (whitelist) or explicitly denied (blacklist,
via NOT being in the allowlist).

### Recommended sudoers allowlist (whitelist)

This template goes in `/etc/sudoers.d/<agent-user>` on the Proxmox host.
Adjust paths and command list to match the actual PVE install.

```sudoers
# /etc/sudoers.d/zen-agent
# Whitelist for an AI agent managing this Proxmox host.
# Each line is one allowed command pattern. Anything NOT in this list
# is denied by sudo at runtime, with an audit log entry.

# --- Proxmox management ---
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/qm *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/pct *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/pvesh *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/pvesm *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/vzdump *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/qmrestore *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/qemu-img *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/pveam *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/ha-manager *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/pve-firewall *

# --- Storage observation ---
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/df *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/du *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/lsblk *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/find *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/ls *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/blkid *

# --- Service observation ---
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl status *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl list-units *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/systemctl is-active *

# --- Network observation ---
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/ip *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/ss *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/ping *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/resolvectl *

# --- User/mount management (for storage workflow) ---
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/mount *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/umount *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/mkdir *

# --- Read-only sysinfo ---
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/uname *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/uptime *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/free *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/cat /etc/fstab
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/cat /etc/network/interfaces

# --- Audit: every invocation logged ---
Defaults!zen-agent LOG_INPUT
Defaults!zen-agent LOG_OUTPUT
Defaults log_output
Defaults!zen-agent env_reset
```

A copy of this file is at `templates/zen-agent-sudoers` — copy to
`/etc/sudoers.d/zen-agent` on the Proxmox host, validate with
`visudo -c -f /etc/sudoers.d/zen-agent`, then test with
`sudo -n -l` as zen-agent to see the loaded rules.

### Explicit blacklist (commands the sudoers MUST NOT include)

Even though sudoers defaults to deny for anything not whitelisted, be
deliberate about these. The blast radius of each is large, the recovery
is hard or impossible, and there is no operational reason for the agent
to need them.

| Command | Reason to deny |
|---|---|
| `reboot`, `shutdown`, `poweroff`, `halt` | Takes the host down. Agent should ASK, user should run. |
| `mkfs.ext4`, `mkfs.vfat`, `mkfs.xfs`, `mkfs.btrfs` | Destroys filesystem contents. Agent gives instructions, user runs. |
| `dd` | Byte-level disk destruction. Almost no legitimate use case. |
| `parted`, `fdisk`, `sfdisk` | Interactive or scriptable partition table rewrites. Agent identifies, user runs. |
| `cryptsetup` | Disk encryption setup/destruction. |
| `mount /dev/nvme*n* ...` with literal device path | Use only UUID= in fstab — but the agent should not be writing fstab directly anyway. |
| `pvesm remove` without explicit `--nostart 1` | Destroys storage pool metadata. |
| `qm destroy`, `qm stop`, `pct destroy`, `pct stop` | **See "Soft blacklist" below** — present in sudoers, but agent's safety policy refuses without user confirmation. |
| `apt`, `apt-get`, `dpkg` | Package management. Agent should never install packages without explicit user instruction, and even then the user runs the command. |
| `visudo` | Modifying sudoers is a privilege escalation vector. User-only. |
| `useradd`, `userdel`, `usermod`, `passwd` | Account management. User-only. |
| `iptables`, `nft` directly | Use `pve-firewall` API instead. |
| `rm -rf /` | Obviously. Don't include `rm` at all if avoidable — agents rarely need to delete files. |

The pattern: **observe freely, manage Proxmox state freely, but
destructive disk operations and host-state changes require a human in the
loop.** This keeps the blast radius at "VM/container state" not "host
state."

### Soft blacklist (in sudoers, but agent refuses without explicit user OK)

These are commands that Proxmox admins legitimately need, and the sudoers
file permits them, but the agent's safety policy refuses to invoke without
asking first. The agent has them in a *runtime* blocklist, not a sudoers
blocklist — defense in depth.

| Command | Why the agent pauses to ask |
|---|---|
| `qm destroy <vmid>` | Deletes the VM and its disks. Irreversible. |
| `qm stop <vmid>` | Hard power-off. Use `qm shutdown` first. |
| `pct destroy <ctid>` | Deletes the container. Irreversible. |
| `pct stop <ctid>` | Hard stop. Use `pct shutdown` first. |
| `pvesm remove <storage>` | Removes storage registration. Doesn't touch data but breaks the web UI. |
| `vzdump --remove 0` (with no other flags) | Can wipe the entire backup retention. |
| `qm snapshot --vmstate 0` on a running VM | Memory snapshot of a live VM. Heavy IO. |
| `ha-manager add` / `ha-manager remove` | HA changes affect failover behavior. |

The agent's exact wording when refusing:
> "I won't run `qm destroy 100` without explicit confirmation — this deletes
> the VM and its disks irrecoverably. Reply `yes destroy 100` if you want me
> to proceed."

This matches the trust model in `scoped-agent-ssh-access`: sudoers says
yes, the agent layer says "ask first."

### How the agent should *think* about the whitelist

When the user says "spin up a VM," the agent's actual command sequence is:

1. **Verify sudoers covers what we need:** `sudo -n -l | grep -E '^.*NOPASSWD.*qm '` — if this returns nothing, stop and tell the user to install the sudoers file.
2. **Verify SSH works with key-only:** `ssh -o BatchMode=yes zen-agent@<host> 'whoami'` — if this prompts for a password, stop.
3. **Verify audit log exists:** `sudo -n -l | grep -i 'log_'` — if no logging is configured, the sudoers install is incomplete; fix before continuing.
4. **Only then** start running `qm`, `pct`, `pvesh` commands.

If any of those checks fail, the right action is **stop and ask the user
to install the sudoers file**, not to fall back to running things as root.

## Common Workflows

### Reading host state

```bash
# Node health (CPU, RAM, uptime, kernel)
sudo -n pvesh get /nodes/<node>/status

# Storage status
sudo -n pvesm status

# Cluster resources (across all nodes if clustered)
sudo -n pvesh get /cluster/resources --type node

# All VMs on the cluster
sudo -n pvesh get /cluster/resources --type vm

# All LXC containers
sudo -n pvesh get /cluster/resources --type ct
```

The `scripts/proxmox-status.sh` script runs all of these in one shot and
prints a clean summary. Run from the agent host:

```bash
scp scripts/proxmox-status.sh zen-agent@<proxmox>:/tmp/
ssh zen-agent@<proxmox> 'bash /tmp/proxmox-status.sh'
```

### Uploading an ISO from a USB or local path

```bash
# Mount the source
sudo -n mount /dev/sdX1 /mnt/source

# Verify perms (sudoers must include /usr/bin/ls)
sudo -n ls /mnt/source/

# Copy. Proxmox default 'local' storage is /var/lib/vz/template/iso
sudo -n cp /mnt/source/*.iso /var/lib/vz/template/iso/

# Verify via pvesh
sudo -n pvesh get /nodes/localhost/storage/local/content --content iso
```

**Always check `df -h /` before a bulk copy.** Ventoy USBs can easily hold
30–60GB; the default `local` storage backing `/var/lib/vz` may not have that
much free. The `scripts/iso-import.sh` wrapper enforces this with a hard
pre-flight abort.

**Strongly prefer copying ISOs to a dedicated NVMe storage pool
(`/mnt/iso`) rather than `/var/lib/vz/template/iso/` on the boot disk.**
A 9-ISO Ventoy stick can easily total 30-60GB; the Proxmox boot disk is
typically 60-70GB total, so a single copy fills it from 8% to 100% and
breaks the system. See *Adding dedicated storage pools* below.

### Adding dedicated storage pools

When the host has additional NVMe drives that should be Proxmox storage,
the full pipeline is: wipe → partition → format → mount → register with
pvesm. The agent drives this end-to-end with the user running the
destructive steps (the agent's safety policy blocks `mkfs`, `parted`, `dd`
by design — see *Explicit blacklist* above).

**Step 1: Identify drives and confirm scope.**

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL,WWN
```

Show the user the boot disk's serial and mark it OUT-OF-SCOPE explicitly.
Reference drives by **serial** (e.g. `S413NS0RC03383M`), NOT by
`/dev/nvmeXnY` — NVMe device numbers shuffle across reboots. The boot disk
in the typical homelab config is identifiable by containing `/boot/efi`
and LVM volumes (`pve-root`, `pve-swap`, `pve-data`).

**Step 2: User partitions (one fdisk at a time).** Agent instructs:

```bash
sudo fdisk /dev/nvmeXnY    # target drive confirmed by serial
# In fdisk:
g                              # new GPT table (destroys existing)
n                              # new partition
1                              # partition 1
[Enter]                        # default first sector
[Enter]    # or +119G          # full disk, or specify size for splits
w                              # write and exit
```

**Step 3: User formats.**

```bash
sudo mkfs.ext4 -L <label> /dev/nvmeXnYp1
```

**Step 4: User mounts.**

```bash
sudo mkdir -p /mnt/<label>
sudo mount /dev/nvmeXnYp1 /mnt/<label>
df -h /mnt/<label>     # verify the FULL partition size, NOT 458MB
```

**Step 5: Agent adds UUID-based fstab entry (NEVER `/dev/nvmeXnYp1`).**

```bash
UUID=$(blkid -s UUID -o value /dev/nvmeXnYp1)
echo "UUID=$UUID /mnt/<label> ext4 defaults,nofail 0 2" >> /etc/fstab
mount -a
df -h | grep <label>
```

NVMe device numbers (`nvme0n1`, `nvme1n1`, ...) are assigned by kernel
discovery order and can shuffle on every reboot, especially after disks are
added/removed. The physical identity (model, serial, WWN) is stable; the
device path is not. UUIDs are stable. Always use `UUID=` or `LABEL=` in
`/etc/fstab` — never `/dev/nvmeXnYp1`. After a reboot, verify with
`df -h /mnt/<label>` that the right contents are at the right mount point.

**Step 6: Agent registers with Proxmox.**

```bash
sudo -n pvesm add dir <name> --path /mnt/<label> --content <types> --is_mountpoint yes
```

After files are copied into the path, force Proxmox to scan and index the
contents:

```bash
sudo -n pvesm set <name> --is_mountpoint no
sudo -n pvesm list <name>   # verify files are indexed
```

There is no `pvesm scan <name>` subcommand on PVE 9.x — its purpose was
folded into the `set` command's `--is_mountpoint` toggle. Proxmox doesn't
auto-scan mount-point-backed storage, which is why `pvesm list` returns
empty even when `ls` shows files at the path. The web UI's "Create VM →
ISO" dropdown won't show the storage's contents until `pvesm list` does.

The `scripts/add-nvme-storage.sh` wrapper runs this full pipeline with
explicit prompts at every destructive step.

### Creating a VM from an ISO

```bash
# 1. Pick a VMID (Proxmox convention: 100+ for VMs, 200+ for LXC)
VMID=100

# 2. Create with sensible defaults
sudo -n qm create $VMID \
    --name "ubuntu-test" \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --scsi0 local-lvm:32 \
    --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
    --boot order=ide2 \
    --ostype l26

# 3. Start it
sudo -n qm start $VMID

# 4. Watch the console (or hand the URL to the user)
sudo -n pvesh get /nodes/<node>/qemu/$VMID/status/current
```

Use `scripts/vm-from-iso.sh` for a one-shot wrapper.

Full `qm create` recipes for common distros (Ubuntu 24.04, Debian 12,
cloud-init, Windows 11 with UEFI+TPM) live in
`references/vm-creation-cheatsheet.md`.

### Creating an LXC container

```bash
# 1. Update template list and download
sudo -n pveam update
sudo -n pveam download local debian-12-standard_12.5-1_amd64.tar.zst

# 2. Create the container
sudo -n pct create 200 local:vztmpl/debian-12-standard_12.5-1_amd64.tar.zst \
    --hostname debian-ct \
    --memory 1024 \
    --cores 2 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --rootfs vmdata:16 \
    --features nesting=1 \
    --unprivileged 1 \
    --password <bcrypt-or-plaintext> \
    --start 1
```

Use `scripts/lxc-from-template.sh` for the wrapper.

### Lifecycle commands

```bash
sudo -n qm start <vmid>     # or pct start <ctid>
sudo -n qm shutdown <vmid>  # graceful ACPI shutdown
sudo -n qm stop <vmid>      # hard stop (only after shutdown times out)
sudo -n qm reboot <vmid>
sudo -n qm destroy <vmid>   # DELETE the VM and its disks — IRREVERSIBLE
sudo -n qm snapshot <vmid> <snapname>
sudo -n qm rollback <vmid> <snapname>
sudo -n qm list

sudo -n pct start <ctid>
sudo -n pct shutdown <ctid>
sudo -n pct stop <ctid>
sudo -n pct reboot <ctid>
sudo -n pct destroy <ctid>   # DELETE the container — IRREVERSIBLE
sudo -n pct list
```

**`qm destroy`, `qm stop`, `pct destroy`, `pct stop` are in the agent's
soft blocklist.** The sudoers allowlist permits them, but the agent will
refuse and ask the user before invoking. This is intentional — see the
*Soft blacklist* section above.

### Backups

```bash
# One-shot backup of a single VM
sudo -n vzdump <vmid> --storage local --mode snapshot --compress zstd

# One-shot backup of all VMs on a node
sudo -n vzdump --all 1 --storage local --mode snapshot --compress zstd

# Schedule via /etc/pve/jobs.cfg or the GUI; agent should usually defer
# scheduling to the user since it requires decisions about retention,
# offsite targets, etc.
```

Restore is `qmrestore <backup-file> <new-vmid>` (irreversible to the
original VMID) or `pct restore`. The agent should always verify the backup
file's integrity first:

```bash
sudo -n vzdump --verify <backup-file>     # not always supported
# Or check the .log sidecar
ls -la /var/lib/vz/dump/vzdump-*.log*
```

### Firewall (`pve-firewall`)

PVE has its own firewall layer managed at Datacenter, Node, and VM levels
via the `pvesh` API or `/etc/pve/firewall/`. The agent should always go
through `pvesh`, never edit `/etc/pve/firewall/*.fw` directly.

```bash
# Add a rule to allow SSH from a specific subnet on the host
sudo -n pvesh create /nodes/<node>/firewall/rules \
    --action ACCEPT --type in --source 192.168.50.0/24 \
    --dest 192.168.50.0/24 --dport 22 --proto tcp

# List current rules
sudo -n pvesh get /nodes/<node>/firewall/rules

# Enable firewall at the host level (default is disabled)
sudo -n pvesh set /nodes/<node>/firewall --enable 1
```

**Default behavior on a fresh PVE install:** firewall is enabled at the
cluster and datacenter level but rules only allow SSH (22) and the web UI
(8006) inbound. Anything else needs a rule added. See
`references/firewall-basics.md` for the full cluster/node/VM firewall
hierarchy.

### Cluster operations (multi-node)

If the host is in a cluster:

```bash
# Cluster status
sudo -n pvecm status

# Nodes in the cluster
sudo -n pvesh get /nodes

# Migrate a running VM to another node
sudo -n qm migrate <vmid> <target-node> --online 1

# HA status
sudo -n ha-manager status
```

`scripts/cluster-info.sh` prints a one-shot summary of cluster state,
node health, and HA configuration.

## Verification Recipes

After any significant operation, run a verification. The right verification
depends on what changed:

| Operation | Verify with |
|---|---|
| Created VM | `qm list`, then `qm status <vmid>`, then `pvesh get /cluster/resources --type vm` |
| Started VM | `qm status <vmid>` shows `status: running`, console reachable |
| Stopped VM | `qm status <vmid>` shows `status: stopped` |
| Snapshotted VM | `qm snapshot <vmid>` lists the new snapname |
| Created LXC | `pct list`, then `pct status <ctid>` |
| Added storage | `pvesm status` shows the new storage, `df -h /mnt/<mount>` shows correct size |
| Imported ISO | `ls /var/lib/vz/template/iso/` shows the file, `pvesh get /nodes/.../storage/local/content --content iso` indexes it |
| Created backup | `ls /var/lib/vz/dump/` shows the .vma.zst file |
| Restored backup | `qm list` shows new VMID, `qm status <new-vmid>` reports running |
| Edited firewall | `pvesh get /nodes/<node>/firewall/rules` shows the new rule, test from allowed source |

**Always verify the *full* state, not just the immediate operation.**
A common failure mode is the operation succeeding but a downstream effect
(notify, index, replication) silently failing. Example: `pvesm add dir`
succeeds but the web UI dropdown doesn't show the storage until you toggle
`--is_mountpoint no` and back. The Verify column above is the "did this
actually take effect everywhere" check.

## Common Pitfalls

A numbered list of mistakes and their fixes. Read the relevant one BEFORE
running the corresponding operation.

### 1. `pvesm scan <storage-id>` does NOT exist on PVE 9.x

The help banner shows `scan cifs/iscsi/lvm/lvmthin/nfs/pbs/zfs` only. Older
docs and AI agents trained on PVE 7/8 will tell you to use
`pvesm scan iso` to refresh the storage index — that command doesn't exist
anymore. The PVE 9.x equivalent for re-indexing a `dir` storage is
`pvesm set <storage> --is_mountpoint no`. Even that doesn't reliably
populate the index on a fresh install — see pitfall #9.

### 2. The `enterprise.proxmox.com` repos fail with 401 Unauthorized on every `apt update`

Expected on any PVE host without a paid subscription key. The error is
noise — `apt install` proceeds fine from the Debian repos. To silence it,
either add the `pve-no-subscription` and `ceph-no-subscription` repos or
disable the enterprise ones. The agent should never run `apt` itself —
flag the noise and let the user decide.

### 3. Disk full after a copy or install — and the agent can't run `du` to triage

If the agent's sudoers allowlist doesn't include `du`, `find`, or `ls`
with broad args, a disk-fill emergency leaves the agent unable to
self-diagnose. Prevention beats recovery:

1. Always `df -h <target>` before a bulk write. If free space is close to
   what you're about to write, stop and ask.
2. When writing sudoers for a new agent, include observation tools:
   `/usr/bin/du`, `/usr/bin/find`, `/usr/bin/df`, `/usr/bin/ls` with
   reasonable arg patterns. The blast radius of "can observe disk usage"
   is zero; the operational cost of "agent can't see why disk is full" is
   real.
3. Recovery path if already full: ask the user (as root) to run
   `du -sh /* | sort -h | tail -10` — single paste, very reliable.

### 4. `pvesm list <name>` returns empty even though files are on disk

Proxmox doesn't auto-scan mount-point-backed storage. After
`pvesm add dir <name> --is_mountpoint yes` and `cp` of files into the
storage path, `pvesm list <name>` will show the column headers but no rows
even though `ls` shows files at the path.

Fix: `sudo -n pvesm set <name> --is_mountpoint no`. Proxmox scans the path
on the next access and indexes existing files. There is no
`pvesm scan <name>` subcommand on PVE 9.x — its purpose was folded into
the `set` command's `--is_mountpoint` toggle.

### 5. Storage pool shows correct `df` size but the wrong files

NVMe device numbers (`/dev/nvme0n1`, `/dev/nvme1n1`, ...) are assigned by
kernel discovery order and shuffle across reboots. `/etc/fstab` entries
using `/dev/nvmeXnYp1` will silently point at the wrong drive after reboot
— the mount succeeds but the wrong filesystem is at the mount point.
Symptom: `/mnt/iso` shows contents that should be at `/mnt/vmdata`, or
vice versa.

Fix: rewrite `/etc/fstab` entries using `UUID=` or `LABEL=` (stable across
reboots) instead of `/dev/nvmeXnYp1`. Verify after every reboot with
`blkid /dev/nvme*Np* | grep <label-or-uuid>` that the right partition is
mounted at the right place.

### 6. `mkfs.ext4` finished but `df -h` shows 458MB on a 119GB partition

The kernel had stale partition geometry. Reboot, run `partprobe`
(requires `apt install -y parted`), or just re-run
`mkfs.ext4 -F /dev/nvmeXnYp1` — the `-F` forces overwrite and the kernel
now sees the correct size.

### 7. `cp ... /mnt/iso/` asks for a password even though sudoers has the rule

Sudoers path matching is exact-character. A rule specifying
`/usr/bin/cp ... /mnt/iso` matches a call to `cp ... /mnt/iso` but NOT
`cp ... /mnt/iso/` (with trailing slash). Drop the trailing slash or
rewrite the rule to include the slash. Verify with
`sudo -n -l /usr/bin/cp`.

### 8. `qm list` returns empty — is the agent broken?

No. It means there are no VMs. Verify with `sudo -n -l` from the agent
user to confirm the command itself ran (the output will list every
allowlisted rule). Empty `qm list` output is a feature, not a bug.

### 9. The web shell shows `about:blank` and the user is stuck

Independent of whether SSH is working. Fallback order: SSH dropdown in web
UI header → SSH from another machine → different browser with hard-refresh
→ give up on web shell and use SSH from a working terminal.

### 10. Mount an ISO on an existing VM but it doesn't show up at boot

The ISO is attached as a CD-ROM device but the VM's boot order may have
the disk first. Either change boot order with
`qm set <vmid> --boot order=ide2,scsi0` (CD first, then disk) or hit
Escape at boot to enter the BIOS menu and pick the CD manually.

### 11. The agent has to ship a multi-line script to the Proxmox host

`scp` works once you have SSH access, but the dropped script may land
owned by the agent user with restrictive perms — root can't execute it.
Self-install perms at the top of the script:

```bash
#!/bin/bash
[[ "$EUID" -ne 0 ]] && exec sudo "$0" "$@"
```

This way `bash /tmp/script.sh` works regardless of how it got there.

### 12. Boot disk wiped by mistake

The single most catastrophic failure mode. Symptoms: the host doesn't
come back after reboot, or worse, comes back but with the OS gone.

This happens when:
- A user pastes a `dd` or `mkfs` command meant for a data drive but
  targets the boot drive.
- The agent's `lsblk` output had `/dev/nvme0n1` as data drive in one
  session but the kernel reordered devices after a reboot, so what was
  `nvme2n1` is now `nvme0n1`.
- `fdisk` is run on the wrong drive because the user picked by `/dev/`
  path instead of serial.

**Prevention:**
- ALWAYS identify drives by SERIAL, never by `/dev/nvmeXnY`. Cross-check
  `lsblk -o NAME,MODEL,SERIAL` before any disk op.
- The agent should refuse to give `fdisk` instructions for any drive
  whose serial matches the boot drive.
- The boot drive has `/boot/efi` and LVM volumes (`pve-root`, `pve-swap`,
  `pve-data` mounted at `/`). If a target drive has any of those, stop.

**Recovery is hard.** If the user has ZFS or btrfs on the boot drive, the
metadata may be recoverable from another live system. If it's plain LVM
(ext4 on LVM), recovery is essentially impossible. This is why prevention
is everything.

### 13. Fresh PVE install: DNS is broken

Default Proxmox network config may have `gateway` pointing at the host's
own IP (self-gateway), which silently breaks all off-subnet traffic.
Fix BOTH:
- `/etc/network/interfaces`: change `gateway` to the real router IP
  (usually `.1` on the subnet — verify with `ip route get 8.8.8.8` from
  a working machine on the same network)
- `/etc/resolv.conf`: point at a working nameserver (1.1.1.1 or the
  router's DNS)

These are NOT persistent across reboot via `sed`; either commit through
the Proxmox web UI (Network → Interfaces → Edit) or write proper
`/etc/network/interfaces.d/*` config.

### 14. `apt update` fails with "Could not resolve host"

This is the DNS-broken symptom (above). The error is at the network
layer, not the apt layer. Don't waste time on apt config; fix the network
first.

### 15. Agent's sudoers has wrong path for `pvesh` or `pvesm`

On PVE 9.x, `pvesh` is `/usr/bin/pvesh` (NOT `/usr/sbin/pvesh`), and
`pvesm` is `/usr/sbin/pvesm` (which IS correct). Many tutorials list both
in `/usr/sbin/`, which silently breaks sudoers rules for `pvesh`. Symptom:
`ssh zen-agent@host 'sudo -n pvesh get /version'` returns
"a password is required" with no other error.

Fix: `command -v pvesh` on the target. Update the sudoers file to the
actual path. Verify with `visudo -c -f /etc/sudoers.d/<agent>`.

### 16. `qm` snapshot succeeded but rollback complains about missing disk

Snapshots on LVM-thin or ZFS are cheap and atomic. Snapshots on `dir`
storage with `qcow2` files are NOT atomic — if the underlying disk image
moves or is moved between storage pools between snapshot and rollback,
rollback fails. Always verify the snapshot's backing storage path with
`qm config <vmid>` before rollback.

### 17. `qm migrate` to another node fails with "local storage not available on target"

The target node needs to have the same storage ID defined locally. The
common homelab case is a single-node setup with `local-lvm` and
`vmdata` — these don't exist on other nodes unless the cluster is
explicitly set up that way. For a single-node homelab, `qm migrate` is
not useful; for migration to work, the target must have the same storage
configured.

## References

- `references/storage-layouts.md` — directory vs LVM-thin vs ZFS, when to
  pick which for a homelab.
- `references/iso-workflow.md` — full worked example of mounting a
  Ventoy USB, copying ISOs, verifying via pvesh, and the disk-full
  emergency triage when the USB is bigger than expected.
- `references/vm-creation-cheatsheet.md` — full `qm create` recipes for
  Ubuntu Server 24.04, Debian 12, cloud-init (Ubuntu cloud image),
  Windows 11 (UEFI + TPM + VirtIO), LXC Debian 12. Plus follow-ups
  (resize disk, add NIC, snapshot, detach ISO with `--ide2 none`).
- `references/firewall-basics.md` — cluster/node/VM firewall hierarchy,
  common rule patterns, why the default pve-firewall blocks everything
  except 22 and 8006.
- `references/proxmox-api-token.md` — using `pveum token` for
  API-based management as an alternative to SSH + sudo.
- `references/cluster.md` — joining nodes to a cluster, quorum,
  HA setup, fencing.

## Scripts

- `scripts/vm-from-iso.sh` — wrapper around `qm create` with sensible
  defaults, prompts for VMID and storage target.
- `scripts/lxc-from-template.sh` — wrapper around `pct create` with the
  common Debian/Ubuntu/Alpine template paths.
- `scripts/iso-import.sh` — Ventoy USB → Proxmox ISO storage with
  pre-flight size check (refuses to overflow the target fs), per-file
  verify, and the `--is_mountpoint no` re-index toggle. Run on the
  Proxmox host as root.
- `scripts/add-nvme-storage.sh` — full pipeline walkthrough: identify
  drives by serial, prompt the user to confirm scope, give fdisk
  instructions for 1-or-2 partition layouts, instruct on mkfs+mount,
  then write UUID-based `/etc/fstab` entries and `pvesm add dir`
  registrations. Runs on the Proxmox host as root. Designed for
  multi-NVMe homelab setups where you have spare drives that need to
  become Proxmox storage pools.
- `scripts/proxmox-status.sh` — one-shot summary: uptime, memory, root
  disk, block devices, Proxmox version, node resources, storage pools,
  VMs, LXC containers, recent pvedaemon/pveproxy errors. Run via SSH
  from the agent host: `ssh zen-agent@<proxmox> 'bash /tmp/proxmox-status.sh'`.
- `scripts/cluster-info.sh` — multi-node summary: cluster status, all
  nodes, all VMs across nodes, HA groups, recent cluster log entries.

## Templates

- `templates/zen-agent-sudoers` — drop-in `/etc/sudoers.d/zen-agent`
  file with the whitelist documented in *Recommended sudoers allowlist*
  above. Validate with `visudo -c -f <path>` before installing.
- `templates/99-zen-agent-sshd.conf` — drop-in sshd Match block for the
  agent user. Key-only auth, no forwarding, IP-restricted.
- `templates/install-sudoers.sh` — script to install and validate the
  sudoers file safely. Run as root on the Proxmox host.

## Cross-Agent Compatibility

This skill is designed to work with any agent that loads
`SKILL.md` from a `skills/` directory. Tested/verified conventions:

| Agent | Skill location | Notes |
|---|---|---|
| Hermes | `~/.hermes/skills/<name>/SKILL.md` | Native. Loaded at session start. |
| Claude Code | `~/.claude/skills/<name>/SKILL.md` | Loaded by Claude Code when SKILL.md is present. |
| Codex CLI | `~/.codex/skills/<name>/SKILL.md` | Auto-loads from description. |
| OpenCode | `~/.config/opencode/skills/<name>/SKILL.md` | Uses OpenAI agent-skills format. |
| OpenClaw | `<workspace>/skills/<name>/SKILL.md` | Auto-loads. Workspace default `~/.openclaw/workspace`. For users on the literal Windows-style path (`C:\Users\kev\.openclaw\workspace`), pass `--openclaw-workspace` to `install.sh`. |
| Cursor | `~/.cursor/skills/<name>/SKILL.md` | Auto-loads. Bundled Cursor skills live in `~/.cursor/skills-cursor/`; user-installed skills go in `~/.cursor/skills/`. |
| Paperclip | (agent-specific) | Check Paperclip docs for skill path. |

Run `./install.sh --agent all` to install into all six at once, or
`./install.sh --agent hermes` for one. The script copies the SKILL.md and
supporting files into the right directory structure for each agent.

OpenClaw notes:
- The user-authored skill format is just `SKILL.md` in a directory — no
  `_meta.json` or `.clawhub/` needed.
- If the skill is later published to ClawHub, those files are added
  by the registry on install.
- The skill must have `name:` and `description:` in the frontmatter.
  Description is shown to the agent and in slash-command discovery —
  keep it under 160 chars for OpenClaw (we're at 722, which is fine
  for the canonical SKILL.md; the auto-discovery only uses the first
  line of the description).
- `openclaw skills list` shows the loaded skills. Source column will
  read `openclaw-workspace` after install.
