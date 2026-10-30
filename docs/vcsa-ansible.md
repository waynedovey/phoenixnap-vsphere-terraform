# VCSA installation with Ansible (Ashburn)

The command sequence is on the [main README](../README.md). These are the prerequisites and recovery notes.

## What gets installed

- **PhoenixNAP/Terraform** deploys ESXi 8 on bare metal plus a temporary Ubuntu 20.04 server.
- **Ansible `prepare`** checks the ISO on Ubuntu, or copies one from your Mac if cloud-init did not download it; verifies its **SHA-256**; mounts it read-only; checks/creates the `vcsa-public` port group (public VLAN 3); and generates a private VCSA JSON using the **current Terraform IPs**.
- **Ansible `precheck`** runs the VMware VCSA CLI precheck remotely.
- **Ansible `deploy`** re-runs precheck and, after approvals and an explicit confirmation, installs the VCSA VM on ESXi.
- **Ansible `register-esxi.sh`** adds ESXi into vCenter's `Datacenter` inventory.

**Ansible does not deploy ESXi's ISO**—PhoenixNAP provides the ESXi 8 image during server provisioning. VCSA runs *as a VM on ESXi*, not as a third PhoenixNAP server.

## One-time setup on your Mac

```bash
cd /Users/wdovey/OCP/phoenixnap-vsphere-terraform
bash ashburn/scripts/setup-ansible.sh
```

This creates/reuses `ashburn/.venv` with Python 3.14, Ansible Core 2.21, pyVmomi and the VMware collection. The VCSA playbook runs **on the Mac** and uses SSH/SCP for Ubuntu 20.04, whose Python 3.8 is not supported as a managed host by Ansible Core 2.21.

## Prepare the ISO and VCSA configuration

After `terraform -chdir=ashburn apply servers.tfplan` succeeds, find the **temporary Ubuntu server's primary IPv4** in PhoenixNAP and verify its SSH host key.

```bash
export INSTALLER_IP="UBUNTU_PRIMARY_IP"
ssh ubuntu@"$INSTALLER_IP" true
export VCSA_ISO_SHA256="INDEPENDENTLY_VENDOR_VERIFIED_64_HEX_DIGEST"
```

If your `vcsa_iso_url` and `vcsa_iso_sha256` in Terraform were both approved and the cloud-init download succeeded, the remote ISO already exists. Otherwise supply a **legitimate local VMware VCSA ISO**:

```bash
export VCSA_ISO_PATH="/absolute/path/to/VMware-VCSA-all-8.0.3-24022515.iso"
```

`prepare` uploads that file **only if the ISO is absent on Ubuntu**. If an incomplete or wrong ISO already exists remotely, fix it there before retrying; the checksum check deliberately fails rather than trusting it.

Check that the PhoenixNAP public VM VLAN is **3** before allowing creation of the ESXi port group:

```bash
export VCSA_PUBLIC_VLAN_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh prepare
```

It creates `private/vcsa-config-ashburn.json` automatically and will **not overwrite** an existing one. If restarting with new ESXi IPs, archive the old JSON and VMware template before running prepare. Confirm the new VCSA IP is unused and network-reachable; don't blindly reuse old public addresses.

## Precheck, install, register

```bash
bash ashburn/scripts/vcsa.sh precheck
```

The wrapper prompts for new VCSA root and SSO passwords; it reads the **ESXi root password** from the current Ashburn Terraform state, not from a tracked file. For deployment, only after actual approval:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

`deploy` requires you to type `DEPLOY-VCENTER`. The remote VMware CLI performs the installation; Ansible hides sensitive task output, so consult private VMware installer logs on Ubuntu if a stage fails.

## Troubleshooting and safety

- **Ubuntu SSH fails:** use the server's primary IPv4, verify its SSH host key, and use the SSH keys installed by PhoenixNAP. Do not use the public IP *range* as an SSH address.
- **ISO validation fails:** confirm legitimate source, the independently verified digest, and `/var/log/vcsa-installer-bootstrap.log` on Ubuntu. An empty checksum in Terraform makes cloud-init skip download.
- **VCSA connectivity fails:** check ESXi `vcsa-public` port group, the actual VLAN mapping, the new `/29`, DNS, and the VCSA guest IP.
- **Existing private JSON points to old IP:** archive it and regenerate from current Terraform outputs. Never put passwords directly in this JSON.
- **Ansible cannot register host:** confirm VCSA is healthy; use `source ashburn/.venv/bin/activate` to run compatible VMware modules.
- **Never format `datastore1`.** The prior ESXi host contained its boot partitions and VMFS datastore on the same NVMe disk.

For the old manual CLI workflow see [manual fallback](ashburn-manual.md). Back up your **ignored** Terraform state securely; it can contain credentials. Never commit ISO images, passwords, Terraform state or plan files.
