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
#   5. Copies ISOs to target
#   6. Re-indexes Proxmox storage (via --is_mountpoint no toggle) so the
#      ISOs show up in `pvesm list` and the web UI dropdown
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
if ! mount | grep -q "on $VENTOY_DEV "; then
    echo "Mounting $VENTOY_DEV temporarily..."
    TEMP_MOUNT=$(mktemp -d)
    mount "$VENTOY_DEV" "$TEMP_MOUNT"
    VENTOY_PATH="$TEMP_MOUNT"
    CLEANUP_MOUNT=1
else
    VENTOY_PATH=$(findmnt -no TARGET "$VENTOY_DEV")
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
echo "About to copy ${#ISO_FILES[@]} ISOs ($TOTAL_HUMAN) to $TARGET_MOUNT"
read -p "Continue? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# --- Copy ---

echo
echo "Copying..."
cp -v "${ISO_FILES[@]}" "$TARGET_MOUNT/" 2>&1 | tail -20

# --- Post-copy ---

echo
echo "=== Verifying ==="
COPY_OK=0
COPY_FAIL=0
for iso in "${ISO_FILES[@]}"; do
    name=$(basename "$iso")
    SRC_SIZE=$(stat -c %s "$iso")
    DST_SIZE=$(stat -c %s "$TARGET_MOUNT/$name" 2>/dev/null || echo 0)
    if [[ "$SRC_SIZE" == "$DST_SIZE" ]]; then
        ((COPY_OK++))
    else
        ((COPY_FAIL++))
        echo "  MISMATCH: $name (src=$SRC_SIZE, dst=$DST_SIZE)"
    fi
done

echo "Verified: $COPY_OK OK, $COPY_FAIL failed"

if (( COPY_FAIL > 0 )); then
    echo "Some copies failed. Check the names above."
    exit 1
fi

# Re-index if this is a registered Proxmox storage.
# NOTE: `pvesm scan <name>` does NOT exist on PVE 9.x — its purpose
# was folded into the `set` command's `--is_mountpoint` toggle. Toggle
# it off so Proxmox scans the path and indexes existing files, then
# toggle back on so future operations don't trigger unexpected
# reformatting.
STORAGE_ID=$(pvesm status 2>/dev/null | awk -v mp="$TARGET_MOUNT" '$1 != "Name" && $NF == mp {print $1; exit}')
if [[ -n "$STORAGE_ID" ]]; then
    echo
    echo "Target is Proxmox storage '$STORAGE_ID' — re-indexing..."
    pvesm set "$STORAGE_ID" --is_mountpoint no
    echo
    echo "ISO listing:"
    pvesm list "$STORAGE_ID"
    pvesm set "$STORAGE_ID" --is_mountpoint yes
fi

echo
echo "Done."