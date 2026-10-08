#!/bin/bash
# vm-from-iso.sh — Create a Proxmox VM from an ISO with sensible defaults.
#
# Usage:
#   vm-from-iso.sh --name <vmname> --iso <isoname> [--vmid N] [--memory 2048] \
#                  [--cores 2] [--disk 32] [--bridge vmbr0] [--ostype l26]
#
# Examples:
#   vm-from-iso.sh --name ubuntu-test --iso ubuntu-24.04-live-server-amd64.iso
#   vm-from-iso.sh --name pihole --iso debian-12-generic-amd64.iso --memory 1024 --cores 1 --disk 8
#
# Notes:
#   - Run on the Proxmox host as root, or as a user with the sudoers allowlist.
#   - The ISO must already be on an ISO storage: 'local' by default
#     (/var/lib/vz/template/iso/), or pass --iso-storage <storage-id>.
#   - VMID defaults to Proxmox's next free ID. Override with --vmid.
#   - Disk defaults to local-lvm (thin provisioning). Override with --storage.

set -euo pipefail

# Stock PVE has no sudo; use it only when not already root.
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo -n"

NAME=""
ISO=""
VMID=""
MEMORY=2048
CORES=2
DISK=32
BRIDGE="vmbr0"
OSTYPE="l26"
STORAGE="local-lvm"
ISO_STORAGE="local"

usage() {
    sed -n '2,15p' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)    NAME="$2"; shift 2 ;;
        --iso)     ISO="$2"; shift 2 ;;
        --vmid)    VMID="$2"; shift 2 ;;
        --memory)  MEMORY="$2"; shift 2 ;;
        --cores)   CORES="$2"; shift 2 ;;
        --disk)    DISK="$2"; shift 2 ;;
        --bridge)  BRIDGE="$2"; shift 2 ;;
        --ostype)  OSTYPE="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --iso-storage) ISO_STORAGE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$NAME" ]] && { echo "ERROR: --name required" >&2; usage; }
[[ -z "$ISO"  ]] && { echo "ERROR: --iso required" >&2; usage; }

# Pick next free VMID if not specified
if [[ -z "$VMID" ]]; then
    VMID=$($SUDO pvesh get /cluster/nextid)
fi

# Verify the ISO exists on the named storage
ISOS=$($SUDO pvesm list "$ISO_STORAGE" --content iso | awk 'NR>1 {print $1}')
if ! grep -qxF "${ISO_STORAGE}:iso/${ISO}" <<<"$ISOS"; then
    echo "ERROR: ISO '${ISO}' not found on storage '${ISO_STORAGE}'." >&2
    echo "Available ISOs:" >&2
    sed "s|^${ISO_STORAGE}:iso/|  |" <<<"$ISOS" >&2
    exit 1
fi

echo "Creating VM ${VMID} (${NAME}) from ${ISO}..."
$SUDO qm create "$VMID" \
    --name "$NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK}" \
    --ide2 "${ISO_STORAGE}:iso/${ISO},media=cdrom" \
    --boot "order=scsi0;ide2" \
    --ostype "$OSTYPE"

echo
echo "VM ${VMID} created. Start with:"
echo "  qm start ${VMID}"
echo
echo "Then open its console: https://<proxmox-host>:8006, VM ${VMID}, Console."
echo "Boot order is disk first, then the ISO: an empty disk falls through to the installer."
echo "After the install, eject the ISO: qm set ${VMID} --ide2 none,media=cdrom"
