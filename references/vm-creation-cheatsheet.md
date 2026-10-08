# Proxmox VM Creation Cheatsheet

Common `qm create` invocations for typical homelab VMs. All assume
an ISO storage pool named `iso` and a VM disk storage pool named
`vmdata` (or whichever you registered with `pvesm add dir`).

## General command shape

```bash
qm create <vmid> \
    --name <vm-name> \
    --memory <mb> \
    --cores <n> \
    --sockets 1 \
    --cpu host \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --ostype l26 \
    --scsi0 <storage>:<size>,format=qcow2 \
    --ide2 <iso-storage>:iso/<iso-filename>,media=cdrom \
    --boot order=ide2 \
    --agent enabled=1
```

The `--ostype l26` is Linux 2.6+ kernel (any modern Linux). Other
options: `win11`, `win10`, `win8`, `win7`, `solaris`, `other`.

## Ubuntu Server 24.04 LTS

```bash
qm create 100 \
    --name ubuntu-server \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --ostype l26 \
    --scsi0 vmdata:32,format=qcow2 \
    --ide2 iso:iso/ubuntu-24.04.2-live-server-amd64.iso,media=cdrom \
    --boot order=ide2 \
    --agent enabled=1
```

After install, switch boot order to disk-only and detach ISO:

```bash
qm set 100 --boot order=scsi0
qm set 100 --ide2 none
```

## Debian 12 (Bookworm)

Same as Ubuntu but with the Debian netinst ISO:

```bash
qm create 101 \
    --name debian-12 \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --ostype l26 \
    --scsi0 vmdata:32,format=qcow2 \
    --ide2 iso:iso/debian-12.5.0-amd64-netinst.iso,media=cdrom \
    --boot order=ide2 \
    --agent enabled=1
```

## With cloud-init (Ubuntu / Debian / Fedora cloud images)

For headless VMs that auto-configure user/ssh/network on first boot:

```bash
# 1. Download the cloud image to the host (or use the API's download-url with
#    content=import and a checksum; see SKILL.md)
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
    -O /root/noble-server-cloudimg-amd64.img

# 2. Create the VM referencing that image as the disk source
qm create 102 \
    --name ubuntu-cloud \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --ostype l26 \
    --scsi0 vmdata:0,import-from=/root/noble-server-cloudimg-amd64.img \
    --ide2 vmdata:cloudinit \
    --boot order=scsi0 \
    --serial0 socket --vga serial0 \
    --agent enabled=1 \
    --ciuser <user> \
    --ipconfig0 ip=dhcp \
    --ciupgrade 0 \
    --sshkeys /root/.ssh/authorized_keys
qm resize 102 scsi0 20G   # the imported disk is only as big as the image

# 3. Convert to a template for cloning (optional)
qm template 102
```

`--ide2 <storage>:cloudinit` adds the cloud-init drive; Proxmox regenerates
its contents from `--ciuser`, `--sshkeys`, `--ipconfig0` and friends. The
image has no `qemu-guest-agent` on Ubuntu and Debian; install it with a
`--cicustom vendor=...` snippet (see SKILL.md) or the IP never shows up.
`--ciupgrade 0` skips the default full upgrade on first boot.

## Windows 11 (UEFI + TPM)

Windows 11 requires UEFI, SecureBoot, and a TPM. Proxmox has
templates for this:

```bash
qm create 103 \
    --name windows-11 \
    --memory 8192 \
    --cores 4 \
    --net0 virtio,bridge=vmbr0 \
    --ostype win11 \
    --scsi0 vmdata:64,format=qcow2 \
    --ide2 iso:iso/Win11_23H2_English_x64v1.iso,media=cdrom \
    --boot order=ide2 \
    --bios ovmf \
    --efidisk0 vmdata:1,format=qcow2 \
    --tpmstate0 vmdata:1,version=v2.0 \
    --machine pc-q35-8.1 \
    --agent enabled=1
```

The TPM state file lives on the same storage as the disk. For the
VirtIO drivers ISO (needed for Windows to see the virtio NIC and
disk during install), attach a second CD-ROM:

```bash
qm set 103 --ide3 iso:iso/virtio-win-0.1.240.iso,media=cdrom
```

## LXC container (Debian 12)

LXC is faster to provision than a full VM. Requires a Debian template
on a storage pool with `vztmpl` content type:

```bash
# Download template once
pveam update
pveam download local debian-12-standard_12.5-1_amd64.tar.zst

# Create container
pct create 200 local:vztmpl/debian-12-standard_12.5-1_amd64.tar.zst \
    --hostname debian-ct \
    --memory 1024 \
    --cores 2 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp \
    --rootfs vmdata:16 \
    --features nesting=1 \
    --unprivileged 1 \
    --password <bcrypt-or-plaintext> \
    --start 1
```

The `--password` value, if not a bcrypt hash, must be wrapped in
single quotes and passed literally — Proxmox warns but accepts plain
text passwords for LXC.

## Useful follow-up commands

```bash
# Resize disk after VM is created (live or stopped)
qm resize <vmid> scsi0 +10G

# Add a second NIC
qm set <vmid> --net1 virtio,bridge=vmbr0,tag=10

# Add a data disk on a different storage pool
qm set <vmid> --scsi1 vmdata2a:100

# Snapshot before a risky change
qm snapshot <vmid> before-upgrade

# Start / stop / shutdown (gentle)
qm start <vmid>
qm shutdown <vmid>
qm stop <vmid>     # hard power-off, like pulling the plug

# Console info (for the web UI "Console" button)
qm terminal <vmid>   # opens serial terminal
qm vncproxy <vmid>   # opens noVNC (use from web UI instead)
```

## Common gotchas

- **`--ide2 none` to detach an ISO.** Just `--ide2` without the ISO
  path doesn't work; you must explicitly say `none`.
- **`qm set` doesn't accept `--net0` to delete** — use `--delete net0`
  instead. Different verbs for different actions in `qm set`.
- **Cloud-init passwords:** Proxmox stores `--cipassword` as a hash, not
  plain text. Most cloud images still refuse SSH password logins unless a
  snippet sets `ssh_pwauth: true`. Keep the password off command lines: set
  it through the API with `--data-urlencode cipassword@<file>`, which curl
  reads from the file.
- **Boot order matters for installation:** `--boot order=ide2` to
  boot from CD first, then after install `--boot order=scsi0` to boot
  from disk.
- **Agent must be installed in guest for `--agent enabled=1` to work.**
  Linux: install `qemu-guest-agent`. Windows: install the VirtIO guest
  tools ISO's agent. Without it, the Proxmox web UI "Summary" tab
  shows stale IP info.