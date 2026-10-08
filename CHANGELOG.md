# Changelog

## 1.3.0 (2026-10-07)

Every item below was run on a PVE 9.2.2 host or, for Mode B, on Debian 13.

Added:
- Backup checking table: `zstd -t` catches bit rot in the stored file;
  `zstd -dc | vma verify -` catches truncation and header damage but passed
  4 of 4 archives with corrupted data; only a restore proves the data.
- Restore test with `unique=1` plus `link_down=1`, read through the guest
  agent. A restored copy shares `/etc/machine-id`, so its DHCP client ID
  matches the original's and it took the original's IP even with a new MAC.
- Mode B rehearsal notes: no sudo on stock PVE 9, IP lock via `from=` on the
  key, root-equivalence shown (`find -exec` runs as uid 0), audit via
  `journalctl _COMM=sudo` and `sudoreplay`.
- `qm monitor` `screendump` to see a console-only VM's screen.
- `lxc-from-template.sh --ssh-key`.
- Pitfall 24 (OpenSSH `PerSourcePenalties` blocks an agent after failed
  logins) and 25 (thin-pool overcommit).

Fixed:
- `vm-from-iso.sh` and `lxc-from-template.sh` reported existing ISOs and
  templates as missing (unsupported `--content` option, bare filename, and
  `sudo`, which stock PVE lacks). The LXC script also forced CTID 200 even
  when taken, and the VM script booted the installer again after install.
- Firewall: every enable/disable command lacked `/options` and failed; a VM's
  rules also need `firewall=1` on its NIC and the datacenter switch on; SSH
  and 8006 are allowed through the `local_network` alias, not an IPSet.
- `install-sudoers.sh` blamed "syntax errors" when sudo was not installed.
- The sshd template claimed an IP restriction it did not have, and its
  "optional" `Match Address` block restricts nothing (tested).
- README Mode B setup: `ssh-copy-id` cannot work for a locked account; root
  now installs the key with `from=`. Removed `resolvectl` (not on PVE) from
  the allowlist, and `/var/log/auth.log` (not on PVE 9) from the audit notes.
- `vma verify` recipe no longer decompresses into `/tmp`, a tmpfs on PVE 9.
- Boot order uses `;` between devices (pitfall 10 used `,`).

## 1.2.0 (2026-10-07)

Added:
- `scripts/pve-api.sh`: sourceable `pve_api`, `pve_wait` (returns non-zero on a
  failed task, prints its log, times out) and `pve_vm_ip`. Offline test in
  `tests/pve-api.test.sh`.
- Mode A-narrow: a pool-scoped API token built from four built-in roles, with
  the 403 messages measured on PVE 9.2.2 (`SDN.Use` on
  `/sdn/zones/localnetwork/<bridge>` is required even without SDN).
- Operating rules: survey first, own a VMID range, respect `protection` and
  `keep`, read the API schema from the host with `pvesh usage`, wait for every
  task, keep secrets in files.
- Cloud-init lessons: `ciupgrade` defaults to a full upgrade and lives in user
  data, grow the imported 3.5 GB disk before templating, guest agent per distro
  family, password login, EOL mirrors, linked vs full clones.
- Snapshot and rollback behaviour: no-RAM snapshots roll back to a stopped VM;
  retry `can't lock file` after a rollback.
- Dead-man revert timer for host network changes (`AccuracySec=1s` matters).
- Drive inventory and staging through the API (`/disks/list`, `wearout` is life
  remaining, `/disks/lvmthin` and `/disks/directory`).
- Pitfalls 18-23: dash on the host, laptop lid suspend, VPN DNS, VM disks on the
  boot drive, guest NIC order, serial console output.
- PVE 9 notes: HA rules replace HA groups, `VM.Monitor` removed,
  `VM.GuestAgent.*` added, deb822 repository files.

Fixed:
- `scripts/iso-import.sh` copied ISOs to the storage root, where Proxmox does
  not list them; it now copies to `template/iso/`. It also exited with status 1
  after the first verified copy (`((x++))` under `set -e`), never detected an
  already-mounted source, and ran a false `--is_mountpoint` "re-index".
- `install.sh` never printed the OpenClaw workspace line (compared a literal
  string), and a plain `./install.sh` skipped Cursor.
- `references/proxmox-api-token.md`: `--expire` takes a Unix timestamp, not days;
  `pvesh` cannot use a token; privsep defaults; removed `VM.Monitor`.
- `references/cluster.md`: removed the nonexistent `ha-manager fence-add`;
  fencing is watchdog-based.
- `references/vm-creation-cheatsheet.md`: the cloud-init drive is
  `<storage>:cloudinit`, not a seed ISO; Python's `crypt` module is gone.
- Verification table: `qm listsnapshot`, not `qm snapshot`.
- README: the safety model no longer claims a leaked Mode B key cannot harm the
  host; agent count and file list corrected.
- Removed the dependency on a skill that is not published.

## 1.1.0 (2026-10-03)

- Add admin API-token plus root SSH access mode and retain the scoped SSH mode.
- Correct sudoers Defaults syntax and PVE 9 binary paths.
- Document the scoped allowlist as root-equivalent rather than containment.
- Mark unsupported Mode B workflows as root-only and fix the fstab append.
- Use `template/iso/` for dir storage and remove the false re-index guidance.
- Correct the fresh-install firewall default to OFF at datacenter level.
- Replace unsupported `vzdump --verify` with `vma verify` guidance.
- Correct the PVE 9 binary table and path pitfalls.
- Promote the cloud-init template and clone workflow, with API commands verified on PVE 9.2.2.

## 1.0.2 (2026-06-26)

- Add Cursor support to `install.sh` (`--agent cursor`).
  Cursor skills live at `~/.cursor/skills/<name>/SKILL.md`.
- Bump version to 1.0.2.
- Update SKILL.md and README.md Cross-Agent Compatibility tables.

## 1.0.1 (2026-06-26)

- Add OpenClaw support to `install.sh` (`--agent openclaw`,
  `--openclaw-workspace <path>`). OpenClaw workspace path defaults to
  `~/.openclaw/workspace`; users on the literal Windows-style path
  (`C:\Users\kev\.openclaw\workspace`) can override with the flag.
- Update SKILL.md Cross-Agent Compatibility table with OpenClaw notes.
- Update README.md manual install section with OpenClaw example.
- Verified OpenClaw picks the skill up via `openclaw skills list`.

## 1.0.0 (2026-06-26)

Initial public release.

**Coverage:**
- VM lifecycle (create, start, stop, shutdown, snapshot, rollback, destroy)
- LXC container lifecycle (create, start, stop, snapshot, restore)
- Storage management (dir, lvmthin, zfspool, nfs, cephfs)
- ISO import with pre-flight size check
- Backup and restore (vzdump, qmrestore)
- Firewall management (pve-firewall cluster/node/VM, security groups)
- Cluster operations (multi-node, HA, live migration, replication)
- Read-only status, observation, and audit-friendly reporting

**Safety:**
- Explicit whitelist and blacklist sections in SKILL.md
- Drop-in sudoers template (templates/zen-agent-sudoers)
- Drop-in sshd Match block (templates/99-zen-agent-sshd.conf)
- Hard agent blocklist (mkfs, dd, fdisk, etc. — agent never runs these)
- Soft agent blocklist (qm destroy, pct destroy, etc. — agent asks first)
- Full audit logging via sudoers LOG_INPUT LOG_OUTPUT defaults

**Scripts:**
- vm-from-iso.sh — qm create wrapper with sensible defaults
- lxc-from-template.sh — pct create wrapper with network/password handling
- iso-import.sh — Ventoy USB → Proxmox storage with size pre-flight
- add-nvme-storage.sh — full pipeline with serial-based drive identification
- proxmox-status.sh — one-shot node health snapshot
- cluster-info.sh — multi-node cluster summary

**References:**
- storage-layouts.md — when to pick dir/lvmthin/zfspool/nfs
- iso-workflow.md — full Ventoy-to-Proxmox example
- vm-creation-cheatsheet.md — Ubuntu/Debian/cloud-init/Windows 11 recipes
- firewall-basics.md — pve-firewall hierarchy and patterns
- proxmox-api-token.md — alternative to SSH + sudo
- cluster.md — multi-node, HA, live migration

**Cross-agent:**
- Single SKILL.md format works in Hermes, Claude Code, Codex, OpenCode, OpenClaw
- install.sh handles all 5 agents (--agent hermes|claude|codex|opencode|openclaw|all)
- Validated against Hermes skill conventions, OpenAI agent-skills spec, and OpenClaw skills list
