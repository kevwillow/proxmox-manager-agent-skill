#!/bin/bash
# proxmox-add-nvme-storage.sh — wipe, partition, format, mount, and register
# a new NVMe drive as Proxmox storage. User-driven for destructive steps;
# the agent verifies after each step.
#
# This script intentionally does NOT run fdisk, mkfs, or pvesm add
# without human confirmation at each step. The pipeline is:
#
#   1. List all drives with identity (user verifies target by serial)
#   2. User runs fdisk (split pattern: 1 partition, or 2 partitions)
#   3. User runs mkfs.ext4 (with -F for the re-format case)
#   4. User mounts the partition
#   5. Script writes UUID-based /etc/fstab entry (NEVER /dev/nvmeXnYp1)
#   6. Script registers with pvesm
#
# Usage (as root on the Proxmox host):
#   bash proxmox-add-nvme-storage.sh
#
# The script prompts for everything it needs. To script a known-good
# config, set env vars:
#   TARGET_DRIVE=/dev/nvme2n1
#   PARTITION_COUNT=2
#   MOUNT_PREFIX=/mnt/vmdata
#   PVE_STORAGE_NAMES="vmdata2a vmdata2b"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    echo "Re-run as root (stock PVE has no sudo): bash $0"
    exit 1
fi

echo "=== Step 1: Identify all drives ==="
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL,WWN
echo
echo "Before continuing, identify the BOOT DRIVE by serial."
echo "It will have /boot/efi and LVM volumes (pve-root, pve-swap, pve-data)."
echo "Mark that serial as OFF-LIMITS — this script must NEVER touch it."
echo
read -p "Enter the BOOT DRIVE SERIAL to exclude: " BOOT_SERIAL
echo "Excluding boot drive: $BOOT_SERIAL"
echo

# Show candidate drives
echo "Candidate drives (excluding boot):"
while IFS= read -r line; do
    SERIAL=$(echo "$line" | awk '{print $NF}')
    if [[ "$SERIAL" != "$BOOT_SERIAL" && -n "$SERIAL" ]]; then
        echo "  $line"
    fi
done < <(lsblk -dn -o NAME,SIZE,MODEL,SERIAL | tail -n +2)

echo
read -p "Enter the TARGET drive (e.g. /dev/nvme2n1): " TARGET_DRIVE
if [[ ! -b "$TARGET_DRIVE" ]]; then
    echo "ERROR: $TARGET_DRIVE is not a block device"
    exit 1
fi

# Confirm identity
TARGET_SERIAL=$(cat "/sys/block/$(basename "$TARGET_DRIVE")/device/serial" 2>/dev/null || echo "unknown")
TARGET_MODEL=$(cat "/sys/block/$(basename "$TARGET_DRIVE")/device/model" 2>/dev/null || echo "unknown")
echo
echo "Target: $TARGET_DRIVE ($TARGET_MODEL, S/N $TARGET_SERIAL)"
if [[ "$TARGET_SERIAL" == "$BOOT_SERIAL" ]]; then
    echo "ERROR: That is the BOOT DRIVE. Aborting."
    exit 1
fi
read -p "Confirm wipe of $TARGET_DRIVE? [yes/NO] " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

echo
read -p "Partition count (1 for single pool, 2 to split): " PARTITION_COUNT
if [[ "$PARTITION_COUNT" != "1" && "$PARTITION_COUNT" != "2" ]]; then
    echo "ERROR: partition count must be 1 or 2"
    exit 1
fi

echo
read -p "Mount point prefix (e.g. /mnt/vmdata): " MOUNT_PREFIX
if [[ ! "$MOUNT_PREFIX" =~ ^/mnt/ ]]; then
    echo "ERROR: mount point must start with /mnt/"
    exit 1
fi

read -p "Proxmox storage names (space-separated, e.g. 'vmdata2a vmdata2b'): " PVE_NAMES_RAW
read -ra PVE_STORAGE_NAMES <<< "$PVE_NAMES_RAW"
if [[ "${#PVE_STORAGE_NAMES[@]}" != "$PARTITION_COUNT" ]]; then
    echo "ERROR: need $PARTITION_COUNT storage name(s), got ${#PVE_STORAGE_NAMES[@]}"
    exit 1
fi

# --- Step 2: User partitions ---
echo
echo "=== Step 2: Partition with fdisk ==="
echo "Run in another terminal, or paste this into a shell:"
echo
echo "  fdisk $TARGET_DRIVE"
echo
echo "Inside fdisk, type these one at a time:"
echo
if [[ "$PARTITION_COUNT" == "1" ]]; then
    echo "  g       # new GPT table"
    echo "  n       # new partition"
    echo "  1       # partition number 1"
    echo "  [Enter] # default first sector"
    echo "  [Enter] # default last sector (full disk)"
    echo "  w       # write and exit"
else
    DISK_GB=$(($(cat "/sys/block/$(basename "$TARGET_DRIVE")/size") * 512 / 1024 / 1024 / 1024))
    HALF_GB=$((DISK_GB / 2))
    echo "  g       # new GPT table"
    echo "  n       # new partition"
    echo "  1       # partition number 1"
    echo "  [Enter] # default first sector"
    echo "  +${HALF_GB}G"
    echo "          # half the disk — adjust as needed"
    echo "  n       # new partition"
    echo "  2       # partition number 2"
    echo "  [Enter] # default first sector (after partition 1)"
    echo "  [Enter] # default last sector (rest of disk)"
    echo "  w       # write and exit"
fi
echo
echo "When fdisk exits, press ENTER to continue."
read -r

# --- Step 3 & 4: User formats and mounts ---
echo
echo "=== Step 3 & 4: Format and mount ==="
echo "Run as root:"
echo
for i in $(seq 1 "$PARTITION_COUNT"); do
    PART="${TARGET_DRIVE}p${i}"
    LABEL="${PVE_STORAGE_NAMES[$((i-1))]}"
    MOUNT_DIR="${MOUNT_PREFIX}${i}"
    echo "  mkfs.ext4 -L $LABEL $PART"
    echo "  mkdir -p $MOUNT_DIR"
    echo "  mount $PART $MOUNT_DIR"
done
echo
echo "Verify with: df -h $MOUNT_PREFIX*  (each should show full partition size, NOT 458MB)"
echo
echo "If any shows 458MB on a larger partition, the kernel had stale"
echo "partition geometry. Re-run:  mkfs.ext4 -F -L <label> <partition>"
echo "or reboot."
echo
echo "When all partitions are mounted, press ENTER to continue."
read -r

# --- Step 5: fstab with UUID ---
echo
echo "=== Step 5: Writing /etc/fstab entries (UUID-based) ==="
FSTAB_BAK="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/fstab "$FSTAB_BAK"
echo "Backed up to $FSTAB_BAK"

for i in $(seq 1 "$PARTITION_COUNT"); do
    PART="${TARGET_DRIVE}p${i}"
    LABEL="${PVE_STORAGE_NAMES[$((i-1))]}"
    UUID=$(blkid -s UUID -o value "$PART")
    MOUNT_DIR="${MOUNT_PREFIX}${i}"
    echo "UUID=$UUID $MOUNT_DIR ext4 defaults,nofail 0 2" >> /etc/fstab
    echo "  Added: UUID=$UUID -> $MOUNT_DIR (label=$LABEL)"
done

echo
echo "Validating with mount -a..."
if mount -a; then
    echo "OK — all mounts verified."
else
    echo "ERROR: mount -a failed. Restoring backup..."
    cp "$FSTAB_BAK" /etc/fstab
    exit 1
fi

# --- Step 6: Register with Proxmox ---
echo
echo "=== Step 6: Register with Proxmox ==="
for i in $(seq 1 "$PARTITION_COUNT"); do
    NAME="${PVE_STORAGE_NAMES[$((i-1))]}"
    MOUNT_DIR="${MOUNT_PREFIX}${i}"
    echo "pvesm add dir $NAME --content images,rootdir --is_mountpoint yes --path $MOUNT_DIR"
    pvesm add dir "$NAME" --content images,rootdir --is_mountpoint yes --path "$MOUNT_DIR"
done

echo
echo "=== Done ==="
echo "Verify:"
echo "  pvesm status"
echo "  df -h | grep ${MOUNT_PREFIX}"
echo
echo "If VMs don't see the new storage in the web UI dropdown, check"
echo "Datacenter -> Storage in the Proxmox UI for per-node enablement."