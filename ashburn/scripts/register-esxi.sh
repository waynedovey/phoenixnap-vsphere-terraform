#!/usr/bin/env bash
# Safely register the Terraform-managed Ashburn ESXi server in the VCSA inventory.
# Does not provision, format storage, delete resources, or modify Seattle state.
set -Eeuo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

for utility in terraform jq govc; do
  if ! command -v "$utility" >/dev/null 2>&1; then
    echo "Missing required command: $utility" >&2
    exit 1
  fi
done

config_path="$repo_root/private/vcsa-config-ashburn.json"
if [[ ! -f "$config_path" ]]; then
  echo "Missing $config_path. Generate the private Ashburn VCSA template first." >&2
  exit 1
fi

export ASHBURN_VCENTER_IP="$(jq -er '.new_vcsa.network.ip' "$config_path")"
export ASHBURN_VCENTER_USERNAME="${ASHBURN_VCENTER_USERNAME:-administrator@vsphere.local}"

esxi_url="$(terraform -chdir="$repo_root/ashburn" output -raw esxi_management_url)"
if [[ ! "$esxi_url" =~ ^https://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?/?$ ]]; then
  echo "Unexpected ESXi management URL from Terraform: $esxi_url" >&2
  exit 1
fi
export ASHBURN_ESXI_IP="${BASH_REMATCH[1]}"

config_esxi_ip="$(jq -er '.new_vcsa.esxi.hostname' "$config_path")"
if [[ "$config_esxi_ip" != "$ASHBURN_ESXI_IP" ]]; then
  echo "Refusing to continue: private VCSA template does not match Ashburn ESXi IP." >&2
  exit 1
fi

export ESXI_ROOT_PASSWORD="$(
  terraform -chdir="$repo_root/ashburn" state pull |
    jq -er '
      .resources[]
      | select(.type == "pnap_server" and .name == "esxi")
      | .instances[0].attributes.root_password
    '
)"
if [[ -z "$ESXI_ROOT_PASSWORD" ]]; then
  echo "ESXi root password is missing from the Ashburn Terraform state." >&2
  exit 1
fi

if [[ -z "${VCSA_SSO_PASSWORD:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "VCSA_SSO_PASSWORD must be supplied when running non-interactively." >&2
    exit 1
  fi
  read -rsp 'vCenter SSO password: ' VCSA_SSO_PASSWORD
  printf '\n'
fi
if [[ -z "$VCSA_SSO_PASSWORD" ]]; then
  echo "vCenter SSO password is required." >&2
  exit 1
fi
export VCSA_SSO_PASSWORD

echo "Target vCenter: $ASHBURN_VCENTER_IP"
echo "Target ESXi: $ASHBURN_ESXI_IP"
echo "Desired Datacenter: Datacenter"
echo "No datastores will be formatted or modified."

# Same Python/collections used by the VCSA workflow, independent of
# whichever system Ansible binary happens to be on PATH.
if [[ ! -x "$repo_root/ashburn/.venv/bin/ansible-playbook" ]]; then
  echo "Missing Ashburn Ansible venv. Run: bash ashburn/scripts/setup-ansible.sh" >&2
  exit 1
fi
# The login information is displayed only after Ansible successfully
# registers and verifies the ESXi host. Never persist passwords or emit them
# into automated logs by default.
"$repo_root/ashburn/.venv/bin/ansible-playbook" -i localhost, -c local "$repo_root/ashburn/ansible/register-esxi.yml"

printf '\n'
printf '%s\n' '========================================'
printf '%s\n' '       vCenter Server Login'
printf '%s\n' '========================================'
printf 'Login URL : https://%s/ui\n' "$ASHBURN_VCENTER_IP"
printf 'Username  : %s\n' "$ASHBURN_VCENTER_USERNAME"
printf '%s\n' 'Password  : [hidden - the VCSA SSO password entered earlier]'
printf '%s\n' '========================================'

# For interactive use, allow an explicit reveal after registration. This is
# the same credential entered above; never discover or invent a password.
# Showing it on screen risks terminal recording and scrollback exposure.
if [[ "${ASHBURN_NONINTERACTIVE:-}" != YES && -t 0 && -t 1 ]]; then
  reveal=''
  read -r -p 'Reveal SSO password on screen? [y/N]: ' reveal || true
  case "$reveal" in
    y|Y|yes|YES)
      printf 'Password  : %s\n' "$VCSA_SSO_PASSWORD"
      printf '%s\n' 'CAUTION: password is visible in terminal scrollback.'
      ;;
  esac
fi
