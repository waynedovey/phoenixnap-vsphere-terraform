# PhoenixNAP vSphere 8 Lab

**Terraform** creates an Ashburn ESXi server, public `/29` and temporary Ubuntu installer. **Ansible** stages the VCSA ISO, installs vCenter **inside ESXi**, then registers the host. ESXi itself comes from PhoenixNAP's image.

For a fresh install, clone the `main` branch and run commands from `phoenixnap-vsphere-terraform`. **Always use `-chdir=ashburn`**; root Terraform files are legacy Seattle.

## Create (new lab only)

**Authentication:** Terraform automatically reads `~/.pnap/config.yaml` (`/Users/wdovey/.pnap/config.yaml` on this Mac). It must contain `clientId` and `clientSecret` from the PhoenixNAP portal. Keep the file outside Git and do **not** copy its contents into Terraform files. Unset `PNAP_CLIENT_ID` and `PNAP_CLIENT_SECRET` so old environment values cannot override the file.

Copy the example only if `terraform.tfvars` is absent; edit it to enable both servers, set correct SKUs and approval flags, and verify hourly pricing. Start only after checking the PhoenixNAP console and Ashburn state contain **no old resources**.

```bash
git clone --branch main --single-branch https://github.com/waynedovey/phoenixnap-vsphere-terraform.git
cd phoenixnap-vsphere-terraform
test -r ~/.pnap/config.yaml
chmod 600 ~/.pnap/config.yaml
unset PNAP_CLIENT_ID PNAP_CLIENT_SECRET
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
vim ashburn/terraform.tfvars
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn state list
```

If state is **empty**, and the PhoenixNAP portal confirms no old Ashburn servers or IP allocations, allocate the public `/29` first:

```bash
terraform -chdir=ashburn plan -target='pnap_ip_block.esxi_29[0]' -out=ip-block-only.tfplan
terraform -chdir=ashburn show ip-block-only.tfplan
terraform -chdir=ashburn apply ip-block-only.tfplan
```

Expect **1 add**. If `pnap_ip_block.esxi_29[0]` is **already in state**, **skip this entire allocation step**; never create a duplicate. Verify its ID and API access first. A **403** during refresh means STOP: confirm the same PhoenixNAP account/credentials and whether the block exists in the portal. Never remove a state entry just to silence a 403.

If the `/29` is managed and accessible but **both servers are absent**, run:

```bash
terraform -chdir=ashburn plan -out=servers.tfplan
terraform -chdir=ashburn show servers.tfplan
terraform -chdir=ashburn apply servers.tfplan
terraform -chdir=ashburn output
```

Inspect each plan **before apply** (expect **2 adds** for the servers). Stop if anything is deleted/replaced or the ESXi `/29` block ID is `null`. Do not repeat creation commands when either server is already managed.

## Install vCenter (Ansible)

Find Ubuntu's **primary public IP** in PhoenixNAP. Use an **authorized VMware ISO** and an independently vendor-verified SHA-256. No untrusted ISO mirror is configured by default. Supply `VCSA_ISO_PATH` for a local ISO when cloud-init has not downloaded a verified one.

**Before deploying, make sure ESXi itself is synchronized** (PhoenixNAP's default NTP servers were unreachable in the previous lab). The helper uses the ESXi API, so no SSH service is needed:

```bash
bash ashburn/scripts/esxi-time.sh check
# Only if the time is NOT synchronized, configure tested public NTP servers:
bash ashburn/scripts/esxi-time.sh configure
bash ashburn/scripts/esxi-time.sh check
```

Proceed only after the output reports **Time Synchronized: true**. The new Ansible workflow uses ESXi's existing `public.<VLAN>` port group and VMware Tools host time sync by default; it does **not** create a hardcoded VLAN 3 port group.

```bash
bash ashburn/scripts/setup-ansible.sh
export INSTALLER_IP="UBUNTU_PRIMARY_IP"
export VCSA_ISO_SHA256="VENDOR_VERIFIED_64_HEX_SHA256"
# export VCSA_ISO_PATH="/path/to/VMware-VCSA.iso"
bash ashburn/scripts/vcsa.sh prepare

# Verify the ESXi TLS certificate fingerprint out of band (see detailed guide):
export VCSA_ESXI_CERT_SHA256="VERIFIED_ESXI_CERT_SHA256"
export ESXI_NTP_SYNC_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh precheck

# Only after required PhoenixNAP/VMware approvals and successful precheck:
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

The deploy stage refuses to overwrite an existing `vcsa-ash` VM. Deployment requires typing `DEPLOY-VCENTER` and prompts for passwords. See [ISO, networking, NTP and Ansible prerequisites](docs/vcsa-ansible.md).

## Destroy everything

**Permanent:** destroys ESXi, vCenter, VMs, local data, Ubuntu and the `/29`. Back up first.

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
terraform -chdir=ashburn apply teardown.tfplan
```

Check PhoenixNAP **Servers, IP Allocations and Billing** afterward, including the installer's default public IP allocation. Do not delete local Terraform state before destroying resources.

**Before Monday's new lab:** keep the state backup, but archive old `private/vcsa-config-ashburn.json` and `private/embedded_vCSA_on_ESXi.json` so Ansible generates configuration for the **new** ESXi IP, certificate and port group. Recheck state and the portal for zero existing resources, then create once. To remove **only Ubuntu** after VCSA is healthy: `bash ashburn/scripts/retire-installer.sh`, then set `enable_installer = false` in `ashburn/terraform.tfvars`.

**Keep `ashburn/terraform.tfstate` safe and out of Git. Never format `datastore1`.** [Details](ashburn/README.md) · [Manual fallback](docs/ashburn-manual.md)
