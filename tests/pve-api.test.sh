#!/bin/bash
# Unit test for scripts/pve-api.sh with pve_api stubbed (no network).
# Run: bash tests/pve-api.test.sh   (optional arg: another copy of pve-api.sh to test)
# shellcheck source=scripts/pve-api.sh
source "${1:-$(dirname "$0")/../scripts/pve-api.sh}"
sleep() { :; }
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }
UPID='UPID:node1:000B8980:012A8B34:6AC6FC30:qmclone:9002:a@pve!t:'

pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"OK"}}';; esac; }
out=$(pve_wait "$UPID" 9); rc=$?; check "ok-task output" "$out" "OK"; check "ok-task rc" "$rc" 0

pve_api() { case $2 in */status) echo '{"data":{"status":"stopped","exitstatus":"clone failed: disk full"}}';; */log*) echo '{"data":[{"t":"line1"},{"t":"boom"}]}';; esac; }
out=$(pve_wait "$UPID" 9 2>"$ERR"); rc=$?; check "failed-task rc" "$rc" 1; check "failed-task output" "$out" "clone failed: disk full"; check "failed-task log on stderr" "$(tail -1 "$ERR")" "boom"

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
exit $fail
