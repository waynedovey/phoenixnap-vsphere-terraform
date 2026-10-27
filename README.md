# phoenixNAP VMware vSphere evaluation lab

> **Seattle /29 rebuild:** Read [REBUILD-29.md](REBUILD-29.md) for the operator-approved replacement of server `6ae0430e5f894da540fb7126`. Live Seattle pricing is checked against US$0.50/hour before the /29 or replacement ESXi is purchased. Updating this repository does not itself delete or create anything.

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
| Replacement public IPv4 block | /29, five assignable, account-quoted **US$0.028/hour for the whole range** |
| Estimated total | **US$0.428/hour**, or **US$308.16 for 30 days** |
| Maximum budget | **US$0.50/hour total** (creation gated on live quote; not an ongoing spending cap) |
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
- **US$0.50/hour total budget** for one host and one /29 public IPv4 block.
  Confirmed catalog SKU `W0I2-DIVY-ZJVP` (`GLOBAL`, `range-29`) is
  US$0.028/hour **for the complete /29 block**, not each address. Together
  with the US$0.40/hour server, estimated total is US$0.428/hour.
  Creation fails if the live API quote is missing, ambiguous or too high. This is not ongoing billing control and
  excludes taxes, overages, licensing and other resources.
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

## 3. Quote and rebuild with the Seattle /29

**Do not run a direct `terraform apply` against the existing /30-backed server.**
Follow [REBUILD-29.md](REBUILD-29.md). The two approved steps are:

```bash
terraform init
terraform validate
bash scripts/rebuild_29.sh quote    # optional: print full read-only billing catalog
bash scripts/rebuild_29.sh verify   # strict SKU and US$0.428/hour check; no apply
# STOP unless verify succeeds and the old host is ready to be permanently deleted.
bash scripts/rebuild_29.sh retire
# Verify in phoenixNAP the old server and /30 allocation are deleted.
bash scripts/rebuild_29.sh create
```

The optional `quote` step reads the billing catalog only.
`verify` confirms the exact approved GLOBAL /29 range SKU, checks the
live combined cost under US$0.50/hour, and **never applies** its temporary plan.
The `retire` step rechecks the same guard and then confirms a destroy-only
plan for the original server (with `delete_ip_blocks=true`).
The `create` step requires the approved live server + full /29 range price
at or below US$0.50/hour,
confirms the plan creates only one /29 and one ESXi host, and asks for explicit
approval before purchasing. ESXi will receive a new management address.

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

To enable SSH on an ESXi host and import your Mac's existing
`~/.ssh/id_ed25519.pub` for root without committing the key to GitHub:

```bash
brew install govc
bash scripts/install_esxi_ssh_key.sh "$(terraform output -raw esxi_public_ip)"
```

phoenixNAP disables SSH on ESXi by default. The helper uses authenticated
vSphere HTTPS to start `TSM-SSH`, asks for the root password, then adds the
public key on the host. It temporarily skips self-signed HTTPS verification
for this evaluation lab and opens SSH on the public interface; use only when
needed. Re-run it against the **replacement host's IP** after rebuilding.

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
The replacement server uses a separately managed `pnap_ip_block` for /29 with
`delete_ip_blocks = false` on the server. A normal approved Terraform destroy
removes the server, then its IP block. The original /30-backed server is
retired separately with its prior `delete_ip_blocks = true` state. Always
verify both allocations and servers are gone from BMC billing.

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
