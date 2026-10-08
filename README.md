# Proxmox Manager Agent Skill

An AI agent skill for managing a Proxmox VE homelab or small cluster through
the Proxmox API and SSH. Works with Hermes, Claude Code, Codex CLI, OpenCode,
OpenClaw, Cursor, and any other agent that loads skills from a `SKILL.md`
file. Written against PVE 9.2 and checked on a live 9.2.2 host; most of it
also applies to PVE 8.

## What it does

- Create, start, stop, snapshot and destroy VMs and LXC containers
- Build cloud-init templates and clone test VMs in under a minute
- Manage storage: list drives by serial, stage spare drives, import ISOs with
  disk-full guards
- Backups and restores (vzdump, qmrestore)
- Host network changes behind a dead-man revert timer
- Firewall rules (pve-firewall, security groups)
- Cluster operations (multi-node, HA rules, live migration)
- Read-only status, observation, and audit-friendly reporting

## Access modes

Pick one per host. The confirmation rules apply in every mode.

| Mode | How the agent connects | What a leaked credential can do |
|---|---|---|
| A: admin | `Administrator` API token plus a root SSH key | Everything. Simplest; for hosts the agent fully runs. |
| A-narrow | API token limited to one resource pool | Only the guests in that pool. The one mode that contains a leak. |
| B: scoped SSH | Non-root user with a sudoers allowlist | Root-equivalent (the allowlist allows `find -exec`, `pvesh`, `qm` hookscripts). An audit trail, not a wall. |

Setup for Mode A and A-narrow is in `SKILL.md` (*Access modes*). Setup for
Mode B is under *Prerequisites* below.

## What's new in 1.2.0

- Tested API helpers in `scripts/pve-api.sh`: task waits that fail loudly and
  time out, and guest-agent IP polling.
- A pool-scoped least-privilege token recipe, with the PVE 9 privilege changes.
- Operating rules: survey first, own a VMID range, read the API schema from
  the host, wait for every task.
- Cloud-init lessons from a 16-distro template matrix (`ciupgrade`, disk size,
  guest agent per distro, password login, EOL mirrors, linked clones).
- Dead-man revert timer for host network changes.
- Fixes to scripts and references that were wrong; see `CHANGELOG.md`.

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
./install.sh                # installs for all 6 agents
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
| Cursor | `~/.cursor/skills/proxmox-manager-agent/` |

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

# Example for Cursor
mkdir -p ~/.cursor/skills/proxmox-manager-agent
cp SKILL.md ~/.cursor/skills/proxmox-manager-agent/
cp -r references scripts templates ~/.cursor/skills/proxmox-manager-agent/
chmod +x ~/.cursor/skills/proxmox-manager-agent/scripts/*.sh
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
1. Survey the host read-only: version, nodes, guests, storage.
2. Check its access works (API token or SSH, depending on the mode).
3. Run the API call or `qm`, `pct`, `pvesh`, `pvesm` command, and wait for
   the task to finish.
4. Verify the result took effect.
5. Ask before anything irreversible, and tell you what it did.

## Prerequisites

For Mode A or A-narrow, follow *Access modes* in `SKILL.md`. For Mode B, set
up scoped SSH access from the agent's host to your Proxmox host. That setup
is one-time per host:

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
│   ├── proxmox-api-token.md    API tokens, pool-scoped least privilege
│   └── cluster.md              multi-node, HA rules, live migration
├── scripts/
│   ├── pve-api.sh              Sourceable API helpers: pve_api, pve_wait, pve_vm_ip
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
└── tests/
    └── pve-api.test.sh         Offline test for scripts/pve-api.sh
```

## Safety model

The skill layers its safety model:

1. **Credential scope.** A pool-scoped token (Mode A-narrow) is the only
   layer that actually contains a leaked credential. The admin token and the
   sudoers allowlist are both root-equivalent.
2. **Agent soft-blocklist.** For irreversible actions like `qm destroy`,
   `qm stop` or a rollback, the agent asks the user first, whatever its
   rights allow.
3. **Hard agent blocklist.** The agent never runs `mkfs`, `dd` or `fdisk`
   itself. It identifies drives by serial, gives the user the exact command,
   and verifies the result. The API's disk-wiping calls get the same
   confirmation.
4. **Ownership.** The agent works in its own VMID range and leaves guests
   marked `protection=1` or `keep` alone.
5. **Audit trail.** API calls are logged in `/var/log/pveproxy/access.log`
   and every task carries the token ID. In Mode B, every sudo invocation is
   logged with input and output capture.

## Contributing

See CONTRIBUTING.md. Bug reports and PRs welcome.

## License

MIT. See LICENSE.
