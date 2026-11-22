# Build a dev VM from a template

plane: pve

Show each plan, wait for a yes. Tasks need task.succeeded=true. Failed or cut read, failed write, timeout: stop.

1. In steps 1-3 {vmid} is the template. GET /nodes/{node}/qemu/{vmid}/pending with fields=key lists its config keys. GET /nodes/{node}/qemu/{vmid}/config with fields=name,template and its ide, sata, scsi, virtio keys: stop unless template is 1 and one names cloudinit. Operator: confirm its name; give new name, id, pool, storage, memory, address, user, key.
2. GET /cluster/nextid with vmid=the new id: refused means in use. GET /cluster/resources with type=vm, fields=name: the new name must be absent.
3. POST /nodes/{node}/qemu/{vmid}/clone with newid, name, pool, storage, full=1. Now {vmid} is the new id. GET /nodes/{node}/qemu/{vmid}/config with fields=name,smbios1,vmgenid,net0: the name must match. That is its identity.
4. PUT /nodes/{node}/qemu/{vmid}/config with ciuser, sshkeys (URL-encoded, %20 for space), ipconfig0 (ip=address/prefix,gw=gateway or ip=dhcp), memory, onboot=0. Read back: each must equal what was sent.
5. Its network is up. The operator opens its agent lane. POST /nodes/{node}/qemu/{vmid}/status/start. Repeat GET /nodes/{node}/qemu/{vmid}/agent/get-host-name (failed reads retried) until it answers the new name, five minutes at most. Proximo cuts the agent's address list: with DHCP, match net0's MAC to a lease.
6. If a step after 3 failed, report it. On a separate yes, before POST /nodes/{node}/qemu/{vmid}/status/stop and again before DELETE /nodes/{node}/qemu/{vmid} with purge=1, re-read step 3's fields: stop unless unchanged.

Report id, name, address, user. Not proven: user and key; the operator runs ssh user@address. Close the agent lane.
