# ISO Upload Workflow — Worked Example

Reference session: copying ISOs from a Ventoy USB (Samsung 232GB SSD) onto
a Proxmox 9.2 host with `local` storage (`/var/lib/vz`) backing a 68GB
root volume. The Ventoy partition was exfat, mounted at `/mnt/ventoy`,
held 9 ISOs (~30GB total).

## Pre-flight: always check space first

Before any bulk copy, run this from the agent user's shell:

```bash
# Source: total size of ISOs we're about to copy
sudo -n find /mnt/source -maxdepth 2 -name "*.iso" -printf "%s\n" | \
    awk '{s+=$1} END {printf "%.1f GB\n", s/1024/1024/1024}'

# Target: free space on the destination
df -h /var/lib/vz
```

If the source size is within 80% of target free space, **stop and ask the
user before continuing.** This single check has prevented at least one
disk-full emergency in practice.

## The successful path

```bash
# 1. Mount the source (sudoers must include mount + mkdir)
sudo -n mkdir -p /mnt/ventoy
sudo -n mount /dev/sda1 /mnt/ventoy

# 2. Verify mount + contents
mount | grep ventoy
sudo -n find /mnt/ventoy -maxdepth 2 -name "*.iso"

# 3. Copy
sudo -n cp /mnt/ventoy/*.iso /var/lib/vz/template/iso/

# 4. Confirm via Proxmox API
sudo -n pvesh get /nodes/localhost/storage/local/content --content iso

# 5. Unmount (don't leave USBs mounted indefinitely)
sudo -n umount /mnt/ventoy
```

## The emergency: source bigger than target free space

What happened: a `cp /mnt/ventoy/*.iso /var/lib/vz/template/iso/`
appeared to succeed silently, but immediately after, `df -h /` showed
the root volume at 100%. The disk was full.

**Why this can happen silently:**

- `cp` to an exfat source on a slow USB can take minutes; the agent
  sees no intermediate progress.
- If the source has files larger than expected (e.g. a 30GB Windows
  ISO mixed in with Linux ISOs), the cumulative size can exceed
  available space.
- The Proxmox `local` storage defaults to the root volume on a fresh
  install — there's no separate ISO-only volume until the user creates
  one.

**Triage path when this happens:**

1. **Stop all writes.** Don't try to copy more, don't try to delete
   files yet — a full disk can cause `rm` itself to fail if the journal
   can't flush.
2. **Ask the user to run as root on Proxmox:**
   ```bash
   du -sh /var/lib/vz/* 2>/dev/null | sort -h | tail -10
   ```
   This shows the top consumers. `/var/lib/vz/template/iso/` will
   usually be the answer if ISOs were just copied.
3. **If the user can't run `du` (full disk makes even bash slow),**
   fall back to checking by directory:
   ```bash
   ls -lah /var/lib/vz/template/iso/
   ```
   At minimum you can see file sizes and pick which ISOs to delete.
4. **Remove the offender as root** — typically the largest ISOs that
   weren't actually needed, or all of them if the user's intent was
   to confirm the copy mechanism works, not to keep them all.
5. **Verify recovery:** `df -h /` should show non-zero free space
   before resuming other work.

## Prevention: better sudoers defaults

When setting up the agent's sudoers for a Proxmox host, include the
disk-observation tools so the agent can self-diagnose without needing
the user to step in:

```sudoers
# Disk + filesystem observation (read-only)
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/df *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/du -sh /*
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/find /* -maxdepth *
zen-agent ALL=(ALL) NOPASSWD: /usr/bin/ls *
```

The blast radius of "the agent can see disk usage" is zero. The
operational cost of "the agent filled the disk and can't see why" is
a full session interruption while the user runs diagnostics manually.

## Post-copy verification

```bash
# Should list every ISO you just copied, with sizes
sudo -n pvesh get /nodes/localhost/storage/local/content --content iso

# Should match what's mounted at /mnt/ventoy
sudo -n find /mnt/ventoy -maxdepth 2 -name "*.iso" -printf "%f\n" | sort > /tmp/source.txt
sudo -n ls /var/lib/vz/template/iso/ | sort > /tmp/dest.txt
diff /tmp/source.txt /tmp/dest.txt
```

If `diff` shows any differences, the copy didn't get everything —
likely an interrupted USB read or a file too large for the destination.

## Unmount safety

```bash
# Always umount before physically unplugging the USB
sudo -n umount /mnt/ventoy

# Verify
mount | grep ventoy   # should be empty

# Then it's safe to unplug
```

`umount` on a busy filesystem will fail with `target is busy` — usually
because some process has a file handle open. Identify the offender
with `lsof /mnt/ventoy` or `fuser /mnt/ventoy` and stop that process
before retrying. Never `umount -f` on a USB unless you're prepared for
filesystem corruption.