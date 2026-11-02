#!/usr/bin/env bash
# Orchestrate ISO preparation, precheck, and VCSA deployment using Ansible on Mac.
set -Eeuo pipefail
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
stage="${1:-}"
case "$stage" in
  prepare|precheck|deploy|diagnose) ;;
  *) echo "Usage: bash ashburn/scripts/vcsa.sh prepare|precheck|deploy|diagnose" >&2; exit 2 ;;
esac
for utility in terraform jq govc ssh scp; do
  command -v "$utility" >/dev/null || { echo "Missing $utility" >&2; exit 1; }
done
if [[ ! -x ashburn/.venv/bin/ansible-playbook ]]; then
  echo "Run: bash ashburn/scripts/setup-ansible.sh" >&2; exit 1
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

sensitive = re.compile(r'(?i)(?:password|passwd|secret|token|authorization|credential|private.key|api.key)\s*[:=]')
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
if [[ "$stage" != prepare && "${ESXI_NTP_SYNC_CONFIRMED:-}" != YES ]]; then
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
if [[ "$stage" != prepare ]]; then
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

if [[ "$stage" != prepare ]]; then
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
  read -r -p "Deploy VCSA on ESXi $ASHBURN_ESXI_IP? Type DEPLOY-VCENTER: " ack
  [[ "$ack" == DEPLOY-VCENTER ]] || { echo "Cancelled."; exit 1; }
fi
export VCSA_STAGE="$stage"
ashburn/.venv/bin/ansible-playbook -i 'localhost,' -c local ashburn/ansible/vcsa.yml
