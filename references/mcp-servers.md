# Using a Proxmox MCP server with this skill

Read this when the session has a Proxmox MCP server connected, or when the
user asks to set one up. The MCP server makes the API calls; this skill still
supplies the rules (survey first, own a VMID range, wait for every task,
confirm anything irreversible) and the pitfalls.

Everything below was measured on PVE 9.2.2 on 2026-10-08 with Proximo 0.44.1
unless a line says otherwise.

## Choosing one

| | Proximo | ProxmoxMCP-Plus |
|---|---|---|
| Repo | github.com/john-broadway/proximo (Apache-2.0) | github.com/RekklesNA/ProxmoxMCP-Plus (MIT) |
| Before a change | Every mutation returns a PLAN (blast radius, risk); it runs only with `confirm=true` | Optional static approval token |
| Audit | Keyed, hash-chained ledger; `audit_verify` checks it | Job history in SQLite |
| Coverage | PVE, PBS, PMG, PDM: 924 tools behind a small search "door" (about 1.7k tokens of context) | 54 tools: VM/LXC lifecycle, snapshots, backup/restore, jobs, logs |
| Self-signed PVE certificate | Pins the node certificate (`PROXIMO_CA_BUNDLE`) | TLS on/off only |

Both were active in October 2026. Proximo was chosen here for its plan-first
design and coverage; its risk is size (about 108k lines, one maintainer).
Contribute fixes upstream rather than forking: its CONTRIBUTING asks for an
issue first for anything non-trivial.

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

2. **Mint a pool-scoped token on the PVE host** (the user runs it as root):
   `templates/proximo-token-setup.sh`. It grants read everywhere
   (`PVEAuditor` on `/`), full control only of guests in pool `agent`, clone
   rights on a `templates` pool, disk space on the VM and backup storages, and
   `SDN.Use` on the bridge. The secret goes straight to a mode-600 file and is
   never printed. Copy it to the agent's machine, then delete it on the host.

3. **Pin the node certificate and write the config** (no secrets in it):

   ```bash
   scp root@<host>:/etc/pve/local/pve-ssl.pem ~/.config/proximo/pve-node.pem
   cat > ~/.config/proximo/proximo.env <<'EOF'
   PROXIMO_API_BASE_URL=https://<host>:8006/api2/json
   PROXIMO_NODE=<node>
   PROXIMO_TOKEN_PATH=<home>/.config/proximo/pve.token
   PROXIMO_VERIFY_TLS=true
   PROXIMO_CA_BUNDLE=<home>/.config/proximo/pve-node.pem
   EOF
   ```

   Compare the pinned file's fingerprint with the live one
   (`openssl s_client ... | openssl x509 -fingerprint -sha256`) before trusting it.
   The stdio server loads `proximo.env` itself, so the MCP client entry needs
   no `env` block.

4. **Prove the boundary before any model sees it:** `proximo doctor`. Expect
   `"reachable": true`, empty `flags`, and a `cannot` list that includes
   storage definition, firewall and node configuration, tokens/ACLs and users.

5. **Register it.** Claude Code: `claude mcp add --scope user proximo -- <path-to>/proximo`.
   Tools appear only in a NEW session.

Optional hardening Proximo offers but leaves off: `PROXIMO_CONSENT_DIR`
(approval files only the user can write), `PROXIMO_CONTAIN_TRIP_PATH` (kill
switch), an off-box audit anchor, and `PROXIMO_TOOLS_PIN` (refuse to start if
the tool surface changed). `proximo doctor` says how to turn each on.

## Calling tools

The default door serves 7 tools. Find others with `proximo_find_tools`, read
their arguments with `proximo_tool_schema`, run read-only ones with
`proximo_read` and mutations with `proximo_call` (`{"tool": ..., "arguments": {...}}`).

| Workflow | Proximo tool |
|---|---|
| Boundary check | `pve_doctor` |
| What exists | `pve_list_guests`, `pve_guest_status`, `pve_guest_config_get` |
| Clone a template | `pve_clone` (`kind=qemu`, `pool=agent`) |
| Power | `pve_guest_power` (`action=start/stop/shutdown/reboot`) |
| Cloud-init | `pve_cloudinit_get`, `pve_cloudinit_set` |
| Snapshot / undo | `pve_snapshot_create`, `pve_snapshot_list`, `pve_rollback` |
| Backup / restore | `pve_backup`, `pve_backup_list`, `pve_restore`, `pve_backup_delete` |
| Delete a guest | `pve_delete_guest` (`purge=true`) |
| Wait for a task | `pve_task_wait`, `pve_task_status` |
| Prove the record | `audit_verify`, `audit_entries` |

## Measured behaviour and gotchas

- **Plan, then confirm.** Without `confirm=true` a mutation returns
  `"status": "plan"` and changes nothing. The delete plan was marked high risk,
  listed the disk and snapshot it would remove, and predicted that PVE would
  refuse because the guest was running.
- **The pool fence holds.** Cloning into `pool=agent` worked; cloning without
  a pool returned HTTP 403, so the token cannot create guests outside it.
- **"submitted" is not "done".** A stop sent while a snapshot was still running
  failed with `VM is locked (snapshot)`. Call `pve_task_wait` on every UPID
  before the next mutation.
- **`kind` defaults to `lxc`.** Cloning a QEMU template without `kind=qemu`
  produced a plan for "lxc/9002" (a guest that does not exist) that still said
  `"complete": true`. Always pass `kind`.
- **QEMU restore cannot make a safe copy (0.44.1).** `pve_restore` sends no
  `unique` and no `storage` for QEMU. A restored copy had the original's MAC
  and SMBIOS UUID, so starting both would put two identical machines on the
  network. Do not start such a copy next to its original. For a safe test
  restore, use the API directly with `unique=1` and `link_down=1` (see
  SKILL.md, *Backups*).
- **Delete backups before their guest.** With a pool-scoped token, deleting a
  backup after its guest was destroyed returned HTTP 403 (the backup no longer
  belongs to anything in the pool). Deleting the backup first worked.
- **Existence checks outside the pool read "unknown".** A restore plan for a
  free VMID said it could not confirm whether the target exists, because the
  token cannot see IDs outside its pool. That is honest, not a fault.
- **Guest firewall plans (not measured through Proximo; read in its 0.44.1
  source):** the enable plan does not mention that nothing is enforced while
  the datacenter switch is off, or that a NIC needs `firewall=1`. Check both
  yourself (SKILL.md, *Firewall*).
