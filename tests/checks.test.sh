#!/bin/bash
# A failed, empty or unanswered check must never read as success.
# Offline: every Proxmox, disk and network command is a stand-in.
# Run: bash tests/checks.test.sh   (optional arg: another copy of the repo to test)
# shellcheck disable=SC2016  # the stand-ins are single-quoted on purpose
R=$(cd "${1:-$(dirname "$0")/..}" && pwd) || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
export LOG=$T/log
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
stub() { printf '#!/bin/bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
fresh() { rm -f "$T"/bin/*; : >"$LOG"; stub sleep 'exit 0'; }
run() { PATH="$T/bin:$PATH" bash "$@" >"$T/out" 2>&1; }
said() { grep -c -- "$1" "$T/out"; }
logged() { grep -cE -- "$1" "$LOG"; }
nonzero() { [[ $1 != 0 ]] && echo yes || echo no; }

# block FILE MARKER: the first fenced block containing MARKER, placeholders filled.
block() {
  awk -v m="$2" '/^ *```/ { if (f) { if (index(b, m)) { printf "%s", b; exit } } f = !f; b = ""; next }
    f { b = b $0 "\n" }' "$R/$1" >"$T/raw"
  [[ -s $T/raw ]] || echo "FAIL no block in $1 contains: $2"
  sed -E -e '/^ *source scripts\//d' -e 's/<[^<>()|&]+>/X/g' "$T/raw"
}
# doc FILE MARKER PRELUDE: run that block as an agent would paste it (no set -e).
doc() { { echo "$3"; block "$1" "$2"; } >"$T/doc"; run "$T/doc"; }

## The disk script must never offer to wipe the boot drive.
sed -e 's/\[\[ \$EUID -ne 0 \]\]/false/' -e 's/\[\[ ! -b "\$TARGET_DRIVE" \]\]/false/' \
  -e "s#/etc/fstab#$T/fstab#g" "$R/scripts/add-nvme-storage.sh" >"$T/add.sh"
disks() {
  fresh
  stub lsblk 'case "$*" in
*"-o SERIAL /dev/zzboot") echo "  BOOTSERIAL  ";;
*"-o SERIAL /dev/zznew") echo "NEWSERIAL";;
*"-o SERIAL /dev/zzanon") echo "";;
*"-o SERIAL /dev/"*) exit 32;;
*"-o SERIAL") printf "BOOTSERIAL  \nNEWSERIAL\n";;
*"-o TYPE /dev/zzboot"*|*"-o TYPE /dev/zznew"|*"-o TYPE /dev/zzanon") echo disk;;
*"-o TYPE /dev/"*) exit 32;;
*"-o MOUNTPOINT,FSTYPE /dev/zzboot") echo "$BOOT_USE";;
*"-o MOUNTPOINT,FSTYPE /dev/"*) echo;;
*) echo "zznew 1T MODEL NEWSERIAL";;
esac'
}
wipe_offered() { printf '%b' "$1" | PATH="$T/bin:$PATH" bash "$T/add.sh" >"$T/out" 2>&1; said '^Aborted'; }
export BOOT_USE=
disks
check "disk: padded boot serial still refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zzboot\nno\n')" 0
check "disk: empty boot serial refused" "$(wipe_offered '\n/dev/zznew\nno\n')" 0
check "disk: mistyped boot serial refused" "$(wipe_offered 'B0OTSERIAL\n/dev/zznew\nno\n')" 0
check "disk: target without a serial refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zzanon\nno\n')" 0
check "disk: partition refused" "$(wipe_offered 'BOOTSERIAL\n/dev/zzboot3\nno\n')" 0
BOOT_USE='/boot/efi vfat'
check "disk: mounted disk refused even if the wrong serial was excluded" "$(wipe_offered 'NEWSERIAL\n/dev/zzboot\nno\n')" 0
BOOT_USE=' LVM2_member'
check "disk: LVM disk refused even if the wrong serial was excluded" "$(wipe_offered 'NEWSERIAL\n/dev/zzboot\nno\n')" 0
BOOT_USE=
check "disk: a good target is still offered" "$(wipe_offered 'BOOTSERIAL\n/dev/zznew\nno\n')" 1

: >"$T/fstab"
stub blkid 'echo 1111-2222'
stub mount 'exit 0'
stub findmnt 'exit 1'
stub pvesm 'echo "pvesm $*" >>"$LOG"'
printf 'BOOTSERIAL\n/dev/zznew\nyes\n1\n/mnt/zz\nstore\n\n\n' | PATH="$T/bin:$PATH" bash "$T/add.sh" >"$T/out" 2>&1
check "disk: nothing mounted is not 'verified'" "$(said 'mounts verified')" 0
check "disk: nothing mounted is not registered" "$(logged '^pvesm add')" 0

## pve_api and pve_wait
fresh
stub curl 'echo "{\"data\":null}"; case " $* " in *" --fail-with-body "*) exit 22;; esac; exit 0'
echo token >"$T/tok"; echo pin >"$T/pin"
(export PVE_HOST=h PVE_TOKEN_FILE=$T/tok PVE_PIN_FILE=$T/pin PATH=$T/bin:$PATH
  source "$R/scripts/pve-api.sh"; pve_api POST /x >/dev/null 2>&1)
check "pve_api: refused write is non-zero" "$(nonzero $?)" yes

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
ssh() { echo "ssh $*" >>"$LOG"; case "$*" in *interfaces.new*) [[ $FAILS != *pending* ]];; *systemd-run*) [[ $FAILS != *arm* ]];; esac; }'
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

READS='pve_api() { case "$*" in *file-read*) echo "$GOT";; *) echo "{\"data\":\"UPID:x\"}";; esac; }
pve_task() { return 0; }; pve_wait() { return 0; }; pve_isolate_copy() { return 0; }'
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT=; $READS"; rc=$?
check "restore: unread data exits non-zero" "$(nonzero $rc)" yes
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT='{\"data\":{\"content\":\"something else\"}}'; $READS"; rc=$?
check "restore: wrong data exits non-zero" "$(nonzero $rc)" yes
fresh; doc SKILL.md 'pve_isolate_copy "$node"' "GOT='{\"data\":{\"content\":\"X\"}}'; $READS"; rc=$?
check "restore: matching data exits zero" "$(nonzero $rc)" no

fresh
stub blkid 'exit 2'; stub sudo 'echo "sudo $*" >>"$LOG"'; stub mount 'exit 0'; stub df 'exit 0'; stub findmnt 'exit 1'
doc SKILL.md 'UUID=$(' ''
check "fstab: no UUID, no line written" "$(logged 'tee -a')" 0

fresh
stub curl 'exit 22'; stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: failed check installs nothing" "$(logged '^uv ')" 0

fresh
stub curl 'echo "{\"data\":null}"; case " $* " in *" --fail-with-body "*) exit 22;; esac; exit 0'
doc references/proxmox-api-token.md '-X POST' 'cat() { echo x; }'; rc=$?
check "token reference: refused create is non-zero" "$(nonzero $rc)" yes

fresh
stub pvesh 'echo "not json"; exit 1'
doc references/cluster.md '--tags "homelab' ''; rc=$?
check "cluster tag loop: failed listing is non-zero" "$(nonzero $rc)" yes

fresh
stub sudo 'exit 1'
doc references/iso-workflow.md 'diff ' ''; rc=$?
check "iso diff: two failed listings are not a match" "$(nonzero $rc)" yes

fresh
stub install 'exit 0'; stub jq 'exit 1'; stub rm 'echo "rm $*" >>"$LOG"'
doc SKILL.md 'rm token-response.json' "cd '$T'; HOME='$T'; PIN=x"
check "bootstrap: unsaved token is not deleted" "$(logged '^rm ')" 0

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
node=n copy=100 restored=n/100"
check "removal: good run deletes" "$(logged '^api DELETE')" 1
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
stub curl 'echo "{\"attestation_bundles\":[{\"publisher\":{\"repository\":\"john-broadway/proximo\"}}]}"'
stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: the project's own release installs" "$(logged '^uv ')" 1
fresh
stub curl 'echo "{\"attestation_bundles\":[{\"publisher\":{\"repository\":\"someone/else\"}}]}"'
stub uv 'echo "uv $*" >>"$LOG"'
doc references/mcp-servers.md 'uv tool install' ''
check "provenance: another publisher installs nothing" "$(logged '^uv ')" 0

fresh
stub blkid 'echo 1111'; stub sudo '[ "$1" != tee ] || { echo "sudo $*" >>"$LOG"; exit 0; }; exec "$@"'
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

disks
: >"$T/fstab"
stub blkid 'echo 1111-2222'; stub mount 'exit 0'; stub findmnt 'echo 1111-2222'
stub pvesm 'echo "pvesm $*" >>"$LOG"'
printf 'BOOTSERIAL\n/dev/zznew\nyes\n1\n/mnt/zz\nstore\n\n\n' | PATH="$T/bin:$PATH" bash "$T/add.sh" >"$T/out" 2>&1
check "disk: mounted partition is registered" "$(logged '^pvesm add')" 1

(set -euo pipefail
  source "$R/scripts/pve-api.sh"
  sleep() { :; }
  pve_api() { if [[ -e $T/agent ]]; then echo '{"data":{"result":[{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.0.5"}]}]}}'; else : >"$T/agent"; return 22; fi; }
  pve_vm_ip n 1 30) >"$T/out" 2>&1
check "pve_vm_ip: keeps polling under set -e" "$(tail -1 "$T/out")" 10.0.0.5
exit $fail
