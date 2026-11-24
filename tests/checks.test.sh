#!/bin/bash
# A failed, empty or unanswered check must never read as success.
# Offline: every Proxmox, disk and network command is a stand-in.
# Run: bash tests/checks.test.sh   (optional arg: another copy of the repo to test)
# shellcheck disable=SC2016  # the stand-ins are single-quoted on purpose
R=$(cd "${1:-$(dirname "$0")/..}" && pwd) || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.ssh" "$T/.config/pve"; echo 'ssh-ed25519 AAAA k' >"$T/.ssh/id_ed25519.pub"
mkdir "$T/bin"
export LOG=$T/log
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
fresh() { rm -f "$T"/bin/*; : >"$LOG"; stub sleep 'exit 0'; }
as_agent() { sed 's/\$EUID -ne 0/1 == 1/' "$R/scripts/$1.sh" >"$T/$1.sh"; echo "$T/$1.sh"; }   # also when the tests run as root
run() { PATH="$T/bin:$PATH" bash "$@" >"$T/out" 2>&1; }
said() { grep -c -- "$1" "$T/out"; }
logged() { grep -cE -- "$1" "$LOG"; }
nonzero() { [[ $1 != 0 ]] && echo yes || echo no; }

# block FILE MARKER: the first fenced block containing MARKER, placeholders filled.
block() {
  awk -v m="$2" '/^ *```/ { if (f) { if (index(b, m)) { printf "%s", b; exit } } f = !f; b = ""; next }
    f { b = b $0 "\n" }' "$R/$1" >"$T/raw"
  if [[ ! -s $T/raw ]]; then
    echo "FAIL no block in $1 contains: $2" >&2
    : >"$T/missing"
  fi
  sed -E -e '/^ *source scripts\//d' -e 's/<[^<>()|&]+>/X/g' "$T/raw"
}
# doc FILE MARKER PRELUDE: run that block as an agent would paste it (no set -e).
doc() { { echo "HOME='$T'"; echo "$3"; block "$1" "$2"; } >"$T/doc"; run "$T/doc"; }

## The disk script must never offer to wipe the boot drive.
sed -e 's/\[\[ \$EUID -ne 0 \]\]/false/' -e 's/\[\[ ! -b "\$TARGET_DRIVE" \]\]/false/' \
  -e "s#/etc/fstab#$T/fstab#g" "$R/scripts/add-nvme-storage.sh" >"$T/add.sh"
disks() {
  fresh
  stub lsblk 'case "$*" in
*"-o SERIAL /dev/zzboot"|*"-o SERIAL /dev/zzboot3") echo "  BOOTSERIAL  ";;
*"-o SERIAL /dev/zznew") echo "NEWSERIAL";;
*"-o SERIAL /dev/zzanon") echo "";;
*"-o SERIAL /dev/"*) exit 32;;
*"-o SERIAL") printf "BOOTSERIAL  \nNEWSERIAL\n";;
*"-o TYPE /dev/zzboot"|*"-o TYPE /dev/zznew"|*"-o TYPE /dev/zzanon") echo disk;;
*"-o TYPE /dev/zzboot3") echo part;;
*"-o MOUNTPOINT,FSTYPE /dev/"*) echo "$USED";;
*"-o MOUNTPOINT,LABEL /dev/zzboot") echo "/boot/efi ESP";;
*"-o MOUNTPOINT,LABEL /dev/zznew") echo "$NEWBOOT";;
*"-o NAME /dev/zzboot3") echo zzboot3;;
*"-o NAME /dev/"*) echo disk; [ -z "$PARTS" ] || echo part;;
*"/dev/zzboot") echo "zzboot 1T M";;
*"/dev/zznew") echo "zznew 1T M";;
*) printf "zznew\nzzboot\n";;
esac'
  stub wipefs 'echo "$SIGS" | sed "/^$/d"; exit "${SIGS_RC:-0}"'
}
wipe_offered() { printf '%b' "$1" | PATH="$T/bin:$PATH" bash "$T/add.sh" >"$T/out" 2>&1; said '^Aborted'; }
export USED='' PARTS='' SIGS='' SIGS_RC=0 NEWBOOT='/ root'
disks
check "disk: padded boot serial still refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zzboot\nno\n')" 0
check "disk: empty boot serial refused" "$(wipe_offered '\n/dev/zznew\nno\n')" 0
check "disk: mistyped boot serial refused" "$(wipe_offered 'B0OTSERIAL\n/dev/zznew\nno\n')" 0
check "disk: target without a serial refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zzanon\nno\n')" 0
check "disk: partition refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zzboot3\nno\n')" 0
check "disk: partition refused when another disk was excluded" "$(wipe_offered 'NEWSERIAL\n/dev/zzboot3\nno\n')" 0
USED='/boot/efi vfat'
check "disk: mounted disk refused" "$(wipe_offered 'NEWSERIAL\n/dev/zzboot\nno\n')" 0
USED=
SIGS='0x10040 btrfs'
check "disk: btrfs mirror half refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n')" 0
SIGS='0x438 ext4'
check "disk: unmounted data refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n')" 0
SIGS='' PARTS=1
check "disk: partitioned disk refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n')" 0
PARTS='' SIGS_RC=1
check "disk: unreadable signatures refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n')" 0
SIGS_RC=0
NEWBOOT=
check "disk: a serial that is not the boot disk's refused" "$(wipe_offered 'NEWSERIAL\n/dev/zzboot\nno\n'; said 'not the boot')" $'0\n1'
NEWBOOT='/ root'
check "disk: candidates leave out only the boot drive" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n' >/dev/null; sed -n '/^Candidate drives/,/^$/p' "$T/out" | grep -oE 'zzboot|zznew' | tr -d '\n')" zznew
check "disk: a good target is still offered" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n')" 1

# mountpoints: UP=1 while mounted; a broken fstab line leaves it down, exit 0 (nofail).
MOUNTS='stub findmnt "[ -e $T/up ] && echo 1111-2222"
stub umount "rm -f $T/up"'
partition_run() {
  disks; eval "$MOUNTS"
  echo '# original' >"$T/fstab"; : >"$T/up"
  stub blkid "$2"; stub mount "$1"
  stub pvesm 'echo "pvesm $*" >>"$LOG"'
  printf "BOOTSERIAL\n/dev/zznew\nyes\n$3\n/mnt/zz\n$4\n\n\n" | PATH="$T/bin:$PATH" bash "$T/add.sh" >"$T/out" 2>&1
}
partition_run 'exit 0' 'echo 1111-2222' 1 store
check "disk: a broken fstab line is not 'verified'" "$(said 'mounts verified')" 0
check "disk: a broken fstab line is not registered" "$(logged '^pvesm add')" 0
check "disk: a broken fstab line is taken out again" "$(grep -c UUID "$T/fstab")" 0
partition_run 'exit 0' 'echo 1111-2222' 1 store
check "disk: a name without a digit gets no 'p'" "$(said 'mkfs.ext4 -L store /dev/zznew1$')" 1
partition_run 'exit 0' 'case "$*" in *2) exit 2;; esac; echo 1111-2222' 2 'one two'
check "disk: unreadable second partition leaves fstab as it was" "$(grep -c UUID "$T/fstab")" 0

## pve_api and pve_wait
fresh
stub curl 'echo "{\"data\":null}"; case " $* " in *" --fail-with-body "*) exit 22;; esac; exit 0'
echo token >"$T/tok"; echo pin >"$T/pin"
(export PVE_HOST=h PVE_TOKEN_FILE=$T/tok PVE_PIN_FILE=$T/pin PATH=$T/bin:$PATH
  source "$R/scripts/pve-api.sh"; pve_api POST /x >/dev/null 2>&1)
check "pve_api: refused write is non-zero" "$(nonzero $?)" yes
fresh
stub curl 'echo "$*" >>"$LOG"'
echo SECRETTOKEN >"$T/tok"
(export PVE_HOST=h PVE_TOKEN_FILE=$T/tok PVE_PIN_FILE=$T/pin PATH=$T/bin:$PATH
  source "$R/scripts/pve-api.sh"; pve_api GET /x >/dev/null 2>&1)
check "pve_api: token is not in curl's arguments" "$(logged SECRETTOKEN)" 0
check "pve_api: requests have a timeout" "$(logged '--max-time')" 1

# jq 1.6 (Debian 12, Ubuntu 22.04) exits 0 for -e on empty input.
fresh
export REAL_JQ; REAL_JQ=$(command -v jq)
OLD_JQ='case " $* " in *" -e "*) i=$(cat); [[ -n ${i//[[:space:]]/} ]] || exit 0; printf "%s" "$i" | "$REAL_JQ" "$@"; exit;; esac
exec "$REAL_JQ" "$@"'
stub jq "$OLD_JQ"
out=$(
  export PATH=$T/bin:$PATH
  source "$R/scripts/pve-api.sh"
  pve_api() { if [[ -e $T/asked ]]; then echo '{"data":{"status":"stopped","exitstatus":"OK"}}'; else : >"$T/asked"; fi; }
  pve_wait 'UPID:n:1:2:3:t:1:u:' 30 2>/dev/null)
check "pve_wait: empty answer is not a finished task" "$out" OK

## Recipes: a failed step stops the steps after it.
REFUSE='pve_api() { echo "api $*" >>"$LOG"; echo "{\"data\":null}"; return 22; }
pve_task() { echo "api $*" >>"$LOG"; return 1; }
pve_wait() { return 1; }; pve_vm_ip() { return 2; }
ssh() { echo "ssh $*" >>"$LOG"; }'
fresh
doc SKILL.md '/9000/template' "$REFUSE"
check "template: refused step stops resize, convert, start" "$(logged 'resize|/template|status/start')" 0
fresh
doc SKILL.md 'newid=<vmid> --data-urlencode name=<name>' "$REFUSE"
check "clone: refused clone stops resize and start" "$(logged 'resize|/config|status/start')" 0

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'
stub qm 'echo "qm $*" >>"$LOG"; [ "$1" != create ]'
doc SKILL.md 'sudo -n qm create' ''
check "qm recipe: refused create does not start that id" "$(logged '^qm (start|monitor)')" 0
fresh
stub qm 'echo "qm $*" >>"$LOG"; [ "$1" != create ]'
stub wget 'exit 0'
doc references/vm-creation-cheatsheet.md 'qm template 102' ''
check "cheatsheet: refused create does not convert that id" "$(logged '^qm (resize|template)')" 0

fresh
doc SKILL.md '?purge=1' "$REFUSE
node=n copy=100"
check "removal: nothing sent unless this restore succeeded" "$(logged '^api')" 0

NET='pve_api() { echo "api $*" >>"$LOG"; [[ $FAILS == *"$1"* ]] && { echo "{\"data\":null}"; return 22; }; echo "{\"data\":{\"active\":1}}"; }
pve_task() { echo "api $*" >>"$LOG"; [[ $FAILS != *"$1"* ]]; }
pve_wait() { [[ $FAILS != *PUT* ]]; }
ssh() { echo "ssh $*" >>"$LOG"; case "$*" in *systemd-run*) [[ $FAILS != *arm* ]];; *interfaces.new*) [[ $FAILS != *pending* ]];; esac; }'
fresh; doc SKILL.md 'net-revert' "FAILS=pending; $NET"
check "network: pending changes stop the apply" "$(logged '^api (POST|PUT)')" 0
fresh; doc SKILL.md 'net-revert' "FAILS=arm; $NET"
check "network: no revert timer, no apply" "$(logged '^api (POST|PUT)')" 0
fresh; doc SKILL.md 'net-revert' "FAILS=PUT; $NET"
check "network: failed apply keeps the revert" "$(logged 'stop net-revert')" 0
fresh; stub jq "$OLD_JQ"
doc SKILL.md 'net-revert' "FAILS=; $NET
pve_api() { [[ \$1 != GET ]] && echo '{\"data\":null}'; return 0; }"
check "network: empty verify keeps the revert on jq 1.6" "$(logged 'stop net-revert')" 0
fresh; doc SKILL.md 'net-revert' "FAILS=; $NET"
check "network: good run still disarms" "$(logged 'stop net-revert')" 1
fresh; doc SKILL.md 'net-revert' "FAILS=; $NET
ssh() { echo \"ssh \$*\" >>\"\$LOG\"; case \"\$*\" in *'systemctl stop'*) return 1;; esac; }"; rc=$?
check "network: a revert that fired is not 'disarmed'" "$(nonzero $rc)" yes
check "network: snapshot and timer are per run" "$(block SKILL.md 'net-revert' | grep -c 'interfaces.pre-agent[^-]\|unit=net-revert ')" 0
check "network: revert clears the staged file" "$(block SKILL.md 'net-revert' | grep -c 'rm -f /etc/network/interfaces.new')" 1

READS='pve_vm_identity() { echo id; }; pve_api() { case "$*" in *file-read*) echo "$GOT";; *) echo "{\"data\":\"UPID:x\"}";; esac; }
pve_task() { return 0; }; pve_wait() { return 0; }; pve_isolate_copy() { return 0; }'
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT=; $READS"; rc=$?
check "restore: unread data exits non-zero" "$(nonzero $rc)" yes
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT='{\"data\":{\"content\":\"something else\"}}'; $READS"; rc=$?
check "restore: wrong data exits non-zero" "$(nonzero $rc)" yes
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT='{\"data\":{\"content\":\"X\"}}'; $READS"; rc=$?
check "restore: matching data exits zero" "$(nonzero $rc)" no
check "restore: the file is not printed" "$(block SKILL.md 'pve_isolate_copy "$node"' | grep -c 'echo.*[$]got')" 0
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT='{\"data\":{\"content\":\"X\\n\"}}'; $READS"; rc=$?
check "restore: a different final newline is not a match" "$(nonzero $rc)" yes
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT='{\"data\":{\"content\":\"X\",\"truncated\":true}}'; $READS"; rc=$?
check "restore: a cut file is not a match" "$(nonzero $rc)" yes

fresh
stub blkid 'exit 2'; stub sudo '[ "$1" != tee ] || { echo "sudo $*" >>"$LOG"; exit 0; }; exec "$@"'; stub mount 'exit 0'; stub df 'exit 0'; stub findmnt 'exit 1'
doc SKILL.md 'UUID=$(' ''
check "fstab: no UUID, no line written" "$(logged 'tee -a')" 0

fresh
stub curl 'exit 22'; stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: failed check installs nothing" "$(logged '^uv ')" 0
fresh
stub curl 'echo "{\"attestation_bundles\":[{\"publisher\":{\"repository\":\"john-broadway/proximo\",\"workflow\":\"release-pypi.yml\"}}]}"; exit 18'
stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: a cut transfer installs nothing" "$(logged '^uv ')" 0

fresh
stub curl 'echo "{\"data\":null}"; case " $* " in *" --fail-with-body "*) exit 22;; esac; exit 0'
doc references/proxmox-api-token.md '-X POST' 'cat() { echo x; }'; rc=$?
grep -c -- '-H "\$AUTH"\|-H "Authorization' "$R/references/proxmox-api-token.md" >"$T/argv"
check "token reference: refused create is non-zero" "$(nonzero $rc)" yes
check "token reference: token is not in curl's arguments" "$(sed -n 1p "$T/argv")" 0

fresh
stub pvesh 'echo "not json"; exit 1'
doc references/cluster.md '--tags "homelab' ''; rc=$?
check "cluster tag: refused change is non-zero" "$(nonzero $rc)" yes

fresh
stub sudo 'exit 1'
doc references/iso-workflow.md 'diff ' ''; rc=$?
check "iso diff: two failed listings are not a match" "$(nonzero $rc)" yes

fresh
stub install ': >"${@: -1}"'; stub jq 'echo "jq" >>"$LOG"; exit 1'; stub rm 'echo "rm $*" >>"$LOG"'
doc SKILL.md 'rm token-response.json' "cd '$T'; HOME='$T'; PIN=x"
check "bootstrap: unsaved token is not deleted" "$(logged '^rm ')" 0
check "bootstrap: that test really reached jq" "$(logged '^jq')" 1

## Scripts
for s in proxmox-status cluster-info; do
  fresh
  for c in uptime free df lsblk pvesh pvesm qm pct pvecm ha-manager journalctl; do stub "$c" 'echo denied >&2; exit 1'; done
  run "$R/scripts/$s.sh"; rc=$?
  check "$s: failed reads exit non-zero" "$(nonzero $rc)" yes
done

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'
stub pvesm 'printf "Volid Format\nlocal:vztmpl/t.tar.zst tzst\n"'
stub pct '[ "$1" != status ] || echo "status: stopped"'
run "$R/scripts/lxc-from-template.sh" --hostname h --template t.tar.zst --ctid 8100; rc=$?
check "lxc: created but not running is non-zero" "$(nonzero $rc)" yes
check "lxc: does not say started" "$(said 'created and started')" 0

fresh
mkdir -p "$T/src" "$T/dst"; echo AAAA >"$T/src/a.iso"
sed 's/\[\[ ! -b "\$VENTOY_DEV" \]\]/false/' "$R/scripts/iso-import.sh" >"$T/iso.sh"
stub mountpoint 'exit 0'
stub findmnt 'case "$*" in "-no SOURCE /") echo boot;; *"-no SOURCE"*) echo data;; *"-no TARGET"*) echo "$SRC";; esac; exit 0'
stub cp 'mkdir -p "$DST/template/iso"; echo BBBB >"$DST/template/iso/a.iso"'
stub pvesm 'exit 0'
echo y | SRC=$T/src DST=$T/dst PATH="$T/bin:$PATH" bash "$T/iso.sh" /dev/zz "$T/dst" >"$T/out" 2>&1; rc=$?
check "iso: same size, different bytes is not verified" "$(nonzero $rc)" yes
check "iso: that test reached the copy" "$([[ -e $T/dst/template/iso/a.iso ]] && echo yes)" yes

fresh
stub visudo 'exit 0'; stub chown 'exit 0'; stub id 'exit 0'
stub sudo 'case "$*" in *"qm list"*) exit 1;; esac; exit 0'
sed -e "s#/etc/sudoers.d/zen-agent#$T/sudoers#g" -e "s#^SUDOERS_SRC=.*#SUDOERS_SRC=$R/templates/zen-agent-sudoers#" \
  "$R/templates/install-sudoers.sh" >"$T/sudoers.sh"
run "$T/sudoers.sh"; rc=$?
check "sudoers: rules listed but qm denied is non-zero" "$(nonzero $rc)" yes

## Controls: with every step working, the same blocks do their job.
OK='pve_api() { echo "api $*" >>"$LOG"; echo "{\"data\":{}}"; }
pve_task() { echo "api $*" >>"$LOG"; }; pve_vm_ip() { echo ip; }
ssh() { echo "ssh $*" >>"$LOG"; }'
fresh; mkdir -p "$T/.ssh" "$T/.config/pve"; echo 'ssh-ed25519 AAAA k' >"$T/.ssh/id_ed25519.pub"
doc SKILL.md '/9000/template' "HOME='$T'; $OK"
check "template: good run converts" "$(logged '/9000/template')" 1
fresh; doc SKILL.md '# 4a.' "$OK"
check "clone 4a: good run starts" "$(logged 'status/start')" 1
fresh; doc SKILL.md '# 4b.' "$REFUSE"
check "clone 4b: refused clone stops resize and start" "$(logged 'resize|/config|status/start')" 0
fresh; doc SKILL.md '# 4b.' "$OK"
check "clone 4b: good run starts" "$(logged 'status/start')" 1
fresh; doc SKILL.md '?purge=1' "$OK
node=n copy=100 restored=n/100 restored_id=same
pve_vm_identity() { echo same; }"
check "removal: good run deletes" "$(logged '^api DELETE')" 1
fresh; doc SKILL.md '?purge=1' "$OK
node=n copy=100 restored=n/100 restored_id=same
pve_vm_identity() { echo replaced; }"
check "removal: a replacement at the same id is not deleted" "$(logged '^api')" 0
fresh; doc SKILL.md '?purge=1' "$OK
node=n copy=100 restored=n/8100"
check "removal: another id is not deleted" "$(logged '^api')" 0

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'; stub qm 'echo "qm $*" >>"$LOG"'
doc SKILL.md 'sudo -n qm create' ''
check "qm recipe: good run starts" "$(logged '^qm start')" 1
fresh
stub qm 'echo "qm $*" >>"$LOG"'; stub wget 'exit 0'
doc references/vm-creation-cheatsheet.md 'qm template 102' ''
check "cheatsheet: good run converts" "$(logged '^qm template')" 1

fresh
stub curl 'echo "{\"attestation_bundles\":[{\"publisher\":{\"repository\":\"john-broadway/proximo\",\"workflow\":\"release-pypi.yml\"}}]}"'
stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: the project's own release installs" "$(logged '^uv ')" 1
fresh
stub curl 'echo "{\"attestation_bundles\":[{\"publisher\":{\"repository\":\"someone/else\"}}]}"'
stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: another publisher installs nothing" "$(logged '^uv ')" 0
fresh
stub curl 'echo "{\"attestation_bundles\":[{\"publisher\":{\"repository\":\"john-broadway/proximo\",\"workflow\":\"other.yml\"}}]}"'
stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: another workflow installs nothing" "$(logged '^uv ')" 0

fresh
stub blkid 'echo 1111'; stub umount 'exit 0'; stub sudo '[ "$1" != tee ] || { echo "sudo $*" >>"$LOG"; exit 0; }; exec "$@"'
stub mount 'exit 0'; stub findmnt 'echo 1111'; stub df 'echo mounted'
doc SKILL.md 'UUID=$(' ''; rc=$?
check "fstab: good run exits zero" "$rc" 0

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'; stub find 'printf "b.iso\na.iso\n"'; stub ls 'printf "a.iso\nb.iso\nolder.iso\n"'
doc references/iso-workflow.md 'diff ' ''; rc=$?
check "iso diff: all names present exits zero" "$rc" 0
stub ls 'printf "a.iso\n"'
doc references/iso-workflow.md 'diff ' ''; rc=$?
check "iso diff: a missing name exits non-zero" "$(nonzero $rc)" yes

fresh
echo '{"data":{"full-tokenid":"a@pve!t","value":"s"}}' >"$T/token-response.json"
doc SKILL.md 'rm token-response.json' "cd '$T'; HOME='$T'; PIN=x"
check "bootstrap: saved token deletes the response" "$([[ -e $T/token-response.json ]] && echo kept || echo deleted)" deleted

partition_run "touch $T/up" 'echo 1111-2222' 1 store
check "disk: mounted partition is registered" "$(logged '^pvesm add')" 1

(set -euo pipefail
  source "$R/scripts/pve-api.sh"
  sleep() { :; }
  pve_api() { if [[ -e $T/agent ]]; then echo '{"data":{"result":[{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.0.5"}]}]}}'; else : >"$T/agent"; return 22; fi; }
  pve_vm_ip n 1 30) >"$T/out" 2>&1
check "pve_vm_ip: keeps polling under set -e" "$(tail -1 "$T/out")" 10.0.0.5

fresh
echo 1111 >"$T/uuid"; : >"$T/up"
stub blkid 'echo 1111'; stub sudo '[ "$1" != tee ] || exit 0; exec "$@"'
stub mount 'exit 0'; stub umount "rm -f $T/up"; stub findmnt "[ -e $T/up ] && echo 1111"; stub df 'exit 0'
doc SKILL.md 'UUID=$(' ''; rc=$?
check "fstab: a broken line fails although it was mounted by hand" "$(nonzero $rc)" yes

## Every recipe with several writes: the first failure is the last write.
WRITERS='qm pct pveum pveam zpool pvcreate vgcreate lvcreate mount umount cp mkdir ha-manager pvecm'
chain() { # FILE MARKER NAME
  local c
  fresh
  stub sudo '[ "$1" = -n ] && shift; exec "$@"'
  for c in $WRITERS; do stub "$c" "echo $c >>\"\$LOG\"; exit 1"; done
  stub pvesm '[ "$1" != add ] || { echo pvesm >>"$LOG"; exit 1; }'
  stub pvesh 'case "$1" in create|set) echo pvesh >>"$LOG"; exit 1;; esac'
  stub qm 'if [ "$1" = config ]; then echo "net0: virtio=X,bridge=vmbr0"; echo "smbios1: uuid=X"; else echo qm >>"$LOG"; exit 1; fi'
  stub findmnt 'exit 1'; stub mountpoint 'exit 0'; stub find 'exit 1'
  echo "smbios1: uuid=X" >"$T/vm100.id"; echo "smbios1: uuid=X" >"$T/vm103.id"
  doc "$1" "$2" ''
  check "chain: $3" "$([[ $(logged .) == 1 ]] && echo stops || echo "writes: $(logged .)")" stops
}
chain SKILL.md 'mount /dev/sdX1' "ISO copy after a failed mount"
chain SKILL.md 'mount /dev/nvmeXnYp1 /mnt/' "manual mount"
chain SKILL.md 'mkdir -p /mnt/<label>/template/iso' "copy to a storage"
chain SKILL.md 'pveam download local <template-name>' "container recipe"
chain SKILL.md 'Add a rule to allow SSH' "firewall on after a failed allow"
chain references/cluster.md 'pvecm add <existing' "cluster join"
chain references/cluster.md 'ha-manager add vm:100' "HA"
chain references/firewall-basics.md '# Datacenter: the master switch' "firewall switches"
chain references/firewall-basics.md '# Create a group' "firewall group"
chain references/firewall-basics.md '# Allow Tailscale CGNAT' "firewall allow rules"
chain references/firewall-basics.md '# LAN HTTP/HTTPS inbound' "VM firewall on after a failed allow"
chain references/iso-workflow.md '# 1. Mount the source' "ISO workflow"
chain references/proxmox-api-token.md 'pveum user add agent@pve' "token for an existing user"
chain references/proxmox-api-token.md 'pveum pool add agent' "grants on an existing pool"
chain references/storage-layouts.md 'pvcreate' "LVM"
chain references/storage-layouts.md '# Create a mirrored pool' "ZFS"
chain references/storage-layouts.md '# After installing a second disk' "ZFS second disk"
chain references/storage-layouts.md '# Two SSDs in a ZFS mirror' "ZFS mirror and backups"
chain references/vm-creation-cheatsheet.md 'qm set 100 --boot order=scsi0' "qm set on guest 100"
chain references/vm-creation-cheatsheet.md '--ide3 iso:iso/virtio-win' "qm set on guest 103"
chain references/vm-creation-cheatsheet.md 'pct create 200' "container cheatsheet"

fresh
doc SKILL.md 'pve_vm_ip <node> <new-vmid> 180' "$REFUSE
PVE_HOST=h"
check "helper example: refused clone starts nothing" "$(logged 'status/start')" 0

for r in 'SKILL.md|pveam download local <template-name>' 'references/vm-creation-cheatsheet.md|pct create 200'; do
  fresh
  stub sudo '[ "$1" = -n ] && shift; exec "$@"'; stub pveam 'echo debian-13-standard_amd64'
  stub pct '[ "$1" != status ] || echo "status: stopped"'
  doc "${r%%|*}" "${r#*|}" ''; rc=$?
  check "container recipe in ${r%%|*}: not running is non-zero" "$(nonzero $rc)" yes
done

fresh
stub sudo 'exit 1'; stub df 'exit 0'
doc references/iso-workflow.md '%.1f GB' ''; rc=$?
check "space check: failed listing is non-zero" "$(nonzero $rc)" yes
fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'; stub umount 'exit 1'; stub findmnt 'exit 1'
doc references/iso-workflow.md 'Always umount' ''; rc=$?
check "unplug: failed unmount is non-zero" "$(nonzero $rc)" yes

fresh
stub curl 'echo "{\"data\":null}"; case " $* " in *" --fail-with-body "*) exit 22;; esac; exit 0'
stub openssl 'echo key'
doc SKILL.md 'access/ticket' "cd '$T'; H=h; PWFILE=f"; rc=$?
check "bootstrap: refused ticket is non-zero" "$(nonzero $rc)" yes

for s in proxmox-status cluster-info; do
  fresh
  for c in uptime free df lsblk; do stub "$c" 'echo ok'; done
  for c in pvesh pvesm qm pct pvecm ha-manager journalctl; do stub "$c" '[ -n "$AS_ROOT" ] || exit 1; echo ok'; done
  stub sudo '[ "$1" = -n ] && shift; export AS_ROOT=1; case "$1" in pvecm) exit 1;; esac; exec "$@"'
  run "$(as_agent "$s")"
  check "$s: works as the agent user through the allowlist" "$?" 0
done

pt=$(source "$R/scripts/pve-api.sh"
  pve_api() { echo '{"data":null}'; return 22; }
  pve_task POST /x >/dev/null 2>&1; a=$?
  pve_api() { echo '{"data":"UPID:n:1:2:3:t:1:u:"}'; }
  pve_wait() { [[ $1 == UPID:* ]]; }
  pve_task POST /x >/dev/null 2>&1; echo "$(nonzero $a) $?")
check "pve_task: refusal fails, accepted task passes" "$pt" "yes 0"

# iso-import: a partly unreadable source, then a failed storage listing.
iso_run() {
  fresh
  rm -f "$T/dst/template/iso/a.iso"
  stub mountpoint 'exit 0'
  stub findmnt 'case "$*" in "-no SOURCE /") echo boot;; *"-no SOURCE"*) echo data;; *"-no TARGET"*) echo "$SRC";; esac; exit 0'
  stub pvesm "$1"
  stub cp 'mkdir -p "$DST/template/iso"; echo AAAA >"$DST/template/iso/a.iso"'
  [[ -z $2 ]] || stub find "$2"
  echo y | SRC=$T/src DST=$T/dst PATH="$T/bin:$PATH" bash "$T/iso.sh" /dev/zz "$T/dst" >"$T/out" 2>&1
}
iso_run 'exit 0' "printf '%s\\0' \"$T/src/a.iso\"; exit 1"; rc=$?
check "iso: partly unreadable source is non-zero" "$(nonzero $rc)" yes
check "iso: it stopped on the unreadable source, not earlier" "$(said 'could not read all')" 1
iso_run 'exit 1' ''; rc=$?
check "iso: failed storage listing is non-zero" "$(nonzero $rc)" yes
check "iso: that test reached the copy of a readable file" "$([[ -e $T/dst/template/iso/a.iso ]] && echo yes)" yes
iso_run 'exit 0' ''; rc=$?
check "iso: control, all working exits zero" "$rc" 0

for g in '100 qm set 100 --boot order=scsi0' '103 --ide3 iso:iso/virtio-win'; do
  fresh
  stub qm 'if [ "$1" = config ]; then echo "name: ubuntu-server"; echo "name: windows-11"; echo "smbios1: uuid=SOMEONE-ELSE"; else echo "qm $*" >>"$LOG"; fi'
  doc references/vm-creation-cheatsheet.md "${g#* }" ''
  check "cheatsheet: another guest at ${g%% *} is not edited" "$(logged '^qm set')" 0
done

fresh
stub visudo 'exit 0'; stub chown 'exit 0'; stub id 'exit 0'
stub sudo 'case "$*" in *" -l") for i in $(seq 35); do echo rule; /bin/sleep 0.01; done;; esac; exit 0'
sed "s#$T/sudoers#$T/sudoers-long#g" "$T/sudoers.sh" >"$T/long.sh"   # its own destination file
run "$T/long.sh"; rc=$?
check "sudoers: a long rule list does not fail the install" "$rc" 0

fresh
stub openssl 'cat >/dev/null 2>&1; case "$1" in x509) exit 1;; esac; echo fromempty'
stub curl 'echo curl >>"$LOG"'
doc SKILL.md 'access/ticket' "cd '$T'; H=h; PWFILE=f"
check "bootstrap: no certificate, no pin, no password sent" "$(logged '^curl')" 0

fresh
stub install ': >"${@: -1}"'; stub jq 'exit 1'
doc SKILL.md 'rm token-response.json' "cd '$T'; PIN=x"; rc=$?
check "bootstrap: unsaved token is non-zero" "$(nonzero $rc)" yes
fresh
stub install ': >"${@: -1}"'
echo '{"data":{"full-tokenid":"a@pve!t","value":"s"}}' >"$T/token-response.json"
doc SKILL.md 'rm token-response.json' "cd '$T'; PIN="; rc=$?
check "bootstrap: empty pin is non-zero" "$(nonzero $rc)" yes

fresh
stub scp 'exit 1'; stub ssh 'case "$*" in *mktemp*) echo /staging;; *) echo ssh >>"$LOG";; esac'
doc README.md 'sshd -t && systemctl reload ssh' ''
check "sshd step: failed copy reloads nothing" "$(logged '^ssh')" 0
fresh
stub scp 'exit 1'; stub ssh 'case "$*" in *mktemp*) echo /staging;; *) echo ssh >>"$LOG";; esac'
doc README.md 'install-sudoers.sh"' ''
check "sudoers step: failed copy runs nothing" "$(logged '^ssh')" 0

# PVE creates a rule disabled unless told otherwise (measured).
n=$(cat "$R/SKILL.md" "$R"/references/*.md | awk '{ while (sub(/\\$/, "")) { getline next_line; $0 = $0 next_line } print }' |
  grep -E 'pvesh create [^ ]*firewall/(rules|groups/[^ ]+/rules)' | grep -vc -- '--enable 1')
check "firewall: every rule a recipe creates is enabled" "$n" 0

dl=$(grep -n 'storage/local/download-url' "$R/SKILL.md" | cut -d: -f1)
put=$(grep -n 'content=vztmpl,iso,import' "$R/SKILL.md" | cut -d: -f1)
check "template: import is enabled before the download" "$((put < dl))" 1

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'; stub pvesh 'exit 0'
stub qm 'if [ "$1" = config ]; then echo "net0: virtio=X,bridge=vmbr0,tag=30,link_down=1"; else echo "qm $*" >>"$LOG"; fi'
doc references/firewall-basics.md '# Datacenter: the master switch' ''
check "firewall: turning it on keeps VLAN and link state" "$(logged 'tag=30,link_down=1,firewall=1')" 1

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'
stub pvesh 'echo "pvesh $*" >>"$LOG"; [ "$1" != get ] || echo "[]"'
doc SKILL.md 'Add a rule to allow SSH' ''
check "firewall: not switched on without the rule in the list" "$(logged 'options --enable 1')" 0
fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'
stub pvesh 'echo "pvesh $*" >>"$LOG"; [ "$1" != get ] || echo "[{\"action\":\"ACCEPT\",\"enable\":1,\"source\":\"192.168.50.0/24\"}]"'
doc SKILL.md 'Add a rule to allow SSH' ''
check "firewall: good run switches on" "$([[ $(logged 'options --enable 1') -ge 1 ]] && echo yes)" yes
check "firewall: no write to a path with no set" "$(grep -E 'pvesh set [^ ]*/firewall( |$)' "$R/references/firewall-basics.md" | grep -vc "No 'set'\|without\|^Every switch")" 0
check "firewall: group is attached as a rule" "$(grep -c -- '--type group --action web-tier' "$R/references/firewall-basics.md")" 1

check "storage: no forced pool on a guessable device" "$(cat "$R/SKILL.md" "$R"/references/*.md | grep -cE 'zpool create -f|zpool create .*/dev/(nvme|sd)')" 0

fresh
stub sudo '[ "$1" = -n ] && shift; exec "$@"'; stub umount 'exit 0'; stub findmnt 'exit 127'; stub awk 'exit 2'
doc references/iso-workflow.md 'Always umount' ''; rc=$?
check "unplug: a failed mount lookup is non-zero" "$(nonzero $rc)" yes

fresh
for c in pvesh pvesm journalctl; do stub "$c" 'echo ok'; done
stub sudo '[ "$1" = -n ] && shift; exec "$@"'
stub ha-manager '[ "$1" != rules ] || { echo "500 cannot read rules"; exit 1; }; echo ok'
run "$R/scripts/cluster-info.sh"; rc=$?
check "cluster-info: failed HA rules read is non-zero" "$(nonzero $rc)" yes
stub ha-manager '[ "$1" != rules ] || { echo "ERROR: unknown command"; exit 1; }; echo ok'
run "$R/scripts/cluster-info.sh"
check "cluster-info: PVE 8 without rules still passes" "$?" 0

fresh
stub install ': >"${@: -1}"'
echo old-token >"$T/.config/pve/X.token"
echo '{"data":{"full-tokenid":"","value":""}}' >"$T/token-response.json"
doc SKILL.md 'rm token-response.json' "cd '$T'; PIN=x"; rc=$?
check "bootstrap: empty fields are non-zero" "$(nonzero $rc)" yes
check "bootstrap: a failed save keeps the old token" "$(cat "$T/.config/pve/X.token")" old-token
fresh
stub openssl 'cat >/dev/null 2>&1; case "$1" in pkey) exit 1;; esac; echo key'
stub curl 'echo curl >>"$LOG"'
doc SKILL.md 'access/ticket' "cd '$T'; H=h; PWFILE=f"
check "bootstrap: unconvertible key, no pin, no password sent" "$(logged '^curl')" 0

fresh
echo "UUID=old X ext4 defaults 0 2" >"$T/fstab2"
stub blkid 'echo 1111'; stub umount 'exit 0'; stub sudo '[ "$1" != tee ] || { echo "sudo $*" >>"$LOG"; exit 0; }; exec "$@"'
stub mount 'exit 0'; stub findmnt 'echo 1111'; stub df 'echo mounted'
stub awk 'echo 1'
doc SKILL.md 'UUID=$(' ''; rc=$?
check "fstab: an existing entry for that path is refused" "$(nonzero $rc) $(logged 'tee -a')" "yes 0"

check "readme: installers are not staged in shared /tmp" "$(grep -c 'root@<proxmox-host>:/tmp/\|:/etc/ssh/sshd_config.d/' "$R/README.md")" 0
check "runbooks: both are listed" "$(grep -c 'runbooks/snapshot_change.md' "$R/SKILL.md" | head -1)" 2

check "network: run id is unique within a second" "$(block SKILL.md 'net-revert' | grep -c 'run=$(date +%s)-')" 1
check "network: a running revert is not 'disarmed'" "$(block SKILL.md 'net-revert' | grep -c 'is-active net-revert')" 1
check "runbook: the copy is re-read against the post-isolation read-back before stop and delete" "$(grep -c "^8\. Re-read step 5's read-back fields: stop unless unchanged\." "$R/runbooks/restore_test.md" "$R/runbooks/ct_restore_test.md" | awk -F: '{s+=$2} END{print s}')" 2
check "runbook: restore's first config read names only the links and devices (absent keys are refused)" "$(grep -c -E 'with fields naming only every netN(, serialN and ide, sata, scsi, virtio key| and mpN)\.' "$R/runbooks/restore_test.md" "$R/runbooks/ct_restore_test.md" | awk -F: '{s+=$2} END{print s}')" 2
check "runbook: restore stops on a host device disk" "$(grep -c 'or a disk starts with / (host device)' "$R/runbooks/restore_test.md")" 1
check "runbook: a failed container exec is data not proven, not a stop" "$(grep -c 'else (a failed exec too): data not proven' "$R/runbooks/ct_restore_test.md")" 1
check "runbook: dev VM names only the disk keys the key list has" "$(grep -c 'each ide, sata, scsi, virtio key in that list (only those)' "$R/runbooks/clone_dev_vm.md")" 1
check "runbook: dev VM needs net0 and calls the address unproven" "$(grep -c -e 'and net0 is listed' -e 'Address, user and key stay unproven' "$R/runbooks/clone_dev_vm.md")" 2
check "runbook: ACME set up is not called renewal proven" "$(grep -c 'renewal not proven' "$R/runbooks/cert_expiry.md")" 1
check "runbook: restore isolates in its own step" "$(grep -c '^5\. Isolate it\.' "$R/runbooks/restore_test.md" "$R/runbooks/ct_restore_test.md" | awk -F: '{s+=$2} END{print s}')" 2
check "runbook: restore starts only after the isolation read-back" "$(grep -c '^6\. Only if step 5 read back link_down=1 on each netN and both flags 0: POST' "$R/runbooks/restore_test.md" "$R/runbooks/ct_restore_test.md" | awk -F: '{s+=$2} END{print s}')" 2
check "runbooks: the operator, not the agent, closes the lane" "$(grep -c -E '^Report .*(Operator|The operator) closes the (agent )?lane\.$' "$R/runbooks/restore_test.md" "$R/runbooks/ct_restore_test.md" "$R/runbooks/clone_dev_vm.md" | awk -F: '{s+=$2} END{print s}')" 3
check "runbook: snapshot name is unique" "$(grep -c 'unique new' "$R/runbooks/snapshot_change.md")" 1
check "runbooks: the dev VM one is listed" "$(grep -c 'runbooks/clone_dev_vm.md' "$R/SKILL.md" | head -1)" 2
check "runbook: dev VM identity is re-read before delete" "$(grep -c "re-read step 3's fields: stop unless unchanged" "$R/runbooks/clone_dev_vm.md")" 1
check "runbook: dev VM never reads the cut address list" "$(grep -c 'network-get-interfaces' "$R/runbooks/clone_dev_vm.md")" 0
check "runbook: dev VM tells the agent not to read the address list" "$(grep -c 'Never read its address list' "$R/runbooks/clone_dev_vm.md")" 1
check "runbook: dev VM reports net0's MAC for DHCP" "$(grep -c "address (or net0's MAC)" "$R/runbooks/clone_dev_vm.md")" 1
check "runbooks: the container restore one is listed" "$(grep -c 'runbooks/ct_restore_test.md' "$R/SKILL.md" | head -1)" 2
check "runbooks: the backup coverage one is listed" "$(grep -c 'runbooks/backup_coverage.md' "$R/SKILL.md" | head -1)" 2
check "runbooks: the update check one is listed" "$(grep -c 'runbooks/update_check.md' "$R/SKILL.md" | head -1)" 2
check "runbook: a container copy is stopped only if running" "$(grep -c 'If running, POST /nodes/{node}/lxc/{vmid}/status/stop' "$R/runbooks/ct_restore_test.md")" 1
check "runbook: container data needs returncode 0" "$(grep -c 'need returncode 0' "$R/runbooks/ct_restore_test.md")" 1
check "runbook: an unread storage makes no-backup unknown" "$(grep -c 'none or too old is unknown' "$R/runbooks/backup_coverage.md")" 1
check "runbook: no pending updates only after an OK refresh" "$(grep -c "only if step 2's newest run was OK" "$R/runbooks/update_check.md")" 1
for n in backup_failures storage_capacity cert_expiry snapshot_hygiene decommission_guest; do
  check "runbooks: $n is listed" "$(grep -c "runbooks/$n.md" "$R/SKILL.md")" 2
done
check "runbook: a backup that warned is its own class, by exact form" "$(grep -c 'Exactly WARNINGS: and a number finished with warnings' "$R/runbooks/backup_failures.md")" 1
check "runbook: backup task lists are read in pages that fit" "$(grep -c 'limit=4, start=0' "$R/runbooks/backup_failures.md")" 1
check "runbook: a job with no run seen is not called a failure" "$(grep -c 'That is not a failure: it may not have been due' "$R/runbooks/backup_failures.md")" 1
check "runbook: overcommit unread or refused is unknown, with the permission named" "$(grep -c 'Unread or refused (Proxmox lists disks only with VM.Config.Disk' "$R/runbooks/storage_capacity.md")" 1
check "runbook: thin pool metadata is checked" "$(grep -c 'metadata_size,metadata_used' "$R/runbooks/storage_capacity.md")" 1
check "runbooks: now comes from the node, not the agent's clock" "$(grep -c 'GET /nodes/{node}/time' "$R/runbooks/cert_expiry.md" "$R/runbooks/backup_failures.md" "$R/runbooks/snapshot_hygiene.md" | awk -F: '{s+=$2} END{print s}')" 3
check "runbook: snapshots are deleted only when picked, each on its own yes" "$(grep -c -e 'nothing is deleted unpicked' -e 'For each pick, on its own yes: re-read step 2' "$R/runbooks/snapshot_hygiene.md")" 2
check "runbook: decommission names protection, lock and template only if listed" "$(grep -c 'each of protection, lock, template only if the key list has it' "$R/runbooks/decommission_guest.md")" 1
check "runbook: decommission stops on protection, a lock or a template" "$(grep -c 'Stop if protection is 1, lock is set, or template is 1' "$R/runbooks/decommission_guest.md")" 1
check "runbook: decommission never destroys unreferenced disks" "$(grep -c 'destroy-unreferenced-disks' "$R/runbooks/decommission_guest.md")" 0
check "runbook: decommission shuts down gracefully, never forces" "$(grep -c -e 'status/shutdown with timeout=120' -e "a forced stop is the operator's call" "$R/runbooks/decommission_guest.md")" 1
check "runbook: decommission re-reads identity before stop and delete" "$(grep -c "re-read step 1's fields" "$R/runbooks/decommission_guest.md")" 2
check "runbook: decommission keeps the backups and unreferenced disks" "$(grep -c 'Backups and disks it did not reference stay' "$R/runbooks/decommission_guest.md")" 1
check "runbooks: list reads never name fields on an empty list first" "$(grep -c 'read plain first' "$R/runbooks/backup_coverage.md" "$R/runbooks/update_check.md" | awk -F: '{s+=$2} END{print s}')" 2

check "every recipe under test was found" "$([[ -e $T/missing ]] && echo missing || echo found)" found
exit $fail
