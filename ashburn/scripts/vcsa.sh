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
: "${INSTALLER_IP:?Set INSTALLER_IP to the primary public IPv4 of the Ubuntu installer}"
: "${VCSA_ISO_SHA256:?Set VCSA_ISO_SHA256 to your vendor-verified 64-character checksum}"
[[ "$INSTALLER_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Use a single IPv4, not an IP range." >&2; exit 1; }
[[ "$VCSA_ISO_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Invalid SHA-256." >&2; exit 1; }
if [[ "$stage" != prepare ]]; then
  : "${VCSA_ESXI_CERT_SHA256:?Set VCSA_ESXI_CERT_SHA256 to the independently verified ESXi certificate SHA-256}"
  [[ "${VCSA_ESXI_CERT_SHA256//:/}" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Invalid ESXi certificate fingerprint." >&2; exit 1; }
  if [[ "${ESXI_NTP_SYNC_CONFIRMED:-}" != YES ]]; then
    echo "STOP: verify ESXi reports 'Time Synchronized: true' using esxcli system ntp get." >&2
    echo "Then set ESXI_NTP_SYNC_CONFIRMED=YES for this lab." >&2
    exit 1
  fi
fi

installer_id="$(terraform -chdir=ashburn output -raw installer_id)"
esxi_id="$(terraform -chdir=ashburn output -raw esxi_id)"
if [[ -z "$installer_id" || "$installer_id" == null || -z "$esxi_id" || "$esxi_id" == null ]]; then
  echo "ESXi and the installer must be present in Ashburn Terraform state." >&2; exit 1
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
