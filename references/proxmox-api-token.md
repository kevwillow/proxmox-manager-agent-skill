# Proxmox API Token Authentication

An alternative to SSH + sudo for an AI agent. Use when the agent needs
Proxmox management but doesn't need arbitrary shell access.

## What is an API token?

A PVE API token is a `<user>@<realm>!<tokenid>` ID plus a secret UUID. It
authenticates to the Proxmox REST API at `https://<host>:8006/api2/json/` with
the header `Authorization: PVEAPIToken=<user>@<realm>!<tokenid>=<secret>`.
Tokens belong to a user, can have their own permissions and an expiry date,
and can be revoked one at a time.

## When to use API tokens vs SSH + sudo

| Use API tokens when | Use SSH + sudo when |
|---|---|
| Agent only needs Proxmox ops | Agent also needs non-Proxmox access (logs, services, files) |
| You want real containment (pool-scoped token) | You accept a root-equivalent allowlist |
| Agent is network-isolated and the web API is the only path | Agent is on the same network and SSH is reachable |
| You're running many small agents | You have one agent per host |

The sudoers allowlist in this skill is root-equivalent; a pool-scoped token is
the only option here that actually limits what a leaked credential can do.

## Creating an API token

```bash
# Create a user for the agent (one-time, as root)
pveum user add agent@pve --comment "AI agent"

# Create the token. --expire is a Unix timestamp, NOT a number of days.
pveum user token add agent@pve t1 --comment "Agent token" \
    --expire "$(date -d '+1 year' +%s)" --privsep 1
```

The output shows the token secret once (`value`). Store the whole header
value in a mode-600 file straight away and do not print it; see SKILL.md,
Mode A step 3. Lose it and you must create a new token.

## Granting permissions

`--privsep 1` (the default) gives the token **no** permissions until you grant
them to the token itself; its effective rights are the intersection of the
user's and the token's. `--privsep 0` makes the token act with all of the
user's rights, which is simpler when the user exists only for this token.

Pool-scoped setup, all built-in roles (see SKILL.md, *Mode A-narrow*, for
what was measured on PVE 9.2.2):

```bash
pveum pool add agent
pveum acl modify /pool/agent                       --tokens 'agent@pve!t1' --roles PVEVMAdmin
pveum acl modify /storage/<vm-storage>             --tokens 'agent@pve!t1' --roles PVEDatastoreUser
pveum acl modify /sdn/zones/localnetwork/<bridge>  --tokens 'agent@pve!t1' --roles PVESDNUser
pveum acl modify /vms/<template-vmid>              --tokens 'agent@pve!t1' --roles PVETemplateUser
```

With `--privsep 1`, grant the same ACLs to the user too (`--users agent@pve`),
because the token can never exceed its user.

Custom roles: PVE 9 removed `VM.Monitor` (use `Sys.Audit` for monitor access)
and added `VM.GuestAgent.*` privileges. `VM.GuestAgent.Unrestricted` allows
running commands as root inside guests; leave it out of a role that does not
need it. List the current privileges of a role with
`pveum role list --output-format json`.

## Using the token

```bash
H=https://pve.example.com:8006
AUTH="Authorization: $(cat ~/.config/pve/pve.token)"

# List VMs
curl -sS -k --pinnedpubkey "$(cat ~/.config/pve/pve.pin)" -H "$AUTH" \
    "$H/api2/json/cluster/resources?type=vm"

# Create a VM (form-encoded, as the web UI does)
curl -sS -k --pinnedpubkey "$(cat ~/.config/pve/pve.pin)" -H "$AUTH" -X POST \
    "$H/api2/json/nodes/<node>/qemu" \
    --data-urlencode vmid=8100 --data-urlencode name=test \
    --data-urlencode memory=2048 --data-urlencode cores=2
```

`scripts/pve-api.sh` wraps this in `pve_api`, `pve_wait` and `pve_vm_ip`.
`pvesh` cannot use a token: it runs on the host as root and talks to the API
locally.

## Revoking a token

```bash
pveum user token delete agent@pve t1
```

The token is invalid at once. The user remains. Deleting the user
(`pveum user delete agent@pve`) removes its tokens and its ACL entries too.

## Security notes

- **HTTPS with a pinned key.** `-k` only skips the CA check for the
  self-signed certificate; `--pinnedpubkey` still rejects any other key.
- **Treat the secret like a password.** Keep it in a mode-600 file, not in
  environment variables, shell history or git.
- **Token scope matters.** A token with `Administrator` on `/` can do
  anything, including deleting storage. Prefer the pool-scoped setup.
- **Expiry.** Set one for anything long-running. `0` means never.
- **Audit.** API calls appear in `/var/log/pveproxy/access.log` with the token
  ID, and every task records the token ID in its UPID.

## Hybrid: SSH for ops, API token for read-only

A common pattern: the agent uses SSH + sudo (or root SSH) for host work and a
token with `PVEAuditor` on `/` for observation. A leaked read-only token can
then reveal configuration but change nothing.
