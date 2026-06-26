#!/bin/bash
# lxc-from-template.sh — Create a Proxmox LXC container from an
# already-downloaded template. Sensible defaults for common homelab use.
#
# Usage:
#   lxc-from-template.sh --hostname <name> --template <tpl> [options]
#
# Examples:
#   lxc-from-template.sh --hostname pihole --template debian-12-standard_12.5-1_amd64.tar.zst --memory 512 --cores 1
#   lxc-from-template.sh --hostname nginx --template alpine-3.20-default_20240605_amd64.tar.xz --bridge vmbr1 --ip 192.168.50.50/24
#   lxc-from-template.sh --hostname nodered --template ubuntu-24.04-standard_24.04-2_amd64.tar.zst --storage vmdata --disk 16
#
# Notes:
#   - Must be run as root (uses sudo internally; or run directly as root).
#   - The template must already be downloaded with `pveam download <storage> <tpl>`.
#   - CTID defaults to the next free ID >= 200. Override with --ctid.
#   - Disk defaults to local-lvm (thin provisioning). Override with --storage.

set -euo pipefail

HOSTNAME=""
TEMPLATE=""
CTID=""
MEMORY=1024
CORES=1
DISK=8
BRIDGE="vmbr0"
STORAGE="local-lvm"
TPL_STORAGE="local"
IP=""
GATEWAY=""
ONBOOT=1
UNPRIVILEGED=1
FEATURES=""
PASSWORD=""

usage() {
    sed -n '2,21p' "$0"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)    HOSTNAME="$2"; shift 2 ;;
        --template)    TEMPLATE="$2"; shift 2 ;;
        --ctid)        CTID="$2"; shift 2 ;;
        --memory)      MEMORY="$2"; shift 2 ;;
        --cores)       CORES="$2"; shift 2 ;;
        --disk)        DISK="$2"; shift 2 ;;
        --bridge)      BRIDGE="$2"; shift 2 ;;
        --storage)     STORAGE="$2"; shift 2 ;;
        --tpl-storage) TPL_STORAGE="$2"; shift 2 ;;
        --ip)          IP="$2"; shift 2 ;;
        --gateway)     GATEWAY="$2"; shift 2 ;;
        --password)    PASSWORD="$2"; shift 2 ;;
        --privileged)  UNPRIVILEGED=0; shift 1 ;;
        --no-onboot)   ONBOOT=0; shift 1 ;;
        --features)    FEATURES="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$HOSTNAME" ]] && { echo "ERROR: --hostname required" >&2; usage; }
[[ -z "$TEMPLATE" ]] && { echo "ERROR: --template required" >&2; usage; }

# Pick next free CTID if not specified
if [[ -z "$CTID" ]]; then
    CTID=$(sudo -n pvesh get /cluster/nextid 2>/dev/null || echo 200)
    if [[ "$CTID" -lt 200 ]]; then CTID=200; fi
fi

# Verify the template exists
if ! sudo -n pvesh get "/nodes/localhost/storage/${TPL_STORAGE}/content/${TEMPLATE}" --content vztmpl \
        >/dev/null 2>&1; then
    echo "ERROR: Template '${TEMPLATE}' not found on storage '${TPL_STORAGE}'." >&2
    echo "Available templates:" >&2
    sudo -n pvesh get "/nodes/localhost/storage/${TPL_STORAGE}/content" --content vztmpl 2>&1 | \
        grep -oE '[a-zA-Z0-9._+-]+\.(tar\.zst|tar\.xz|tar\.gz)' | sort -u >&2
    exit 1
fi

# Build net0 string
if [[ -n "$IP" && -n "$GATEWAY" ]]; then
    NET0="name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}"
elif [[ -n "$IP" ]]; then
    NET0="name=eth0,bridge=${BRIDGE},ip=${IP}"
else
    NET0="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

# Build features string (comma-separated)
FEAT_ARGS=()
if [[ -n "$FEATURES" ]]; then
    FEAT_ARGS=(--features "$FEATURES")
fi

# Build password arg (if empty, omit --password)
PASS_ARGS=()
if [[ -n "$PASSWORD" ]]; then
    PASS_ARGS=(--password "$PASSWORD")
fi

echo "Creating CT ${CTID} (${HOSTNAME}) from ${TEMPLATE}..."
sudo -n pct create "$CTID" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "$NET0" \
    --rootfs "${STORAGE}:${DISK}" \
    --onboot "$ONBOOT" \
    --unprivileged "$UNPRIVILEGED" \
    --start 1 \
    "${FEAT_ARGS[@]}" \
    "${PASS_ARGS[@]}"

echo
echo "CT ${CTID} created and started."
echo "Console:"
echo "  pct enter ${CTID}    # attach to console"
echo "  pct shutdown ${CTID} # graceful stop"
echo "  pct stop ${CTID}     # hard stop"
echo
echo "Network config:"
echo "  ${NET0}"
