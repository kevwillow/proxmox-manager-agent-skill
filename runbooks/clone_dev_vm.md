# Build a dev VM from a template

plane: pve

Show each plan, wait for a yes. Tasks need task.succeeded=true. Failed or cut read, failed write, timeout: stop.

1. In steps 1-3 {vmid} is the template. GET /nodes/{node}/qemu/{vmid}/pending with fields=key lists its keys. GET /nodes/{node}/qemu/{vmid}/config with fields=name,template and its ide, sata, scsi and virtio keys: stop unless template is 1 and one names cloudinit. Operator: confirm its name; give new name, id, pool, storage, memory, address, user, key.
2. GET /cluster/nextid with vmid=the new id: refused means in use. GET /cluster/resources with type=vm, fields=name: the new name must be absent.
3. POST /nodes/{node}/qemu/{vmid}/clone with newid, name, pool, storage, full=1. Now {vmid} is the new id. GET /nodes/{node}/qemu/{vmid}/config with fields=name,smbios1,vmgenid,net0: the name must match. Note them: its identity.
4. PUT /nodes/{node}/qemu/{vmid}/config with ciuser, sshkeys (URL-encoded, spaces as %20), ipconfig0 (ip=address/prefix,gw=gateway or ip=dhcp), memory, onboot=0. Read back: each must equal what was sent.
5. It boots on the network. The operator opens its agent lane. POST /nodes/{node}/qemu/{vmid}/status/start. Repeat GET /nodes/{node}/qemu/{vmid}/agent/get-host-name until it answers the new name, five minutes at most. Proximo cuts the agent's address list: with DHCP, find net0's MAC in the DHCP leases.
6. A step after 3 failed: report. On a separate yes, before POST /nodes/{node}/qemu/{vmid}/status/stop and again before DELETE /nodes/{node}/qemu/{vmid} with purge=1, re-read step 3's fields: stop unless unchanged.

Report id, name, address, user. Not proven: user and key; the operator runs ssh user@address. Then close the agent lane.
