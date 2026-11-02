# Ashburn ESXi + vCenter

This folder contains the **Ashburn Terraform stack** (separate from the old Seattle Terraform files at the repository root).

Use [the top-level quickstart](../README.md) for the shortest **Create → Install → Destroy** workflow.

## Commands at a glance

**Create a new lab:** first allocate its public `/29` once, then create ESXi and the temporary Ubuntu server.

```bash
terraform -chdir=ashburn init
terraform -chdir=ashburn plan -target='pnap_ip_block.esxi_29[0]' -out=ip-block-only.tfplan
terraform -chdir=ashburn show ip-block-only.tfplan
terraform -chdir=ashburn apply ip-block-only.tfplan

terraform -chdir=ashburn plan -out=servers.tfplan
terraform -chdir=ashburn show servers.tfplan
terraform -chdir=ashburn apply servers.tfplan
```

Review plans before applying: **1 add** for the IP block, then **2 adds** for the servers. Only use these commands for a clean build with no old Ashburn resources; check that the ESXi block ID is **not null**.

**Install vCenter (Ansible):**

```bash
bash ashburn/scripts/setup-ansible.sh
bash ashburn/scripts/esxi-time.sh check
bash ashburn/scripts/vcsa.sh prepare
bash ashburn/scripts/vcsa.sh precheck
bash ashburn/scripts/vcsa.sh deploy
bash ashburn/scripts/register-esxi.sh
```

No `INSTALLER_IP`, `VCSA_ISO_SHA256`, `VCSA_ISO_PATH`, or `VCSA_ESXI_CERT_SHA256` exports are required. `vcsa.sh` resolves the installer IPv4 from current Terraform state and `vcsa_iso_url`, `vcsa_iso_sha256`, and optional `vcsa_iso_local_path` from `ashburn/terraform.tfvars`. Supply an authorized HTTPS ISO URL or a local Mac ISO file, plus an independently verified SHA-256. Reused IPs are handled with a per-server SSH known_hosts file (first-use trust); stale generated VCSA settings are automatically archived for a newly provisioned installer ID.

Check ESXi NTP synchronization with `bash ashburn/scripts/esxi-time.sh check` before precheck/deploy. Ansible discovers PhoenixNAP's VMkernel management network `public.<VLAN>` and creates a dedicated `vcsa-public` **VM-only** port group on the same VLAN. ESXi TLS fingerprint pinning is automatic (trust on first use); set `ESXI_NTP_SYNC_CONFIRMED=YES` only after verifying synchronization, and provide required VMware/PhoenixNAP approvals before deploying. See the [Ansible installation guide](../docs/vcsa-ansible.md).

**Destroy the full lab:**

```bash
terraform -chdir=ashburn plan -destroy -out=teardown.tfplan
terraform -chdir=ashburn show teardown.tfplan
terraform -chdir=ashburn apply teardown.tfplan
```

This permanently removes ESXi, VCSA, all VMs and local data, the Ubuntu server and the public `/29`. Verify **Servers, Public IP Allocations and billing** in PhoenixNAP. Before Monday's rebuild, archive the old `private/vcsa-config-ashburn.json` and ISO template; do not delete `terraform.tfstate` manually.

## Reference

- [Main README — simple quickstart](../README.md)
- [Ansible VCSA installation stages](../docs/vcsa-ansible.md)
- [Detailed manual fallback and troubleshooting](../docs/ashburn-manual.md)
- [ESXi registration with Ansible](ansible/README.md)

Never run Ashburn Terraform commands at repository root, delete state to tear down infrastructure, or format `datastore1`.
