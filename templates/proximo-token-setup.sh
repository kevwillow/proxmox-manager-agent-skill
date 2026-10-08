#!/bin/bash
# proximo-token-setup.sh: least-privilege Proxmox token for an MCP server
# (written for Proximo; works for any client that takes a PVE API token).
# Edit the four settings below, then run ONCE on the Proxmox host as root:
#   bash proximo-token-setup.sh
#
# What it grants (token proximo@pve!mcp, privsep=1, same grants on the user,
# because a privsep token's rights are the intersection of both):
#   /                                     PVEAuditor        read everything, change nothing
#   /pool/agent                           PVEVMAdmin        full control of guests IN pool "agent" only
#   /pool/templates                       PVETemplateUser   clone (and read) the templates, nothing else
#   /storage/$VM_STORAGE                  PVEDatastoreUser  allocate VM disks
#   /storage/$BACKUP_STORAGE              PVEDatastoreUser  write backups
#   /sdn/zones/localnetwork/$BRIDGE       PVESDNUser        attach NICs to the bridge
# It also creates pools "agent" (empty) and "templates" ($TEMPLATE_IDS added).
# Clone with pool=agent so new guests land inside the token's reach.
# The token secret goes straight into /root/proximo.token (mode 600) and is never
# printed. Copy it to the agent's machine, then delete it here.
# Undo everything: pveum user delete proximo@pve; pveum pool delete agent;
#   pvesh set /pools/templates --vms <ids> --delete 1; pveum pool delete templates
#
# Tested on PVE 9.2.2 (2026-10-08) with templates 9000-9015, storages vmdata and
# shared, bridge vmbr0: clone/start/snapshot/stop/backup/restore/delete inside the
# pool worked; a clone outside the pool returned 403.
set -euo pipefail
umask 077

# --- Settings: edit these ---
TEMPLATE_IDS="$(seq -s, 9000 9015)"   # comma-separated VMIDs of the templates to allow cloning
VM_STORAGE=vmdata                     # where new guests' disks go
BACKUP_STORAGE=shared                 # where backups go
BRIDGE=vmbr0                          # the bridge guests attach to

U=proximo@pve
T="$U!mcp"

id_ok() { pvesh get "$1" >/dev/null 2>&1; }

id_ok /access/users/$U || pveum user add $U --comment "Proximo MCP (least-privilege)"
id_ok /pools/agent     || pveum pool add agent --comment "Guests the AI agent may manage"
id_ok /pools/templates || pveum pool add templates --comment "Templates the AI agent may clone"

pvesh set /pools/templates --vms "$TEMPLATE_IDS"

if id_ok "/access/users/$U/token/mcp"; then
    echo "Token $T already exists; leaving it and its file alone."
else
    pvesh create /access/users/$U/token/mcp --privsep 1 --output-format json \
      | python3 -c 'import json,sys; print("proximo@pve!mcp=" + json.load(sys.stdin)["value"], end="")' \
      > /root/proximo.token
    chmod 600 /root/proximo.token
    echo "Token written to /root/proximo.token (not shown)."
fi

grant() {  # grant PATH ROLE to both the token and the user (privsep = intersection)
    pveum acl modify "$1" --tokens "$T" --roles "$2"
    pveum acl modify "$1" --users "$U" --roles "$2"
}
grant /                             PVEAuditor
grant /pool/agent                   PVEVMAdmin
grant /pool/templates               PVETemplateUser
grant "/storage/$VM_STORAGE"         PVEDatastoreUser
grant "/storage/$BACKUP_STORAGE"     PVEDatastoreUser
grant "/sdn/zones/localnetwork/$BRIDGE" PVESDNUser

echo
echo "Grants now in place:"
pveum acl list --output-format json | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    if a["ugid"].startswith("proximo@pve"):
        print("  %-32s %-18s %-6s %s" % (a["path"], a["roleid"], a["type"], a["ugid"]))'
echo
echo "Done. Next: copy /root/proximo.token to the agent's machine (mode 600), then delete it here."
