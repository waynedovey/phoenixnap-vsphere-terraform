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

After `terraform -chdir=ashburn apply servers.tfplan`, **do not manually export the installer IP or ISO checksum**. The wrapper reads the current installer ID and resolves the Ubuntu SSH IPv4 from the managed server's `public_ip_addresses` in Terraform state. PhoenixNAP can return a `/31` or two-address range rather than a single IP, so the built-in resolver handles those formats and stops on ambiguity. ISO settings are evaluated from `ashburn/terraform.tfvars`.

Set an authorized ISO location **once** in `ashburn/terraform.tfvars`:

```hcl
vcsa_iso_url        = "https://YOUR_AUTHORIZED_VCSA_ISO_URL"
vcsa_iso_sha256     = "YOUR_INDEPENDENTLY_VENDOR_VERIFIED_64_HEX_SHA256"
vcsa_iso_local_path = ""
```

Alternatively, set `vcsa_iso_url = ""` and `vcsa_iso_local_path = "/absolute/path/to/authorized/VMware-VCSA.iso"`. The checksum is required in both cases. Cloud-init downloads and verifies the ISO at boot if the URL and checksum were present during provisioning. If no ISO was downloaded, `prepare` automatically retries the configured HTTPS download or uploads the local file, then verifies its digest.

**ISO location:** Ubuntu stores the downloaded file as `/opt/vcsa/media/VMware-VCSA-all-8.0.3-24022515.iso` and mounts it at `/mnt/vcsa`. The source URL is `vcsa_iso_url` in `terraform.tfvars`; it is intentionally blank by default. Find legitimately accessible VCSA media through [Broadcom's official ISO download instructions](https://knowledge.broadcom.com/external/article/387785/download-vcenter-server-patches-and-isos.html). The previously used third-party mirror and its observed hash were **not** independently publisher-verified and are not restored as defaults.

**SSH on repeated builds:** PhoenixNAP can reassign the same Ubuntu IP to a new physical server with a new host key. The wrapper now uses `private/ssh/installer-<SERVER_ID>.known_hosts` and OpenSSH `StrictHostKeyChecking=accept-new`: it accepts a key only on the first connection for that server ID, then rejects subsequent changes. It no longer conflicts with your global `~/.ssh/known_hosts`, and you should not delete or edit that global file to bypass warnings. First-contact trust is TOFU; for higher assurance compare the fingerprint against a trusted PhoenixNAP console or out-of-band source.

The wrapper archives existing VCSA configuration and ISO template when it detects a new installer server ID. If an incomplete or incorrect ISO already exists remotely, the checksum verification deliberately fails rather than trusting it.

Check that PhoenixNAP has an ESXi port group named `public.<VLAN>` (for the previous lab it was `public.5`). Ansible now **uses the existing public port group directly**. It does not create `vcsa-public` or assume VLAN 3.

```bash
bash ashburn/scripts/vcsa.sh prepare
jq '{network: .new_vcsa.esxi.deployment_network, ip: .new_vcsa.network.ip, tools_time: .new_vcsa.os.time_tools_sync, ntp: .new_vcsa.os.ntp_servers}' private/vcsa-config-ashburn.json
```

By default, `time_tools_sync` is true and no guest NTP server is specified; VCSA receives time from the **synchronized ESXi host**. If you have confirmed working guest NTP on UDP/123 and prefer direct NTP, set `VCSA_TIME_SOURCE=ntp` and `VCSA_NTP_SERVER=<reachable NTP address>` **before prepare**. Do not set both NTP and Tools sync.

The generated `private/vcsa-config-ashburn.json` is not overwritten automatically. **After weekend teardown**, archive the old JSON and ISO template before running prepare on a new host. Ansible rejects stale port-group references. Confirm that the new VCSA IP is unused and reachable; never reuse old allocations without validating them.

## Precheck, install, register

ESXi has a self-signed TLS certificate. Rather than requiring a manual `export VCSA_ESXI_CERT_SHA256=...`, the Mac wrapper automatically:

1. Reads the ESXi management HTTPS address and current PhoenixNAP server ID from Ashburn Terraform.
2. Fetches the ESXi TLS certificate and calculates SHA-256.
3. Saves it in ignored `private/certs/esxi-<SERVER_ID>.sha256` on first use, then verifies it is unchanged on subsequent runs for that same ID.
4. Exports `VCSA_ESXI_CERT_SHA256` **internally** to Ansible; the Ubuntu installer separately checks its own TLS connection against the same fingerprint before using VMware's non-interactive `--no-esx-ssl-verify` option.

**Important security limitation:** This is *trust on first use* (TOFU). It prevents a silent certificate change after initial pinning, but it **does not independently authenticate** the ESXi host on the first connection. If you need stronger assurance, compare the printed SHA-256 with the ESXi certificate through a trusted PhoenixNAP management console before proceeding. Never automatically overwrite an existing pin after a mismatch.

```bash
# Only after ESXi NTP reports "Time Synchronized: true":
export ESXI_NTP_SYNC_CONFIRMED=YES
bash ashburn/scripts/vcsa.sh precheck
```

There is **no certificate-fingerprint export to set**. A newly provisioned ESXi has a new server ID and therefore gets a new pin. The private pin files are excluded from Git.

The wrapper prompts for new VCSA root and SSO passwords; it reads the **ESXi root password** from the current Ashburn Terraform state, not from a tracked file. For deployment, only after actual approval:

```bash
export PNAP_VCENTER_SUPPORT_CONFIRMED=YES
export VCSA_DEPLOY_APPROVED=YES
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

`deploy` requires you to type `DEPLOY-VCENTER`. It also refuses to deploy when a `vcsa-ash` VM already exists, protecting against duplicate deployment after a failed run. The remote VMware CLI performs the installation. Ansible keeps `no_log: true` for tasks containing credentials, so failure details do not appear in its task result. A new `diagnose` stage provides a read-only, filtered summary:

```bash
bash ashburn/scripts/vcsa.sh diagnose
```

The precheck subprocess writes combined output to `/home/ubuntu/vcsa/last-precheck.log` on Ubuntu with permissions 0600; the diagnostic also examines recent `/tmp/vcsaCliInstaller-*/.../vcsa-cli-installer.log` files. **If the failed precheck preceded this logging improvement**, first try diagnose for VMware's earlier logs, then rerun `precheck` after pulling the changes to capture any missing Python/CLI errors. The diagnostic does not deploy the appliance or need VCSA passwords. It suppresses lines with common secret assignments, but inspect output before sharing it. Raw installer logs may contain secrets.

The exact VM name and previous deployment state must be inspected before any manual cleanup.

## Troubleshooting and safety

- **Ubuntu SSH fails:** verify the installer ID and IP shown by `vcsa.sh`. The per-ID host key file avoids recycled-IP mismatches, but first-use fingerprints still require out-of-band verification if security requires it. Do not disable host key checking or delete `~/.ssh/known_hosts`.
- **ISO validation fails:** confirm legitimate source, the independently verified digest, and `/var/log/vcsa-installer-bootstrap.log` on Ubuntu. An empty checksum in Terraform makes cloud-init skip download.
- **VCSA connectivity fails:** compare the detected `public.<VLAN>` port group, the new `/29`, DNS, gateway, and the VCSA guest IP. The old hardcoded `vcsa-public` VLAN 3 was incorrect: public traffic used VLAN 5.
- **NTP/firstboot fails:** confirm `esxcli system ntp get` reports `Time Synchronized: true`; the new single-host default uses VMware Tools host-time sync. If using guest NTP, independently test DNS and UDP/123 from the VCSA network. Don't simply rerun deploy into an existing failed VM.
- **Existing private JSON points to old IP:** archive it and regenerate from current Terraform outputs. Never put passwords directly in this JSON.
- **Ansible cannot register host:** confirm VCSA is healthy; use `source ashburn/.venv/bin/activate` to run compatible VMware modules.
- **Never format `datastore1`.** The prior ESXi host contained its boot partitions and VMFS datastore on the same NVMe disk.

For the old manual CLI workflow see [manual fallback](ashburn-manual.md). Back up your **ignored** Terraform state securely; it can contain credentials. Never commit ISO images, passwords, Terraform state or plan files.
