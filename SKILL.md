---
name: proxmox-manager-agent
description: "Manage a Proxmox VE homelab (single-node or small cluster) from an AI agent through the PVE API (admin or pool-scoped token) plus root SSH, or a scoped SSH user. Covers VM and LXC lifecycle, cloud-init templates and fast clones, ISO and storage management, backup/restore, network bridges with a dead-man revert timer, firewall, cluster operations, and PVE 9.x gotchas. Includes tested API helpers, a least-privilege token recipe, and a sudoers allowlist template. Use when the user says 'manage my Proxmox', 'spin up a VM', 'make a template', 'add an ISO', 'backup the VMs', 'add storage', 'create an LXC', 'snapshot before I upgrade', or any task touching qm, pct, pvesh, pvesm, vzdump, or pve-firewall on a PVE host."
version: 1.3.0
author: kevwillow
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [proxmox, pve, virtualization, kvm, lxc, homelab, infrastructure, devops]
---

# Proxmox Manager Agent

Operational skill for managing a Proxmox VE host (single-node or small cluster)
from any AI agent — Hermes, Claude Code, Codex, OpenCode, or any headless
runner. It supports three access modes: an admin API token plus root SSH, a
pool-scoped API token, and a scoped SSH user with a sudoers allowlist. The
one-time setup for the scoped SSH user is in the README (*Prerequisites*) and
`templates/`. This skill is the *operational* side: which commands to run, in
what order, with what pitfall-avoidance.

## Operating rules (every mode)

1. **Survey before any write.** Read `GET /version`, `GET /nodes` (node names
   are case-sensitive), `GET /cluster/resources`, storage and pools first.
   Note every guest's tags and `protection` flag.
2. **Own a range, touch nothing else.** Put guests you create in an agreed VMID
   range (for example 8000-8999) with a name prefix and a tag (for example
   `agent`). Never stop, change, roll back or destroy a guest outside that
   range without the user's yes. Guests with `protection=1` or a `keep` tag are
   the user's: leave them alone. When the user wants a guest locked, set
   `protection=1`; destroy then fails until it is cleared.
3. **Read the API schema from the host, not from memory.** Parameters and
   privileges change between releases. `pvesh usage <path> -v` (root SSH)
   prints the live parameters, and the API viewer is at
   `https://<host>:8006/pve-docs/api-viewer/`.
4. **Wait for every task.** Most writes return a task ID (UPID). Check its exit
   status before the next step. A write you did not wait for is not done.
5. **Keep secrets in files.** Read the token and passwords from mode-600 files
   and never print them. UPIDs and logs contain the token ID (`user@realm!id`),
   which is not secret; the token value is.
6. **Confirm before anything irreversible**, in every mode. Admin rights change
   what the agent CAN do, not what it does without asking. See *Soft blacklist*.

## When to Use

- User says "manage my Proxmox," "spin up a VM," "add an ISO," "backup the VMs,"
  "create an LXC," "add storage," "snapshot before I upgrade," "what's running
  on my proxmox," or any equivalent.
- A task touches any of: `qm`, `pct`, `pvesh`, `pvesm`, `vzdump`, `pve-firewall`,
  `ha-manager`, `pvecm`, `qemu-img`, on a PVE 8.x or 9.x host.

**Don't use for:** generic Linux sysadmin, non-Proxmox virtualization
(KVM/libvirt without the PVE wrapper, Xen, ESXi), or a host where the user has
not yet chosen and set up an access mode below.

## Access modes

### Mode A: Admin (recommended when the user wants the agent to fully manage VMs)

Use a PVE user `<agent>@pve` with the `Administrator` role on `/` and an API
token with `privsep=0` for everything the API covers. Add a dedicated root SSH
key for host-level work the API cannot do, including root@pam-only VM options
such as `args` and `hookscript`, host packages, and `/etc/network/interfaces`.

Bootstrap this mode as follows:

1. Save the root@pam password in a mode-600 file, for example
   `~/.config/pve/<host>.password`; never put it on a command line.
2. Pin the host certificate and request a ticket. `-k` is needed for the
   self-signed certificate, while `--pinnedpubkey` still enforces the pin.

   ```bash
   PIN=$(echo | openssl s_client -connect $H:8006 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
   curl -s -k --pinnedpubkey "sha256//$PIN" https://$H:8006/api2/json/access/ticket \
     --data-urlencode 'username=root@pam' --data-urlencode "password@$PWFILE"
   ```

3. With cookie `PVEAuthCookie=<ticket>` and header
   `CSRFPreventionToken: <csrf>`, create the user and grant it access:

   ```text
   POST /access/users            userid=<agent>@pve
   PUT  /access/acl              path=/ users=<agent>@pve roles=Administrator propagate=1
   POST /access/users/<agent>@pve/token/agent   privsep=0
   ```

   The final response's `.data.value` is the token secret and is shown only
   once. Write the whole header value straight to a mode-600 file without
   printing it, and save the pin (with its `sha256//` prefix) the same way:

   ```bash
   install -m 600 /dev/null ~/.config/pve/<host>.token
   jq -j '"PVEAPIToken=\(.data["full-tokenid"])=\(.data.value)"' token-response.json > ~/.config/pve/<host>.token
   rm token-response.json
   install -m 600 /dev/null ~/.config/pve/<host>.pin
   printf 'sha256//%s' "$PIN" > ~/.config/pve/<host>.pin
   ```
4. Install the root SSH key without `sshpass`, using OpenSSH askpass. On PVE,
   `/root/.ssh/authorized_keys` is a symlink to
   `/etc/pve/priv/authorized_keys`.

   ```bash
   SSH_ASKPASS=<script-that-cats-the-password-file> SSH_ASKPASS_REQUIRE=force DISPLAY=x \
     setsid -w ssh -o PubkeyAuthentication=no root@$H 'cat >> /root/.ssh/authorized_keys'
   ```

5. Delete the password file.

Use the token through the helpers in `scripts/pve-api.sh`: pinned TLS, token
read from its file on each call, and a task wait that fails loudly. Node names
are case-sensitive (`pve` and `PVE` are different nodes); read them from
`GET /nodes`.

```bash
export PVE_HOST=<host> PVE_TOKEN_FILE=~/.config/pve/<host>.token PVE_PIN_FILE=~/.config/pve/<host>.pin
source scripts/pve-api.sh

pve_api GET '/cluster/resources?type=vm'
pve_api GET '/nodes/<node>/status'
upid=$(pve_api POST '/nodes/<node>/qemu/<vmid>/clone' --data-urlencode 'newid=<new-vmid>' | jq -r .data)
pve_wait "$upid" 300      # prints the exit status; returns 0 only on "OK", 1 on failure (task log to stderr), 2 on timeout
pve_vm_ip <node> <new-vmid> 180   # first IPv4 from the guest agent, polling until it answers
```

A write that fails its permission check returns HTTP 403 with no UPID, and
the body names the missing privilege and path, for example
`Permission check failed (/sdn/zones/localnetwork/vmbr0, SDN.Use)`. `pve_wait`
returns 1 at once when it gets no UPID; read the response for the reason.

### Mode A-narrow: pool-scoped API token (real containment)

Mode A and Mode B are both root-equivalent. When the agent only needs to run
its own guests, give it a token that can touch nothing else: a resource pool
for its guests plus four built-in roles. Run as an admin:

```text
POST /pools                 poolid=agent
POST /access/users          userid=agent@pve
POST /access/users/agent@pve/token/t1    privsep=0     # save .data.value as in Mode A step 3
PUT  /access/acl  path=/pool/agent                       users=agent@pve roles=PVEVMAdmin
PUT  /access/acl  path=/storage/<vm-storage>             users=agent@pve roles=PVEDatastoreUser
PUT  /access/acl  path=/sdn/zones/localnetwork/<bridge>  users=agent@pve roles=PVESDNUser
PUT  /access/acl  path=/vms/<template-vmid>              users=agent@pve roles=PVETemplateUser
```

Then clone with `pool=agent` so each new guest lands inside the token's reach.
Measured on PVE 9.2.2:

- The token sees only what it is granted: `GET /cluster/resources` listed the
  template alone, and reading a guest outside the pool returned
  `403 Permission check failed (/vms/<vmid>, VM.Audit)`.
- Without the `/sdn/zones/localnetwork/<bridge>` grant, a clone fails with
  `403 ... SDN.Use` even when no SDN is configured. Plain Linux bridges sit in
  the built-in `localnetwork` zone.
- `PVEVMAdmin` on PVE 9 includes `VM.GuestAgent.Unrestricted`, which lets the
  token run commands as root inside its guests through the guest agent. If
  that is too much, copy the role without it.
- `VM.Monitor` no longer exists on PVE 9. Custom roles that list it must drop it.

Not measured here: the full clone-and-start run with all four grants in
place. Run that once on your host before relying on this mode.
The token cannot set root-only options (`args`, `hookscript`, host devices)
and cannot change the host; keep root SSH for that, or have the user do it.

### Mode B: Scoped SSH user

A dedicated non-root SSH user (the templates call it `zen-agent`) with a
sudoers allowlist, key-only authentication, source-IP restriction, and audit
trail. It is described in the architecture and command sections below.

Rehearsed end to end on Debian 13 (PVE 9's base) with the templates:

- **Stock PVE 9 has no `sudo`.** The user installs it first (`apt install
  sudo`); `templates/install-sudoers.sh` stops with that message otherwise.
- **Restrict the source IP on the key, not in sshd.** Prefix the key in
  `authorized_keys` with `from="<agent-ip>",restrict,pty`. Measured: a wrong
  source IP is refused, `restrict` blocks port forwarding, `pty` keeps a
  terminal. A `Match User ... Address <range>` block in sshd only changes
  settings for that range and denies nobody: a login from outside the range
  still succeeded.
- **The allowlist really is root-equivalent:**
  `sudo -n find /tmp -maxdepth 0 -exec id -u \;` printed `0`.
- **Audit lives in the journal.** PVE 9 has no `/var/log/auth.log`. Use
  `journalctl _COMM=sudo` for commands and `sudoreplay -l` for the
  input/output sessions that `log_input, log_output` record.

The confirmation policy, including the soft blacklist, applies in EVERY mode.

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
│   audit: journalctl _COMM=sudo; sudoreplay -l (I/O sessions)    │
└─────────────────────────────────────────────────────────────────┘
```

For Mode B only, the agent never logs in as root and never has a root password.
Every action goes through the scoped user with a sudoers allowlist. A leaked key
still requires the right source IP and the agent user still exists with the same
blast radius. This allowlist is ROOT-EQUIVALENT, so it is an audit trail and a
speed bump rather than containment. See *Access modes* for Mode A.

## The Command Surface

### Binary locations (PVE 8/9)

| Binary | Path | Purpose |
|---|---|---|
| `qm` | `/usr/sbin/qm` | KVM/QEMU VM management |
| `pct` | `/usr/sbin/pct` | LXC container management |
| `pvesh` | **`/usr/bin/pvesh`** | Proxmox API CLI (preferred for scripted ops) |
| `pvesm` | `/usr/sbin/pvesm` | Storage manager |
| `vzdump` | `/usr/bin/vzdump` | Backup |
| `qemu-img` | `/usr/bin/qemu-img` | Raw disk image operations |
| `pveum` | `/usr/sbin/pveum` | User/permission manager |
| `pvecm` | `/usr/bin/pvecm` | Cluster manager |
| `ha-manager` | `/usr/sbin/ha-manager` | HA (high availability) manager |
| `pve-firewall` | `/usr/sbin/pve-firewall` | Firewall rules compiler |
| `pveam` | `/usr/bin/pveam` | Appliance manager (templates, ISOs) |
| `qmrestore` | `/usr/sbin/qmrestore` | Restore from vzdump backup |
| `vma` | `/usr/bin/vma` | VMA archive verification |

`pvesh`, `pveam`, `vzdump`, `qemu-img` and `pvecm` are in `/usr/bin` on PVE
9.x; most tutorials list `/usr/sbin`. A sudoers rule with the wrong path
silently falls through to "ask for a password"; see pitfall #15 for the
diagnose-and-fix recipe.

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
# │ pve    │ online │ 0.17% │
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
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/vzdump *
zen-agent ALL=(ALL) NOPASSWD: /usr/sbin/qmrestore *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/qemu-img *
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
Defaults:zen-agent log_input, log_output, env_reset, always_set_home
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

The pattern: **observe freely, manage Proxmox state freely, but destructive
disk operations and host-state changes require a human in the loop.** This
allowlist is ROOT-EQUIVALENT, not containment: `find *` allows `-exec` of any
command as root, `pvesh *` runs as root@pam and can create users and ACLs,
`mount *` can mount over system paths, and `qm *` can set hookscripts. It is an
audit trail and a speed bump. If real containment is needed, use a PVE API token
with a narrow role, for example `PVEVMAdmin` on `/vms`, instead of sudo.

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

Sudoers (or the token) says yes; the agent layer says "ask first."

### How the agent should *think* about the whitelist

When the user says "spin up a VM," the agent's actual command sequence is:

1. **Verify sudoers covers what we need:** `sudo -n -l | grep -E '^.*NOPASSWD.*qm '` — if this returns nothing, stop and tell the user to install the sudoers file.
2. **Verify SSH works with key-only:** `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i <key> zen-agent@<host> 'whoami'` — if this fails, stop (and see pitfall #24 before retrying).
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

# Copy, run as root (user in Mode B, root SSH in Mode A).
# A dir storage's ISO directory is <path>/template/iso/.
mkdir -p <path>/template/iso
cp /mnt/source/*.iso <path>/template/iso/

# Verify via pvesh
pvesh get /nodes/<node>/storage/<storage>/content --content iso
```

The API can fetch an ISO straight onto the host:

```text
POST /nodes/<node>/storage/<storage>/download-url  content=iso filename=<name> url=<url> [checksum=<sum> checksum-algorithm=sha256]
```

**Always check `df -h /` before a bulk copy.** Ventoy USBs can easily hold
30–60GB; the default `local` storage backing `/var/lib/vz` may not have that
much free. The `scripts/iso-import.sh` wrapper enforces this with a hard
pre-flight abort.

**Strongly prefer copying ISOs to a dedicated NVMe storage pool
(`/mnt/iso/template/iso/`) rather than `/var/lib/vz/template/iso/` on the boot disk.**
A 9-ISO Ventoy stick can easily total 30-60GB; the Proxmox boot disk is
typically 60-70GB total, so a single copy fills it from 8% to 100% and
breaks the system. See *Adding dedicated storage pools* below.

### Adding dedicated storage pools

When the host has additional NVMe drives that should be Proxmox storage,
the full pipeline is: wipe → partition → format → mount → register with
pvesm. The agent drives this end-to-end with the user running the
destructive steps (the agent's safety policy blocks `mkfs`, `parted`, `dd`
by design — see *Explicit blacklist* above).

**API shortcut (Mode A).** List drives with their serials without a shell:

```bash
pve_api GET /nodes/<node>/disks/list | jq -c '.data[] | {devpath, model, serial, size, used, wearout}'
```

`wearout` is the percentage of life **remaining** (100 = new), not used.
`used` says what Proxmox found on the drive (`BIOS boot`, `LVM`, `ext4`,
`partitions`). Before proposing to stage a drive, look
read-only at what it holds (`wipefs -n /dev/<dev>`, `smartctl -H /dev/<dev>`,
or a read-only mount and `ls`). If it holds anything that looks like real data
(home directories, VM disks, databases, documents), stop and ask.

With the user's yes, one API call wipes a drive and creates registered storage:

```text
POST /nodes/<node>/disks/lvmthin    device=/dev/<dev> name=<storage-id> add_storage=1    # VM disks
POST /nodes/<node>/disks/directory  device=/dev/<dev> name=<storage-id> filesystem=ext4 add_storage=1
```

Both destroy everything on the drive, exactly like `mkfs`, so they carry the
same confirmation as the manual path: name the drive by **serial**, show its
`used` value, and wait for an explicit yes. Re-read `/disks/list` right before
the call, because `/dev/nvmeXnY` numbers can change across reboots. The
directory variant mounts the drive with a systemd mount unit under
`/mnt/pve/<storage-id>`; add the content types you need afterwards with
`PUT /storage/<storage-id> content=iso,import,backup,snippets`.

**Step 1: Identify drives and confirm scope.**

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL,WWN
```

Show the user the boot disk's serial and mark it OUT-OF-SCOPE explicitly.
Reference drives by **serial** (e.g. `S413NS0RC03383M`), NOT by
`/dev/nvmeXnY` — NVMe device numbers shuffle across reboots. The boot disk
in the typical homelab config is identifiable by containing `/boot/efi`
and LVM volumes (`pve-root`, `pve-swap`, `pve-data`).

The user runs steps 2-4 as root at the host's console or root shell. Stock
PVE 9 has no `sudo`, so they drop the `sudo` prefix shown below unless they
installed it.

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

**Step 5: Add a UUID-based fstab entry (NEVER `/dev/nvmeXnYp1`) as root
(user in Mode B, root SSH in Mode A).**

```bash
UUID=$(blkid -s UUID -o value /dev/nvmeXnYp1)
echo "UUID=$UUID /mnt/<label> ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
mount -a
df -h | grep <label>
```

The shell redirects `>>` before sudo runs, so `tee` needs root to append to
`/etc/fstab`.

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

For ISO content in a `dir` storage, create the required subdirectory and copy
files there:

```bash
mkdir -p /mnt/<label>/template/iso
# Copy as root (user in Mode B, root SSH in Mode A).
cp <source>.iso /mnt/<label>/template/iso/
sudo -n pvesm list <name>   # verifies content discovered by directory scan
```

Proxmox keeps no index for `dir` storage; it scans the content-specific
subdirectories on each request. Files outside `template/iso/` are simply not
listed as ISOs. `--is_mountpoint yes` only marks the storage inactive when the
path is not a mount point; it does not rescan anything.

The `scripts/add-nvme-storage.sh` wrapper runs this full pipeline with
explicit prompts at every destructive step.

### Creating dev VMs fast: cloud-init template + clone

Use a cloud-init template when you want a VM without a console: the user,
SSH key and network are injected at first boot and a clone takes seconds.

Verified end to end on PVE 9.2.2 on 2026-10-03 with 16 cloud images: Ubuntu
22.04/24.04/26.04, Debian 11/12/13, Rocky and Alma 8/9/10, Fedora 44,
openSUSE Leap 15.6 and Tumbleweed, Amazon Linux 2023. Every one went from
clone to an IP from the guest agent in 21-43 seconds, with SSH and sudo
working. The recipe below, exactly as written, was re-run for Ubuntu 24.04
on 2026-10-07: template built, linked clone, IP and SSH in 46 seconds. Each
write returns a UPID; `pve_wait` it.

```bash
# 1. Fetch the image onto the host, checksum-verified. Saved with a .qcow2 name.
pve_api POST /nodes/<node>/storage/local/download-url \
  --data-urlencode content=import --data-urlencode filename=ubuntu-26.04-server-cloudimg-amd64.qcow2 \
  --data-urlencode url=https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img \
  --data-urlencode checksum=<sha256 from SHA256SUMS> --data-urlencode checksum-algorithm=sha256

# 2. A vendor snippet that makes sure qemu-guest-agent is installed and running.
#    The agent is what reports the VM's IP to /agent/network-get-interfaces.
pve_api PUT /storage/local --data-urlencode content=vztmpl,iso,import,backup,snippets
ssh root@<host> 'mkdir -p /var/lib/vz/snippets; printf "#cloud-config\npackage_update: true\npackages: [qemu-guest-agent]\nruncmd:\n  - [systemctl, enable, --now, qemu-guest-agent]\n" > /var/lib/vz/snippets/vendor-guest-agent.yaml'

# 3. Template VM. sshkeys must be URL-encoded BEFORE --data-urlencode encodes it again.
#    ciupgrade=0: see the note below.
KEYS=$(cat ~/.ssh/id_ed25519.pub | jq -sRr @uri)
pve_api POST /nodes/<node>/qemu --data-urlencode vmid=9000 --data-urlencode name=ubuntu-2604-tmpl \
  --data-urlencode memory=2048 --data-urlencode cores=2 --data-urlencode cpu=host --data-urlencode ostype=l26 \
  --data-urlencode scsihw=virtio-scsi-single \
  --data-urlencode 'scsi0=local-lvm:0,import-from=local:import/ubuntu-26.04-server-cloudimg-amd64.qcow2,discard=on,ssd=1,iothread=1' \
  --data-urlencode ide2=local-lvm:cloudinit --data-urlencode boot=order=scsi0 \
  --data-urlencode serial0=socket --data-urlencode vga=serial0 --data-urlencode agent=enabled=1 \
  --data-urlencode net0=virtio,bridge=vmbr0 --data-urlencode ciuser=<user> --data-urlencode "sshkeys=$KEYS" \
  --data-urlencode ipconfig0=ip=dhcp --data-urlencode ciupgrade=0 \
  --data-urlencode cicustom=vendor=local:snippets/vendor-guest-agent.yaml
# The imported disk is only as big as the image (about 3.5 GB). Grow it before
# converting, or every clone starts nearly full.
pve_api PUT  /nodes/<node>/qemu/9000/resize --data-urlencode disk=scsi0 --data-urlencode size=20G
pve_api POST /nodes/<node>/qemu/9000/template

# 4a. Throwaway test VM: linked clone (full=0). Near-instant on LVM-thin, ZFS or
#     Ceph, and it uses almost no space. Must live on the template's storage.
pve_api POST /nodes/<node>/qemu/9000/clone --data-urlencode newid=<vmid> --data-urlencode name=<name> \
  --data-urlencode full=0
# 4b. Long-lived VM: full clone, independent of the template, then size it.
pve_api POST /nodes/<node>/qemu/9000/clone --data-urlencode newid=<vmid> --data-urlencode name=<name> \
  --data-urlencode full=1 --data-urlencode storage=<vm-storage>
pve_api PUT  /nodes/<node>/qemu/<vmid>/config --data-urlencode cores=4 --data-urlencode memory=8192 --data-urlencode onboot=1
pve_api PUT  /nodes/<node>/qemu/<vmid>/resize --data-urlencode disk=scsi0 --data-urlencode size=64G

# 5. Start, then poll the guest agent for the IP.
pve_api POST /nodes/<node>/qemu/<vmid>/status/start
pve_vm_ip <node> <vmid> 180
```

cloud-init grows the root filesystem to the resized disk on first boot. The
`qm` CLI equivalents are in `references/vm-creation-cheatsheet.md`.

**Template lessons:**

- **`ciupgrade` defaults to 1**: a full package upgrade on first boot. It took
  1-5 minutes per distro and filled an unresized 3.5 GB disk. Proxmox puts it
  in the generated *user* data as `package_upgrade: true`, so a `cicustom
  vendor=` snippet does not turn it off. Set `ciupgrade=0` on test templates;
  set `ciupgrade=1` on a long-lived clone if you want it patched at birth.
- **Guest agent by distro family.** Ubuntu, Debian and openSUSE cloud images
  lack `qemu-guest-agent`; the snippet above installs it. Rocky, Alma and
  Fedora ship it, but a snippet with only
  `runcmd: [[systemctl, enable, --now, qemu-guest-agent]]` is still the safe
  way to make sure it runs. Without the agent, `pve_vm_ip` times out.
- **Password login.** `cipassword` sets the password, but most cloud images
  turn off SSH password authentication. Add `ssh_pwauth: true` to the snippet
  if the user wants to log in with a password. Write any password file with
  `printf '%s'`, never `echo`, or a trailing newline becomes part of the
  password.
- **End-of-life distros.** Once a release is EOL its security mirror can
  return 404 and first-boot `apt` fails. Point apt at the archive mirror
  (for Debian, `archive.debian.org`) with `write_files` in a snippet. The
  `apt:` module can conflict with images that set
  `apt_preserve_sources_list: true`.
- **Do not delete a template that has linked clones.** Measured on LVM-thin:
  Proxmox allowed it, removed the template's disks, and the clone kept
  running, because a thin snapshot does not depend on its origin. On ZFS
  or qcow2 file storage a linked clone reads from the template's base disk, so
  there it is not safe. Use full clones for anything long-lived.
- **IPs come from DHCP.** Re-read them from the guest agent after any reboot
  instead of caching them.
- **A cloned guest can lose its cloud-init drive** when the template's
  cloud-init disk sits on different storage from the clone target (reported on
  the Proxmox forum). Keep the template's disks on one storage, or re-add
  `ide2=<storage>:cloudinit` on the clone.

### Creating a VM from an ISO

```bash
# 1. Pick a free VMID in your range (or ask Proxmox: pvesh get /cluster/nextid)
VMID=<vmid>

# 2. Create with sensible defaults
sudo -n qm create $VMID \
    --name "ubuntu-test" \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --scsi0 local-lvm:32 \
    --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom \
    --boot "order=scsi0;ide2" \
    --ostype l26

# 3. Start it
sudo -n qm start $VMID

# 4. See the screen without a browser (root): save a screenshot, then view it
echo "screendump /tmp/vm-$VMID.ppm" | qm monitor $VMID
```

`order=scsi0;ide2` boots the disk first; an empty disk falls through to the
installer, and the installed system boots on the next start. Eject the ISO
afterwards with `qm set <vmid> --ide2 none,media=cdrom`. The `screendump`
screenshot is how an agent checks what a console-only VM is showing (convert
the PPM to PNG to view it). Measured: a Debian 13 netinst VM built this way
showed its installer menu.

Use `scripts/vm-from-iso.sh` for a one-shot wrapper.

Full `qm create` recipes for common distros (Ubuntu 24.04, Debian 12,
cloud-init, Windows 11 with UEFI+TPM) live in
`references/vm-creation-cheatsheet.md`.

### Creating an LXC container

```bash
# 1. Update the template list, find the current name, download it.
#    The list includes arm64 builds; pick the one matching the host.
sudo -n pveam update
sudo -n pveam available --section system | grep -E 'debian-13.*amd64'
sudo -n pveam download local <template-name>

# 2. Create the container (key-based root login; no password on the command line)
sudo -n pct create <ctid> local:vztmpl/<template-name> \
    --hostname debian-ct \
    --memory 1024 \
    --cores 2 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --rootfs vmdata:16 \
    --features nesting=1 \
    --unprivileged 1 \
    --ssh-public-keys /root/agent.pub \
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

**Snapshots and rollback, measured on PVE 9.2.2:**

- A snapshot taken without RAM (`vmstate=0`, the default) rolls back to a
  **stopped** VM. Start it again yourself, and check `status/current` rather
  than assuming it is up.
- Right after a rollback, a start can fail with `can't lock file` while
  Proxmox finishes its cleanup. Retry a few times, 10-15 seconds apart, before
  calling it a failure.
- Guests without `onboot=1` stay off after the host reboots. After any host
  reboot, list what is stopped and ask before starting the user's guests.
- `protection=1` makes destroy and disk removal fail until it is cleared. Use
  it on anything the user calls important.

### Backups

```bash
# One-shot backup of a single VM (Mode A: POST /nodes/<node>/vzdump vmid=<vmid> ... returns a UPID)
sudo -n vzdump <vmid> --storage <backup-storage> --mode snapshot --compress zstd

# One-shot backup of all VMs on a node
sudo -n vzdump --all 1 --storage <backup-storage> --mode snapshot --compress zstd

# Schedule via the GUI or /cluster/backup; the agent should usually defer
# scheduling to the user since it requires decisions about retention,
# offsite targets, etc.
```

**Checking a backup, measured on PVE 9.2.2.** Three checks catch different
failures; only the last one proves the data:

| Check | Catches | Misses |
|---|---|---|
| `zstd -tq <file>.vma.zst` | bit rot in the stored file (vzdump writes an XXH64 checksum) | anything wrong before compression |
| `zstd -dc <file>.vma.zst \| vma verify -` | truncation, damaged headers and structure | corrupted VM data: 4 of 4 archives with flipped data bytes passed |
| restore to a scratch VMID and read known data | everything above, plus whether it boots | — |

Run `vma verify` on a stream as above. Do not decompress to `/tmp`: on PVE 9
`/tmp` is a RAM-backed tmpfs, so a large backup fills memory. In a pipeline,
check every stage (`set -o pipefail`), not just the last.

Restore test without disturbing the original (tested end to end):

```bash
# 1. Restore to a scratch VMID. unique=1 gives the copy a new MAC address.
pve_api POST /nodes/<node>/qemu --data-urlencode vmid=<scratch> \
  --data-urlencode archive=<storage>:backup/vzdump-qemu-<vmid>-<ts>.vma.zst \
  --data-urlencode storage=<vm-storage> --data-urlencode unique=1
# 2. Unplug its network before first boot, then start it.
pve_api PUT /nodes/<node>/qemu/<scratch>/config --data-urlencode "net0=<existing net0 value>,link_down=1"
pve_api POST /nodes/<node>/qemu/<scratch>/status/start
# 3. Read a file you know the answer to through the guest agent (no network needed).
pve_api GET "/nodes/<node>/qemu/<scratch>/agent/file-read?file=/etc/hostname" | jq -r .data.content
```

**Why unplug it:** a restored copy keeps the original's `/etc/machine-id`.
On Ubuntu 24.04 (systemd-networkd) the DHCP client ID is derived from it, so
even with a new MAC the router handed the copy the original's IP while the
original was still running (measured: two VMs on one address). This is
systemd-networkd's default (a DUID-based client ID); the CLIENTID in the
copy's lease file was that DUID. `unique=1` alone does not prevent this. If the copy must join the network, regenerate its identity first, then
clear `link_down` and reboot:
`rm /etc/machine-id /var/lib/dbus/machine-id && systemd-machine-id-setup`
(run it from the console, or `qm guest exec <scratch> -- sh -c '...'`, while
the link is down). Measured: after this and a reboot the copy got its own
address.

Restoring over the original VMID replaces it and is irreversible: confirm
first, and prefer a scratch VMID.

### Changing host networking with a dead-man switch

A wrong bridge, VLAN or address change on the management interface cuts the
agent off, and nobody is left to undo it. Arm a revert timer first, apply,
verify from the agent's side, and only then disarm. Mode A, root SSH:

```bash
# 0. Refuse to start if someone else has pending, unapplied network changes.
ssh root@<host> 'test ! -e /etc/network/interfaces.new || { echo "pending changes exist"; exit 1; }'

# 1. Back up and arm a 120 s revert. AccuracySec=1s matters: systemd timers
#    default to 1 minute of slack, so a "120 s" timer can fire much later.
ssh root@<host> 'cp -a /etc/network/interfaces /root/interfaces.pre-agent &&
  systemd-run --unit=net-revert --on-active=120 --timer-property=AccuracySec=1s \
    /bin/sh -c "cp -a /root/interfaces.pre-agent /etc/network/interfaces && ifreload -a"'

# 2. Stage and apply through the API (staged changes go to /etc/network/interfaces.new).
pve_api POST /nodes/<node>/network --data-urlencode iface=vmbr10 --data-urlencode type=bridge --data-urlencode autostart=1
upid=$(pve_api PUT /nodes/<node>/network | jq -r .data); pve_wait "$upid" 60

# 3. Verify over the SAME path the agent uses, then disarm.
ssh -o ConnectTimeout=5 root@<host> true &&
  pve_api GET /nodes/<node>/network/vmbr10 | jq -e '.data.active == 1' >/dev/null &&
  ssh root@<host> 'systemctl stop net-revert.timer'
```

If step 3 fails, do nothing: the timer restores the old file and reloads.
`DELETE /nodes/<node>/network` discards staged changes that were never applied.
Tested on PVE 9.2.2: the transient timer fires on time and `systemctl stop`
disarms it. A real lockout being reverted was not exercised for this release;
try the recipe on a harmless change (an unused bridge) before trusting it.

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

# Switches live under /options. The datacenter switch is the master: node and
# VM rules are not enforced while it is off (the default).
sudo -n pvesh set /cluster/firewall/options --enable 1
# A VM's rules also need its firewall enabled and firewall=1 on each NIC:
sudo -n pvesh set /nodes/<node>/qemu/<vmid>/firewall/options --enable 1
```

**Default behavior on a fresh PVE install:** firewall is OFF by default at the
datacenter level. Once enabled, the default input policy is DROP, with SSH (22)
and the web UI (8006) allowed from the auto-detected `local_network` alias
(`pve-firewall localnet` shows it). Enabling it is a lockout risk: arm the
dead-man revert above first. See
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

# PVE 9: HA groups are replaced by HA rules (node and resource affinity).
# Existing groups migrate automatically once every node runs PVE 9.
sudo -n ha-manager rules list
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
| Snapshotted VM | `qm listsnapshot <vmid>` lists the new snapname |
| Created LXC | `pct list`, then `pct status <ctid>` |
| Added storage | `pvesm status` shows the new storage, `df -h /mnt/<mount>` shows correct size |
| Imported ISO | `ls /var/lib/vz/template/iso/` shows the file, `pvesh get /nodes/.../storage/local/content --content iso` lists it |
| Created backup | `ls /var/lib/vz/dump/` shows the .vma.zst file |
| Restored backup | `qm list` shows new VMID, `qm status <new-vmid>` reports running |
| Edited firewall | `pvesh get /nodes/<node>/firewall/rules` shows the new rule, test from allowed source |

**Always verify the *full* state, not just the immediate operation.**
A common failure mode is the operation succeeding but a downstream effect
(notify, content placement, replication) silently failing. Example: `pvesm add
dir` succeeds but an ISO copied outside `template/iso/` does not appear in the
web UI dropdown. The Verify column above is the "did this actually take effect
everywhere" check.

## Common Pitfalls

A numbered list of mistakes and their fixes. Read the relevant one BEFORE
running the corresponding operation.

### 1. `pvesm scan <storage-id>` does NOT exist on PVE 9.x

The help banner shows `scan cifs/iscsi/lvm/lvmthin/nfs/pbs/zfs` only. Older
docs and AI agents trained on PVE 7/8 will tell you to use
`pvesm scan iso` to refresh a storage index, but that command does not exist.
`dir` storage has no index: Proxmox scans its required content directories on
each request. For ISO content, use `<path>/template/iso/`; see pitfall #4.

### 2. The `enterprise.proxmox.com` repos fail with 401 Unauthorized on every `apt update`

Expected on any PVE host without a paid subscription key. Debian packages
still install, but the host gets **no Proxmox updates** until a working
Proxmox repository is configured. PVE 9 uses deb822 files:
`/etc/apt/sources.list.d/pve-enterprise.sources` and `ceph.sources`. To switch,
add an `Enabled: no` line to each enterprise entry and add
`/etc/apt/sources.list.d/proxmox.sources`:

```text
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
```

This changes where the host's updates come from, so it is the user's call.
The agent proposes it and runs it only with a yes.

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

For a `dir` storage, Proxmox lists ISOs only from `<path>/template/iso/`.
If a file was copied to the storage root, `pvesm list <name>` will show no
ISO even though `ls` shows the file.

Fix: `mkdir -p <path>/template/iso` and move or copy the ISO there. There is
no content index to refresh: Proxmox scans that directory on each request.
`--is_mountpoint yes` is a mount check only; it marks the storage inactive if
the path is not mounted and does not rescan content.

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

### 7. ISO copy needs root even though sudoers does not allow `cp`

The Mode B allowlist intentionally does not permit `cp`, so an ISO upload must
run as root: the user runs it in Mode B, or the agent uses root SSH in Mode A.
For a `dir` storage, create and use `/mnt/iso/template/iso/`, not the storage
root. Verify the destination with `pvesh get /nodes/<node>/storage/<storage>/content --content iso`.

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
the disk first. Change the boot order with
`qm set <vmid> --boot "order=ide2;scsi0"` (devices are separated by `;`, not
`,`), or press Escape at boot and pick the CD from the menu.

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

### 15. Agent's sudoers has wrong binary path

On PVE 9.x, `pvesh`, `pveam`, `vzdump`, `qemu-img`, and `pvecm` are in
`/usr/bin`, while `pvesm` remains in `/usr/sbin`. Many tutorials list them
all in `/usr/sbin`, which silently breaks sudoers rules. Symptom:
`ssh zen-agent@host 'sudo -n pvesh get /version'` returns
"a password is required" with no other error.

Fix: run `command -v` for every sudoers binary on the target. Update the
sudoers file to the actual paths. Verify with
`visudo -c -f /etc/sudoers.d/<agent>`.

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

### 18. A network probe on the host says "blocked" but the port is open

`/bin/sh` on a PVE host is `dash`, which has no `/dev/tcp`. A probe such as
`sh -c 'echo > /dev/tcp/10.0.0.1/22'` fails whatever the port does. Run
probes with bash: `timeout 3 bash -c '</dev/tcp/<ip>/<port>'`.

### 19. A laptop used as a PVE host vanishes from the network

By default logind suspends a laptop when its lid closes, and a suspended host
takes every guest down with it and may not wake on its own. On a laptop host,
with the user's yes, add `/etc/systemd/logind.conf.d/10-lid-ignore.conf`:

```ini
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

When any host drops off the network unexpectedly, read the previous boot's
log first: `journalctl -b -1 -n 50`.

### 20. A VPN client on the host rewrites `/etc/resolv.conf`

Proxmox manages the host's DNS (Node → System → DNS). A VPN client that also
manages DNS can overwrite it and break name resolution for the host. For
Tailscale, use `tailscale set --accept-dns=false`.

### 21. VM disks ended up on the boot drive or a slow drive

The installer's `local-lvm` shares the boot drive, so a full VM disk can fill
it. Cheap drives can also write far slower than they read. Keep VM disks on
dedicated storage, and move a disk while the VM runs:

```text
POST /nodes/<node>/qemu/<vmid>/move_disk  disk=scsi0 storage=<target> delete=1
```

`delete=1` removes the source copy after a successful move. Without it the old
disk stays behind as an `unused` entry.

### 22. Guest NIC names do not follow Proxmox's `net0`, `net1` order

Inside the guest, `eth0` is not always `net0`; some router and firewall
images enumerate NICs in a different order. Match interfaces by MAC address
(`GET /nodes/<node>/qemu/<vmid>/config` shows `netN=virtio=<MAC>,...`).

### 23. A serial console shows nothing, or garbled lines

With `serial0=socket`, output written while nothing is attached is lost, so
a boot can look silent. Attach before starting the guest (`qm terminal
<vmid>`; exit with Ctrl-O), and send long commands in short pieces.

### 24. SSH suddenly answers `kex_exchange_identification: Connection reset by peer`

OpenSSH 9.8+ (PVE 9's is 10.0) has `PerSourcePenalties` on by default:
every failed login adds a temporary block on the client's IP (PVE 9.2 ships
`authfail:5 ... max:600`, so up to 10 minutes). An agent whose SSH client
offers several keys from an agent or `~/.ssh` hits "Too many authentication
failures", and retrying makes the block longer. Measured: a handful of quick
failures got the agent's IP dropped on every connection; the block had cleared
by the next attempt, under a minute later. The target's journal shows
`drop connection ... penalty: failed authentication`.

Fix: always pass `-o IdentitiesOnly=yes -i <key>`, stop retrying on the first
failure, and wait before the next attempt.

### 25. LVM warns that thin volumes exceed the pool size

`WARNING: Sum of all thin volume sizes (...) exceeds the size of thin pool` is
normal with thin provisioning: disks only use what they write. The danger is
the pool actually filling, which pauses or corrupts every guest on it. Watch
the real usage, not the sum of disk sizes:

```bash
pve_api GET /nodes/<node>/storage/<lvmthin-storage>/status | jq '.data | {used, total}'
lvs -o lv_name,data_percent,metadata_percent <vg>    # root SSH; the pool's data% and meta%
```

Stop and tell the user before a write would push the pool past about 80%.

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
  common rule patterns, and the default behavior once pve-firewall is enabled.
- `references/proxmox-api-token.md` — creating, scoping and revoking API
  tokens with `pveum`, including the pool-scoped least-privilege setup.
- `references/cluster.md` — joining nodes to a cluster, quorum,
  HA setup, fencing.

## Scripts

- `scripts/pve-api.sh` — source it for `pve_api` (pinned TLS, token read from
  a file per call), `pve_wait` (task exit status, log on failure, timeout) and
  `pve_vm_ip` (guest-agent IP polling). Tested by `tests/pve-api.test.sh`.
- `scripts/vm-from-iso.sh` — wrapper around `qm create`: checks the ISO
  exists, uses the next free VMID unless `--vmid` is given, boots disk then
  ISO. Works as root without sudo. Tested on PVE 9.2.2.
- `scripts/lxc-from-template.sh` — wrapper around `pct create`: checks the
  template exists, optional `--ssh-key`, unprivileged by default. Works as
  root without sudo. Tested on PVE 9.2.2.
- `scripts/iso-import.sh` — Ventoy USB → `<mount>/template/iso/` with a
  pre-flight size check (refuses to overflow the target fs) and per-file
  verification, then lists what Proxmox sees. Run on the Proxmox host as root.
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
  nodes, all VMs across nodes, HA status and rules, recent cluster log entries.

## Templates

- `templates/zen-agent-sudoers` — drop-in `/etc/sudoers.d/zen-agent`
  file with the whitelist documented in *Recommended sudoers allowlist*
  above. Validate with `visudo -c -f <path>` before installing.
- `templates/99-zen-agent-sshd.conf` — drop-in sshd Match block for the
  agent user. Key-only auth, no forwarding. The source-IP lock goes on the
  key (`from="<ip>"` in `authorized_keys`), as its header explains.
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
