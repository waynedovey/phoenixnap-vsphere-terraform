# Legacy Seattle vSphere lab (archived)

This is the previous root README, retained for reference when the primary README was simplified for Ashburn. **Do not run these commands against the Ashburn Terraform state.**

# phoenixNAP VMware vSphere evaluation lab

> **Ashburn migration:** The new independent US East 1 stack and disposable VCSA installer are documented in [ashburn/README.md](ashburn/README.md). This Seattle stack remains unchanged until intentionally retired.

Terraform provisions **one ESXi bare-metal host** in Seattle. A separate,
deliberately gated workflow deploys **vCenter Server Appliance (VCSA) 8**
from legitimate Broadcom media. Nothing is automatically applied.

## Requested hardware

| Item | Value |
| --- | --- |
| BMC location | US Northwest 1 / Seattle (`SEA`) |
| Server | `s2.c2.large` |
| CPU / memory | Xeon E-2388G, 8 cores / 128 GB DDR4 |
| Storage | 2 x 1 TB NVMe; **no RAID requested** |
| Network | 20 Gbps bonded as quoted |
| OS | VMware ESXi 8 (requested **8.0U2**) |
| Server billing | Hourly, quoted **US$0.40/hour** |
| Default ESXi public IPv4 block | /30, estimated **US$0.014/hour** |
| Estimated total | **US$0.414/hour**, or **US$298.08 for 30 days** |
| Maximum budget | **US$0.50/hour total** (operator review; not automatically enforced) |
| ESXi name | `esxi-01` |
| vCenter | Single VCSA 8 VM, evaluation mode, deployed later |

> **STOP: vendor compatibility.** phoenixNAP's December 2025 KB says
> vCenter is not supported on BMC. Obtain written clarification of whether
> customer-managed VCSA on this ESXi host is permitted/supported, and whether
> the appropriate VMware networking and APIs are available. The vCenter script
> will not deploy without an explicit acknowledgment.
>
> **STOP: exact ESXi build.** The phoenixNAP API OS ID is `esxi/esxi80`,
> which does not pin 8.0 Update 2 in Terraform. Verify with phoenixNAP that
> this is the exact image installed in `SEA` before allowing provisioning.
> A mismatch requires vendor guidance, not a blind `terraform apply`.

## What you need before deployment

- A **rotated** phoenixNAP client ID and secret with least-privilege BMC
  access. Never reuse credentials pasted into chat, and never commit them.
- **Security exception:** ESXi HTTPS management is intentionally open to any
  public IPv4 address (`0.0.0.0/0`) for this evaluation lab. Anyone on the
  Internet can reach the login page. Use strong unique credentials, keep ESXi
  patched, monitor authentication attempts, and restrict access before real use.
  A VPN or trusted-source allowlist is strongly recommended for production.
- **US$0.50/hour total budget** for the host plus the default public IPv4
  block. The published server price is US$0.40/hour and the estimated /30 block
  is US$0.014/hour. The provider/API may bill taxes, excess bandwidth, or
  software costs separately. **Terraform does not enforce a live spending cap**:
  verify the current portal/API prices and do not apply if the total exceeds
  your US$0.50/hour ceiling.
- A verified **VCSA 8 installer ISO** from your Broadcom entitlement/trial
  access; this repository contains no VMware software or license keys.
- An actual network design for the vCenter **guest VM**: static reachable IP,
  subnet prefix, gateway, DNS with forward/reverse resolution, NTP, the ESXi
  port group and route to your admin workstation. **The ESXi management
  setting does not protect a vCenter VM's own interface**; separately restrict that
  VM with a firewall/VPN/private-network design.
- Written confirmation of VCSA-on-BMC support and the intended vCenter
  edition/evaluation rights.

## 1. Validate the project locally (no charge)

On your Mac/Linux workstation, install Terraform 1.6+ and Python 3.9+, then:

```bash
git clone https://github.com/waynedovey/phoenixnap-vsphere-terraform.git
cd phoenixnap-vsphere-terraform
python3 -m unittest discover -s tests -v
terraform fmt -check
terraform init -backend=false
terraform validate
```

The `init` step downloads the official phoenixNAP provider. It does not
create a server. The configuration pins version `0.34.0`. Inspect the provider
schema/plan if phoenixNAP updates its API.

## 2. Set credentials without writing them into files

Use your shell's secret manager or a secure credential-prompt method to export
the **newly rotated** values. Environment variable names are:

```bash
export PNAP_CLIENT_ID="REPLACE_WITH_ROTATED_ID"
export PNAP_CLIENT_SECRET="REPLACE_WITH_ROTATED_SECRET"
```

These lines illustrate names **only**: do not paste real secrets into shell
history, Git, issue reports, terminal recordings or CI logs. Prefer your
password manager's environment injection and a short-lived shell.

## 3. Prepare a billable plan — do not apply yet

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit the ignored `terraform.tfvars`:

1. No management IP lookup is required. ESXi HTTPS is open to all IPv4 sources
   by default. If you previously created a `terraform.tfvars` file, **remove
   any old `management_allowed_cidrs` line** to use the new default.
2. Check the exact ESXi image with phoenixNAP.
3. Verify the default ESXi /30 IP price and host charge fit your **US$0.50/hour total ceiling**; do not rely on the estimate as a billing guarantee.
4. Only when ready for an **approval review**, change the safety variables:

```hcl
enable_provisioning  = true
confirm_esxi_image   = true
approve_hourly_costs = true
```

Now inspect the **plan**, which does not create anything:

```bash
terraform plan -out=provision.tfplan
terraform show provision.tfplan
```

Inspect the planned `pnap_server.esxi[0]`, the network, datastores, pricing,
location, OS and unrestricted management CIDR. The plan file is ignored because it may contain
sensitive data.

**Only after your separate explicit approval** may an operator execute:

```bash
terraform apply provision.tfplan
```

That action requests the server and its public IPv4 allocation and starts
billing. **Do not run it merely to test syntax.** After provisioning:

```bash
terraform output esxi_server_id
terraform output esxi_public_ip
terraform output esxi_management_url
```

Record the initial ESXi root password through a protected channel and rotate
it at first login. The phoenixNAP API may return that password only once, and
**Terraform state can contain it**. Use encrypted restricted-access state
storage/backups; `.gitignore` is not a security boundary.

## 4. Verify host and the two independent NVMe devices

Using the ESXi Host Client (publicly accessible in this lab) or BMC remote console:

1. Confirm hardware type, 128 GB RAM, ESXi exact update/build and license mode.
2. Confirm both physical NVMe disks are visible, and identify which physical
   disk holds the ESXi system and `datastore1`.
3. Locate the second NVMe. If it is truly unused, create a **second VMFS
   datastore** (for example `datastore2`) in the Host Client after verifying
   the disk's serial/identifier. **Formatting an occupied disk destroys data.**
4. Confirm datastore capacity, NTP, DNS, management access and port groups.

Only one initial datastore name can be configured through the provider's ESXi
provisioning block. The Terraform project **does not reformat disks**; separate
datastores are a **post-provision verification/configuration step**. This is
not RAID 1 and does not make a single host highly available.

## 5. Deploy the vCenter Appliance — separate gated stage

The VCSA deployment is intentionally **not** part of `terraform apply`.
Broadcom distributes the proprietary appliance and a version-matched
`vcsa-deploy` CLI. We never download or redistribute either.

After confirming vCenter support and obtaining VCSA 8 media:

1. Mount the installer ISO on the machine that can reach the ESXi management
   network (Mac, Linux or Windows).
2. Copy Broadcom's own template from:
   `vcsa-cli-installer/templates/install/embedded_vCSA_on_ESXi.json`
   to `private/vcsa-config.json` (create `private/` yourself).
3. Edit **only non-secret** values in that ignored JSON file, such as:
   - `new_vcsa.esxi.hostname`: real ESXi management IP/FQDN
   - `new_vcsa.esxi.deployment_network`: reachable ESXi port group
   - `new_vcsa.esxi.datastore`: `datastore1`
   - `new_vcsa.appliance.name`: `vcsa-01`
   - `new_vcsa.appliance.deployment_option`: usually `tiny` for a small lab
   - `new_vcsa.network`: **static** VM IP, prefix, gateway, DNS and FQDN
   - `new_vcsa.os.ntp_servers`: reachable NTP service(s)
   - `new_vcsa.sso.domain_name`: e.g. `vsphere.local`
   - `ceip.settings.ceip_enabled`: your choice
4. Make DNS forward and reverse lookups work, ensure the VCSA VM IP can be
   routed securely, and ensure no management ports are exposed broadly.
5. Supply the VCSA/ESXi passwords as runtime environment variables:
   `ESXI_ROOT_PASSWORD`, `VCSA_ROOT_PASSWORD`, `VCSA_SSO_PASSWORD`.
   The Python wrapper temporarily inserts them into a private JSON for
   `vcsa-deploy`; they are not embedded in repository files.
6. Set `VCSA_INSTALLER_DIR` to the **mounted ISO root**.

Examples of commands (run **only later**, after the above requirements):

```bash
python3 scripts/vcsa.py check
python3 scripts/vcsa.py precheck
```

The first checks locally. The second invokes Broadcom's precheck tool, which
checks against the target but **does not deploy VCSA**.

Actual vCenter deployment requires **all** of the following:

- Written vendor-support review and `PNAP_VCENTER_SUPPORT_CONFIRMED=YES`
- Your separate explicit deployment approval and `VCSA_DEPLOY_APPROVED=YES`
- An interactive `DEPLOY-VCENTER` confirmation
- A valid network, installer and password environment

```bash
python3 scripts/vcsa.py deploy
```

The wrapper runs the official CLI installer with the EULA/CEIP acknowledgment
flags and the vendor template. It never bypasses SSL certificate checks.
Review the license and EULA before using this command.

Once VCSA is online, securely create the vCenter datacenter/inventory and add
`esxi-01` as a managed host (Host Client or `govc` with certificate
verification). Verify it appears connected and evaluate the licensing time
remaining. Do not treat vCenter as fully managed until this is complete.

**Evaluation warning:** Broadcom documents a 60-day evaluation period for
new installations, after which licensing restrictions affect management.
Confirm installer access and evaluation entitlement beforehand. It is not a
production license.

## Cleanup

When the lab is no longer needed, plan and review removal first:

```bash
terraform plan -destroy
```

Do **not** run `terraform destroy` without a separate explicit teardown
approval. It deprovisions the host and can permanently remove VMs and data.
The server resource sets `delete_ip_blocks = true`, instructing phoenixNAP
to also delete the automatically purchased public IP block when the server is
deprovisioned. This is intended for a disposable lab: removing the block
permanently releases its IP addresses. After any approved teardown, verify
that **both the server and public IP allocation are gone** in the BMC portal
to ensure billing has stopped.

## Upstream references

- phoenixNAP Terraform provider: https://registry.terraform.io/providers/phoenixnap/pnap/latest
- BMC API network allocation semantics: https://developers.phoenixnap.com/docs/bmc/1/types/NetworkConfiguration
- phoenixNAP ESXi access and vCenter support note: https://phoenixnap.com/kb/esxi-enable-ssh
- Broadcom VCSA 8 CLI instructions: https://www.vmware.com/docs/vsphere-vcenter-802-installation-guide
- Broadcom new installation evaluation mode: https://knowledge.broadcom.com/external/article/440804

## Scope / limitations

This project provisions the ESXi physical host by Terraform and provides an
operator-gated, secret-aware wrapper for the official VCSA installer.
It does **not** promise that phoenixNAP supports vCenter, pin an unavailable
8.0U2 build ID, format the second NVMe, reserve a VCSA guest IP, build a
firewall/VPN, license VMware, or create vCenter inventory automatically.
Those require facts and approvals that are not yet available.
