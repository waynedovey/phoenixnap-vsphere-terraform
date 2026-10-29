# PhoenixNAP vSphere 8 — Ashburn

**One repo:** `phoenixnap-vsphere-terraform`. The active lab is under
`ashburn/` on branch `feat/ashburn-esxi-temporary-vcsa-installer`.
Always run Terraform with **`-chdir=ashburn`**; root-level Terraform
files/state belong to the old Seattle setup.

| Component | Where it runs |
| --- | --- |
| ESXi 8 | PhoenixNAP bare-metal server in **ASH** |
| Temporary Ubuntu ISO installer | **Second** PhoenixNAP server in **ASH** |
| vCenter Server Appliance | **VM on ESXi** (not another PhoenixNAP server) |
| Datacenter and host registration | Ansible against the new vCenter |

## 1. Start with a clean account

If the earlier Ashburn Terraform **state is empty** and you're deliberately
starting over:

1. Back up anything needed. In PhoenixNAP **Servers**, delete the old
   `esxi-01` and `vcsa-installer-ash` if present.
2. In **Networking → Public IP Allocations**, delete the unused ESXi
   **/29** and any remaining installer/default IP allocations.
3. Check both Servers/IP Allocations and **billing** until no old Ashburn
   resources remain. A retained IP allocation can keep costing money.

**Only use this manual UI cleanup for a lost/empty state.** If Terraform
still tracks resources, use the teardown section instead. Deleting ESXi
permanently destroys VCSA and any VM data.

## 2. Provision the new lab (Mac)

For a fresh clone, follow the branch instructions in
[the complete runbook](ashburn/README.md#1-configure-the-empty-stack).
In your existing checkout:

```bash
cd /Users/wdovey/OCP/phoenixnap-vsphere-terraform
git fetch origin
git switch feat/ashburn-esxi-temporary-vcsa-installer
git pull --ff-only
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
chmod 600 ashburn/terraform.tfvars
vim ashburn/terraform.tfvars
```

Requirements: Terraform, `jq`, `govc`, Python 3, SSH/SCP, PhoenixNAP
API credentials, authorized VCSA media and a **vendor-verified ISO SHA-256**.

Set these in `ashburn/terraform.tfvars` after confirming approvals, hardware
stock and current pricing (the SKUs worked previously but may change):

```hcl
enable_esxi              = true
enable_installer         = true
confirm_seattle_retired  = true
confirm_esxi_image       = true
approve_hourly_costs     = true
esxi_type                = "s2.c2.medium"
installer_type           = "s2.c1.small"
maximum_hourly_usd       = 1.00
vcsa_iso_sha256          = "REPLACE_WITH_VENDOR_VERIFIED_64_HEX_SHA256"
```

The default ISO URL is an **unofficial mirror**; use an authorized source
and independently verified checksum. An empty checksum **skips ISO download**.
Restrict `management_allowed_cidrs` to your IP (`/32`) if possible;
`0.0.0.0/0` exposes ESXi management to the Internet.

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -out=provision.tfplan
terraform -chdir=ashburn show provision.tfplan
```

A completely clean first run should be **3 add, 0 change, 0 destroy**:
ESXi, installer and ESXi /29. **Stop** if any existing resources would be
replaced/deleted or if the console still contains the old lab. Review costs.

```bash
terraform -chdir=ashburn apply provision.tfplan
terraform -chdir=ashburn output
```

**Keep `ashburn/terraform.tfstate` securely**; it contains IDs and may contain
passwords. Never commit it or copy the old Seattle state into `ashburn/`.

## 3. Install vCenter and register ESXi

Terraform creates **both PhoenixNAP servers** and prepares verified ISO media.
It does **not** run the VMware installer automatically.

1. Use `govc` to verify ESXi and the `vcsa-public` port group (public VLAN 3).
2. Get the Ubuntu server's primary IP from PhoenixNAP and confirm
   `/opt/vcsa/MEDIA_READY`.
3. Use `scripts/render-vcsa-config.py` to generate a private VCSA JSON
   from the **new** Terraform IPs, then run VMware CLI `check`, `precheck`
   and approved `deploy` on Ubuntu.
4. When VCSA is ready, register ESXi as a standalone host in
   **Datacenter** using Ansible.

**[Full copy/paste commands for ISO, networking and VCSA](ashburn/README.md#3-deploy-vcsa-from-the-temporary-ubuntu-server)**

Ansible once VCSA is working:

```bash
brew install python@3.14
python3.14 -m venv ashburn/.venv
source ashburn/.venv/bin/activate
python -m pip install 'ansible-core>=2.21,<2.22' requests pyvmomi
ansible-galaxy collection install -r ashburn/ansible/requirements.yml
bash ashburn/scripts/register-esxi.sh
```

## 4. Retire only the temporary installer

After VCSA works, keep ESXi + VCSA but remove the **second server**:

```bash
bash ashburn/scripts/retire-installer.sh
```

Confirm its exact ID, then set `enable_installer = false` in
`ashburn/terraform.tfvars`. Verify its default public IP allocation is gone.

## 5. Tear down everything

**Permanent deletion** of ESXi, VCSA, VMs, datastore data, optional
installer and /29:

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
```

Review: **only intended Ashburn resources** may be destroyed. Then:

```bash
terraform -chdir=ashburn apply teardown.tfplan
terraform -chdir=ashburn state list
```

Finally verify **Servers, Public IP Allocations and billing** in PhoenixNAP.
An empty state alone does not prove an untracked server was deleted.

**Do not format the ESXi boot drive.** The previous host exposed one Micron
NVMe holding ESXi, `OSDATA` and `datastore1`; no disk formatting is automated.

[Detailed Ashburn runbook](ashburn/README.md) ·
[Ansible instructions](ashburn/ansible/README.md) ·
[Legacy Seattle notes](docs/seattle-legacy.md)
