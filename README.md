# PhoenixNAP vSphere 8 Lab

Automate **ESXi 8 + vCenter Server 8** on PhoenixNAP bare metal in Ashburn using Terraform and Ansible.

- **Terraform:** ESXi host, public `/29` and temporary Ubuntu installer
- **Ansible:** VCSA installation, network setup and ESXi registration

> Run all commands from the repository root. Use `terraform -chdir=ashburn`; the root Terraform stack is legacy Seattle.

## One-command automation

`bash ashburn/scripts/build-all.sh` runs the **previously approved** Ashburn build: Terraform provisioning, ESXi time checks, VCSA installation, ESXi registration and guarded retirement of the temporary Ubuntu installer. It is **non-interactive**, so configure its prerequisites once before running it.

### First-time setup on macOS

1. Configure PhoenixNAP credentials in `~/.pnap/config.yaml` and the approved infrastructure, costs and ISO settings in `ashburn/terraform.tfvars`. Keep `enable_installer = true` in that file.
2. Create the required local password file **from the repository root**, using the command below. Input is hidden and is not entered in your shell history.

```bash
python3 - <<'PY'
import getpass
import os
from pathlib import Path

file = Path("private/ashburn-lab-password")
file.parent.mkdir(parents=True, exist_ok=True)
if file.exists() or file.is_symlink():
    raise SystemExit("Password file exists; refusing to overwrite it")

password = getpass.getpass("VCSA password (hidden input): ")
if len(password) < 8:
    raise SystemExit("Password must contain at least 8 characters")

fd = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as output:
    output.write(password + "\n")
print("Created private/ashburn-lab-password with mode 600")
PY
```

This password is used for **both the new VCSA appliance root account and the `administrator@vsphere.local` SSO account** on a fresh build. **For an already-installed vCenter, enter its existing SSO password instead** so automatic ESXi registration can authenticate. It is **not** the ESXi root password; that comes from PhoenixNAP and is read from Terraform state. The file must be nonempty, at least eight characters, and have permissions `600` (or `400`). It lives under Git-ignored `private/`; **never commit it or paste its contents into logs or chat**.

3. Verify the file exists and has secure permissions without printing the password:

```bash
stat -f '%Sp %N' private/ashburn-lab-password
```

Expected permission prefix: `-rw-------`.

### Run the build

```bash
# Only after actual PhoenixNAP approval for the vCenter workload:
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
bash ashburn/scripts/build-all.sh
```

If you see `STOP: Missing private/ashburn-lab-password`, the password setup above has not been completed; **the script stops before provisioning**. Other missing configuration or approvals also stop the script rather than granting approval automatically.

**NTP and ISO progress:** On a fresh build, `build-all.sh` polls ESXi NTP up to **40 times at 15-second intervals** (about 10 minutes). It accepts the ESXi `TimeSynchronized: true` field and does not repeatedly reset an already configured NTP service. A failed check is retried; VCSA installation only continues after synchronization is confirmed. At the same time, an ISO monitor prints the **number of GiB downloaded and measured MiB/s** from Ubuntu's existing `.partial` file every 15 seconds, including during `vcsa.sh prepare`. If the server does not provide a trustworthy total download size, percentage and ETA are deliberately not invented. The monitor does not start another download or print ISO source URLs, credentials or raw logs. You can also run `bash ashburn/scripts/vcsa.sh prepare` by itself to see that progress. If NTP does not converge, check ESXi UDP/123, DNS and NTP reachability before another attempt.

**Automatic installer cleanup:** After ESXi registration is verified, the script validates a Terraform plan that deletes only `vcsa-installer-ash`, then retires it. Your original `ashburn/terraform.tfvars` remains at `enable_installer = true`. Instead, an ignored `ashburn/zz-installer-retired.auto.tfvars` automatically sets the effective value to `false` so later Terraform plans do not recreate the installer. ESXi, `vcsa-ash`, `datastore1` and the dedicated public `/29` are preserved. Verify retirement in Terraform state and the PhoenixNAP portal.

**Already have a working vCenter?** You do not need `build-all.sh` or a password file to finish cleanup interactively. Run `bash ashburn/scripts/register-esxi.sh`, enter your existing SSO password at its prompt, and it will verify registration and safely retire any remaining Ubuntu installer. Do not rerun `vcsa.sh prepare` or `deploy` against an already-installed appliance.

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

After successful registration **and verification of the exact ESXi host**, this script automatically destroys only the temporary PhoenixNAP Ubuntu installer. It checks the Terraform deletion plan, then writes a separate, ignored `zz-installer-retired.auto.tfvars` lifecycle override. `terraform.tfvars` stays at `enable_installer = true` and is never edited. Terraform automatically loads the override to prevent unwanted server recreation. If registration or the plan check fails, Ubuntu stays running. Cleanup reads the managed installer directly from Terraform state, so it also works if the `installer_id` root output is missing. Verify retirement with `terraform -chdir=ashburn state list` (there should be no `pnap_server.installer[0]`), and confirm the PhoenixNAP portal and billing. The script then prints the vCenter login URL and username; the SSO password is hidden by default, with an optional interactive reveal.

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
