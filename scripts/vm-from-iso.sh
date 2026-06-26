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
#   - Must be run as root (uses sudo internally; or run directly as root).
#   - The ISO must already be uploaded to /var/lib/vz/template/iso/ on the
#     'local' storage, OR pass --storage to specify another storage ID.
#   - VMID defaults to the next free ID >= 100. Override with --vmid.
#   - Disk defaults to local-lvm (thin provisioning). Override with --storage.

set -euo pipefail

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
    VMID=$(sudo -n pvesh get /cluster/nextid 2>/dev/null || echo 100)
    if [[ "$VMID" -lt 100 ]]; then VMID=100; fi
fi

# Verify the ISO exists on the named storage
if ! sudo -n pvesh get "/nodes/localhost/storage/${ISO_STORAGE}/content/${ISO}" --content iso \
        >/dev/null 2>&1; then
    echo "ERROR: ISO '${ISO}' not found on storage '${ISO_STORAGE}'." >&2
    echo "Available ISOs:" >&2
    sudo -n pvesh get "/nodes/localhost/storage/${ISO_STORAGE}/content" --content iso 2>&1 | \
        grep -oE '[a-zA-Z0-9._-]+\.iso' | sort -u >&2
    exit 1
fi

echo "Creating VM ${VMID} (${NAME}) from ${ISO}..."
sudo -n qm create "$VMID" \
    --name "$NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK}" \
    --ide2 "${ISO_STORAGE}:iso/${ISO},media=cdrom" \
    --boot "order=ide2" \
    --ostype "$OSTYPE"

echo
echo "VM ${VMID} created. Start with:"
echo "  sudo -n qm start ${VMID}"
echo
echo "Or open the noVNC console at:"
sudo -n pvesh get "/nodes/localhost/qemu/${VMID}/vncproxy" 2>/dev/null | \
    grep -oE '[^"]*:[0-9]+' | head -1 || echo "  https://<proxmox-host>:8006 (login, then VM ${VMID} → Console)"