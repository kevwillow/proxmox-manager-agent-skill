#!/bin/bash
# cluster-info.sh — multi-node Proxmox cluster summary.
# Use on a PVE host that's part of a cluster (single-node is also valid,
# output just shows the local node).
#
# Requires sudoers rules for: pvesh, pvesm, qm list, pct list,
# pvecm, ha-manager, journalctl.
# Run via SSH from the agent host:
#   scp scripts/cluster-info.sh zen-agent@<proxmox>:/tmp/
#   ssh zen-agent@<proxmox> 'bash /tmp/cluster-info.sh'

set -uo pipefail

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
echo "=== Cluster status (pvecm) ==="
if out=$(pvecm status 2>&1); then
    echo "$out"
elif grep -q 'corosync.conf.* does not exist' <<<"$out"; then
    echo "(not in a cluster)"
else
    echo "$out"
    echo "!! FAILED: pvecm status (cluster state is unknown)"
    failed=1
fi

echo
echo "=== Nodes ==="
show pvesh get /nodes

echo
echo "=== Cluster resources (all VMs and CTs across nodes) ==="
show pvesh get /cluster/resources --type vm

echo
echo "=== Storage pools ==="
show pvesm status

echo
echo "=== HA services and rules ==="
show ha-manager status
# PVE 9 replaced HA groups with rules; this fails harmlessly on PVE 8.
ha-manager rules list 2>&1 || echo "(HA rules not read: PVE 9+ only, or the read failed)"

echo
echo "=== Recent pve-cluster log errors ==="
show journalctl -u pve-cluster --no-pager -n 10 -p err

echo
echo "========================================"
if (( failed )); then echo " Done, with FAILED reads above."; else echo " Done."; fi
echo "========================================"
exit "$failed"
