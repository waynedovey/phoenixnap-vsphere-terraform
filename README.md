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

**No manual IP or checksum exports.** `vcsa.sh` resolves the Ubuntu SSH IPv4 from the current PhoenixNAP server's public IP allocation in Terraform state. Its resolver handles a single IPv4 address, `/31`, or a two-address range, and rejects ambiguous allocations instead of proceeding with an empty IP. It reads `vcsa_iso_sha256`, `vcsa_iso_url` and optional `vcsa_iso_local_path` from `ashburn/terraform.tfvars` via Terraform console.

Set **one authorized ISO source** in `ashburn/terraform.tfvars`:
```hcl
vcsa_iso_url        = "https://YOUR_AUTHORIZED_VCSA_ISO_URL"
vcsa_iso_sha256     = "YOUR_INDEPENDENTLY_VERIFIED_64_HEX_SHA256"
vcsa_iso_local_path = ""  # Leave empty when using the URL; this means a path ON YOUR MAC
```

If the ISO is absent on Ubuntu, Ansible downloads it using the configured HTTPS URL and verifies SHA-256 before mounting. Alternatively, if the URL is empty, Ansible uploads the configured local ISO and verifies it. **A checksum alone cannot identify where to download the ISO.** The old third-party mirror is intentionally not a default; use the [Broadcom vCenter download portal instructions](https://knowledge.broadcom.com/external/article/387785/download-vcenter-server-patches-and-isos.html).

**Before deploying, make sure ESXi itself is synchronized** (PhoenixNAP's default NTP servers were unreachable in the previous lab). The helper uses the ESXi API, so no SSH service is needed:

```bash
bash ashburn/scripts/esxi-time.sh check
# Only if the time is NOT synchronized, configure tested public NTP servers:
bash ashburn/scripts/esxi-time.sh configure
bash ashburn/scripts/esxi-time.sh check
```

Proceed only after the output reports **Time Synchronized: true**. The Ansible workflow discovers the actual VLAN and switch used by ESXi's existing `public.<VLAN>` **VMkernel management** port group, then creates a separate `vcsa-public` **VM-only** port group on the same VLAN. It never attaches VMs to `public.<VLAN>`, and it does not modify the management interface or use a hardcoded VLAN. VCSA uses VMware Tools host time sync by default.

```bash
bash ashburn/scripts/setup-ansible.sh
bash ashburn/scripts/vcsa.sh prepare

# The ESXi TLS SHA-256 pin is retrieved, saved and exported automatically
# by vcsa.sh; no VCSA_ESXI_CERT_SHA256 export is needed.
export ESXI_NTP_SYNC_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh precheck

# If precheck fails, inspect filtered private logs automatically:
# bash ashburn/scripts/vcsa.sh diagnose

# Read-only inspection of any VCSA VM before an attempted redeploy:
# bash ashburn/scripts/vcsa.sh inspect

# Only after required PhoenixNAP/VMware approvals and successful precheck:
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy  # Live VMware progress bar + elapsed time
bash ashburn/scripts/register-esxi.sh
```

For ESXi TLS, `vcsa.sh precheck` automatically retrieves and pins the SHA-256 certificate fingerprint in `private/certs/esxi-<SERVER_ID>.sha256`, keyed by the current PhoenixNAP ESXi server ID. Later runs reject a changed certificate for the same ID. **First-use pinning is trust-on-first-use (TOFU), not independent identity verification**; for higher assurance compare the displayed fingerprint using a trusted PhoenixNAP management channel. The Ubuntu installer independently rechecks that same pin before invoking VMware's CLI.

The port group fix also archives and regenerates any previously generated VCSA JSON incorrectly targeting `public.<VLAN>` (the VMware OVF precheck error was `Invalid target name (public.2)` with no target VM networks). The `precheck` stage creates only the dedicated VM port group when absent; repeated runs validate it without changing it.

SSH uses a private, per-installer-server-ID `known_hosts` file with `StrictHostKeyChecking=accept-new`. This avoids false host-key conflicts when PhoenixNAP reuses an IP, while still rejecting subsequent changes for the same server. **First connection is trust-on-first-use**, so verify the fingerprint through the PhoenixNAP console when stronger host authentication is required. No global SSH known_hosts edits or disabled host-key checks are needed. The wrapper also archives stale VCSA JSON/templates when a new installer ID is detected.

**Deployment progress:** `vcsa.sh deploy` now displays a live, per-task VMware progress bar with elapsed time while the Ansible task is hidden behind `no_log: true`. It polls only sanitized task names/progress from the current installer's log over SSH, keyed by a unique deployment-run marker, so old precheck logs are not mistaken for a new installation. The displayed percentage is **within VMware's current task**, not a guessed overall percentage. After firstboot reaches 100%, the display changes to *Finalizing VMware deployment* until Ansible returns success. Pressing Ctrl-C on the progress display is intentionally ignored to avoid interrupting a partially installed appliance. The progress monitor is optional presentation only; actual success/failure is always determined by Ansible's exit code.

**vCenter registration:** `register-esxi.sh` uses the same Ansible virtual environment as deployment, authenticates against vCenter and discovers datacenters before selecting any datacenter. If authenticated inventory discovery fails, it reports a sanitized explanation without exposing the SSO password. After **successful** registration, it prints the current `https://<VCSA-IP>/ui` login URL and `administrator@vsphere.local` (or configured username). The password is the SSO password the operator entered; it is hidden by default, with an **interactive opt-in reveal** when run in a terminal. This avoids exposing passwords in automatic logs. Verify vCenter services are healthy and the SSO credentials are correct before retrying registration; it is not necessary to redeploy VCSA.

**Troubleshooting:** Ansible conceals the password-bearing command output using `no_log`, but `vcsa.sh` now records the VMware precheck's stdout/stderr in mode-0600 `/home/ubuntu/vcsa/last-precheck.log`. Run `bash ashburn/scripts/vcsa.sh diagnose` for a read-only, filtered error summary from that file and recent VMware CLI logs. Diagnose does not ask for VCSA passwords or deploy anything. Inspect the private raw log yourself if the summary omits a sensitive line; don't post raw logs containing credentials.

Deployment queries the **actual ESXi VM inventory** using `govc find / -type m -name vcsa-ash` and refuses to overwrite a matching VM **before asking for VCSA passwords**. Do not rely on the exit code of `govc vm.info`: it returns 0 without output when no VM is found. Run `bash ashburn/scripts/vcsa.sh inspect` for a read-only inventory check. If no VM is found, the command says so explicitly; it only shows network/HTTPS probes if a VM exists. **Never delete a VM solely because a deployment attempt failed.** Deployment requires typing `DEPLOY-VCENTER` and prompts for passwords only after the duplicate check. See [ISO, networking, NTP and Ansible prerequisites](docs/vcsa-ansible.md).

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
