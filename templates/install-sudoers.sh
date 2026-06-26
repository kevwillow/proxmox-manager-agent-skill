#!/bin/bash
# install-sudoers.sh — install and validate the zen-agent sudoers file
# on the Proxmox host. Run as root on the host.
#
# Usage (run on the Proxmox host as root):
#   bash install-sudoers.sh
#
# This script:
#   1. Validates the sudoers file syntax BEFORE installing (visudo -c)
#   2. Installs to /etc/sudoers.d/zen-agent with 0440 perms
#   3. Confirms zen-agent user exists; creates if missing
#   4. Runs a smoke test (sudo -n -l as zen-agent)
#
# Required: zen-agent user must already exist (or root will create it
# with passwd -l, no password login).

set -euo pipefail

SUDOERS_SRC="$(dirname "$0")/zen-agent-sudoers"
SUDOERS_DST="/etc/sudoers.d/zen-agent"
AGENT_USER="zen-agent"

# 1. Validate before installing
if [[ ! -f "$SUDOERS_SRC" ]]; then
    echo "ERROR: sudoers source not found at $SUDOERS_SRC"
    exit 1
fi

echo "Validating sudoers syntax..."
if ! visudo -c -f "$SUDOERS_SRC"; then
    echo "ERROR: sudoers file has syntax errors. NOT installing."
    exit 1
fi
echo "OK"

# 2. Ensure agent user exists
if ! id "$AGENT_USER" &>/dev/null; then
    echo "User $AGENT_USER does not exist. Creating..."
    useradd -m -s /bin/bash "$AGENT_USER"
    passwd -l "$AGENT_USER"   # disable password login (key-only)
    echo "Created $AGENT_USER with locked password (key-only auth)."
else
    echo "User $AGENT_USER exists."
fi

# 3. Install
cp "$SUDOERS_SRC" "$SUDOERS_DST"
chmod 0440 "$SUDOERS_DST"
chown root:root "$SUDOERS_DST"
echo "Installed: $SUDOERS_DST (0440, root:root)"

# 4. Final validate of the installed file
echo
echo "Validating installed file..."
visudo -c -f "$SUDOERS_DST"

# 5. Smoke test (must run as the agent user)
echo
echo "Smoke test: 'sudo -n -l' as $AGENT_USER..."
if sudo -u "$AGENT_USER" sudo -n -l &>/dev/null; then
    echo "OK — $AGENT_USER can sudo without a password."
    echo
    echo "Loaded rules (first 20):"
    sudo -u "$AGENT_USER" sudo -n -l | head -20
else
    echo "WARNING: 'sudo -n -l' failed for $AGENT_USER."
    echo "Possible causes:"
    echo "  - The agent user's SSH key is not installed yet"
    echo "  - The user hasn't logged in yet"
    echo "  - Default secure_path in /etc/sudoers is restrictive"
    echo
    echo "Continue with: sudo -u $AGENT_USER sudo -n -l"
fi

echo
echo "============================================"
echo " Done. Next steps:"
echo "============================================"
echo "1. Push the agent's SSH public key:"
echo "   ssh-copy-id -i ~/.ssh/<agent>-<host>.pub $AGENT_USER@<host>"
echo
echo "2. Test SSH + sudo from the agent host:"
echo "   ssh $AGENT_USER@<host> 'sudo -n qm list'"
echo
echo "3. Install the sshd Match block:"
echo "   cp templates/99-zen-agent-sshd.conf /etc/ssh/sshd_config.d/"
echo "   sshd -t && systemctl reload sshd"
echo
echo "4. Verify the audit log is working:"
echo "   tail -f /var/log/auth.log | grep -i 'sudo:'"
