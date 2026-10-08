#!/bin/bash
# proxmox-iso-import.sh — Ventoy USB to Proxmox ISO storage, with pre-flight checks.
#
# Usage (as root on Proxmox, or with sudo from a sudoers-allowed user):
#   bash proxmox-iso-import.sh <ventoy-device> <target-mount>
#
# Example:
#   bash proxmox-iso-import.sh /dev/sda1 /mnt/iso
#
# What it does:
#   1. Confirms ventoy device is mounted or mountable
#   2. Lists ISOs with sizes
#   3. Compares total size to free space on target
#   4. ABORTS if target would overflow
#   5. Copies ISOs to <target-mount>/template/iso/, the only directory a
#      Proxmox `dir` storage lists ISOs from
#   6. Lists the storage's ISO content if the target is registered storage.
#      There is no index to refresh: Proxmox scans the directory on each request.
#
# Safety: never deletes files. Never overwrites the boot disk.
# Refuses to run if target is on the same mount as the boot disk AND
# total ISO size exceeds available space (would fill /).

set -euo pipefail

VENTOY_DEV="${1:-}"
TARGET_MOUNT="${2:-}"

if [[ -z "$VENTOY_DEV" || -z "$TARGET_MOUNT" ]]; then
    echo "Usage: $0 <ventoy-device> <target-mount>"
    echo "Example: $0 /dev/sda1 /mnt/iso"
    exit 1
fi

# --- Pre-flight ---

if [[ ! -b "$VENTOY_DEV" ]]; then
    echo "ERROR: $VENTOY_DEV is not a block device"
    exit 1
fi

if ! mountpoint -q "$TARGET_MOUNT"; then
    echo "ERROR: $TARGET_MOUNT is not a mounted filesystem"
    echo "Mount it first: mount <device> $TARGET_MOUNT"
    exit 1
fi

# Check target is not on the boot volume (would fill /)
BOOT_DEV=$(findmnt -no SOURCE /)
TARGET_DEV=$(findmnt -no SOURCE "$TARGET_MOUNT")
if [[ "$BOOT_DEV" == "$TARGET_DEV" ]]; then
    echo "WARNING: Target is on the same device as /"
    echo "Copying large ISOs here may fill the boot disk."
    echo "Boot disk: $BOOT_DEV, Target: $TARGET_DEV"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# Make sure the Ventoy filesystem is mounted
if ! findmnt -n "$VENTOY_DEV" >/dev/null; then
    echo "Mounting $VENTOY_DEV temporarily..."
    TEMP_MOUNT=$(mktemp -d)
    mount "$VENTOY_DEV" "$TEMP_MOUNT"
    VENTOY_PATH="$TEMP_MOUNT"
    CLEANUP_MOUNT=1
else
    VENTOY_PATH=$(findmnt -no TARGET "$VENTOY_DEV" | head -1)
    CLEANUP_MOUNT=0
fi

trap '[[ $CLEANUP_MOUNT -eq 1 ]] && umount "$TEMP_MOUNT" && rmdir "$TEMP_MOUNT"' EXIT

# --- Inventory ---

echo
echo "=== ISOs found on $VENTOY_DEV (mounted at $VENTOY_PATH) ==="
ISO_FILES=()
TOTAL_BYTES=0
while IFS= read -r -d '' iso; do
    SIZE=$(stat -c %s "$iso")
    HUMAN=$(numfmt --to=iec --suffix=B "$SIZE")
    printf "  %10s  %s\n" "$HUMAN" "$(basename "$iso")"
    ISO_FILES+=("$iso")
    TOTAL_BYTES=$((TOTAL_BYTES + SIZE))
done < <(find "$VENTOY_PATH" -maxdepth 3 -name "*.iso" -print0 | sort -z)

if [[ ${#ISO_FILES[@]} -eq 0 ]]; then
    echo "No .iso files found. Aborting."
    exit 1
fi

TOTAL_HUMAN=$(numfmt --to=iec --suffix=B "$TOTAL_BYTES")
echo
echo "Total: ${TOTAL_HUMAN} across ${#ISO_FILES[@]} files"

# --- Space check ---

ISO_DIR="$TARGET_MOUNT/template/iso"

AVAIL_BYTES=$(df -B1 "$TARGET_MOUNT" | tail -1 | awk '{print $4}')
AVAIL_HUMAN=$(numfmt --to=iec --suffix=B "$AVAIL_BYTES")
echo "Available on $TARGET_MOUNT: $AVAIL_HUMAN"

if (( TOTAL_BYTES > AVAIL_BYTES )); then
    echo
    echo "ERROR: ISOs total $TOTAL_HUMAN but only $AVAIL_HUMAN available"
    echo "Refusing to copy — would fill the target filesystem."
    echo "Free up space, target a larger mount, or pick fewer ISOs."
    exit 1
fi

# --- Confirm ---

echo
echo "About to copy ${#ISO_FILES[@]} ISOs ($TOTAL_HUMAN) to $ISO_DIR"
read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# --- Copy ---

echo
echo "Copying..."
mkdir -p "$ISO_DIR"
cp -v "${ISO_FILES[@]}" "$ISO_DIR/" 2>&1 | tail -20

# --- Post-copy ---

echo
echo "=== Verifying ==="
COPY_OK=0
COPY_FAIL=0
for iso in "${ISO_FILES[@]}"; do
    name=$(basename "$iso")
    SRC_SIZE=$(stat -c %s "$iso")
    DST_SIZE=$(stat -c %s "$ISO_DIR/$name" 2>/dev/null || echo 0)
    if [[ "$SRC_SIZE" == "$DST_SIZE" ]]; then
        COPY_OK=$((COPY_OK + 1))   # not ((x++)): it returns 1 at 0 and set -e exits
    else
        COPY_FAIL=$((COPY_FAIL + 1))
        echo "  MISMATCH: $name (src=$SRC_SIZE, dst=$DST_SIZE)"
    fi
done

echo "Verified: $COPY_OK OK, $COPY_FAIL failed"

if (( COPY_FAIL > 0 )); then
    echo "Some copies failed. Check the names above."
    exit 1
fi

# Show what Proxmox now lists, if the target is registered storage.
# `pvesm status` has no path column, so ask each storage where its ISOs live.
STORAGE_ID=""
for id in $(pvesm status 2>/dev/null | awk 'NR>1 {print $1}'); do
    if [[ "$(pvesm path "$id:iso/x.iso" 2>/dev/null || true)" == "$ISO_DIR/x.iso" ]]; then
        STORAGE_ID=$id
        break
    fi
done
if [[ -n "$STORAGE_ID" ]]; then
    echo
    echo "ISO content of Proxmox storage '$STORAGE_ID':"
    pvesm list "$STORAGE_ID" --content iso
fi

echo
echo "Done."