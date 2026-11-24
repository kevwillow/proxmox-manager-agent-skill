#!/bin/bash
# Unit test for scripts/pve-api.sh with pve_api stubbed (no network).
# Run: bash tests/pve-api.test.sh   (optional arg: another copy of pve-api.sh to test)
# shellcheck source=scripts/pve-api.sh
source "${1:-$(dirname "$0")/../scripts/pve-api.sh}"
sleep() { SECONDS=$((SECONDS + $1)); }   # a wait costs no real time
ERR=$(mktemp); CFG=$(mktemp); PUTS=$(mktemp); trap 'rm -f "$ERR" "$CFG" "$PUTS"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
UPID='UPID:node1:000B8980:012A8B34:6AC6FC30:qmclone:9002:a@pve!t:'

pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"OK"}}';; esac; }
out=$(pve_wait "$UPID" 9); rc=$?; check "ok-task output" "$out" "OK"; check "ok-task rc" "$rc" 0

pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"clone failed: disk full"}}';; */log*) echo '{"data":[{"t":"line1"},{"t":"boom"}]}';; esac; }
out=$(pve_wait "$UPID" 9 2>"$ERR"); rc=$?; check "failed-task rc" "$rc" 1; check "failed-task output" "$out" "clone failed: disk full"; check "failed-task log on stderr" "$(tail -1 "$ERR")" "boom"

# A task that finished with warnings (e.g. a network apply on a host without the SDN source line)
# ends "WARNINGS: <n>": it ran to the end, so it counts as done, and its log goes to stderr.
pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"WARNINGS: 1"}}';; */log*) echo '{"data":[{"t":"WARN: missing source line"},{"t":"TASK WARNINGS: 1"}]}';; esac; }
out=$(pve_wait "$UPID" 9 2>"$ERR"); rc=$?; check "warnings-task rc" "$rc" 0; check "warnings-task output" "$out" "WARNINGS: 1"; check "warnings-task log on stderr" "$(grep -c 'WARN: missing source line' "$ERR")" 1
# Only that exact form: anything else that merely contains the word still fails.
pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"WARNINGS: 1 then error: disk full"}}';; */log*) echo '{"data":[{"t":"x"}]}';; esac; }
out=$(pve_wait "$UPID" 9 2>"$ERR"); rc=$?; check "warnings-lookalike rc" "$rc" 1
pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"WARNINGS: "}}';; */log*) echo '{"data":[{"t":"x"}]}';; esac; }
out=$(pve_wait "$UPID" 9 2>"$ERR"); rc=$?; check "warnings-without-count rc" "$rc" 1

pve_api() { echo '{"data":{"status":"running"}}'; }
out=$(pve_wait "$UPID" 9 2>"$ERR"); rc=$?; check "timeout rc" "$rc" 2; check "timeout msg" "$(grep -c TIMEOUT "$ERR")" 1

pve_api() { [[ $2 == /nodes/node1/tasks/* ]] && echo '{"data":{"status":"stopped","exitstatus":"OK"}}' || echo '{"data":null}'; }
out=$(pve_wait "$UPID" 9); check "node taken from UPID" "$out" "OK"

pve_api() { echo SHOULD-NOT-BE-CALLED; }
out=$(pve_wait null 9 2>"$ERR"); rc=$?; check "non-UPID rc" "$rc" 1; check "non-UPID msg" "$(grep -c 'not a task ID' "$ERR")" 1

pve_api() { echo '{"data":null,"message":"QEMU guest agent is not running\n"}'; }
pve_vm_ip node1 100 9 2>/dev/null; check "ip: agent down rc" "$?" 2
pve_api() { echo '{"data":{"result":[{"name":"lo","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1"}]},{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv6","ip-address":"fe80::1"},{"ip-address-type":"ipv4","ip-address":"10.0.0.5"}]}]}}'; }
check "ip: skips lo and ipv6" "$(pve_vm_ip node1 100 9)" "10.0.0.5"

# pve_isolate_copy: a fake copy whose config changes only when a PUT is accepted.
VMSTATE=stopped PUT_WORKS=1
pve_api() {
  local method=$1 path=$2 a kv
  shift 2
  case "$method $path" in
    "GET "*/status/current) echo "{\"data\":{\"status\":\"$VMSTATE\"}}" ;;
    "GET "*/config) cat "$CFG" ;;
    "PUT "*/config)
      for a in "$@"; do
        [[ $a == --* ]] && continue
        echo "$a" >>"$PUTS"
        [[ $PUT_WORKS == 1 ]] || continue
        kv=$(jq -c --arg k "${a%%=*}" --arg v "${a#*=}" '.data[$k]=$v' "$CFG") && echo "$kv" >"$CFG"
      done
      echo '{"data":null}'
      [[ $PUT_WORKS != refused ]] || return 22 ;;
  esac
}
copy() { echo "$1" >"$CFG"; : >"$PUTS"; }
isolate() { pve_isolate_copy node1 8100 >/dev/null 2>"$ERR"; echo $?; }
field() { jq -r ".data.$1" "$CFG"; }

copy '{"data":{"net0":"virtio=AA:AA:AA:AA:AA:00,bridge=vmbr0","net1":"virtio=AA:AA:AA:AA:AA:01,bridge=vmbr1,link_down=0,firewall=1","net10":"e1000=AA:AA:AA:AA:AA:10,bridge=vmbr0,link_down=1","serial0":"socket","onboot":1,"protection":1}}'
check "isolate: rc" "$(isolate)" 0
check "isolate: net0 down, own MAC kept" "$(field net0)" "virtio=AA:AA:AA:AA:AA:00,bridge=vmbr0,link_down=1"
check "isolate: net1 link_down=0 replaced" "$(field net1)" "virtio=AA:AA:AA:AA:AA:01,bridge=vmbr1,firewall=1,link_down=1"
check "isolate: net10 not doubled" "$(field net10)" "e1000=AA:AA:AA:AA:AA:10,bridge=vmbr0,link_down=1"
check "isolate: onboot cleared" "$(field onboot)" 0
check "isolate: protection cleared" "$(field protection)" 0

copy '{"data":{"onboot":1}}'
check "isolate: no NIC is fine" "$(isolate)" 0

copy '{"data":{"net0":"virtio=AA:AA:AA:AA:AA:00,bridge=vmbr0"}}'
PUT_WORKS=0; check "isolate: accepted but unchanged fails closed" "$(isolate)" 1; PUT_WORKS=1
copy '{"data":{"net0":"virtio=AA:AA:AA:AA:AA:00,bridge=vmbr0,link_down=1","onboot":0,"protection":0}}'
PUT_WORKS=refused; check "isolate: refused write fails closed even if it reads as isolated" "$(isolate)" 1; PUT_WORKS=1

# A read-back that is short or empty.
for after in '{"data":{"net0":"virtio=A,bridge=b,link_down=1","onboot":0,"protection":0}}' '{"data":{}}' '{"data":{"net0":"virtio=A,bridge=b,link_down=1","net1":"virtio=OTHER,bridge=b,link_down=1","onboot":0,"protection":0}}'; do
  got=$(
    : >"$PUTS"
    pve_api() {
      case "$1 $2" in
        "GET "*/status/current) echo '{"data":{"status":"stopped"}}' ;;
        "PUT "*) echo put >"$PUTS" ;;
        "GET "*/config) if [[ -s $PUTS ]]; then echo "$after"; else echo '{"data":{"net0":"virtio=A,bridge=b","net1":"virtio=B,bridge=b"}}'; fi ;;
      esac
    }
    isolate)
  check "isolate: read-back must match what was sent: $after" "$got" 1
done
got=$(
  pve_api() { case "$1 $2" in "GET "*/status/current) echo '{"data":{"status":"stopped"}}'; return 18 ;; "GET "*) echo '{"data":{"onboot":0,"protection":0}}' ;; esac; }
  isolate)
check "isolate: cut status read is not 'stopped'" "$got" 1
got=$(pve_api() { echo '{"data":{"result":[{"name":"eth0","ip-addresses":[{"ip-address-type":"ipv4","ip-address":"10.0.0.5"}]}]}}'; return 18; }
  pve_vm_ip node1 100 6 2>/dev/null; echo "rc$?")
check "ip: cut read is not an answer" "$got" rc2
got=$(pve_api() { sleep 5; echo '{"data":{"status":"running"}}'; }
  a=$SECONDS; pve_wait "$UPID" 9 >/dev/null 2>&1; echo $((SECONDS - a <= 16)))
check "wait: slow requests count toward the timeout" "$got" 1
got=$(pve_api() { printf '{"data":"%s"}\ngarbage' "$UPID"; }
  pve_wait() { return 0; }; pve_task POST /x >/dev/null 2>&1; echo $?)
check "task: unparsable reply is a failure" "$got" 1

copy '{"data":{"net0":"virtio=AA:AA:AA:AA:AA:00,bridge=vmbr0"}}'
VMSTATE=running; check "isolate: running VM refused" "$(isolate)" 1; VMSTATE=stopped
check "isolate: running VM not written" "$(wc -c <"$PUTS")" 0

copy '{"data":null,"message":"Permission check failed\n"}'
check "isolate: unreadable config refused" "$(isolate)" 1
check "isolate: unreadable config not written" "$(wc -c <"$PUTS")" 0

copy 'not json'
check "isolate: non-JSON config refused" "$(isolate)" 1
check "isolate: non-JSON config not written" "$(wc -c <"$PUTS")" 0

copy ''
check "isolate: empty response refused" "$(isolate)" 1
check "isolate: empty response not written" "$(wc -c <"$PUTS")" 0

for dev in '"hostpci0":"0000:01:00.0"' '"usb1":"host=1-2"' '"virtiofs0":"share"' '"args":"-S"' '"hookscript":"local:snippets/h.sh"' '"parallel0":"/dev/parport0"' '"serial1":"/dev/ttyS0"'; do
  copy "{\"data\":{$dev}}"
  check "isolate: refuses ${dev%%:*}" "$(isolate)" 1
  check "isolate: ${dev%%:*} not written" "$(wc -c <"$PUTS")" 0
done
exit $fail
