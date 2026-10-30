# PhoenixNAP vSphere 8 Lab

**Terraform** creates ESXi 8, an Ashburn public `/29`, and a temporary Ubuntu installer server. **Ansible** prepares the VMware ISO, installs **vCenter as a VM on ESXi**, and registers the host.

Run everything from `phoenixnap-vsphere-terraform` on branch `feat/ashburn-esxi-temporary-vcsa-installer`. **Always use `terraform -chdir=ashburn`**, never root-level Terraform (legacy Seattle).

## Create

Set PhoenixNAP API credentials (`PNAP_CLIENT_ID` / `PNAP_CLIENT_SECRET`), then:

```bash
git pull --ff-only
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
vim ashburn/terraform.tfvars
terraform -chdir=ashburn init
```

In `ashburn/terraform.tfvars`, enable **ESXi** and **installer** and set the confirmation flags only after verifying the approvals, stock and hourly costs. Last used: `s2.c2.medium` / `s2.c1.small`. **Do not overwrite your existing tfvars.**

**Fresh, empty-state lab only:** confirm old Ashburn servers and IP allocations are gone. Allocate the `/29` first, then the two servers:

```bash
terraform -chdir=ashburn plan -target='pnap_ip_block.esxi_29[0]' -out=ip-block-only.tfplan
terraform -chdir=ashburn show ip-block-only.tfplan    # 1 add; review
terraform -chdir=ashburn apply ip-block-only.tfplan

terraform -chdir=ashburn plan -out=servers.tfplan
terraform -chdir=ashburn show servers.tfplan          # 2 add; review
terraform -chdir=ashburn apply servers.tfplan
terraform -chdir=ashburn output
```

**STOP** if a plan would modify/delete existing resources or the ESXi public IP block ID is `null`. Never rerun these creation steps if the lab is already provisioned.

## Install vCenter with Ansible

ESXi itself is installed from the **PhoenixNAP ESXi image**; Ansible does **not** install an ESXi ISO. It stages the **VCSA ISO** on Ubuntu and installs vCenter **inside ESXi**.

```bash
bash ashburn/scripts/setup-ansible.sh
export INSTALLER_IP="UBUNTU_PRIMARY_IP"         # PhoenixNAP server page
export VCSA_ISO_SHA256="VENDOR_VERIFIED_SHA256" # 64 hex characters
# export VCSA_ISO_PATH="/path/to/VCSA.iso"      # Only if cloud-init did not fetch it
```

Verify PhoenixNAP's public VLAN really is **3**, then run the stages:

```bash
export VCSA_PUBLIC_VLAN_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh prepare
bash ashburn/scripts/vcsa.sh precheck
```

After the precheck passes **and required PhoenixNAP/VMware approvals are confirmed**:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

Passwords are requested privately; deployment requires typing `DEPLOY-VCENTER`. Use an **authorized ISO and independently vendor-verified checksum**; the configured third-party mirror is not an official source. See [Ansible setup and troubleshooting](docs/vcsa-ansible.md).

## Destroy

**Permanent:** removes ESXi, vCenter and all VMs/data, the installer and the dedicated `/29`. Back up anything needed.

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan   # inspect every deletion
terraform -chdir=ashburn apply teardown.tfplan
```

Check **PhoenixNAP Servers, Public IP Allocations and billing** afterward. Keep Terraform state securely outside Git: an empty state is not proof that untracked resources or billing are gone.

To remove **only Ubuntu** after vCenter is healthy, use `bash ashburn/scripts/retire-installer.sh`, then set `enable_installer = false` in your tfvars.

[Detailed notes](ashburn/README.md) · [Manual fallback](docs/ashburn-manual.md) · [Ansible install](docs/vcsa-ansible.md)
