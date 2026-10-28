# Ashburn vSphere 8 lab + disposable VCSA installer

This is a **separate Terraform state** for PhoenixNAP US East 1 / Ashburn
(`ASH`), not a change to the active Seattle state. It provisions:

- One billable `s2.c2.large` ESXi 8 BMC host with a dedicated IPv4 /29.
- One **temporary** `s0.d1.small` Ubuntu 20.04 BMC host, with its own
  system-managed public IP allocation.
- Cloud-init on the Ubuntu host automatically downloads, checks SHA-256, and
  mounts the VCSA 8 ISO in **Ashburn**; it does not deploy VCSA.

Nothing is provisioned by default, and the old Seattle state is untouched.
Running the real VCSA installer is intentionally a separate, gated step.

## Safety prerequisites

1. Stop any Mac-to-Seattle OVF transfer. Inspect the Seattle VCSA VM before
   deleting it, and retire the old Seattle bare-metal host and its public IP
   block through the **existing Seattle state**. Never delete state files or
   use `terraform state rm` to retire billable cloud resources.
2. Verify in the PhoenixNAP portal that Seattle resources/IP allocations are
   gone. Terraform applies in this directory cannot release the Seattle IPs.
3. Confirm `s2.c2.large`, `s0.d1.small`, ESXi 8 and Ubuntu 20.04 images are
   available in ASH. The provider's billing catalog shows **price**, not stock.
4. Verify you may use VCSA media and compare its checksum to an independent
   vendor source. The supplied `d.idc.ir` mirror is **not official**. The
   existing Mac file's digest alone does *not* establish authenticity.
5. Ensure the new ESXi IPv4 /29 can carry a public guest on VLAN 3. Create an
   ESXi VM port group `vcsa-public` with VLAN 3; do not alter management
   VMkernel port groups. Pick an **unused Ashburn address** for VCSA, with
   the Ashburn gateway and prefix. Do **not** reuse Seattle .146/.147 IPs.
6. This lab uses a publicly reachable ESXi management API by default, mirroring
   the existing lab. Prefer setting `management_allowed_cidrs` to trusted /32s.

## Create both in Ashburn

From the repository root, with PhoenixNAP credentials already configured:

```bash
cp ashburn/terraform.tfvars.example ashburn/terraform.tfvars
terraform -chdir=ashburn init
terraform -chdir=ashburn fmt -check
terraform -chdir=ashburn validate
```

Edit `ashburn/terraform.tfvars`. Once the old host is actually retired and
you have independently verified the ISO checksum:

```hcl
enable_esxi             = true
enable_installer        = true
confirm_seattle_retired = true
confirm_esxi_image      = true
approve_hourly_costs    = true
vcsa_iso_sha256         = "YOUR_OFFICIALLY_VERIFIED_SHA256"
```

Terraform retrieves **live, account-specific hourly prices** for the Ashburn
ESXi SKU, installer SKU, /29, and anticipated Linux /31. Its preconditions
block creation on missing/ambiguous prices or a combined price above
`maximum_hourly_usd`. The default US$1.00/hour cap is a safety ceiling,
**not** a preapproval or an asserted price.

```bash
terraform -chdir=ashburn plan -out=ashburn.tfplan
terraform -chdir=ashburn show ashburn.tfplan
```

Expect exactly three creations: `pnap_ip_block.esxi_29[0]`,
`pnap_server.esxi[0]`, and `pnap_server.installer[0]`.
Review pricing, availability, IPs and all resources. Only when satisfied,
explicitly run:

```bash
terraform -chdir=ashburn apply ashburn.tfplan
terraform -chdir=ashburn output
```

Provisioning both BMC instances incurs **additional hourly charges** until
the temporary installer is retired. There is no unattended cloud deletion.

## Temporary Ubuntu host bootstrap

Cloud-init installs `curl`, `python3`, `jq`, and `libnsl2`, downloads
the ISO from `vcsa_iso_url`, checks its SHA-256, and mounts it read-only at
`/mnt/vcsa`. It does not execute the ISO's installer.

SSH to the temporary Ubuntu server using the actual primary IP reported by
PhoenixNAP (public-address outputs may contain ranges):

```bash
ssh ubuntu@TEMP_INSTALLER_IP
sudo tail -n 50 /var/log/vcsa-installer-bootstrap.log
ls -l /opt/vcsa/MEDIA_READY
ls -l /mnt/vcsa/vcsa-cli-installer/lin64/vcsa-deploy
nc -vz ASHBURN_ESXI_IP 443
```

For the last command, replace `ASHBURN_ESXI_IP` with the **new** Ashburn ESXi
management IP. A successful connection is mandatory. Verify the new VCSA
static IP will also be reachable over ports 443 and 5480.

## Deploy VCSA from Ashburn (manual approval)

After the Seattle installer is stopped and its VM/state cleaned up, update
your Mac's ignored `private/vcsa-config.json` with the **new** ESXi address,
Ashburn unused public VCSA IP, gateway and prefix. Keep `datastore1` and
`vcsa-public`. Check the JSON contains placeholders, not passwords.

Copy only the non-secret template and the existing password-injecting wrapper:

```bash
ssh ubuntu@TEMP_INSTALLER_IP 'umask 077; mkdir -p vcsa; chmod 700 vcsa'
scp private/vcsa-config.json scripts/vcsa.py ubuntu@TEMP_INSTALLER_IP:vcsa/
```

SSH to the temporary server. Within that **SSH session**, supply each password
privately (not as inline shell commands or in Git/plan files):

```bash
cd ~/vcsa
umask 077
read -rsp 'ESXi root password: ' ESXI_ROOT_PASSWORD; echo
read -rsp 'New VCSA root password: ' VCSA_ROOT_PASSWORD; echo
read -rsp 'New VCSA SSO password: ' VCSA_SSO_PASSWORD; echo
export ESXI_ROOT_PASSWORD VCSA_ROOT_PASSWORD VCSA_SSO_PASSWORD
export VCSA_INSTALLER_DIR=/mnt/vcsa

python3 vcsa.py check --template vcsa-config.json
python3 vcsa.py precheck --template vcsa-config.json
```

Only after reviewing the precheck and any vendor-support limitations:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
python3 vcsa.py deploy --template vcsa-config.json
```

That command also requires typing `DEPLOY-VCENTER`. It is **not** started by
Terraform or cloud-init.

## Automatically retire only the temporary host

After VCSA is working, run the guarded cleanup helper from your Mac:

```bash
bash ashburn/scripts/retire-installer.sh
```

It checks that **only** the temporary Ubuntu BMC server will be deleted and
requires you to type its exact BMC ID. Its system-managed public IP block is
configured with `delete_ip_blocks=true` for cleanup. Verify billing in the
PNAP portal afterward. ESXi and its /29 remain running.

To remove the entire Ashburn lab later, review `terraform -chdir=ashburn
plan -destroy` and explicitly approve the full `terraform destroy`.
