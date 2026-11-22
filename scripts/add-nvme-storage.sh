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
# The script prompts for everything it needs, and only takes a blank disk.

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
# sysfs pads NVMe serials and has none for SATA, so ask lsblk and ignore spaces.
squash() { tr -d '[:blank:]' <<<"$1"; }
BOOT_KEY=$(squash "$BOOT_SERIAL")
ALL_SERIALS=$(lsblk -dn -o SERIAL | tr -d '[:blank:]')
if [[ -z "$BOOT_KEY" ]] || ! grep -qxF -- "$BOOT_KEY" <<<"$ALL_SERIALS"; then
    echo "ERROR: no disk here has the serial '$BOOT_SERIAL'. Aborting."
    exit 1
fi
boot_use=
while IFS= read -r name; do
    key=$(lsblk -dn -o SERIAL "/dev/$name" | tr -d '[:blank:]') || continue
    [[ "$key" != "$BOOT_KEY" ]] || boot_use+=" $(lsblk -nr -o MOUNTPOINT,LABEL "/dev/$name")"$'\n'
done < <(lsblk -dn -o NAME)
if ! grep -qE '(^|[[:space:]])(/|/boot|/boot/efi|rpool)([[:space:]]|$)' <<<"$boot_use"; then
    echo "ERROR: '$BOOT_SERIAL' is not the boot disk's serial (no /, /boot or rpool on it). Aborting."
    exit 1
fi
echo "Excluding boot drive: $BOOT_SERIAL"
echo

# Show candidate drives
echo "Candidate drives (excluding boot):"
while IFS= read -r name; do
    key=$(lsblk -dn -o SERIAL "/dev/$name" | tr -d '[:blank:]') || continue
    if [[ -n "$key" && "$key" != "$BOOT_KEY" ]]; then
        echo "  $(lsblk -dn -o NAME,SIZE,MODEL,SERIAL "/dev/$name")"
    fi
done < <(lsblk -dn -o NAME)

echo
read -p "Enter the TARGET drive (e.g. /dev/nvme2n1): " TARGET_DRIVE
if [[ ! -b "$TARGET_DRIVE" ]]; then
    echo "ERROR: $TARGET_DRIVE is not a block device"
    exit 1
fi

TARGET_DRIVE=$(readlink -f "$TARGET_DRIVE")
# nvme0n1 -> nvme0n1p1, sdb -> sdb1
part() { case "$TARGET_DRIVE" in *[0-9]) echo "${TARGET_DRIVE}p$1";; *) echo "${TARGET_DRIVE}$1";; esac; }
# Confirm identity
if [[ "$(lsblk -dn -o TYPE "$TARGET_DRIVE")" != "disk" ]]; then
    echo "ERROR: $TARGET_DRIVE is not a whole disk. Aborting."
    exit 1
fi
TARGET_SERIAL=$(lsblk -dn -o SERIAL "$TARGET_DRIVE")
TARGET_KEY=$(squash "$TARGET_SERIAL")
if [[ -z "$TARGET_KEY" ]]; then
    echo "ERROR: cannot read the serial of $TARGET_DRIVE, so cannot rule out the boot drive. Aborting."
    exit 1
fi
TARGET_MODEL=$(cat "/sys/block/$(basename "$TARGET_DRIVE")/device/model" 2>/dev/null || echo "unknown")
echo
echo "Target: $TARGET_DRIVE ($TARGET_MODEL, S/N $TARGET_SERIAL)"
if [[ "$TARGET_KEY" == "$BOOT_KEY" ]]; then
    echo "ERROR: That is the BOOT DRIVE. Aborting."
    exit 1
fi
# The typed serial can name the wrong disk, and "in use" cannot be listed in
# full (btrfs mirrors, Ceph, passthrough, cold backups), so take only a blank
# disk: not mounted, no partitions or holders, no signature of any kind.
TARGET_TREE=$(lsblk -nr -o NAME "$TARGET_DRIVE")
TARGET_USE=$(lsblk -nr -o MOUNTPOINT,FSTYPE "$TARGET_DRIVE")
if ! TARGET_SIGS=$(wipefs --no-act "$TARGET_DRIVE"); then
    echo "ERROR: cannot read what is on $TARGET_DRIVE. Aborting."
    exit 1
fi
if [[ $(wc -l <<<"$TARGET_TREE") -ne 1 || -n "$TARGET_SIGS" || "$TARGET_USE" =~ [^[:space:]] ]]; then
    echo "ERROR: $TARGET_DRIVE is not blank (partitions, data or in use). Aborting."
    echo "This script only sets up blank disks. If this one is disposable, the user must clear it by hand first."
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
read -p "Mount point prefix (e.g. /mnt/data): " MOUNT_PREFIX
if [[ ! "$MOUNT_PREFIX" =~ ^/mnt/ ]]; then
    echo "ERROR: mount point must start with /mnt/"
    exit 1
fi

read -p "Proxmox storage names (space-separated, e.g. 'data-a data-b'): " PVE_NAMES_RAW
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
    PART=$(part "$i")
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
on_dir() { [[ "$(findmnt -n -o UUID --mountpoint "$1")" == "$2" ]]; }
UUIDS=()
for i in $(seq 1 "$PARTITION_COUNT"); do
    PART=$(part "$i")
    if ! UUID=$(blkid -s UUID -o value "$PART") || [[ -z "$UUID" ]] || ! on_dir "${MOUNT_PREFIX}${i}" "$UUID"; then
        echo "ERROR: $PART is not formatted and mounted on ${MOUNT_PREFIX}${i}. /etc/fstab is unchanged."
        exit 1
    fi
    UUIDS+=("$UUID")
done
for i in $(seq 1 "$PARTITION_COUNT"); do
    if ! n=$(awk -v d="${MOUNT_PREFIX}${i}" '$1 !~ /^#/ && $2 == d {n++} END {print n+0}' /etc/fstab) || [[ "$n" != 0 ]]; then
        echo "ERROR: /etc/fstab already has, or can't be checked for, ${MOUNT_PREFIX}${i}. It is unchanged."
        exit 1
    fi
done
FSTAB_BAK="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/fstab "$FSTAB_BAK"
echo "Backed up to $FSTAB_BAK"

for i in $(seq 1 "$PARTITION_COUNT"); do
    UUID=${UUIDS[$((i-1))]}
    MOUNT_DIR="${MOUNT_PREFIX}${i}"
    echo "UUID=$UUID $MOUNT_DIR ext4 defaults,nofail 0 2" >> /etc/fstab
    echo "  Added: UUID=$UUID -> $MOUNT_DIR (label=${PVE_STORAGE_NAMES[$((i-1))]})"
done

echo
echo "Validating by remounting each one from fstab..."
# mount -a skips what is already mounted and exits 0 when a nofail device is missing.
remounted() {
    local i dir
    for i in $(seq 1 "$PARTITION_COUNT"); do
        dir="${MOUNT_PREFIX}${i}"
        umount "$dir" && mount "$dir" && on_dir "$dir" "${UUIDS[$((i-1))]}" || return 1
    done
}
if remounted; then
    echo "OK — all mounts verified."
else
    echo "ERROR: a partition does not mount from fstab. Restoring backup of fstab (some of them may now be unmounted)..."
    cp "$FSTAB_BAK" /etc/fstab
    exit 1
fi

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