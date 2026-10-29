# PhoenixNAP vSphere 8 lab — Ashburn

One repository: **`phoenixnap-vsphere-terraform`**. All commands run from its root on the
**`feat/ashburn-esxi-temporary-vcsa-installer`** branch. Do **not** use root-level
Terraform files (legacy Seattle); use **`terraform -chdir=ashburn`** exclusively.

| Component | Location | Provisioner |
| --- | --- | --- |
| ESXi 8 bare-metal host | PhoenixNAP **ASH** | Terraform `pnap_server.esxi` |
| Temporary Ubuntu ISO installer | Separate PhoenixNAP **ASH** server | Terraform `pnap_server.installer` |
| vCenter Server Appliance (VCSA) | **VM on ESXi**, not a third server | VMware CLI from Ubuntu |
| Datacenter + ESXi registration | vCenter inventory | Ansible |

## 0. If restarting after manual deletion

**Only when Ashburn Terraform state is empty**, an old lab can be cleaned up in the PhoenixNAP UI:

1. Back up any VMs/data needed; deleting ESXi permanently deletes the local VCSA and datastore contents.
2. Delete **both** Ashburn servers if present: `esxi-01` and `vcsa-installer-ash`.
3. Under **Networking → Public IP Allocations**, remove the old ESXi **/29**
   and any remaining installer/default allocation. Unused IP blocks can still incur charges.
4. Confirm **no old Ashburn servers/IP allocations remain** and billing has stopped.
5. Run `terraform -chdir=ashburn state list`. If it lists managed resources,
   **STOP** and reconcile state. Don't delete infrastructure behind Terraform's back.

This manual reset is an **exception** for lost/empty state. Once Terraform owns the new lab,
use the teardown commands below—not the UI.

## 1. Configure (Mac)

Requirements: `terraform`, `jq`, `govc`, `python3`, `ssh`, `scp`,
PhoenixNAP credentials (`PNAP_CLIENT_ID` and `PNAP_CLIENT_SECRET`),
authorized VMware media, and any required PhoenixNAP approval to run VCSA.

```bash
cd /Users/wdovey/OCP/phoenixnap-vsphere-terraform
git branch --show-current
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
chmod 600 ashburn/terraform.tfvars
vim ashburn/terraform.tfvars
```

For a **verified clean rebuild**, set the following in `ashburn/terraform.tfvars`
(reconfirm hardware stock, required approvals and actual prices first):

```hcl
enable_esxi              = true
enable_installer         = true
confirm_seattle_retired  = true
confirm_esxi_image       = true
approve_hourly_costs     = true
esxi_type                = "s2.c2.medium"
installer_type           = "s2.c1.small"
maximum_hourly_usd       = 1.00
management_allowed_cidrs = ["0.0.0.0/0"]
vcsa_iso_sha256          = "REPLACE_WITH_INDEPENDENTLY_VENDOR_VERIFIED_SHA256"
```

`0.0.0.0/0` exposes management to the Internet; restrict it to your own
`/32` when possible. Set `vcsa_iso_url` to an authorized source as needed.
The default URL is an **unofficial mirror**. Confirm SHA-256 against a
**trusted vendor source**. An empty checksum makes cloud-init **skip** the ISO.
Never commit credentials or state.

## 2. Provision **both** PhoenixNAP servers

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -out=provision.tfplan
terraform -chdir=ashburn show provision.tfplan
```

Only if the console is clean and the state is empty should the fresh plan create:
`pnap_ip_block.esxi_29[0]`, `pnap_server.esxi[0]` and
`pnap_server.installer[0]` (**3 add, 0 change, 0 destroy**).
Stop if it replaces/deletes anything. Review quoted hourly costs and stock first.

```bash
terraform -chdir=ashburn apply provision.tfplan
terraform -chdir=ashburn state list
terraform -chdir=ashburn output
```

**Preserve `ashburn/terraform.tfstate`** securely outside Git: it can contain
passwords and is required to tear down the lab.

## 3. Install vCenter **inside ESXi**

Terraform creates the **installer server and verified ISO media**, not VCSA itself.

1. Connect `govc` to the new ESXi. Check/create the `vcsa-public` port group on
   PhoenixNAP's verified public **VLAN 3**.
2. Get the Ubuntu installer's **primary public IP** from the console
   (Terraform may show an IP range). SSH in and check `/opt/vcsa/MEDIA_READY`.
3. Copy VMware's `embedded_vCSA_on_ESXi.json` from the mounted ISO.
   Use `scripts/render-vcsa-config.py` to fill in the **current Terraform IPs**.
4. Copy the generated JSON and `scripts/vcsa.py` to Ubuntu. Enter passwords
   privately on Ubuntu Bash; run `check`, `precheck`, then approved `deploy`.

Use the exact commands in the **[VCSA installation guide](ashburn/README.md#3-deploy-vcsa-from-the-temporary-ubuntu-server)**.

## 4. Register ESXi in vCenter (Ansible)

After VCSA is healthy, from the repo root on the Mac:

```bash
brew install python@3.14
python3.14 -m venv ashburn/.venv
source ashburn/.venv/bin/activate
python -m pip install 'ansible-core>=2.21,<2.22' requests pyvmomi
ansible-galaxy collection install -r ashburn/ansible/requirements.yml
bash ashburn/scripts/register-esxi.sh
```

This prompts for the VCSA SSO password, creates **Datacenter** if missing
and registers ESXi idempotently. It **never formats disks**.
[Ansible details](ashburn/ansible/README.md).

## 5. Remove the temporary installer (save hourly cost)

Once VCSA works, keep ESXi + VCSA but retire the **separate Ubuntu server**:

```bash
bash ashburn/scripts/retire-installer.sh
```

Confirm its exact server ID; then edit `ashburn/terraform.tfvars` to
`enable_installer = false` so future applies don't recreate it. Verify the
installer/default IP allocation was removed in PhoenixNAP.

## 6. Tear down **everything** when finished

**Irreversible:** ESXi, VCSA, VMs, local datastores, optional installer and
the dedicated `/29` will be deleted.

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
```

Check the plan contains **only Ashburn resources**. Then—and only then:

```bash
terraform -chdir=ashburn apply teardown.tfplan
terraform -chdir=ashburn state list
```

Check PhoenixNAP **Servers**, **Public IP Allocations**, and billing screens
to confirm charges stopped. Empty state does not prove untracked servers are gone.

> Storage: the previous ESXi hardware exposed **one** Micron NVMe boot drive
> holding ESXi, `OSDATA` and `datastore1`. **Never format it**. Disk formatting
> is not part of this automation.

Full guide: [ashburn/README.md](ashburn/README.md).
Historical Seattle notes: [docs/seattle-legacy.md](docs/seattle-legacy.md).
The `.old` directories and root-level Terraform state are **not** for Ashburn.
