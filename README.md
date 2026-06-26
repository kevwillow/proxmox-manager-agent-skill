# Proxmox Manager Agent Skill

A fully-featured AI agent skill for managing a Proxmox VE homelab or small
cluster via scoped SSH access. Works with Hermes, Claude Code, Codex CLI,
OpenCode, and any other agent that loads skills from a `SKILL.md` file.

## What it does

- Create, start, stop, snapshot, destroy VMs and LXC containers
- Manage storage (ISOs, dir/lvmthin/zfs pools, ISO imports with disk-full guards)
- Backups and restores (vzdump, qmrestore)
- Firewall rules (pve-firewall, security groups)
- Cluster operations (multi-node, HA, live migration, replication)
- Read-only status, observation, and audit-friendly reporting

## What it doesn't do

- Run destructive disk operations as root (mkfs, dd, parted) — those are
  reserved for the human, with the agent giving the exact commands.
- Manage sudoers itself — the user installs the scoped sudoers file
  from `templates/zen-agent-sudoers`.
- Bypass the agent's own safety policy — even sudoer-allowed commands
  like `qm destroy` still require explicit user confirmation.

## Install

### Easiest: clone and run install.sh

```bash
git clone https://github.com/kevwillow/proxmox-manager-agent-skill.git
cd proxmox-manager-agent-skill
./install.sh                # installs to all 4 agents
# or
./install.sh --agent hermes # installs to Hermes only
```

### Tell the agent to do it

Just paste the GitHub URL into a chat with any of the supported agents
and say "install this skill." The agent can clone the repo and run
`./install.sh --agent <name>` itself.

```
"Install this skill for Hermes: https://github.com/kevwillow/proxmox-manager-agent-skill"
```

### Manual install

Copy `SKILL.md` and the `references/`, `scripts/`, `templates/`
directories into the right place for your agent:

| Agent | Path |
|---|---|
| Hermes | `~/.hermes/skills/proxmox-manager-agent/` |
| Claude Code | `~/.claude/skills/proxmox-manager-agent/` |
| Codex CLI | `~/.codex/skills/proxmox-manager-agent/` |
| OpenCode | `~/.config/opencode/skills/proxmox-manager-agent/` |
| OpenClaw | `~/.openclaw/workspace/skills/proxmox-manager-agent/` |

```bash
# Example for Hermes
mkdir -p ~/.hermes/skills/proxmox-manager-agent
cp SKILL.md ~/.hermes/skills/proxmox-manager-agent/
cp -r references scripts templates ~/.hermes/skills/proxmox-manager-agent/
chmod +x ~/.hermes/skills/proxmox-manager-agent/scripts/*.sh

# Example for OpenClaw (note the workspace, not ~/.openclaw/skills/)
mkdir -p ~/.openclaw/workspace/skills/proxmox-manager-agent
cp SKILL.md ~/.openclaw/workspace/skills/proxmox-manager-agent/
cp -r references scripts templates ~/.openclaw/workspace/skills/proxmox-manager-agent/
chmod +x ~/.openclaw/workspace/skills/proxmox-manager-agent/scripts/*.sh
```

Verify OpenClaw picked it up: `openclaw skills list | grep proxmox`.

## Usage

After install, the agent picks up the skill automatically. Ask things like:

- "What's running on my Proxmox host?"
- "Create an Ubuntu 24.04 VM with 4 cores and 8GB of RAM."
- "Upload this ISO to the Proxmox ISO storage."
- "Snapshot VM 100 before I upgrade it."
- "Add a firewall rule to allow HTTPS from the LAN to VM 100."
- "Migrate VM 100 to the other node."
- "Show me a storage summary."

The agent will:
1. Verify it can SSH to the Proxmox host as the scoped agent user.
2. Verify the sudoers allowlist covers what it needs.
3. Run the appropriate `qm`, `pct`, `pvesh`, `pvesm`, etc. command.
4. Verify the operation took effect.
5. Tell you what it did and any pitfalls to watch for.

## Prerequisites

The skill assumes you have already set up scoped SSH access from the
agent's host to your Proxmox host. That setup is one-time per host:

1. **Create a dedicated agent user on the Proxmox host:**
   ```bash
   # As root on the Proxmox host
   useradd -m -s /bin/bash zen-agent
   passwd -l zen-agent
   ```

2. **Generate a keypair on the AGENT's host:**
   ```bash
   # On the agent's host (where the AI runs)
   ssh-keygen -t ed25519 -f ~/.ssh/zen-agent-proxmox \
       -C "zen-agent@$(hostname) ($(date +%Y-%m-%d))" -N ""
   ```

3. **Push the public key:**
   ```bash
   ssh-copy-id -i ~/.ssh/zen-agent-proxmox.pub zen-agent@<proxmox-host>
   # Verify
   ssh -i ~/.ssh/zen-agent-proxmox zen-agent@<proxmox-host> 'whoami'
   ```

4. **Install the sudoers file** (run on the Proxmox host as root):
   ```bash
   scp templates/zen-agent-sudoers root@<proxmox-host>:/tmp/
   scp templates/install-sudoers.sh root@<proxmox-host>:/tmp/
   ssh root@<proxmox-host> 'bash /tmp/install-sudoers.sh'
   ```

5. **Install the sshd Match block** (run on the Proxmox host as root):
   ```bash
   scp templates/99-zen-agent-sshd.conf root@<proxmox-host>:/etc/ssh/sshd_config.d/
   ssh root@<proxmox-host> 'sshd -t && systemctl reload sshd'
   ```

6. **Final verification:**
   ```bash
   # From the agent's host
   ssh -i ~/.ssh/zen-agent-proxmox zen-agent@<proxmox-host> 'sudo -n qm list'
   ```
   Should print the VM list with no password prompt.

After that, the agent has all the access it needs. The agent's own
safety policy will refuse destructive commands without explicit
confirmation.

## Files

```
proxmox-manager-agent-skill/
├── SKILL.md                    The skill (loadable by any agent)
├── README.md                   This file
├── LICENSE                     MIT
├── CHANGELOG.md                Release history
├── CONTRIBUTING.md             How to contribute
├── install.sh                  Multi-agent installer
├── references/
│   ├── storage-layouts.md      dir vs lvmthin vs zfs
│   ├── iso-workflow.md         Ventoy USB to Proxmox ISO storage
│   ├── vm-creation-cheatsheet.md  Ubuntu/Debian/cloud-init/Windows recipes
│   ├── firewall-basics.md      pve-firewall cluster/node/VM hierarchy
│   ├── proxmox-api-token.md    API token alternative to SSH + sudo
│   └── cluster.md              multi-node, HA, live migration
├── scripts/
│   ├── vm-from-iso.sh          Wrapper around qm create
│   ├── lxc-from-template.sh    Wrapper around pct create
│   ├── iso-import.sh           Ventoy USB → Proxmox ISO with size guard
│   ├── add-nvme-storage.sh     Full wipe→partition→format→mount→pvesm pipeline
│   ├── proxmox-status.sh       One-shot node health snapshot
│   └── cluster-info.sh         Multi-node cluster summary
├── templates/
│   ├── zen-agent-sudoers       Drop-in /etc/sudoers.d/zen-agent
│   ├── 99-zen-agent-sshd.conf  Drop-in sshd Match block
│   └── install-sudoers.sh      Install + validate the sudoers file
└── examples/
    └── (planned: example conversation logs)
```

## Safety model

The skill enforces a layered safety model:

1. **sudoers allowlist** — the agent CAN'T run commands not in the list.
2. **Agent soft-blocklist** — for commands like `qm destroy` that are in
   sudoers but have irreversible effects, the agent asks the user before
   invoking.
3. **Hard agent blocklist** — commands like `mkfs`, `dd`, `fdisk` are
   NEVER run by the agent, even if sudoers permits them. The agent
   identifies drives, gives the user the exact command, and verifies the
   result.
4. **Audit trail** — every sudo invocation is logged to
   `/var/log/auth.log` with full input/output capture.

A leaked agent key = a scoped user with a curated allowlist. The
attacker can manage VMs but not destroy the host.

## Contributing

See CONTRIBUTING.md. Bug reports and PRs welcome.

## License

MIT. See LICENSE.
