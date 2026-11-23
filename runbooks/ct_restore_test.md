# Prove a container backup by restoring a copy

plane: pve

Never write to the original: check each write's id is step 2's. Show each plan, wait for a yes. A task must end succeeded=true or exitstatus WARNINGS (report it). Failed write or timeout: stop.

1. GET /nodes/{node}/storage/{storage}/content with content=backup and the original vmid. The operator picks the volid and a file of known content outside the system temp folders (backups skip them).
2. GET /cluster/nextid for an id the operator accepts; they open its container lane.
3. POST /nodes/{node}/lxc with that vmid, ostemplate=volid, restore=1, storage, pool, unique=1. Never force or start.
4. GET /nodes/{node}/lxc/{vmid}/pending with fields=key. Stop if failed, empty, cut, or it has devN, lxc or hookscript. GET /nodes/{node}/lxc/{vmid}/config with fields naming every netN and mpN. Stop if failed, cut, missing, or an mpN starts with / (host path). PUT /nodes/{node}/lxc/{vmid}/config with onboot=0, protection=0 and each netN's own value with link_down=1 (replacing any). Read them back, same stops: start only if every netN has link_down=1, both flags 0.
5. POST /nodes/{node}/lxc/{vmid}/status/start, then GET /nodes/{node}/lxc/{vmid}/status/current with fields=status until running (up to a minute); else report start not proven, skip to 7.
6. POST /nodes/{node}/lxc/{vmid}/exec with command ["cat", the file]; need returncode 0 and stdout exactly the known text; else started, data not proven.
7. Re-read step 4's fields: stop unless unchanged. If running, POST /nodes/{node}/lxc/{vmid}/status/stop; on a separate yes re-read, then DELETE /nodes/{node}/lxc/{vmid} with purge=1. Keep the backup.

Report volid, file, result, copy gone or not; the operator closes the lane.
