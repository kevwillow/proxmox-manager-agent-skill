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

echo "========================================"
echo " Proxmox cluster: $(hostname)"
echo " $(date)"
echo "========================================"

echo
echo "=== Cluster status (pvecm) ==="
pvecm status 2>/dev/null || echo "(not in a cluster)"

echo
echo "=== Nodes ==="
pvesh get /nodes 2>/dev/null

echo
echo "=== Cluster resources (all VMs and CTs across nodes) ==="
pvesh get /cluster/resources --type vm 2>/dev/null

echo
echo "=== Storage pools ==="
pvesm status 2>/dev/null

echo
echo "=== HA services and rules ==="
ha-manager status 2>/dev/null || echo "(HA not configured)"
# PVE 9 replaced HA groups with rules; this fails harmlessly on PVE 8.
ha-manager rules list 2>/dev/null || true

echo
echo "=== Recent pve-cluster log errors ==="
journalctl -u pve-cluster --no-pager -n 10 -p err 2>/dev/null | tail -10

echo
echo "========================================"
echo " Done."
echo "========================================"
