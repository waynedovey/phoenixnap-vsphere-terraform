# PhoenixNAP vSphere 8 Lab

Deploy **VMware ESXi 8 and vCenter Server 8** on PhoenixNAP bare metal in Ashburn (ASH).

Terraform provisions ESXi, a dedicated public `/29`, and a temporary Ubuntu installer. Ansible installs vCenter and registers ESXi. After successful registration, automation retires the Ubuntu server to stop ongoing charges.

> **Use the `ashburn/` stack.** The Terraform files at the repository root are for the older Seattle lab. Run commands below from the repository root.

## Quick start (macOS)

### 1. Prerequisites

Install **Terraform, Python 3, jq, govc, SSH/SCP, and curl**. The scripts set up their own Ansible virtual environment.

You'll also need:

- PhoenixNAP API credentials in `~/.pnap/config.yaml` (`clientId` and `clientSecret`).
- PhoenixNAP approval to run the vCenter workload, plus confirmation of the ESXi image, server availability, and hourly costs.
- A legitimate vCenter Server 8 ISO and its **publisher-verified SHA-256**. [Broadcom download guidance](https://knowledge.broadcom.com/external/article/387785/download-vcenter-server-patches-and-isos.html).

### 2. Configure the lab

```bash
git clone https://github.com/waynedovey/phoenixnap-vsphere-terraform.git
cd phoenixnap-vsphere-terraform
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
${EDITOR:-vi} ashburn/terraform.tfvars
```

In `ashburn/terraform.tfvars`, review the server types, public IP access, cost limit, and ISO source. For a new build, set:

```hcl
enable_esxi             = true
enable_installer        = true
confirm_seattle_retired = true
confirm_esxi_image      = true
approve_hourly_costs    = true
```

**Set confirmation flags only after verifying each condition.** Use either `vcsa_iso_url` (HTTPS download on Ubuntu) or `vcsa_iso_local_path` (ISO on your Mac), and set `vcsa_iso_sha256` to the independently verified checksum. The example ISO mirror/checksum is **not publisher-authenticated**.

### 3. Create a local vCenter password file

The automatic build uses one password for the **new** VCSA root and SSO accounts. Create a Git-ignored file with hidden input:

```bash
python3 - <<'PY'
import getpass, os
from pathlib import Path
p = Path("private/ashburn-lab-password")
p.parent.mkdir(mode=0o700, exist_ok=True)
password = getpass.getpass("VCSA password: ")
if len(password) < 8:
    raise SystemExit("Use at least 8 characters")
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(password + "\n")
PY
```

For an **existing** vCenter, this file must instead contain its current SSO password. It is *not* the ESXi root password. Keep the file and Terraform state private; never commit credentials.

### 4. Run the build

Only after PhoenixNAP has confirmed support for this workload:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
bash ashburn/scripts/build-all.sh
```

The script:

1. Validates configuration and Terraform changes.
2. Provisions the public `/29`, ESXi host, and temporary Ubuntu installer.
3. Waits for ESXi NTP synchronization (up to ~10 minutes) and shows ISO download progress.
4. Prechecks and deploys vCenter with live installation progress.
5. Registers ESXi, verifies the host, and retires **only** the temporary Ubuntu installer.

It stops on missing approvals or unexpected Terraform changes. **Check the PhoenixNAP portal and Terraform state before running against an existing lab.** The final output shows the vCenter URL and login username.

## Day-2 commands

Run these from the repository root:

| Task | Command |
| --- | --- |
| Show infrastructure | `terraform -chdir=ashburn output` |
| Check managed resources | `terraform -chdir=ashburn state list` |
| Check ESXi time | `bash ashburn/scripts/esxi-time.sh check` |
| Inspect existing VCSA (read-only) | `bash ashburn/scripts/vcsa.sh inspect` |
| Register an existing VCSA's ESXi host / finish installer cleanup | `bash ashburn/scripts/register-esxi.sh` |
| Inspect installer errors (if installer still exists) | `bash ashburn/scripts/vcsa.sh diagnose` |

`register-esxi.sh` prompts for the **existing SSO password** when run interactively. Once registration succeeds, it safely removes the Ubuntu installer. An ignored `ashburn/zz-installer-retired.auto.tfvars` prevents Terraform from recreating it; don't delete that override while keeping the lab.

**Already have vCenter?** Use `inspect` or `register-esxi.sh`. Do **not** rerun `prepare` or `deploy` against the installed appliance.

## Manual deployment (advanced)

If you need to run each stage separately, follow the [Ashburn guide](ashburn/README.md) and [VCSA/Ansible guide](docs/vcsa-ansible.md). The key stages are:

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn plan
bash ashburn/scripts/setup-ansible.sh
bash ashburn/scripts/esxi-time.sh check
bash ashburn/scripts/vcsa.sh prepare
bash ashburn/scripts/vcsa.sh precheck
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

This is a **stage outline**, not an unattended copy/paste sequence: review and apply the correct Terraform plans, confirm NTP synchronization, provide passwords, and set the required approval environment variables before precheck/deploy. See the linked guides for exact steps.

## Tear down

**Destructive:** permanently removes the managed ESXi host (and its VMs/vCenter), installer, and public `/29`. Back up required data and review the plan:

```bash
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
terraform -chdir=ashburn apply teardown.tfplan
```

Then verify servers, IP allocations, and billing in PhoenixNAP. Never delete Terraform state as a cleanup shortcut or format `datastore1`.

## More information

- [Ashburn Terraform and manual commands](ashburn/README.md)
- [VCSA installation and troubleshooting](docs/vcsa-ansible.md)
- [Manual recovery/fallback](docs/ashburn-manual.md)
