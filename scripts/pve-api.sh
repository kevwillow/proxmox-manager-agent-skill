# shellcheck shell=bash
# pve-api.sh: source this for pinned-TLS Proxmox API helpers.
#
#   export PVE_HOST=pve.lan                        # host or IP, port 8006 assumed
#   export PVE_TOKEN_FILE=~/.config/pve/pve.token  # mode 600: PVEAPIToken=user@realm!id=secret
#   export PVE_PIN_FILE=~/.config/pve/pve.pin      # mode 600: sha256//<base64 pubkey hash>
#   source scripts/pve-api.sh
#
#   pve_api GET /nodes
#   reply=$(pve_api POST /nodes/<node>/qemu/9000/clone --data-urlencode newid=8100) && upid=$(jq -r .data <<<"$reply")
#   pve_wait "$upid" 300 || echo "clone failed"
#   pve_task POST /nodes/<node>/qemu/8100/status/start && pve_vm_ip <node> 8100 120
#   pve_isolate_copy <node> 8100 || echo "do not start the copy"
#
# The token and pin are read from files on every call, so they never sit in
# the environment or on a command line. Requires curl 7.76+ and jq.

# pve_api METHOD PATH [curl args...]: prints the JSON response, and returns
# non-zero when the request fails, takes over 120 s, or Proxmox refuses it.
# Don't pipe it into jq: the pipe hides a failed transfer. Capture, then parse.
pve_api() {
  local method=$1 path=$2
  shift 2
  curl -sS --fail-with-body --connect-timeout 10 --max-time 120 -k \
    --pinnedpubkey "$(cat "$PVE_PIN_FILE")" \
    -H @<(printf 'Authorization: %s\n' "$(cat "$PVE_TOKEN_FILE")") \
    -X "$method" "https://$PVE_HOST:8006/api2/json$path" "$@"
}

# pve_wait UPID [timeout-seconds, default 600]
# Waits for a task, prints its exit status, and returns 0 only on "OK".
# Returns 1 at once if given something that is not a UPID.
# On failure it prints the task's last log lines to stderr and returns 1.
# On timeout it returns 2; the task keeps running on the host.
pve_wait() {
  local upid=$1 timeout=${2:-600} node enc status exitstatus start=$SECONDS
  # A refused write (403, 400) returns no UPID; jq then hands us "null".
  if [[ $upid != UPID:* ]]; then
    echo "not a task ID: '$upid' (the write was probably refused; read its response)" >&2
    return 1
  fi
  node=$(cut -d: -f2 <<<"$upid")
  enc=$(jq -rn --arg u "$upid" '$u|@uri')
  while (( SECONDS - start < timeout )); do
    status=$(pve_api GET "/nodes/$node/tasks/$enc/status") || status=
    # -s, because jq 1.6 exits 0 for -e on empty input.
    if jq -es 'length == 1 and .[0].data.status == "stopped"' >/dev/null 2>&1 <<<"$status"; then
      exitstatus=$(jq -r '.data.exitstatus' <<<"$status")
      echo "$exitstatus"
      [[ $exitstatus == OK ]] && return 0
      pve_api GET "/nodes/$node/tasks/$enc/log?limit=500" | jq -r '.data[].t' | tail -20 >&2 || true
      return 1
    fi
    sleep 3
  done
  echo "TIMEOUT after ${timeout}s: $upid" >&2
  return 2
}

# pve_task METHOD PATH [curl args...]
# Sends a write that starts a task and waits up to 30 minutes for it.
# Returns 0 only if the write was accepted and the task ended OK.
pve_task() {
  local reply upid
  if ! reply=$(pve_api "$@"); then
    echo "refused: $1 $2 $reply" >&2
    return 1
  fi
  if ! upid=$(jq -r .data <<<"$reply"); then
    echo "unreadable reply: $1 $2" >&2
    return 1
  fi
  pve_wait "$upid" 1800
}

# pve_vm_ip NODE VMID [timeout-seconds, default 180]
# Prints the VM's first non-loopback IPv4 from the guest agent. The agent
# endpoint returns an error until the agent is up, so errors mean "not yet".
pve_vm_ip() {
  local node=$1 vmid=$2 timeout=${3:-180} ip reply start=$SECONDS
  while (( SECONDS - start < timeout )); do
    ip=
    if reply=$(pve_api GET "/nodes/$node/qemu/$vmid/agent/network-get-interfaces" 2>/dev/null); then
      ip=$(jq -r '[.data.result[]? | select(.name != "lo") | .["ip-addresses"][]?
            | select(.["ip-address-type"] == "ipv4") | .["ip-address"]][0] // empty' 2>/dev/null <<<"$reply") || ip=
    fi
    if [[ -n $ip ]]; then
      echo "$ip"
      return 0
    fi
    sleep 3
  done
  echo "no IPv4 from the guest agent after ${timeout}s (is qemu-guest-agent installed and running?)" >&2
  return 2
}

# pve_vm_identity NODE VMID
# Prints what tells this guest from another at the same VMID: SMBIOS UUID,
# vmgenid and MACs. Returns 1 when that can't be read.
pve_vm_identity() {
  local reply
  reply=$(pve_api GET "/nodes/$1/qemu/$2/config") || return 1
  jq -ers 'select(length == 1) | .[0].data | [.smbios1, .vmgenid,
    (to_entries | sort_by(.key)[] | select(.key | test("^net[0-9]+$")) | .value | split(",")[0])]
    | map(select(. != null)) | select(length > 0) | join(" ")' <<<"$reply" 2>/dev/null | grep .
}

# pve_isolate_copy NODE VMID
# Run on a freshly restored, stopped copy, before its first start; never on the
# original. Sets link_down=1 on every NIC (each keeps the copy's own MAC),
# clears onboot and protection, then reads the config back.
# Returns 0 only if the write was accepted and that read shows all of it. Changes nothing and returns 1
# when the VM is not stopped, its config can't be read, or it has host devices,
# args or a hookscript, which can reach past the network.
pve_isolate_copy() {
  local node=$1 vmid=$2 base cfg state risky nic want
  local -a set_args=(--data-urlencode onboot=0 --data-urlencode protection=0)
  base="/nodes/$node/qemu/$vmid"
  state=$(pve_api GET "$base/status/current") || state=
  if [[ $(jq -r '.data.status' 2>/dev/null <<<"$state") != stopped ]]; then
    echo "$vmid is not a readable, stopped VM; nothing changed" >&2
    return 1
  fi
  cfg=$(pve_api GET "$base/config") || cfg=
  if ! jq -es 'length == 1 and (.[0].data | type == "object")' >/dev/null 2>&1 <<<"$cfg"; then
    echo "cannot read the config of $vmid; nothing changed" >&2
    return 1
  fi
  risky=$(jq -r '.data | to_entries[]
    | select((.key | test("^((hostpci|usb|virtiofs|parallel)[0-9]+|args|hookscript)$"))
        or ((.key | test("^serial[0-9]+$")) and .value != "socket")) | .key' <<<"$cfg")
  if [[ -n $risky ]]; then
    echo "$vmid has ${risky//$'\n'/, }; do not start it without the user. Nothing changed" >&2
    return 1
  fi
  if ! want=$(jq -c '.data | with_entries(select(.key | test("^net[0-9]+$"))
        | .value |= (split(",") | map(select(startswith("link_down=") | not)) + ["link_down=1"] | join(",")))' <<<"$cfg"); then
    echo "cannot work out the NICs of $vmid; nothing changed" >&2
    return 1
  fi
  while IFS= read -r nic; do
    [[ -n $nic ]] && set_args+=(--data-urlencode "$nic")
  done < <(jq -r 'to_entries[] | .key + "=" + .value' <<<"$want")
  if ! pve_api PUT "$base/config" "${set_args[@]}" >/dev/null; then
    echo "the isolation write to $vmid failed; do not start it" >&2
    return 1
  fi
  cfg=$(pve_api GET "$base/config") || cfg=
  # Same NICs with the same options (Proxmox may reorder them), and both flags present.
  if ! jq -es --argjson want "$want" 'def opts: with_entries(.value |= (split(",") | sort));
      length == 1 and (.[0].data | type == "object"
      and (.onboot | tostring) == "0" and (.protection | tostring) == "0"
      and (with_entries(select(.key | test("^net[0-9]+$"))) | opts) == ($want | opts))' >/dev/null 2>&1 <<<"$cfg"; then
    echo "$vmid is not isolated; do not start it" >&2
    return 1
  fi
}
