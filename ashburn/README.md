# Ashburn vSphere 8 — full build and teardown

This guide is for the **`phoenixnap-vsphere-terraform`** folder, checked out on
`feat/ashburn-esxi-temporary-vcsa-installer`. Run all Mac commands from the
**repository root**. Only use **`terraform -chdir=ashburn`**: the root Terraform
files and root `terraform.tfstate` belong to legacy Seattle work.

**Topology:** Terraform provisions (1) bare-metal ESXi with a public /29 and
(2) a **separate temporary Ubuntu ISO installer**. The VCSA is a **VM inside ESXi**.
Ansible adds the host to vCenter after VCSA is installed.

## 0. Manual UI cleanup — only for missing/empty Terraform state

If an old Ashburn run was manually deleted or its state lost:

1. Back up the data you need. Deleting ESXi destroys its VCSA VM and datastore.
2. Verify `terraform -chdir=ashburn state list` is **empty**. If not, stop and
   reconcile its resource IDs before touching the portal.
3. In PhoenixNAP **Servers**, delete `esxi-01` and `vcsa-installer-ash` if present.
   Check you are in region **ASH**, not Seattle.
4. In **Networking → Public IP Allocations**, delete the unused **/29**
   and the installer's remaining default IP allocation, if any.
5. Check the **Servers**, **Public IP Allocations** and **Billing** screens until
   no old chargeable Ashburn resources remain. Retaining an IP allocation is billable.
6. Keep state backups; never copy the root/Seattle state into `ashburn/`.

**Do not use the UI for normal teardown once Terraform manages resources.**
Use section 6.

## 1. Configure the empty stack

A fresh clone starts on `main`, which has no `ashburn/` directory. Use:

```bash
git clone https://github.com/waynedovey/phoenixnap-vsphere-terraform.git
cd phoenixnap-vsphere-terraform
git switch --track origin/feat/ashburn-esxi-temporary-vcsa-installer
```

For an existing checkout, `git switch feat/ashburn-esxi-temporary-vcsa-installer`,
then `git pull --ff-only`. Keep existing ignored state and tfvars files;
never force checkout if Git reports a conflict.

Preflight on the Mac: `terraform`, `jq`, `govc`, `python3`, `ssh`, `scp`,
and PhoenixNAP API environment variables `PNAP_CLIENT_ID` and
`PNAP_CLIENT_SECRET`. Obtain VMware VCSA 8 media legally, a vendor-verified
SHA-256 digest and any required written PhoenixNAP approval for VCSA.

```bash
cd /Users/wdovey/OCP/phoenixnap-vsphere-terraform
git branch --show-current
cp -n ashburn/terraform.tfvars.example ashburn/terraform.tfvars
chmod 600 ashburn/terraform.tfvars
vim ashburn/terraform.tfvars
```

For **both servers in a fully approved clean lab**, use:

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
vcsa_iso_sha256          = "REPLACE_WITH_VENDOR_VERIFIED_64_HEX_CHARACTER_SHA256"
```

Only set the three confirmation flags after checking their conditions.
The SKUs above worked previously but **stock and prices can change**.
The management CIDR allows access from everywhere; for a safer lab use
your IP as a `/32`. The default `vcsa_iso_url` points to an **unofficial mirror**:
use an authorized source and a digest independently verified with the vendor.
With `vcsa_iso_sha256 = ""`, cloud-init intentionally **does not download the ISO**.

## 2. Provision ESXi, /29 and temporary Ubuntu

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn validate
terraform -chdir=ashburn state list
```

First, confirm **Ashburn state and the PhoenixNAP console are empty**.
Allocate only the /29. The PhoenixNAP provider can show
`server_ip_block.id = null` if the ESXi server and its new /29 are in the
**same first plan**. To avoid provisioning with an empty ID, use `-target`
**once** for this initial /29 allocation only (Terraform will warn about targeting):

```bash
terraform -chdir=ashburn plan -target='pnap_ip_block.esxi_29[0]' -out=ip-block-only.tfplan
terraform -chdir=ashburn show ip-block-only.tfplan
```

Expect **1 add, 0 change, 0 destroy** for `pnap_ip_block.esxi_29[0]`
alone. Confirm the price and account are correct; then:

```bash
terraform -chdir=ashburn apply ip-block-only.tfplan
terraform -chdir=ashburn state show 'pnap_ip_block.esxi_29[0]'
```

Next, create a **new, complete plan without `-target`**:

```bash
terraform -chdir=ashburn plan -out=servers.tfplan
terraform -chdir=ashburn show servers.tfplan
terraform -chdir=ashburn show -json servers.tfplan | jq -r '.resource_changes[] | select(.address == "pnap_server.esxi[0]") | .change.after.network_configuration[0].ip_blocks_configuration[0].ip_blocks[0].server_ip_block[0].id'
```

Expect **2 add, 0 change, 0 destroy**: `pnap_server.esxi[0]` and
`pnap_server.installer[0]`. The ID printed by `jq` must match the /29
ID from `state show` (not null or blank). **Stop** if the ID differs,
any resource would be replaced/deleted, or old servers still exist.
Verify the quoted costs, then apply:

```bash
terraform -chdir=ashburn apply servers.tfplan
terraform -chdir=ashburn state list
terraform -chdir=ashburn output
```

If creation returns `406 No server available`, inspect the **partial state**
and PhoenixNAP console before retrying with another available SKU. Never
discard state or blindly reapply. The bare-metal ESXi install can take minutes.
The VCSA is **not** installed by Terraform.

Keep `ashburn/terraform.tfstate` and `ashburn/terraform.tfvars` in the current
repository; both are ignored by Git. State can include your ESXi root password:
back it up **securely outside Git**, do not print or publish it.

## 3. Deploy VCSA from the temporary Ubuntu server

### 3A. Check ESXi networking and storage (Mac)

Connect `govc` to the new ESXi using the password **already in Ashburn state**:

```bash
export GOVC_URL="$(terraform -chdir=ashburn output -raw esxi_management_url)/sdk"
export GOVC_USERNAME=root
export GOVC_INSECURE=1
export GOVC_PASSWORD="$(terraform -chdir=ashburn state pull | jq -er '.resources[] | select(.type == "pnap_server" and .name == "esxi") | .instances[0].attributes.root_password')"
govc about
govc host.portgroup.info
govc datastore.info
```

If `vcsa-public` is **absent**, and PhoenixNAP's public VLAN is confirmed as
**3**, add it once:

```bash
govc host.portgroup.add -vswitch vSwitch0 -vlan 3 vcsa-public
govc host.portgroup.info
```

**Never format `datastore1`.** The previous host showed one Micron NVMe
**boot** drive containing ESXi, `OSDATA` and `datastore1`. Do not assume
there are two spare drives.

### 3B. Check the ISO bootstrap (Mac → Ubuntu)

Look up `pnap_server.installer` in PhoenixNAP and copy its **primary public
IPv4** (the Terraform output may show a *range*). Set that IP explicitly:

```bash
export INSTALLER_IP="REPLACE_WITH_PRIMARY_INSTALLER_PUBLIC_IP"
ssh ubuntu@"$INSTALLER_IP" 'sudo tail -n 40 /var/log/vcsa-installer-bootstrap.log'
ssh ubuntu@"$INSTALLER_IP" 'test -f /opt/vcsa/MEDIA_READY && mountpoint /mnt/vcsa && test -f /mnt/vcsa/vcsa-cli-installer/lin64/vcsa-deploy'
```

If `MEDIA_READY` is missing, stop. Check the log, ISO URL and checksum.
An empty/unverified digest skips download. Ubuntu `focal` media setup no longer
requests the missing `libnsl2` package.

### 3C. Generate IP-correct VCSA configuration (Mac)

Use the **official template from your mounted ISO**, not an old Seattle JSON.
VMware's install template for a standalone ESXi host is
`vcsa-cli-installer/templates/install/embedded_vCSA_on_ESXi.json`.

```bash
mkdir -p private
chmod 700 private
scp ubuntu@"$INSTALLER_IP":/mnt/vcsa/vcsa-cli-installer/templates/install/embedded_vCSA_on_ESXi.json private/embedded_vCSA_on_ESXi.json
python3 scripts/render-vcsa-config.py --template private/embedded_vCSA_on_ESXi.json
jq '{esxi: .new_vcsa.esxi.hostname, portgroup: .new_vcsa.esxi.deployment_network, datastore: .new_vcsa.esxi.datastore, vcsa: .new_vcsa.network.ip, prefix: .new_vcsa.network.prefix, gateway: .new_vcsa.network.gateway, system_name: .new_vcsa.network.system_name}' private/vcsa-config-ashburn.json
```

The renderer reads **`terraform -chdir=ashburn output -json`** and checks
the previously observed /29 layout (gateway = network +1, ESXi = +2,
VCSA = +3). **It will stop if the ESXi layout changes.** Confirm the
VCSA IP is **unused** and routable through VLAN 3 before continuing.
The JSON contains `FILL_RUNTIME` placeholders, **not real passwords**,
and is written mode 0600 under ignored `private/`.

Do **not** overwrite an existing `private/vcsa-config-ashburn.json` without
reviewing and archiving it first. Check DNS, NTP, deployment size and
vCenter network settings for your actual environment.

### 3D. Precheck and deploy (Ubuntu Bash)

Copy the generated template and existing wrapper:

```bash
ssh ubuntu@"$INSTALLER_IP" 'umask 077; mkdir -p vcsa; chmod 700 vcsa'
scp private/vcsa-config-ashburn.json ubuntu@"$INSTALLER_IP":vcsa/vcsa-config.json
scp scripts/vcsa.py ubuntu@"$INSTALLER_IP":vcsa/
ssh ubuntu@"$INSTALLER_IP"
```

**Now in the Ubuntu Bash SSH session**, enter passwords privately.
The new VCSA root password must be 8–20 characters and include upper/lowercase,
a number and punctuation, with no spaces. Do not use macOS/Zsh `read -p`.

```bash
cd ~/vcsa
read -rsp 'ESXi root password: ' ESXI_ROOT_PASSWORD; echo
read -rsp 'New VCSA root password: ' VCSA_ROOT_PASSWORD; echo
read -rsp 'New VCSA SSO password: ' VCSA_SSO_PASSWORD; echo
export ESXI_ROOT_PASSWORD VCSA_ROOT_PASSWORD VCSA_SSO_PASSWORD
export VCSA_INSTALLER_DIR=/mnt/vcsa
python3 vcsa.py check --template vcsa-config.json
python3 vcsa.py precheck --template vcsa-config.json
```

The ESXi password is the root password of the **new** host, not your VCSA
SSO password. Review the precheck output and VMware's EULA and support terms.
**Only after you have actual PhoenixNAP/VCSA deployment approval**:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
python3 vcsa.py deploy --template vcsa-config.json
```

The script requires typing `DEPLOY-VCENTER` as a final confirmation.
Password values are injected into a temporary JSON and not committed to Git.
VMware logs might contain connection details: handle them privately.

Wait for `https://VCSA_IP/ui` to become healthy. The VCSA IP is the
`vcsa` address printed by the renderer; it is **not the installer IP**.

## 4. Register ESXi in vCenter (Ansible on Mac)

From the repository root on Mac **after VCSA is ready**:

```bash
brew install python@3.14
python3.14 -m venv ashburn/.venv
source ashburn/.venv/bin/activate
python -m pip install 'ansible-core>=2.21,<2.22' requests pyvmomi
ansible-galaxy collection install -r ashburn/ansible/requirements.yml
bash ashburn/scripts/register-esxi.sh
```

The wrapper reads the new ESXi IP and root password from Terraform state
and the VCSA IP from `private/vcsa-config-ashburn.json`. It asks for the
VCSA SSO password, creates **Datacenter** if needed and registers ESXi
under `/Datacenter/host`. Re-running it is safe; it **does not format storage**.
See [Ansible notes](ansible/README.md).

Verify through vCenter-connected `govc` (set `GOVC_URL` to the VCSA `/sdk`,
`GOVC_USERNAME` to `administrator@vsphere.local`, and enter the SSO password):

```bash
govc about
govc ls /
govc host.info
govc datastore.info
govc find / -type m
```

Expect the host connected, `Datacenter` present, `datastore1` and a VCSA VM.

## 5. Retire **only** the Ubuntu installer

Once VCSA is working, the Ubuntu ISO downloader is no longer necessary:

```bash
bash ashburn/scripts/retire-installer.sh
```

The script checks for ESXi, shows a plan and requires the installer
**server ID** before deleting it. Afterwards edit `ashburn/terraform.tfvars`
to `enable_installer = false`. Verify the installer and default public IP
allocation disappear in the PhoenixNAP portal and billing.

**Keep ESXi, VCSA and the ESXi /29** running.

## 6. Tear down the complete lab

Back up any data you need; this **irreversibly destroys** ESXi and its VMs,
the local datastore, the installer if present, and the dedicated /29.

```bash
terraform -chdir=ashburn state list
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
```

Review the plan for **only** intended Ashburn resources. If state is empty
but servers exist in PhoenixNAP, **STOP** and recover/import state rather
than assuming `0 to destroy` means billing will end.

```bash
terraform -chdir=ashburn apply teardown.tfplan
terraform -chdir=ashburn state list
```

Finally check PhoenixNAP **Servers**, **Public IP Allocations** and billing.
The ESXi resource uses `delete_ip_blocks = false` because Terraform separately
manages the /29; the installer uses `delete_ip_blocks = true` for its
default allocation. Verify both are gone. Never delete state before teardown.

**Troubleshooting:** If Terraform reports out-of-stock (HTTP 406), use
the live PhoenixNAP product availability API/portal before selecting a new SKU.
If Ansible complains about `requests`, use the same activated Python 3.14
environment for Ansible and its VMware modules. Do not use the root/Seattle
Terraform state for any Ashburn operation.
