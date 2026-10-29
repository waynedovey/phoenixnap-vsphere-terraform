# phoenixNAP vSphere 8 lab — Ashburn

Terraform creates the **bare-metal ESXi host**, temporary Ubuntu VCSA installer,
and public IP allocation in PhoenixNAP **US East 1 (ASH)**. VCSA runs as a VM
on ESXi. Ansible registers ESXi in the vCenter inventory.

**Important:** `ashburn/` has its own Terraform state. Do not run these commands
from the old Seattle Terraform directory. VMware installation and networking
still require separate steps; Terraform alone does **not** deploy VCSA.

## Provision a new lab

From the Ashburn feature-branch checkout, with your PhoenixNAP API credentials
available as `PNAP_CLIENT_ID` and `PNAP_CLIENT_SECRET`:

```bash
cp ashburn/terraform.tfvars.example ashburn/terraform.tfvars
# Edit ashburn/terraform.tfvars and review all approvals, SKUs and ISO checksum.
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn plan -out=provision.tfplan
terraform -chdir=ashburn show provision.tfplan
terraform -chdir=ashburn apply provision.tfplan
terraform -chdir=ashburn output
```

The example turns provisioning **off** by default. Enable the ESXi server and
optional installer, confirm the old environment was retired, verify the vendor
ESXi image and ISO checksum, and approve the live hourly quote **before**
applying. Provisioning starts hourly billing.

## Existing ESXi: deploy **only** the temporary Ubuntu installer

First, check whether an installer is already tracked (or whether VCSA is
already healthy and no installer is needed):

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn output installer_id
terraform -chdir=ashburn output installer_public_ip_addresses
```

An existing installer appears as `pnap_server.installer[0]`. Check its
actual existence and status in PhoenixNAP before creating another server.
Earlier lab runs used installer `131.153.155.201`; **do not assume it still
exists or is the IP for a new deployment**.

If the installer is absent and you need it, edit your **existing**
`ashburn/terraform.tfvars`:

- Set `enable_installer = true`, keeping `enable_esxi = true`.
- Keep the **same** ESXi type and networking as the working host; do not
  overwrite your tfvars with the example or change your ESXi SKU.
- Use an available installer SKU (previously `s2.c1.small`).
- Set `vcsa_iso_sha256` to an independently vendor-verified digest; an empty
  digest deliberately skips ISO download.
- Recheck the live combined hourly cost and existing approval flags.

Then **review before applying**:

```bash
terraform -chdir=ashburn plan -out=installer-only.tfplan
terraform -chdir=ashburn show installer-only.tfplan
```

For this incremental step, the plan must say **1 to add, 0 to change,
0 to destroy**, and the only creation must be
`pnap_server.installer[0]`. If ESXi or the /29 would change, **STOP**.

```bash
terraform -chdir=ashburn apply installer-only.tfplan
terraform -chdir=ashburn output installer_id
terraform -chdir=ashburn output installer_public_ip_addresses
```

Find the actual SSH address in the PhoenixNAP console and check ISO readiness
as shown in the [Ashburn runbook](ashburn/README.md). This instance is billed
hourly until you explicitly retire it.

Next, finish the guest installation and host inventory:

1. Create/check ESXi `vcsa-public` port group on VLAN 3.
2. On the temporary installer, verify `/opt/vcsa/MEDIA_READY`, prepare the
   private VCSA JSON with the **new** Ashburn IPs, and run the VMware CLI precheck
   and deploy.
3. Once vCenter is online, activate the Ansible Python environment and run
   `bash ashburn/scripts/register-esxi.sh`. It creates `Datacenter` if absent
   and safely registers the ESXi host.
4. Verify the host is connected and the `vcsa-ash` VM is present.

For those commands and one-time setup, see the
**[Ashburn step-by-step guide](ashburn/README.md)**. Ansible details:
[ashburn/ansible/README.md](ashburn/ansible/README.md).

## Tear down

Use the **same Ashburn Terraform state and PhoenixNAP account** that created
the resources. Back up any VMs or data you need first.

### Option A — remove only the temporary installer

Keep ESXi, VCSA and the /29 network running:

```bash
bash ashburn/scripts/retire-installer.sh
```

Confirm the requested installer ID, then set `enable_installer = false` in
`ashburn/terraform.tfvars` so a later normal apply does not recreate it.

### Option B — destroy the entire Ashburn lab

**This permanently deletes the ESXi server, its VCSA/VMs and datastores, the
temporary installer if still present, and the dedicated public /29.**

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
# Check that ONLY the intended Ashburn resources will be destroyed.
terraform -chdir=ashburn apply teardown.tfplan
terraform -chdir=ashburn state list
```

Finally, check the **PhoenixNAP portal** to confirm both servers (if present)
and **all** associated public IP allocations are removed and billing has
stopped. Do not delete the Terraform state first, or use `terraform state rm`
to tear down infrastructure. The saved plan and local state can contain secrets.

## Notes

- Restrict management access: `0.0.0.0/0` exposes ESXi login to the Internet.
- The current host has **one** Micron NVMe boot drive with ESXi, `OSDATA` and
  `datastore1`; **never format it**. No datastore formatting is automated.
- Use legitimately obtained VCSA media, independently verified against a
  trusted vendor checksum. The configured third-party ISO mirror is not
  an official verification source.
- Keep `ashburn/terraform.tfstate`, `private/` and any passwords out of Git.
- [Legacy Seattle documentation](docs/seattle-legacy.md) is preserved separately.
