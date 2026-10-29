# Ashburn vSphere 8 — simple runbook

This stack lives in `ashburn/` and uses **independent Terraform state**.
It manages the PhoenixNAP ESXi server, a public IPv4 /29 and (optionally) a
temporary Ubuntu installer. The VCSA VM runs **inside ESXi**, not as a separate
PhoenixNAP server.

## 1. Prerequisites

- On your Mac: `terraform`, `jq`, `govc`, `ssh`, `scp`.
- PhoenixNAP API credentials available as `PNAP_CLIENT_ID` and
  `PNAP_CLIENT_SECRET` (load privately; never commit them).
- Correct ASH hardware stock and live prices. Our working lab used
  `s2.c2.medium` (ESXi) and `s2.c1.small` (temporary installer);
  availability and price can change.
- A legally obtained VCSA ISO and SHA-256 **independently checked against a
  trusted vendor source**. The default third-party URL is not an official
  source. Get any required PhoenixNAP approval for hosting VCSA.
- The old Seattle environment really retired before setting the corresponding
  approval flag. Management access is public unless its CIDRs are restricted.

## 2. Provision the bare-metal lab

Run from the **Ashburn checkout root**, not the old Seattle checkout:

```bash
cp ashburn/terraform.tfvars.example ashburn/terraform.tfvars
```

Edit `ashburn/terraform.tfvars`. For a brand-new, fully approved build:

```hcl
enable_esxi             = true
enable_installer        = true
confirm_seattle_retired = true
confirm_esxi_image      = true
approve_hourly_costs    = true
esxi_type               = "s2.c2.medium"
installer_type          = "s2.c1.small"
maximum_hourly_usd      = 1.00
```

Set `vcsa_iso_sha256` separately to your **actual verified 64-character
digest**. If it is empty, the installer VM may be provisioned but its ISO
download is intentionally skipped. Do not set approvals to true without
verifying them; they do not guarantee stock or enforce a live billing stop.

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn plan -out=provision.tfplan
terraform -chdir=ashburn show provision.tfplan
terraform -chdir=ashburn apply provision.tfplan
terraform -chdir=ashburn output
```

Check the plan's resource addresses, hourly quote and region **before**
applying. Terraform creates servers and a /29; it does **not** install VCSA.
Keep this local state, since you will need it for teardown.

## 2A. ESXi already exists? Deploy **only** the ISO installer

If the ESXi host is running, do **not** provision ESXi a second time. Your
earlier lab ran an installer at `131.153.155.201`, and later logs confirmed
`vcsa-ash` in vCenter. First check whether an installer still exists and
whether you actually need to rebuild VCSA:

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn output installer_id
terraform -chdir=ashburn output installer_public_ip_addresses
terraform -chdir=ashburn output esxi_id
```

- If state lists `pnap_server.installer[0]`, check its ID against the
  PhoenixNAP console. Do **not** launch a duplicate.
- If `installer_id` is `null`, the server is not in this state. Check
  PhoenixNAP for an orphaned server before proceeding.
- If `govc about` shows `VMware vCenter Server` and `govc find / -type m`
  lists `vcsa-ash`, the VCSA installer is no longer required unless you
  intend to rebuild it.

To add *only* the missing Ubuntu host, edit your **existing**
`ashburn/terraform.tfvars` (never copy the example over it):

```hcl
enable_esxi      = true
enable_installer = true
installer_type   = "s2.c1.small"
```

**Keep your current `esxi_type`, network settings and approval flags unchanged.**
Supply a trusted, independently vendor-verified 64-character
`vcsa_iso_sha256`; leaving it blank makes cloud-init skip the ISO. Verify
the temporary server type is in stock and that the revised hourly quote fits
your approved budget.

```bash
terraform -chdir=ashburn plan -out=installer-only.tfplan
terraform -chdir=ashburn show installer-only.tfplan
```

**STOP unless the plan creates exactly `pnap_server.installer[0]`
(1 add, 0 change, 0 destroy).** No ESXi replacement, /29 change or other
resources should appear. Only then apply:

```bash
terraform -chdir=ashburn apply installer-only.tfplan
terraform -chdir=ashburn output installer_id
terraform -chdir=ashburn output installer_public_ip_addresses
```

The public IP output may contain a **range** rather than a single SSH address.
Get the host's **primary IP** from the PhoenixNAP console. The ISO bootstrap
should prepare `/mnt/vcsa`, not deploy vCenter. Check it with:

```bash
ssh ubuntu@INSTALLER_IP
sudo tail -n 50 /var/log/vcsa-installer-bootstrap.log
ls -l /opt/vcsa/MEDIA_READY
mountpoint /mnt/vcsa
ls -l /mnt/vcsa/vcsa-cli-installer/lin64/vcsa-deploy
```

If `MEDIA_READY` is absent or the mount check fails, fix bootstrap/media
verification before trying to install VCSA. The old `libnsl2` package
dependency that caused Ubuntu 20.04 bootstrap failures was removed in this
branch. Continue with section 3 only when the ISO is mounted and ready.

## 3. Deploy VCSA on ESXi

1. Connect `govc` to the **new ESXi IP** from
   `terraform -chdir=ashburn output -raw esxi_management_url`
   using its root credentials from **Ashburn** Terraform state.
2. Check the `vcsa-public` port group. If missing, create it:
   `govc host.portgroup.add -vswitch vSwitch0 -vlan 3 vcsa-public`.
   Do not change ESXi management networking.
3. Get the temporary Ubuntu host's **SSH IP** from the PhoenixNAP console
   (the Terraform output may show an IP range), then check media readiness:

   ```bash
   ssh ubuntu@INSTALLER_IP
   sudo tail -n 40 /var/log/vcsa-installer-bootstrap.log
   ls -l /opt/vcsa/MEDIA_READY
   ls -l /mnt/vcsa/vcsa-cli-installer/lin64/vcsa-deploy
   ```

   If `MEDIA_READY` is missing, fix the bootstrap error first. Some Ubuntu
   20.04 images did not provide `libnsl2`, which previously interrupted setup.
4. On the Mac, create or update the **ignored**
   `private/vcsa-config-ashburn.json` from the VMware installer template.
   Use the current /29 allocation: ESXi's management IP, a **different unused**
   VCSA guest IP, its actual gateway and /29 prefix, DNS, `datastore1`, and
   `vcsa-public`. Do **not** reuse old Seattle addresses or put passwords
   in the file. Check values with `jq` before copying.
5. Copy the configuration and existing deployment wrapper to Ubuntu:

   ```bash
   ssh ubuntu@INSTALLER_IP 'umask 077; mkdir -p vcsa; chmod 700 vcsa'
   scp private/vcsa-config-ashburn.json ubuntu@INSTALLER_IP:vcsa/vcsa-config.json
   scp scripts/vcsa.py ubuntu@INSTALLER_IP:vcsa/
   ```

6. In the **Ubuntu Bash SSH session**, provide passwords privately and run:

   ```bash
   cd ~/vcsa
   read -rsp 'ESXi root password: ' ESXI_ROOT_PASSWORD; echo
   read -rsp 'New VCSA root password: ' VCSA_ROOT_PASSWORD; echo
   read -rsp 'New VCSA SSO password: ' VCSA_SSO_PASSWORD; echo
   export ESXI_ROOT_PASSWORD VCSA_ROOT_PASSWORD VCSA_SSO_PASSWORD
   export VCSA_INSTALLER_DIR=/mnt/vcsa
   python3 vcsa.py check --template vcsa-config.json
   python3 vcsa.py precheck --template vcsa-config.json
   ```

   After reviewing the precheck, EULA and vendor-support requirements, deploy:

   ```bash
   export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
   export VCSA_DEPLOY_APPROVED=YES
   python3 vcsa.py deploy --template vcsa-config.json
   ```

   The wrapper asks for a final `DEPLOY-VCENTER` confirmation.
   The VCSA installation is **manual and separate** from Terraform.

## 4. Register ESXi in vCenter using Ansible

From the Mac, after VCSA responds:

```bash
brew install python@3.14
python3.14 -m venv ashburn/.venv
source ashburn/.venv/bin/activate
python -m pip install 'ansible-core>=2.21,<2.22' requests pyvmomi
ansible-galaxy collection install -r ashburn/ansible/requirements.yml
bash ashburn/scripts/register-esxi.sh
```

The wrapper reads the **current Ashburn IPs** and ESXi credentials from state
and asks for the VCSA SSO password. It idempotently creates `Datacenter`
and registers the standalone ESXi host. See
[Ansible notes](ansible/README.md) for troubleshooting.

Verify from the vCenter-connected `govc` session:

```bash
govc host.info
govc find / -type m
govc datastore.info
```

Expect ESXi connected, VCSA present and `datastore1` visible.
**Never reformat datastore1:** it is on the only observed NVMe boot disk.

## 5. Tear down

### Temporary Ubuntu installer only

Once VCSA is healthy:

```bash
bash ashburn/scripts/retire-installer.sh
```

Confirm the installer ID when prompted. Then change
`enable_installer = false` in `ashburn/terraform.tfvars` so later normal
applies don't recreate it. ESXi, VCSA and the /29 remain running.

### Everything (ESXi, VCSA, installer, public IPs)

**Back up any data you need first. This is irreversible.** Run from the same
checkout, with the same Ashburn Terraform state and PhoenixNAP credentials:

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
terraform -chdir=ashburn apply teardown.tfplan
terraform -chdir=ashburn state list
```

Inspect the plan carefully **before** applying: it should delete the ESXi
host, the optional installer (if still in state) and `pnap_ip_block.esxi_29`.
Deleting ESXi also destroys its local VMs and data. The separate /29 is owned
by Terraform (ESXi has `delete_ip_blocks = false`), so it must be explicitly
destroyed too. The installer has `delete_ip_blocks = true` for its own default
allocation.

Finally verify in **PhoenixNAP's portal** that the servers and all IP
allocations are gone and charges have stopped. Do not manually delete servers
or discard the state as a substitute for Terraform teardown. Saved plan/state
files can contain credentials; never commit them.

This teardown affects **Ashburn only**, not the legacy Seattle state.
