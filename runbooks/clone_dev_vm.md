# Build a dev VM from a template

plane: pve

Show each plan, wait for a yes. Tasks need task.succeeded=true. Failed or cut read, failed write, timeout: stop.

1. In steps 1-3 {vmid} is the template. GET /nodes/{node}/qemu/{vmid}/pending with fields=key. GET /nodes/{node}/qemu/{vmid}/config with fields=name,template and its ide, sata, scsi and virtio keys: stop unless template is 1 and one names cloudinit. The operator confirms its name, gives new name, id, pool, storage, memory, address, user, key.
2. GET /cluster/nextid with vmid set to the new id: refused means in use. GET /cluster/resources with type=vm, fields=name: stop if the new name is there.
3. POST /nodes/{node}/qemu/{vmid}/clone with newid, name, pool, storage, full=1. Now {vmid} is the new id. GET /nodes/{node}/qemu/{vmid}/config with fields=name,smbios1,vmgenid: stop unless the name matches. Note them: its identity.
4. PUT /nodes/{node}/qemu/{vmid}/config with ciuser, sshkeys (URL-encoded, spaces as %20), ipconfig0 (ip=address/prefix,gw=gateway or ip=dhcp), memory, onboot=0. Read them back: each must equal what was sent.
5. It boots with its network up. The operator opens the agent lane for it. POST /nodes/{node}/qemu/{vmid}/status/start. Repeat GET /nodes/{node}/qemu/{vmid}/agent/get-host-name until it answers the new name, five minutes at most: cloud-init ran. A DHCP address comes from the DHCP server: Proximo cuts the agent's list.
6. A step after 3 failed: report. On a separate yes re-read step 3's fields, stop unless unchanged; POST /nodes/{node}/qemu/{vmid}/status/stop; re-read; DELETE /nodes/{node}/qemu/{vmid} with purge=1.

Report id, name, address, user. Not proven: login, so the operator runs ssh user@address. The operator closes the agent lane.
