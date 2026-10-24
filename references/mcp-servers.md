# Using a Proxmox MCP server with this skill

Read this when the session has a Proxmox MCP server connected, or when the
user asks to set one up. The MCP server makes the API calls; this skill still
supplies the rules (survey first, own a VMID range, confirm anything
irreversible) and the pitfalls.

Everything below was measured on PVE 9.2.2 on 2026-10-23 with Proximo 0.46.2
unless a line says otherwise. Proximo 0.45.0 replaced its per-task tools
(`pve_clone`, `pve_restore`, ...) with a few tools that take a raw API path;
notes written for 0.44 do not apply to it.

## Choosing one

| | Proximo | ProxmoxMCP-Plus |
|---|---|---|
| Repo | github.com/john-broadway/proximo (Apache-2.0) | github.com/RekklesNA/ProxmoxMCP-Plus (MIT) |
| Before a change | Every mutation can be planned first; the MCP tool only plans unless `confirm=true` | Optional static approval token |
| Write access | A read token by default; `proximo arm` swaps in a write token, `proximo disarm` swaps it back | One token |
| Audit | Keyed, hash-chained ledger; `audit_verify` checks it | Job history in SQLite |
| Coverage | Every published PVE, PBS, PMG and PDM API path, behind six tools | VM/LXC lifecycle, snapshots, backup/restore, jobs, logs (54 tools on 2026-10-08) |
| Self-signed PVE certificate | Pins the node certificate (`PROXIMO_CA_BUNDLE`) or fingerprint | TLS on/off only |

Both were active in October 2026. Proximo was chosen here for its plan-first
design, its read/write token split and its coverage. It has one maintainer and
changes fast (0.44.1 to 0.46.2 in under three weeks, with breaking changes): pin a version
and re-check this file after upgrading. Report defects upstream as issues; its
CONTRIBUTING asks for an issue before anything non-trivial.

## Setting up Proximo

1. **Install, pinned, on the agent's machine** (not on the PVE host; it talks
   to the API on port 8006). Check that PyPI's provenance names the project's
   own release workflow before installing:

   ```bash
   curl -sS -H 'Accept: application/vnd.pypi.integrity.v1+json' \
     https://pypi.org/integrity/proximo-proxmox/<version>/proximo_proxmox-<version>-py3-none-any.whl/provenance |
     jq -r '.attestation_bundles[0].publisher | "\(.repository) \(.workflow)"'
   uv tool install 'proximo-proxmox==<version>'
   ```

   Expect `john-broadway/proximo release-pypi.yml`.

2. **Mint the two tokens on the PVE host** (the user runs it as root):
   `templates/proximo-token-setup.sh`. It makes `proximo@pve!read`
   (`PVEAuditor` on `/`) and `proximo@pve!write` (full control only of guests
   in pool `agent`, clone rights on a `templates` pool, disk space on the VM
   and backup storages, `SDN.Use` on the bridge). Secrets go straight to
   mode-600 files and are never printed. The user copies both to the agent's
   machine and deletes them on the host. Use it instead of
   `proximo mint pve --write`, whose write token cannot clone a template
   (see *Gotchas*).

3. **Pin the node certificate and write the config** (no secrets in it):

   ```bash
   scp root@<host>:/etc/pve/local/pve-ssl.pem ~/.config/proximo/pve-node.pem
   install -m 600 ~/.config/proximo/pve-read.token ~/.config/proximo/pve.served
   cat > ~/.config/proximo/proximo.env <<'EOF'
   PROXIMO_API_BASE_URL=https://<host>:8006/api2/json
   PROXIMO_TOKEN_PATH=<home>/.config/proximo/pve.served
   PROXIMO_READONLY_SOURCE=<home>/.config/proximo/pve-read.token
   PROXIMO_ARM_SOURCE=<home>/.config/proximo/pve-write.token
   PROXIMO_VERIFY_TLS=true
   PROXIMO_CA_BUNDLE=<home>/.config/proximo/pve-node.pem
   EOF
   ```

   `pve.served` is the file Proximo reads; `arm` and `disarm` copy the write
   or read token into it. Compare the pinned certificate's fingerprint with
   the live one (`openssl s_client ... | openssl x509 -fingerprint -sha256`)
   before trusting it. Every Proximo command loads `proximo.env` itself, so the
   MCP client entry needs no `env` block.

4. **Prove the boundary before any model sees it:** `proximo doctor`. Expect
   the `pve` plane reached, `"arm": {"armed": false, "enforced": true}`, and
   `"chain": "ok"` on the ledger.

5. **Register it.** Claude Code: `claude mcp add --scope user proximo -- <path-to>/proximo`.
   Tools appear only in a NEW session.

6. **Arming is the user's act.** The agent works disarmed (read-only). When a
   change is needed, the user runs `proximo arm`, and `proximo disarm` after.
   Planning works disarmed (the plan says `"allowed": false, "needs": "arm"`);
   a `confirm=true` call is refused until the user arms.

Optional hardening Proximo leaves off: `PROXIMO_CONSENT_DIR` (single-use
approval files only the user can write), `PROXIMO_CONTAIN_TRIP_PATH` (kill
switch) and `PROXIMO_RATE_MAX` (mutations per window). `proximo doctor` names
each one it finds unset.

## Calling tools

| Tool | Use |
|---|---|
| `proximo_find` | Plain words to an API path ("clone vm", "guest status") |
| `proximo_plan` | What a call would do and the path's published parameters. Changes nothing |
| `proximo_read` | Any GET. `fields=all` for full rows |
| `proximo_call` | Any POST/PUT/DELETE. Plans only unless `confirm=true`; then runs armed and waits on the task. `method=undo` restores a captured record |
| `audit_entries`, `audit_verify` | Read and check the ledger |

API parameters go in `params` on `proximo_read` but in `args` on
`proximo_plan` and `proximo_call`; a wrong name is refused, not ignored.
Measured over MCP: a `proximo_call` without `confirm` returned
`"status": "plan"` and created nothing; with `confirm=true` a clone, backup,
`unique=1` restore, backup delete and two guest deletes each returned
`exitstatus: OK`, and `audit_verify` returned `ok`.

Common paths (node name is case-sensitive):

| Workflow | Method and path |
|---|---|
| What exists | `GET /cluster/resources` (`type=vm`) |
| Clone a template | `POST /nodes/<node>/qemu/<template>/clone` (`newid`, `name`, `pool=agent`) |
| Power | `POST /nodes/<node>/qemu/<vmid>/status/start` (or `stop`, `shutdown`, `reboot`) |
| Snapshot | `POST /nodes/<node>/qemu/<vmid>/snapshot` (`snapname`) |
| Back up | `POST /nodes/<node>/vzdump` (`vmid`, `storage`, `mode=snapshot`, `compress=zstd`) |
| List backups | `GET /nodes/<node>/storage/<storage>/content` (`content=backup`) |
| Restore | `POST /nodes/<node>/qemu` (`vmid`, `archive`, `pool=agent`, `storage`, **`unique=1`** for a copy) |
| Delete a backup | `DELETE /nodes/<node>/storage/<storage>/content/<volid with / as %2F>` |
| Delete a guest | `DELETE /nodes/<node>/qemu/<vmid>` (`purge=1`) |

The same engine runs from a shell: `proximo-core pve GET /cluster/resources`.
**Unlike the MCP tool, `proximo-core` runs a mutation as soon as you call it.**
Add `--plan` to preview. An agent with a shell should use `--plan` first, every
time.

## Gotchas (measured)

- **Restore copies the original's identity unless you pass `unique=1`.** A
  QEMU restore without it came back with the original's MAC address and SMBIOS
  UUID; with `unique=1` both were new. The restore plan does not warn. Use it
  for any copy that may run beside its original; leave it off only to rebuild a
  lost guest in place, where the old MAC (DHCP reservations, licences) is
  wanted. Even
  with `unique=1` the disk is copied as-is, including `/etc/machine-id`, so a
  copy started next to its original can still get the original's DHCP lease.
  For a test restore, also set `link_down=1` on the NIC (SKILL.md, *Backups*).
  (Proximo 0.44.2 fixed this in its old `pve_restore` tool; that tool was
  removed in 0.45.0.)
- **The read token does not see backups.** PVE lists a backup archive only to a
  token holding `Datastore.AllocateSpace` on the storage and `VM.Backup` on
  its guest (or `Datastore.Allocate` on the storage); `PVEAuditor` gets an empty list (Proximo's SETUP.md, *Seeing
  backups*). An empty listing while disarmed does not mean there are no
  backups.
- **`proximo mint pve --write` cannot clone a template kept outside the pool.**
  Its token holds only `PVEVMAdmin` on the pool; a clone of a template outside the pool returned
  `403 Permission check failed (/vms/<template>, VM.Clone)`. Cloning also needs
  disk space on the target storage and `SDN.Use` on the bridge.
  `templates/proximo-token-setup.sh` grants all three.
- **A narrower grant hides the pool from both tokens.** A grant on a deeper
  path replaces the inherited one for that principal. With `PVEVMAdmin` on
  `/pool/agent` for the user, the read token's rights there (an intersection
  with the user) shrank to `VM.Audit` and `VM.GuestAgent.Audit`, and
  `GET /pools/agent` returned `403 ... (/pool/agent, Pool.Audit)`. The write
  token, holding `PVEVMAdmin` there itself, lacked `Pool.Audit` too. The setup
  script also gives the user and the write token `PVEAuditor` on each narrower
  path, which adds audit rights only.
- **The pool fence holds.** Cloning into `pool=agent` worked; cloning without
  a pool returned HTTP 403.
- **Proximo waits on tasks now.** `proximo_call` with `confirm=true` (and
  `proximo-core`, 60 s by default, `--wait` up to 600) returns only after the
  task ends, with `exitstatus`. Check `timed_out`: a task that outlives the
  wait is still running.
- **Delete backups before their guest.** Once the guest was destroyed, the
  write token could no longer see its backup at all (an empty listing), and a
  delete was refused because Proximo could not read the record first. Only
  root could remove it.
- **A volume id goes in the path with `/` as `%2F`**
  (`shared:backup%2Fvzdump-...`); a literal `/` is refused as an unknown path.
- **Deleting the token user leaves ACL lines behind.** `pveum user delete`
  with tokens still present left their ACL lines in `/etc/pve/user.cfg` (PVE
  logs `ignore invalid acl token`). Remove the tokens first, then the user.
