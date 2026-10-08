# shellcheck shell=bash
# pve-api.sh: source this for pinned-TLS Proxmox API helpers.
#
#   export PVE_HOST=pve.lan                        # host or IP, port 8006 assumed
#   export PVE_TOKEN_FILE=~/.config/pve/pve.token  # mode 600: PVEAPIToken=user@realm!id=secret
#   export PVE_PIN_FILE=~/.config/pve/pve.pin      # mode 600: sha256//<base64 pubkey hash>
#   source scripts/pve-api.sh
#
#   pve_api GET /nodes
#   upid=$(pve_api POST /nodes/<node>/qemu/9000/clone --data-urlencode newid=8100 | jq -r .data)
#   pve_wait "$upid" 300 || echo "clone failed"
#   pve_vm_ip <node> 8100 120
#
# The token and pin are read from files on every call, so they never sit in
# the environment or on a command line. Requires curl and jq.

# pve_api METHOD PATH [curl args...]: prints the JSON response.
pve_api() {
  local method=$1 path=$2
  shift 2
  curl -sS -k --pinnedpubkey "$(cat "$PVE_PIN_FILE")" \
    -H "Authorization: $(cat "$PVE_TOKEN_FILE")" \
    -X "$method" "https://$PVE_HOST:8006/api2/json$path" "$@"
}

# pve_wait UPID [timeout-seconds, default 600]
# Waits for a task, prints its exit status, and returns 0 only on "OK".
# Returns 1 at once if given something that is not a UPID.
# On failure it prints the task's last log lines to stderr and returns 1.
# On timeout it returns 2; the task keeps running on the host.
pve_wait() {
  local upid=$1 timeout=${2:-600} node enc status exitstatus waited=0
  # A refused write (403, 400) returns no UPID; jq then hands us "null".
  if [[ $upid != UPID:* ]]; then
    echo "not a task ID: '$upid' (the write was probably refused; read its response)" >&2
    return 1
  fi
  node=$(cut -d: -f2 <<<"$upid")
  enc=$(jq -rn --arg u "$upid" '$u|@uri')
  while (( waited < timeout )); do
    status=$(pve_api GET "/nodes/$node/tasks/$enc/status")
    if jq -e '.data.status == "stopped"' >/dev/null 2>&1 <<<"$status"; then
      exitstatus=$(jq -r '.data.exitstatus' <<<"$status")
      echo "$exitstatus"
      [[ $exitstatus == OK ]] && return 0
      pve_api GET "/nodes/$node/tasks/$enc/log?limit=500" | jq -r '.data[].t' | tail -20 >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
  echo "TIMEOUT after ${timeout}s: $upid" >&2
  return 2
}

# pve_vm_ip NODE VMID [timeout-seconds, default 180]
# Prints the VM's first non-loopback IPv4 from the guest agent. The agent
# endpoint returns an error until the agent is up, so errors mean "not yet".
pve_vm_ip() {
  local node=$1 vmid=$2 timeout=${3:-180} ip waited=0
  while (( waited < timeout )); do
    ip=$(pve_api GET "/nodes/$node/qemu/$vmid/agent/network-get-interfaces" 2>/dev/null |
      jq -r '[.data.result[]? | select(.name != "lo") | .["ip-addresses"][]?
              | select(.["ip-address-type"] == "ipv4") | .["ip-address"]][0] // empty' 2>/dev/null)
    if [[ -n $ip ]]; then
      echo "$ip"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  echo "no IPv4 from the guest agent after ${timeout}s (is qemu-guest-agent installed and running?)" >&2
  return 2
}
