# PhoenixNAP vSphere 8 Lab

Automate **ESXi 8 + vCenter Server 8** on PhoenixNAP bare metal in Ashburn using Terraform and Ansible.

- **Terraform:** ESXi host, public `/29` and temporary Ubuntu installer
- **Ansible:** VCSA installation, network setup and ESXi registration

> Run all commands from the repository root. Use `terraform -chdir=ashburn`; the root Terraform stack is legacy Seattle.

## 1. Prepare

Configure PhoenixNAP credentials in `~/.pnap/config.yaml` (`clientId` and `clientSecret`). Keep credentials out of Git.

```bash
git clone https://github.com/waynedovey/phoenixnap-vsphere-terraform.git
cd phoenixnap-vsphere-terraform

unset PNAP_CLIENT_ID PNAP_CLIENT_SECRET
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
vim ashburn/terraform.tfvars

terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn state list
```

In `ashburn/terraform.tfvars`, enable the ESXi and installer servers, choose the server types and confirm the hourly-cost approvals.

## 2. Create the lab

**New lab only:** first check the PhoenixNAP portal and Terraform state. Do not recreate existing servers or IP allocations.

Allocate the public `/29` **only if it is not already managed**:

```bash
terraform -chdir=ashburn plan -target='pnap_ip_block.esxi_29[0]' -out=ip-block-only.tfplan
terraform -chdir=ashburn show ip-block-only.tfplan
terraform -chdir=ashburn apply ip-block-only.tfplan
```

Then create the servers **only when both are absent**:

```bash
terraform -chdir=ashburn plan -out=servers.tfplan
terraform -chdir=ashburn show servers.tfplan
terraform -chdir=ashburn apply servers.tfplan
terraform -chdir=ashburn output
```

Review every plan before applying. Stop if it shows unexpected replacements or deletions, or an invalid IP-block reference. A PhoenixNAP `403` during refresh is a reason to check credentials and existing resources, **not** to remove Terraform state.

## 3. Install vCenter

Set an authorized VCSA ISO source and its independently verified SHA-256 in `ashburn/terraform.tfvars`:

```hcl
vcsa_iso_url        = "https://YOUR_AUTHORIZED_VCSA_ISO_URL"
vcsa_iso_sha256     = "YOUR_VERIFIED_64_CHARACTER_SHA256"
vcsa_iso_local_path = ""
```

Alternatively, leave `vcsa_iso_url` empty and set `vcsa_iso_local_path` to an absolute ISO path **on your Mac**. See [Broadcom's download instructions](https://knowledge.broadcom.com/external/article/387785/download-vcenter-server-patches-and-isos.html).

```bash
bash ashburn/scripts/setup-ansible.sh
bash ashburn/scripts/esxi-time.sh check
# If ESXi is not synchronized:
# bash ashburn/scripts/esxi-time.sh configure
# bash ashburn/scripts/esxi-time.sh check

bash ashburn/scripts/vcsa.sh prepare

# Only after ESXi reports "Time Synchronized: true":
export ESXI_NTP_SYNC_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh precheck

# Only after required approvals and a successful precheck:
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy
```

The deployment command shows **live VMware task progress**. IP discovery, ISO verification and ESXi network setup are automated.

## 4. Register ESXi in vCenter

```bash
bash ashburn/scripts/register-esxi.sh
```

After successful registration, the script prints the vCenter login URL and username. The SSO password is hidden by default, with an optional interactive reveal.

## 5. Destroy the lab

**Destructive:** this removes ESXi, vCenter, all VMs, the Ubuntu installer and the public `/29`. Back up anything you need first.

```bash
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
terraform -chdir=ashburn apply teardown.tfplan
```

Verify PhoenixNAP servers, IP allocations and billing afterwards. Keep Terraform state private; **never format `datastore1`**.

---

**More detail:** [VCSA installation and troubleshooting](docs/vcsa-ansible.md) · [Ashburn commands](ashburn/README.md) · [Manual fallback](docs/ashburn-manual.md)
