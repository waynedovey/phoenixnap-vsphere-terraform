#!/usr/bin/env bash
# Orchestrate ISO preparation, precheck, and VCSA deployment using Ansible on Mac.
set -Eeuo pipefail
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
stage="${1:-}"
case "$stage" in
  prepare|precheck|deploy|diagnose|inspect) ;;
  *) echo "Usage: bash ashburn/scripts/vcsa.sh prepare|precheck|deploy|diagnose|inspect" >&2; exit 2 ;;
esac
for utility in terraform jq govc ssh scp; do
  command -v "$utility" >/dev/null || { echo "Missing $utility" >&2; exit 1; }
done
if [[ ! -x ashburn/.venv/bin/ansible-playbook ]]; then
  echo "Run: bash ashburn/scripts/setup-ansible.sh" >&2; exit 1
fi
# Validate the complete playbook before touching Ubuntu, ISO media or ESXi.
# This catches malformed YAML immediately with a useful local line number.
if [[ "$stage" == prepare || "$stage" == precheck || "$stage" == deploy ]]; then
  if ! ashburn/.venv/bin/ansible-playbook -i 'localhost,' -c local --syntax-check ashburn/ansible/vcsa.yml; then
    echo "STOP: VCSA Ansible playbook syntax check failed. No deployment actions executed." >&2
    exit 1
  fi
fi
# Read one authoritative source of truth: the current Ashburn state and tfvars.
# Terraform console evaluates HCL, rather than treating tfvars as an ad-hoc text file.
tf_variable() {
  local expr="$1"
  printf '%s\n' "var.${expr}" | terraform -chdir=ashburn console -no-color | jq -er 'select(type == "string")'
}
installer_id="$(terraform -chdir=ashburn output -raw installer_id)"
esxi_id="$(terraform -chdir=ashburn output -raw esxi_id)"
[[ "$installer_id" =~ ^[0-9a-f]{24}$ && "$esxi_id" =~ ^[0-9a-f]{24}$ ]] || {
  echo "Expected current Ashburn installer and ESXi IDs in Terraform state." >&2; exit 1;
}
# PhoenixNAP's managed server resource exposes public_ip_addresses, which may
# contain a /31 or an address range rather than a single IPv4. A separate
# resolver handles that format and rejects ambiguous addresses.
if ! INSTALLER_IP="$(terraform -chdir=ashburn state pull | python3 ashburn/scripts/resolve-installer-ip.py)"; then
  echo "STOP: cannot identify installer SSH IP from Ashburn Terraform state." >&2
  echo "Inspect: terraform -chdir=ashburn output -json installer_public_ip_addresses" >&2
  exit 1
fi
[[ "$INSTALLER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
  echo "STOP: resolved installer IP is invalid: $INSTALLER_IP" >&2; exit 1;
}
export INSTALLER_IP
export VCSA_ISO_SHA256="$(tf_variable vcsa_iso_sha256)"
export VCSA_ISO_URL="$(tf_variable vcsa_iso_url)"
export VCSA_ISO_PATH="$(tf_variable vcsa_iso_local_path)"
[[ "$VCSA_ISO_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || {
  echo "Set vcsa_iso_sha256 in ashburn/terraform.tfvars (vendor-verified digest required)." >&2; exit 1;
}
if [[ -n "$VCSA_ISO_URL" && ! "$VCSA_ISO_URL" == https://* ]]; then
  echo "vcsa_iso_url must use HTTPS. In tfvars, enter the plain URL, not Markdown link syntax." >&2; exit 1
fi
if [[ -n "$VCSA_ISO_URL" && -n "$VCSA_ISO_PATH" ]]; then
  echo "NOTE: vcsa_iso_url is set, so the Mac-local vcsa_iso_local_path is ignored." >&2
  echo "Set vcsa_iso_local_path = \"\" in ashburn/terraform.tfvars to avoid confusion." >&2
fi
if [[ -z "$VCSA_ISO_URL" && -z "$VCSA_ISO_PATH" ]]; then
  echo "NOTE: no ISO source configured; prepare requires media already present on Ubuntu." >&2
fi

# Isolate host-key trust to this server ID so a recycled IP does not conflict
# with ~/.ssh/known_hosts. First-contact trust is TOFU, not provider attestation.
install -d -m 0700 private/ssh
export ASHBURN_INSTALLER_KNOWN_HOSTS="$root/private/ssh/installer-${installer_id}.known_hosts"
if [[ ! -e "$ASHBURN_INSTALLER_KNOWN_HOSTS" ]]; then
  (umask 077; : > "$ASHBURN_INSTALLER_KNOWN_HOSTS")
fi
chmod 600 "$ASHBURN_INSTALLER_KNOWN_HOSTS"

echo "Installer: ${INSTALLER_IP} (server ${installer_id})"
echo "ISO source: $([[ -n "$VCSA_ISO_URL" ]] && echo 'configured HTTPS URL' || ([[ -n "$VCSA_ISO_PATH" ]] && echo 'local ISO path' || echo 'not configured'))"
echo "ISO checksum: loaded from ashburn/terraform.tfvars"

if [[ "$stage" == diagnose ]]; then
  echo "Inspecting remote installer diagnostics (read-only)."
  echo "Private logs can contain sensitive data. The summary filters common secrets."
  ssh -o "UserKnownHostsFile=$ASHBURN_INSTALLER_KNOWN_HOSTS" \
      -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=25 \
      "ubuntu@$INSTALLER_IP" 'python3 -' <<'PY'
from pathlib import Path
import re

sensitive = re.compile(r'(?i)(?:password|passwd|secret|token|authorization|credential|private.key|api.key)')
suspicious = re.compile(r'(?i)(error|failed|failure|invalid|unable|cannot|timeout|certificate|warning|denied|refused|exception|precheck)')
paths = [Path('/home/ubuntu/vcsa/last-precheck.log')]
paths += sorted(Path('/tmp').glob('vcsaCliInstaller-*/**/vcsa-cli-installer.log'),
                key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)[:2]
seen = set()
for path in paths:
    if path in seen or not path.is_file():
        continue
    seen.add(path)
    print('\n===', path, '===')
    try:
        lines = path.read_text(errors='replace').splitlines()
    except (OSError, UnicodeError) as exc:
        print('Unable to read diagnostic file:', type(exc).__name__)
        continue
    matches = [line.strip() for line in lines if suspicious.search(line)]
    if not matches:
        print('No distinct errors extracted; inspect this private file directly on Ubuntu.')
        continue
    for line in matches[-25:]:
        if sensitive.search(line):
            print('[Possible credentials in log line; omitted. Inspect privately on Ubuntu.]')
        else:
            print(line[:300])
if not seen:
    print('No logs yet. Pull changes, rerun precheck, then run diagnose.')
PY
  exit 0
fi

# A freshly allocated PhoenixNAP server can reuse the old IP address.
# Archive generated files on new server ID, but never delete user data.
if [[ "$stage" == prepare ]]; then
  install -d -m 0700 private private/archive
  build_id_file="private/ashburn-last-installer-id"
  last_installer_id="$(cat "$build_id_file" 2>/dev/null || true)"
  if [[ "$last_installer_id" != "$installer_id" ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    for file in private/vcsa-config-ashburn.json private/embedded_vCSA_on_ESXi.json; do
      if [[ -f "$file" ]]; then
        mv "$file" "private/archive/$(basename "$file").${stamp}.${installer_id}"
        echo "Archived stale VCSA configuration: $file"
      fi
    done
    printf '%s\n' "$installer_id" > "$build_id_file"
    chmod 600 "$build_id_file"
  fi
fi
# Previous playbook incorrectly used the public.<VLAN> VMkernel port group.
# Its generated JSON cannot work with OVF Tool; archive it and regenerate
# automatically using the dedicated vcsa-public VM network, even on the same host.
if [[ "$stage" != diagnose && -f private/vcsa-config-ashburn.json ]]; then
  old_deployment_network="$(jq -r '.new_vcsa.esxi.deployment_network // ""' private/vcsa-config-ashburn.json)"
  if [[ "$old_deployment_network" =~ ^public\.[0-9]+$ ]]; then
    install -d -m 0700 private/archive
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mv private/vcsa-config-ashburn.json "private/archive/vcsa-config-ashburn.json.vm-kernel-${stamp}.${installer_id}"
    echo "Archived VCSA JSON using VMkernel-only port group ${old_deployment_network}; Ansible will regenerate for vcsa-public."
  fi
fi

if [[ ( "$stage" == precheck || "$stage" == deploy ) && "${ESXI_NTP_SYNC_CONFIRMED:-}" != YES ]]; then
  echo "STOP: verify ESXi reports 'Time Synchronized: true' using esxcli system ntp get." >&2
  echo "Then set ESXI_NTP_SYNC_CONFIRMED=YES for this lab." >&2
  exit 1
fi

esxi_url="$(terraform -chdir=ashburn output -raw esxi_management_url)"
if [[ ! "$esxi_url" =~ ^https://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?/?$ ]]; then
  echo "Unexpected ESXi management URL: $esxi_url" >&2; exit 1
fi
export ASHBURN_ESXI_IP="${BASH_REMATCH[1]}"
export GOVC_URL="${esxi_url%/}/sdk"

# Automatically pin the ESXi HTTPS certificate by PhoenixNAP server ID.
# First run is TOFU, NOT independent identity verification. Subsequent
# certificate changes for the SAME server ID are fatal. A newly provisioned
# ESXi has a new server ID, hence a separate pin. No manual export required.
if [[ "$stage" == precheck || "$stage" == deploy ]]; then
  if ! VCSA_ESXI_CERT_SHA256="$(python3 ashburn/scripts/pin-esxi-cert.py \
    --url "$esxi_url" \
    --server-id "$esxi_id" \
    --pin-dir "$root/private/certs")"; then
    echo "STOP: ESXi certificate could not be pinned or has changed." >&2
    exit 1
  fi
  export VCSA_ESXI_CERT_SHA256
fi

# ESXi password stays in process memory; do not echo it or commit the state.
export ESXI_ROOT_PASSWORD="$(terraform -chdir=ashburn state pull | jq -er '.resources[] | select(.type == "pnap_server" and .name == "esxi") | .instances[0].attributes.root_password')"
[[ -n "$ESXI_ROOT_PASSWORD" ]] || { echo "Missing ESXi root password." >&2; exit 1; }

# govc vm.info returns 0 AND prints nothing when a named VM does not exist.
# Use the real inventory query for both inspection and duplicate guarding.
# Any inventory query failure blocks deployment (fail closed).
find_vcsa_vm() {
  local inventory
  if ! inventory="$(govc find / -type m -name vcsa-ash)"; then
    echo "STOP: failed to query ESXi VM inventory. Do not deploy." >&2
    return 1
  fi
  if [[ -n "$inventory" && "$inventory" == *$'\n'* ]]; then
    echo "STOP: multiple VMs named vcsa-ash found; inspect ESXi manually." >&2
    return 1
  fi
  printf '%s' "$inventory"
}

if [[ "$stage" == inspect || "$stage" == deploy ]]; then
  export GOVC_USERNAME=root GOVC_PASSWORD="$ESXI_ROOT_PASSWORD" GOVC_INSECURE=1
  if ! vm_path="$(find_vcsa_vm)"; then
    exit 1
  fi

  if [[ "$stage" == inspect ]]; then
    echo "Inspecting vcsa-ash on ESXi $ASHBURN_ESXI_IP (read-only):"
    if [[ -z "$vm_path" ]]; then
      echo "No vcsa-ash VM found in ESXi inventory. No VM cleanup necessary."
      echo "VMware precheck can be followed by deployment once all prerequisites are verified."
      exit 0
    fi
    echo "VM found: $vm_path"
    govc vm.info "$vm_path" || exit 1
    echo
    echo "VCSA VM network adapter:"
    govc device.info -vm "$vm_path" ethernet-0 || true

    expected_vcsa_ip="$(jq -r '.new_vcsa.network.ip // empty' private/vcsa-config-ashburn.json 2>/dev/null || true)"
    if [[ "$expected_vcsa_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo
      echo "VCSA appliance endpoint probes at $expected_vcsa_ip:"
      for port in 443 5480; do
        status="$(curl --insecure --silent --output /dev/null --write-out '%{http_code}' \
          --connect-timeout 3 --max-time 6 "https://$expected_vcsa_ip:$port/" || true)"
        [[ "$status" =~ ^[1-5][0-9][0-9]$ ]] || status="unreachable"
        echo "  HTTPS port $port: $status"
      done
      echo "Port reachability alone does not prove that Stage 2 has finished."
    fi
    echo
    echo "Check the existing VM's state before considering cleanup."
    exit 0
  fi

  if [[ -n "$vm_path" ]]; then
    echo "STOP: VM vcsa-ash already exists at $vm_path." >&2
    echo "Run 'bash ashburn/scripts/vcsa.sh inspect'; nothing was modified." >&2
    exit 1
  fi
  echo "ESXi VM inventory: vcsa-ash is absent; safe to attempt the approved deployment."
fi

if [[ "$stage" == precheck || "$stage" == deploy ]]; then
  if [[ -z "${VCSA_ROOT_PASSWORD:-}" ]]; then
    read -rsp 'New VCSA root password: ' VCSA_ROOT_PASSWORD; echo
    export VCSA_ROOT_PASSWORD
  fi
  if [[ -z "${VCSA_SSO_PASSWORD:-}" ]]; then
    read -rsp 'New VCSA SSO password: ' VCSA_SSO_PASSWORD; echo
    export VCSA_SSO_PASSWORD
  fi
  [[ -n "$VCSA_ROOT_PASSWORD" && -n "$VCSA_SSO_PASSWORD" ]] || { echo "Passwords required." >&2; exit 1; }
fi
if [[ "$stage" == deploy ]]; then
  if [[ "${PNAP_VCENTER_SUPPORT_CONFIRMED:-}" != YES || "${VCSA_DEPLOY_APPROVED:-}" != YES ]]; then
    echo "Required approvals: PNAP_VCENTER_SUPPORT_CONFIRMED=YES and VCSA_DEPLOY_APPROVED=YES" >&2; exit 1
  fi
  if [[ "${ASHBURN_NONINTERACTIVE:-}" == YES ]]; then
    echo "Non-interactive VCSA deployment approved by the lab automation."
  else
    read -r -p "Deploy VCSA on ESXi $ASHBURN_ESXI_IP? Type DEPLOY-VCENTER: " ack
    [[ "$ack" == DEPLOY-VCENTER ]] || { echo "Cancelled."; exit 1; }
  fi
fi
export VCSA_STAGE="$stage"
if [[ "$stage" == deploy ]]; then
  export VCSA_DEPLOY_RUN_ID="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  echo "Showing VMware task progress during deployment (no passwords/log contents)."
  echo "Firstboot can reach 100% before the installer has fully finalized."
  # The VMware CLI has occasionally returned nonzero after reporting full
  # deployment success. Never rerun it automatically: reconcile the exact
  # current run's private log plus ESXi VM and authenticated vCenter state.
  if python3 ashburn/scripts/vcsa-progress.py \
    --installer-ip "$INSTALLER_IP" \
    --known-hosts "$ASHBURN_INSTALLER_KNOWN_HOSTS" \
    --run-id "$VCSA_DEPLOY_RUN_ID" -- \
    ashburn/.venv/bin/ansible-playbook -i 'localhost,' -c local ashburn/ansible/vcsa.yml; then
    echo "VCSA deployment completed (Ansible exit 0)."
  else
    deploy_rc=$?
    echo "VCSA installer exited $deploy_rc. Checking for a completed appliance before declaring failure." >&2
    echo "Only read-only health checks are retried. The VM will NOT be redeployed." >&2
    config_path="private/vcsa-config-ashburn.json"
    if [[ ! -f "$config_path" ]] || ! vcsa_ip="$(jq -er '.new_vcsa.network.ip' "$config_path")"; then
      echo "No current VCSA configuration to verify. Run vcsa.sh diagnose and inspect." >&2
      exit "$deploy_rc"
    fi
    if python3 ashburn/scripts/vcsa-verify.py \
      --installer-ip "$INSTALLER_IP" \
      --vcsa-ip "$vcsa_ip" \
      --known-hosts "$ASHBURN_INSTALLER_KNOWN_HOSTS" \
      --run-id "$VCSA_DEPLOY_RUN_ID"; then
      echo "VCSA installation validated despite a nonzero installer exit. Safe to proceed to host registration."
    else
      echo "STOP: VCSA health not conclusively verified. Run vcsa.sh inspect and diagnose." >&2
      exit "$deploy_rc"
    fi
  fi
else
  ashburn/.venv/bin/ansible-playbook -i 'localhost,' -c local ashburn/ansible/vcsa.yml
fi
