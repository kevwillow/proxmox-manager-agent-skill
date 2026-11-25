#!/bin/bash
# proxmox-status.sh — one-shot summary of Proxmox node health.
# Run from the agent host via SSH:
#   ssh -i ~/.ssh/<key> zen-agent@<proxmox> 'bash /tmp/proxmox-status.sh'
#
# Requires sudoers rules for: pvesh, pvesm, qm list, pct list,
# systemctl status, journalctl, df, free, uptime, lsblk.
# No arguments needed; reads everything via the API + standard tools.

set -uo pipefail

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo -n"
failed=0
# A read that fails is unknown, which is not the same as empty.
show() {
    if ! "$@" 2>&1; then
        echo "!! FAILED: $* (this section is unknown, not empty)"
        failed=1
    fi
}

echo "========================================"
echo " Proxmox node: $(hostname)"
echo " $(date)"
echo "========================================"

echo
echo "=== Uptime / Load ==="
show uptime

echo
echo "=== Memory ==="
show free -h

echo
echo "=== Root disk ==="
show df -h /
if [[ -d /boot/efi ]]; then show df -h /boot/efi; fi

echo
echo "=== Block devices ==="
show lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL

echo
echo "=== Proxmox version ==="
show $SUDO pvesh get /version

echo
echo "=== Node resources ==="
show $SUDO pvesh get "/nodes/$(hostname)/status"

echo
echo "=== Storage pools ==="
show $SUDO pvesm status

echo
echo "=== VMs ==="
show $SUDO qm list

echo
echo "=== LXC containers ==="
show $SUDO pct list

echo
echo "=== Recent errors in pvedaemon.log (last 20 lines) ==="
show $SUDO journalctl -u pvedaemon --no-pager -n 20 -p err

echo
echo "=== Recent errors in pveproxy.log (last 20 lines) ==="
show $SUDO journalctl -u pveproxy --no-pager -n 20 -p err

echo
echo "========================================"
if (( failed )); then echo " Done, with FAILED reads above."; else echo " Done."; fi
echo "========================================"
exit "$failed"