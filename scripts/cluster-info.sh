#!/bin/bash
# cluster-info.sh — multi-node Proxmox cluster summary.
# Use on a PVE host that's part of a cluster (single-node is also valid,
# output just shows the local node).
#
# Requires sudoers rules for: pvesh, pvesm, qm list, pct list,
# ha-manager, journalctl.
# Run via SSH from the agent host:
#   scp scripts/cluster-info.sh zen-agent@<proxmox>:/tmp/
#   ssh zen-agent@<proxmox> 'bash /tmp/cluster-info.sh'

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
echo " Proxmox cluster: $(hostname)"
echo " $(date)"
echo "========================================"

echo
echo "=== Cluster status (no 'cluster' row = standalone) ==="
show $SUDO pvesh get /cluster/status   # not pvecm: it is outside the agent allowlist

echo
echo "=== Nodes ==="
show $SUDO pvesh get /nodes

echo
echo "=== Cluster resources (all VMs and CTs across nodes) ==="
show $SUDO pvesh get /cluster/resources --type vm

echo
echo "=== Storage pools ==="
show $SUDO pvesm status

echo
echo "=== HA services and rules ==="
show $SUDO ha-manager status
# PVE 9 replaced HA groups with rules; this fails harmlessly on PVE 8.
if rules=$($SUDO ha-manager rules list 2>&1); then
    echo "$rules"
elif grep -qi 'unknown command' <<<"$rules"; then
    echo "(no HA rules: PVE 9+ only)"
else
    echo "$rules"
    echo "!! FAILED: ha-manager rules list (this section is unknown, not empty)"
    failed=1
fi

echo
echo "=== Recent pve-cluster log errors ==="
show $SUDO journalctl -u pve-cluster --no-pager -n 10 -p err

echo
echo "========================================"
if (( failed )); then echo " Done, with FAILED reads above."; else echo " Done."; fi
echo "========================================"
exit "$failed"
