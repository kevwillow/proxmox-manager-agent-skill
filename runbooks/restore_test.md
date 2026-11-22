# Prove a VM backup by restoring a copy

plane: pve

Never write to the original: before each write, check the id is step 2's. Show each plan, wait for a yes. Tasks need task.succeeded=true. Failed write or timeout: stop.

1. GET /nodes/{node}/storage/{storage}/content with content=backup and the original vmid. The operator picks the volid and a file with known content.
2. GET /cluster/nextid for an id the operator accepts; they open the agent lane for it.
3. POST /nodes/{node}/qemu with that vmid, archive=volid, storage, pool, unique=1. Never force, start or live-restore.
4. GET /nodes/{node}/qemu/{vmid}/pending with fields=key (capped config reads drop keys). Stop if failed, empty, cut, or it has hostpci, usb, virtiofs, parallel, args or hookscript. GET /nodes/{node}/qemu/{vmid}/config with fields naming every netN and serialN. Stop if failed, cut, any is missing, or a serial isn't socket. PUT /nodes/{node}/qemu/{vmid}/config with onboot=0, protection=0 and each netN's own value with link_down=1, replacing any link_down. Read those plus both flags back, same stops: start only if each netN has link_down=1 and both flags are 0.
5. POST /nodes/{node}/qemu/{vmid}/status/start, then GET /nodes/{node}/qemu/{vmid}/agent/get-host-name for up to five minutes. No hostname: report boot not proven, skip to 7.
6. GET /nodes/{node}/qemu/{vmid}/agent/file-read with that file; compare exactly. Failed, empty or cut: report boot proven, data not.
7. Re-read step 4's fields: stop unless unchanged. POST /nodes/{node}/qemu/{vmid}/status/stop, on a separate yes re-read, then DELETE /nodes/{node}/qemu/{vmid} with purge=1. Keep the backup.

Report volid, file compared, result, copy gone or not. The operator closes the agent lane.
