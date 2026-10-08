#!/bin/bash
# proxmox-status.sh — one-shot summary of Proxmox node health.
# Run from the agent host via SSH:
#   ssh -i ~/.ssh/<key> zen-agent@<proxmox> 'bash /tmp/proxmox-status.sh'
#
# Requires sudoers rules for: pvesh, pvesm, qm list, pct list,
# systemctl status, journalctl, df, free, uptime, lsblk.
# No arguments needed; reads everything via the API + standard tools.

set -uo pipefail

echo "========================================"
echo " Proxmox node: $(hostname)"
echo " $(date)"
echo "========================================"

echo
echo "=== Uptime / Load ==="
uptime

echo
echo "=== Memory ==="
free -h | grep -E '^Mem|^Swap'

echo
echo "=== Root disk ==="
df -h / /boot/efi 2>/dev/null | grep -v Filesystem

echo
echo "=== Block devices ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL | grep -v '^loop'

echo
echo "=== Proxmox version ==="
pvesh get /version 2>/dev/null | head -10

echo
echo "=== Node resources ==="
pvesh get "/nodes/$(hostname)/status" 2>/dev/null | head -20

echo
echo "=== Storage pools ==="
pvesm status 2>/dev/null

echo
echo "=== VMs ==="
qm list 2>/dev/null

echo
echo "=== LXC containers ==="
pct list 2>/dev/null

echo
echo "=== Recent errors in pvedaemon.log (last 20 lines) ==="
journalctl -u pvedaemon --no-pager -n 20 -p err 2>/dev/null | tail -20

echo
echo "=== Recent errors in pveproxy.log (last 20 lines) ==="
journalctl -u pveproxy --no-pager -n 20 -p err 2>/dev/null | tail -20

echo
echo "========================================"
echo " Done."
echo "========================================"