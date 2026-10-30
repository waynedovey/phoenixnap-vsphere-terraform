# PhoenixNAP vSphere 8 Lab

Deploy a VMware **ESXi 8 + vCenter** evaluation lab on PhoenixNAP bare metal in **Ashburn (ASH)** using Terraform and Ansible.

| Component | Where it runs |
| --- | --- |
| **ESXi host** (`esxi-01`) | PhoenixNAP bare-metal server |
| **VCSA installer** (`vcsa-installer-ash`) | Second, temporary PhoenixNAP Ubuntu server |
| **vCenter Server (VCSA)** | VM **inside ESXi** — not a third server |
| **Public networking** | Dedicated IPv4 `/29` for ESXi + VCSA |

> **Important:** Always run Terraform with `-chdir=ashburn`. The Terraform files in the repository root are from the old Seattle lab. Keep `ashburn/terraform.tfstate` safe and out of Git.

## Quickstart: Create the lab

**Prerequisites:** Terraform, `jq`, PhoenixNAP API credentials (`PNAP_CLIENT_ID` / `PNAP_CLIENT_SECRET`), confirmed ASH hardware availability and pricing, an authorized VCSA 8 ISO with a trusted SHA-256 checksum, and any required VMware/PhoenixNAP approvals.

Run from the **`phoenixnap-vsphere-terraform` repository root** on branch `feat/ashburn-esxi-temporary-vcsa-installer`.

### 1. Configure

```bash
git pull --ff-only
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
chmod 600 ashburn/terraform.tfvars
vim ashburn/terraform.tfvars
```

For a **brand-new** lab, set these values after verifying the approval conditions and live quote:

```hcl
enable_esxi             = true
enable_installer        = true
confirm_seattle_retired = true
confirm_esxi_image      = true
approve_hourly_costs    = true

esxi_type           = "s2.c2.medium"
installer_type      = "s2.c1.small"
maximum_hourly_usd  = 1.00
```

The server types are **previously working examples**, not guaranteed stock. Restrict `management_allowed_cidrs` to your trusted IP if possible.

**ISO requirement:** Configure an **authorized** `vcsa_iso_url` and a vendor-verified, 64-character `vcsa_iso_sha256` in your private `terraform.tfvars`. The repository's default ISO mirror is unofficial; if the checksum is blank, the Ubuntu bootstrap **skips the ISO download**. Don't overwrite an existing `terraform.tfvars` with the example.

### 2. Allocate the public `/29`

Only start a **fresh** build when the PhoenixNAP console shows no old Ashburn servers/IP allocations and the **Ashburn Terraform state is empty**. These checks avoid duplicate charges.

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn state list

terraform -chdir=ashburn plan \
  -target='pnap_ip_block.esxi_29[0]' \
  -out=ip-block-only.tfplan

terraform -chdir=ashburn show ip-block-only.tfplan
```

Expect **1 to add, 0 to change, 0 to destroy** (only the `/29`). Review the plan and price, then:

```bash
terraform -chdir=ashburn apply ip-block-only.tfplan
terraform -chdir=ashburn state show 'pnap_ip_block.esxi_29[0]'
```

This one-time two-stage setup ensures the IP block has a real ID before ESXi is created.

### 3. Deploy both servers

```bash
terraform -chdir=ashburn plan -out=servers.tfplan
terraform -chdir=ashburn show servers.tfplan
```

Expect **2 to add, 0 to change, 0 to destroy**: `pnap_server.esxi[0]` and `pnap_server.installer[0]`. The ESXi `server_ip_block.id` must match the `/29` ID allocated above; it must **not** be `null`. [Exact ID check](ashburn/README.md#2-provision-esxi-29-and-temporary-ubuntu).

If anything else would change, **stop**. Otherwise:

```bash
terraform -chdir=ashburn apply servers.tfplan
terraform -chdir=ashburn state list
terraform -chdir=ashburn output
```

**Terraform creates the two bare-metal servers, not the vCenter VM.** Follow the [VCSA installation steps](ashburn/README.md#3-deploy-vcsa-from-the-temporary-ubuntu-server) to check the ISO, deploy VCSA inside ESXi, and register the ESXi host with Ansible.

## Quickstart: Destroy the lab

**Warning:** This permanently deletes ESXi, the vCenter VM, all local VMs/datastore data, the temporary installer (if present), and the dedicated `/29`. Back up anything important first.

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
```

**Read the plan.** It must delete only the intended **Ashburn** resources. Then:

```bash
terraform -chdir=ashburn apply teardown.tfplan
terraform -chdir=ashburn state list
```

Finally confirm in PhoenixNAP **Servers**, **Public IP Allocations**, and **Billing** that all resources and charges are gone. **Empty state does not prove untracked servers are deleted.** Never delete Terraform state to tear down infrastructure.

## Remove just the temporary installer

Once VCSA is working, you can stop paying for the second server without affecting ESXi or vCenter:

```bash
bash ashburn/scripts/retire-installer.sh
```

The script shows a deletion plan and asks you to confirm the exact installer ID. Afterward set `enable_installer = false` in `ashburn/terraform.tfvars` to prevent it being recreated.

## More detail

- [Full Ashburn installation runbook](ashburn/README.md) — network, ISO, vCenter CLI, Ansible, troubleshooting
- [ESXi registration with Ansible](ashburn/ansible/README.md)
- [Legacy Seattle notes](docs/seattle-legacy.md)

**Safety:** Never run Terraform at the repository root, never commit state/passwords/plan files, and never format `datastore1` (the previous ESXi host's only NVMe drive contained both ESXi and its datastore).
