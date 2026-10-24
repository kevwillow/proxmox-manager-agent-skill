#!/bin/bash
# proximo-token-setup.sh: least-privilege Proxmox tokens for an MCP server
# (written for Proximo 0.45+; the write token works for any client that takes a
# PVE API token). Edit the settings below, then run ONCE on the Proxmox host as root:
#   bash proximo-token-setup.sh
#
# It makes two privsep tokens on user proximo@pve, the pair Proximo's
# `proximo arm` / `proximo disarm` swap between:
#   proximo@pve!read    PVEAuditor on /: read everything, change nothing
#   proximo@pve!write   the grants below, each also given to the user
#                       (a privsep token's rights are the intersection of both)
#     /                                     PVEAuditor        read everything
#     /pool/agent                           PVEVMAdmin        full control of guests IN pool "agent" only
#     /pool/templates                       PVETemplateUser   clone (and read) the templates, nothing else
#     /storage/$VM_STORAGE                  PVEDatastoreUser  allocate VM disks
#     /storage/$BACKUP_STORAGE              PVEDatastoreUser  write backups
#     /sdn/zones/localnetwork/$BRIDGE       PVESDNUser        attach NICs to the bridge
# Why more than `proximo mint pve --write` prints: that recipe grants only
# PVEVMAdmin on the pool, and a clone from a template then fails with
# "403 Permission check failed (/vms/<template>, VM.Clone)" (measured, PVE 9.2.2).
#
# The user also gets PVEAuditor on every narrower path above. Without it the
# narrower grant replaces the inherited one for the user, and the read token
# loses Pool.Audit / Datastore.Audit there (the intersection shrinks).
#
# It also creates pools "agent" (empty) and "templates" ($TEMPLATE_IDS added).
# Clone with pool=agent so new guests land inside the write token's reach.
# Each secret goes straight into /root/proximo-<name>.token (mode 600) and is
# never printed. Copy both to the agent's machine, then delete them here.
#
# Undo everything. Remove the tokens BEFORE the user: deleting only the user
# leaves the tokens' ACL lines behind in /etc/pve/user.cfg (measured):
#   pveum user token remove proximo@pve read; pveum user token remove proximo@pve write
#   pveum user delete proximo@pve; pveum pool delete agent
#   pvesh set /pools/templates --vms <ids> --delete 1; pveum pool delete templates
#
# Tested on PVE 9.2.2 (2026-10-23) with Proximo 0.46.2, templates 9000-9015,
# storages vmdata and shared, bridge vmbr0: clone/snapshot/backup/restore/delete
# inside the pool worked; a clone outside the pool returned 403.
set -euo pipefail
umask 077

# --- Settings: edit these ---
TEMPLATE_IDS="$(seq -s, 9000 9015)"   # comma-separated VMIDs of the templates to allow cloning
VM_STORAGE=vmdata                     # where new guests' disks go
BACKUP_STORAGE=shared                 # where backups go
BRIDGE=vmbr0                          # the bridge guests attach to
WRITE_EXPIRE_HOURS=0                  # 0 = never; Proximo recommends an expiry on the write token

U=proximo@pve

id_ok() { pvesh get "$1" >/dev/null 2>&1; }

id_ok /access/users/$U || pveum user add $U --comment "Proximo MCP (least-privilege)"
id_ok /pools/agent     || pveum pool add agent --comment "Guests the AI agent may manage"
id_ok /pools/templates || pveum pool add templates --comment "Templates the AI agent may clone"

# Add only templates not already in the pool: PVE refuses an existing member,
# which would stop a re-run here.
MISSING=$(pvesh get /pools --poolid templates --output-format json | python3 -c '
import json,sys
have = {m.get("vmid") for m in json.load(sys.stdin)[0]["members"]}
print(",".join(i for i in sys.argv[1].split(",") if int(i) not in have))' "$TEMPLATE_IDS")
[ -z "$MISSING" ] || pvesh set /pools/templates --vms "$MISSING"

mint() {  # mint NAME EXPIRE: create the token, secret straight to a 600 file
    if id_ok "/access/users/$U/token/$1"; then
        echo "Token $U!$1 already exists; leaving it and its file alone."
        return
    fi
    pvesh create "/access/users/$U/token/$1" --privsep 1 --expire "$2" --output-format json \
      | python3 -c 'import json,sys; print(sys.argv[1] + "=" + json.load(sys.stdin)["value"], end="")' "$U!$1" \
      > "/root/proximo-$1.token"
    chmod 600 "/root/proximo-$1.token"
    echo "Token written to /root/proximo-$1.token (not shown)."
}
EXPIRE=0
[ "$WRITE_EXPIRE_HOURS" -gt 0 ] && EXPIRE=$(( $(date +%s) + WRITE_EXPIRE_HOURS * 3600 ))
mint read 0
mint write "$EXPIRE"

grant() {  # grant PATH ROLE to the write token and the user (privsep = intersection)
    pveum acl modify "$1" --tokens "$U!write" --roles "$2"
    pveum acl modify "$1" --users "$U" --roles "$2"
    [ "$1" = / ] || pveum acl modify "$1" --users "$U" --roles PVEAuditor
}
pveum acl modify / --tokens "$U!read" --roles PVEAuditor
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
    if a["ugid"] == sys.argv[1] or a["ugid"].startswith(sys.argv[1] + "!"):
        print("  %-32s %-18s %-6s %s" % (a["path"], a["roleid"], a["type"], a["ugid"]))' "$U"
echo
echo "Done. Next: copy /root/proximo-read.token and /root/proximo-write.token to the"
echo "agent's machine (mode 600), then delete them here."
