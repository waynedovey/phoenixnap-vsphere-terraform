#!/usr/bin/env bash
# Orchestrate ISO preparation, precheck, and VCSA deployment using Ansible on Mac.
set -Eeuo pipefail
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
stage="${1:-}"
case "$stage" in
  prepare|precheck|deploy) ;;
  *) echo "Usage: bash ashburn/scripts/vcsa.sh prepare|precheck|deploy" >&2; exit 2 ;;
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
if [[ "$stage" != prepare ]]; then
  : "${VCSA_ESXI_CERT_SHA256:?Set VCSA_ESXI_CERT_SHA256 to the independently verified ESXi certificate SHA-256}"
  [[ "${VCSA_ESXI_CERT_SHA256//:/}" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Invalid ESXi certificate fingerprint." >&2; exit 1; }
  if [[ "${ESXI_NTP_SYNC_CONFIRMED:-}" != YES ]]; then
    echo "STOP: verify ESXi reports 'Time Synchronized: true' using esxcli system ntp get." >&2
    echo "Then set ESXI_NTP_SYNC_CONFIRMED=YES for this lab." >&2
    exit 1
  fi
fi

esxi_url="$(terraform -chdir=ashburn output -raw esxi_management_url)"
if [[ ! "$esxi_url" =~ ^https://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?/?$ ]]; then
  echo "Unexpected ESXi management URL: $esxi_url" >&2; exit 1
fi
export ASHBURN_ESXI_IP="${BASH_REMATCH[1]}"
export GOVC_URL="${esxi_url%/}/sdk"
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
