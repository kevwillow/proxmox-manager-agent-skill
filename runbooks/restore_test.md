# Prove a VM backup by restoring a copy

plane: pve

Never write to the original guest: before every write, check the vmid is the copy's from step 2. Plan each write and wait for the operator's yes. After each task, require task.succeeded=true; a timeout is not success. If any write fails, stop and run no later step.

1. GET /nodes/{node}/storage/{storage}/content with content=backup and the original vmid. Let the operator pick the volid and a file with known content.
2. GET /cluster/nextid for the copy's id. The operator must open the agent lane for it.
3. POST /nodes/{node}/qemu with that vmid, archive=volid, storage, pool and unique=1. Never pass force, start or live-restore.
4. GET /nodes/{node}/qemu/{vmid}/pending of the copy with fields=key, as a capped config read drops keys. Stop if that list is truncated or has hostpci, usb, virtiofs, args or hookscript. GET /nodes/{node}/qemu/{vmid}/config with fields naming every netN; stop if clipped. PUT /nodes/{node}/qemu/{vmid}/config with onboot=0, protection=0 and link_down=1 on every netN, keeping the rest of each value. Read those fields again: start only if every one has link_down=1.
5. POST /nodes/{node}/qemu/{vmid}/status/start, then GET /nodes/{node}/qemu/{vmid}/agent/get-host-name until it answers, five minutes at most.
6. GET /nodes/{node}/qemu/{vmid}/agent/file-read with that file, and compare. If the agent refuses, report that boot is proven and data is not.
7. Check the id again, POST /nodes/{node}/qemu/{vmid}/status/stop on the copy, then DELETE /nodes/{node}/qemu/{vmid} with purge=1 on a separate yes. Keep the backup.

Report the volid, what was compared, the result, and whether the copy is gone. Remind the operator to close the agent lane for that id.
