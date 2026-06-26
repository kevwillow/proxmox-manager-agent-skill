# Changelog

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
- Single SKILL.md format works in Hermes, Claude Code, Codex, OpenCode
- install.sh handles all 4 agents (--agent hermes|claude|codex|opencode|all)
- Validated against Hermes skill conventions and OpenAI agent-skills spec
