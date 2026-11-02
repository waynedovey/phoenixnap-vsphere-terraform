# PhoenixNAP vSphere 8 Lab

Automate **ESXi 8 + vCenter Server 8** on PhoenixNAP bare metal in Ashburn using Terraform and Ansible.

- **Terraform:** ESXi host, public `/29` and temporary Ubuntu installer
- **Ansible:** VCSA installation, network setup and ESXi registration

> Run all commands from the repository root. Use `terraform -chdir=ashburn`; the root Terraform stack is legacy Seattle.

## One-command automation

For a **previously approved** lab, the non-interactive entry point runs Terraform provisioning, ESXi NTP checks, VCSA installation with progress, and ESXi registration:

```bash
bash ashburn/scripts/build-all.sh
```

Before running, configure `~/.pnap/config.yaml`, `ashburn/terraform.tfvars` (enable both servers and record real provider/cost/retirement approvals), and a mode-`600` **git-ignored** `private/ashburn-lab-password` containing the VCSA root/SSO password. The shell environment must already have `PNAP_VCENTER_SUPPORT_CONFIRMED=YES` following actual provider approval. Missing approvals cause the script to **stop without prompting**, not silently self-authorize. **Never commit the password.** PhoenixNAP generates the ESXi root password separately; it is retrieved from Terraform state rather than changed. The script won't replace ESXi, its `/29`, or an existing `vcsa-ash`. **Once ESXi is verified in vCenter, it deletes the temporary Ubuntu installer** using an installer-only Terraform plan and persists `enable_installer = false` in your ignored tfvars. It is an initial-build workflow, not a command to reprovision a retired installer.

For manual step-by-step operation, use the sections below.

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

Set these ISO values in `ashburn/terraform.tfvars`:

```hcl
vcsa_iso_sha256     = "645fb3debfe33331fed5ffd9971d5286b070f412b56a523a78abdc7bece07e29"
vcsa_iso_url        = "https://d.idc.ir/VMWare/8.0.3/VMware-VCSA-all-8.0.3-24022515.iso"
vcsa_iso_local_path = ""
```

These are the lab's current ISO settings. **The URL is a third-party mirror and the SHA-256 is user-supplied; neither verifies publisher authenticity.** For a trusted source, use [Broadcom's download instructions](https://knowledge.broadcom.com/external/article/387785/download-vcenter-server-patches-and-isos.html).

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

The deployment command shows **live VMware task progress**. If VMware returns a non-zero exit code after finishing, it retries **read-only health verification** before deciding whether the install succeeded; it never automatically redeploys an existing VM. IP discovery, ISO verification and ESXi network setup are automated.

**Already deployed?** After `register-esxi.sh` retires the Ubuntu installer, don't rerun `vcsa.sh prepare`, `precheck` or `deploy`. They require the temporary installer. Use `bash ashburn/scripts/vcsa.sh inspect` to check the existing VCSA; it works after retirement. Check `terraform -chdir=ashburn state list` for `pnap_server.installer[0]` if you are unsure whether Ubuntu was deleted.

## 4. Register ESXi in vCenter

```bash
bash ashburn/scripts/register-esxi.sh
```

After successful registration **and verification of the exact ESXi host**, this script automatically destroys only the temporary PhoenixNAP Ubuntu installer. It checks the Terraform deletion plan and saves `enable_installer = false` locally to avoid recreating it. If registration or the plan check fails, Ubuntu stays running. Cleanup reads the managed installer directly from Terraform state, so it also works if the `installer_id` root output is missing. Verify retirement with `terraform -chdir=ashburn state list` (there should be no `pnap_server.installer[0]`), and confirm the PhoenixNAP portal and billing. The script then prints the vCenter login URL and username; the SSO password is hidden by default, with an optional interactive reveal.

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
