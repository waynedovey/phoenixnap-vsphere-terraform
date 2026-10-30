# VCSA installation with Ansible (Ashburn)

The command sequence is on the [main README](../README.md). These are the prerequisites and recovery notes.

## What gets installed

- **PhoenixNAP/Terraform** deploys ESXi 8 on bare metal plus a temporary Ubuntu 20.04 server.
- **Ansible `prepare`** checks the ISO on Ubuntu, or copies one from your Mac if cloud-init did not download it; verifies its **SHA-256**; mounts it read-only; discovers the existing `public.<VLAN>` port group without changing ESXi networking; and generates private VCSA JSON using the **current Terraform IPs**.
- **Ansible `precheck`** runs the VMware VCSA CLI precheck remotely.
- **Ansible `deploy`** re-runs precheck and, after approvals and an explicit confirmation, installs the VCSA VM on ESXi.
- **Ansible `register-esxi.sh`** adds ESXi into vCenter's `Datacenter` inventory.

**Ansible does not deploy ESXi's ISO**—PhoenixNAP provides the ESXi 8 image during server provisioning. VCSA runs *as a VM on ESXi*, not as a third PhoenixNAP server.

## One-time setup on your Mac

```bash
cd /Users/wdovey/OCP/phoenixnap-vsphere-terraform
bash ashburn/scripts/setup-ansible.sh
```

This creates/reuses `ashburn/.venv` with Python 3.14, Ansible Core 2.21, pyVmomi and the VMware collection. The VCSA playbook runs **on the Mac** and uses SSH/SCP for Ubuntu 20.04, whose Python 3.8 is not supported as a managed host by Ansible Core 2.21.

**Important:** ESXi's PhoenixNAP-provisioned NTP servers may be unreachable. Before VCSA setup, run `bash ashburn/scripts/esxi-time.sh check`. If `Time Synchronized` is false, run `bash ashburn/scripts/esxi-time.sh configure` (requires confirmation and public UDP/123 connectivity), then check again. Do not start VMware precheck/deploy until it reports `true`. During the earlier October 2026 run, ESXi was receiving NTP packets (`reach 3`) but still reported unsynchronized, so don't treat one successful packet as completion.

## Prepare the ISO and VCSA configuration

After `terraform -chdir=ashburn apply servers.tfplan` succeeds, find the **temporary Ubuntu server's primary IPv4** in PhoenixNAP and verify its SSH host key.

```bash
export INSTALLER_IP="UBUNTU_PRIMARY_IP"
ssh ubuntu@"$INSTALLER_IP" true
export VCSA_ISO_SHA256="INDEPENDENTLY_VENDOR_VERIFIED_64_HEX_DIGEST"
```

If your `vcsa_iso_url` and `vcsa_iso_sha256` in Terraform were both approved and the cloud-init download succeeded, the remote ISO already exists. Otherwise supply a **legitimate local VMware VCSA ISO**:

```bash
export VCSA_ISO_PATH="/absolute/path/to/VMware-VCSA-all-8.0.3-24022515.iso"
```

`prepare` uploads that file **only if the ISO is absent on Ubuntu**. If an incomplete or wrong ISO already exists remotely, fix it there before retrying; the checksum check deliberately fails rather than trusting it.

Check that PhoenixNAP has an ESXi port group named `public.<VLAN>` (for the previous lab it was `public.5`). Ansible now **uses the existing public port group directly**. It does not create `vcsa-public` or assume VLAN 3.

```bash
bash ashburn/scripts/vcsa.sh prepare
jq '{network: .new_vcsa.esxi.deployment_network, ip: .new_vcsa.network.ip, tools_time: .new_vcsa.os.time_tools_sync, ntp: .new_vcsa.os.ntp_servers}' private/vcsa-config-ashburn.json
```

By default, `time_tools_sync` is true and no guest NTP server is specified; VCSA receives time from the **synchronized ESXi host**. If you have confirmed working guest NTP on UDP/123 and prefer direct NTP, set `VCSA_TIME_SOURCE=ntp` and `VCSA_NTP_SERVER=<reachable NTP address>` **before prepare**. Do not set both NTP and Tools sync.

The generated `private/vcsa-config-ashburn.json` is not overwritten automatically. **After weekend teardown**, archive the old JSON and ISO template before running prepare on a new host. Ansible rejects stale port-group references. Confirm that the new VCSA IP is unused and reachable; never reuse old allocations without validating them.

## Precheck, install, register

The freshly installed ESXi host has a self-signed TLS certificate. VMware's CLI normally prompts to accept its fingerprint, which fails with an EOF when run unattended through Ansible. Before precheck, **independently verify** the ESXi TLS certificate fingerprint against the host's certificate shown in a trusted ESXi management session. To collect the certificate as seen from the Ubuntu installer:

```bash
ssh ubuntu@"$INSTALLER_IP" \
  'echo | openssl s_client -connect 192.240.198.138:443 -servername 192.240.198.138 2>/dev/null | openssl x509 -noout -fingerprint -sha256'
```

After checking the fingerprint out of band, supply it in the current Mac session (colons optional):

```bash
export VCSA_ESXI_CERT_SHA256="PASTE_VERIFIED_SHA256_FINGERPRINT"
# Only after ESXi NTP reports "Time Synchronized: true":
export ESXI_NTP_SYNC_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh precheck
```

The Python installer wrapper checks the live TLS certificate **from Ubuntu** against this pin before enabling VMware's narrowly scoped `--no-esx-ssl-verify` option to avoid the interactive certificate prompt. **Never supply a fingerprint without independently checking the ESXi identity.** This option skips VMware's own certificate validation for ESXi; the external pinned check compensates for it. It does not skip certificate checks for every connection.

The wrapper prompts for new VCSA root and SSO passwords; it reads the **ESXi root password** from the current Ashburn Terraform state, not from a tracked file. For deployment, only after actual approval:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

`deploy` requires you to type `DEPLOY-VCENTER`. It also refuses to deploy when a `vcsa-ash` VM already exists, protecting against duplicate deployment after a failed run. The remote VMware CLI performs the installation; Ansible hides sensitive task output, so consult private VMware installer logs on Ubuntu if a stage fails. The exact VM name and previous deployment state must be inspected before any manual cleanup.

## Troubleshooting and safety

- **Ubuntu SSH fails:** use the server's primary IPv4, verify its SSH host key, and use the SSH keys installed by PhoenixNAP. Do not use the public IP *range* as an SSH address.
- **ISO validation fails:** confirm legitimate source, the independently verified digest, and `/var/log/vcsa-installer-bootstrap.log` on Ubuntu. An empty checksum in Terraform makes cloud-init skip download.
- **VCSA connectivity fails:** compare the detected `public.<VLAN>` port group, the new `/29`, DNS, gateway, and the VCSA guest IP. The old hardcoded `vcsa-public` VLAN 3 was incorrect: public traffic used VLAN 5.
- **NTP/firstboot fails:** confirm `esxcli system ntp get` reports `Time Synchronized: true`; the new single-host default uses VMware Tools host-time sync. If using guest NTP, independently test DNS and UDP/123 from the VCSA network. Don't simply rerun deploy into an existing failed VM.
- **Existing private JSON points to old IP:** archive it and regenerate from current Terraform outputs. Never put passwords directly in this JSON.
- **Ansible cannot register host:** confirm VCSA is healthy; use `source ashburn/.venv/bin/activate` to run compatible VMware modules.
- **Never format `datastore1`.** The prior ESXi host contained its boot partitions and VMFS datastore on the same NVMe disk.

For the old manual CLI workflow see [manual fallback](ashburn-manual.md). Back up your **ignored** Terraform state securely; it can contain credentials. Never commit ISO images, passwords, Terraform state or plan files.
