# Proxmox API Token Authentication

An alternative to SSH + sudo for an AI agent. Use when the agent needs
Proxmox management but doesn't need arbitrary shell access.

## What is an API token?

A PVE API token is a `<user>@<realm>!<tokenid>=<uuid>` triple that
authenticates to the Proxmox REST API at `https://<host>:8006/api2/json/`.
Tokens are scoped to a user, can be granted specific permissions, can
have an expiration date, and can be revoked individually.

## When to use API tokens vs SSH + sudo

| Use API tokens when | Use SSH + sudo when |
|---|---|
| Agent only needs Proxmox ops | Agent also needs non-Proxmox access (logs, services, files) |
| You want fine-grained per-token revocation | You want a single blast-radius boundary |
| Agent is network-isolated and the web API is the only path | Agent is on the same network and SSH is reachable |
| You're running many small agents | You have one agent per host |

For a homelab agent that needs to manage VMs *and* debug host issues
(network, storage, services), SSH + sudo is more flexible. For an agent
that's purely a Proxmox orchestrator (deploy VMs from CI, etc.), API
tokens are cleaner.

## Creating an API token

```bash
# Create a user for the agent (one-time, as root)
sudo -n pveum useradd zen-agent@pve -comment "AI agent"

# Create the API token for that user
sudo -n pveum tokenadd zen-agent@pve zen-token \
    --comment "Agent token" \
    --expire 365   # days, 0 = never

# The output includes the token SECRET — capture it once, store safely:
# Token: zen-agent@pve!zen-token
# Value: a1b2c3d4-...    <-- ONLY shown once
```

The `Value` (the UUID) is the secret. It is **only displayed at creation
time**. Lose it and you must create a new token.

## Granting permissions

API tokens inherit their user's permissions by default. To grant the
token its own permissions (recommended — easier to revoke):

```bash
# Create a role with the permissions we want
sudo -n pveum roleadd AgentPVE -privs "VM.Allocate VM.Clone VM.Config.CDROM \
    VM.Config.CPU VM.Config.Disk VM.Config.Memory VM.Config.Network \
    VM.Config.Options VM.Monitor VM.PowerMgmt Datastore.Audit \
    Pool.Audit Sys.Audit Sys.Modify"

# Assign the role to the token at the root path
sudo -n pveum aclmod / -token zen-agent@pve!zen-token -role AgentPVE
```

## Using the token

```bash
# Header format
TOKEN="zen-agent@pve!zen-token=a1b2c3d4-..."
HOST="https://proxmox.example.com:8006"

# List VMs
curl -s -k -H "Authorization: PVEAPIToken=$TOKEN" \
    "$HOST/api2/json/cluster/resources?type=vm"

# Create a VM
curl -s -k -H "Authorization: PVEAPIToken=$TOKEN" -H "Content-Type: application/json" \
    -X POST "$HOST/api2/json/nodes/apollo/qemu" \
    -d '{"vmid":100,"name":"test","memory":2048,"cores":2}'
```

Or use `pvesh` with the env vars:
```bash
export PVE_TOKEN="zen-agent@pve!zen-token"
export PVE_TOKEN_VALUE="a1b2c3d4-..."
pvesh get /cluster/resources --type vm
```

## Revoking a token

```bash
sudo -n pveum tokenrm zen-agent@pve zen-token
```

That's it. The token is immediately invalid. The user remains; only the
token is gone. Create a new one if needed.

## Security notes

- **HTTPS only.** API tokens sent over HTTP are trivially captured.
  PVE's web UI uses HTTPS by default; never disable it.
- **Treat the token secret like a password.** Store in env vars, not in
  shell history or git.
- **Token scoping matters.** A token with `VM.Allocate` and `Datastore.Audit`
  can create VMs and read storage. A token with `/` and `Administrator`
  can do anything the user can — including deleting storage pools.
- **Expiration.** Always set an expiration. `0` (never expire) is for
  testing only.
- **Audit log.** API token actions appear in `/var/log/pveproxy/access.log`
  and `/var/log/auth.log` with the token ID.

## Hybrid: SSH for ops, API token for read-only

A common pattern: agent uses SSH + sudo for write operations (creating
VMs, modifying config) and uses an API token for read-only observation
(list VMs, get cluster status). This way the API token has minimal
permissions (read-only) and even if it's leaked, the damage is bounded.
