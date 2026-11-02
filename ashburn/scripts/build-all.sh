#!/usr/bin/env bash
# One-command, non-interactive Ashburn Terraform -> ESXi -> VCSA -> registration.
# Requires a preapproved tfvars, PhoenixNAP credentials and an ignored local secret.
set -Eeuo pipefail
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 0 ]] || die "No arguments accepted: bash ashburn/scripts/build-all.sh"

for cmd in terraform jq govc python3 ssh scp curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing $cmd. Install prerequisites first."
done
[[ -r "$HOME/.pnap/config.yaml" ]] || die "Missing ~/.pnap/config.yaml with PhoenixNAP client credentials."

# Never commit or print passwords. A local ignored file is required because
# this script is stored in a potentially public GitHub repository.
password_file="$root/private/ashburn-lab-password"
[[ -f "$password_file" && -r "$password_file" && -s "$password_file" ]] ||
  die "Missing private/ashburn-lab-password (a local git-ignored file, mode 600)."
[[ ! -L "$password_file" ]] || die "Password file must not be a symbolic link."
file_mode="$(stat -f %Lp "$password_file" 2>/dev/null || stat -c %a "$password_file")"
[[ "$file_mode" == 600 || "$file_mode" == 400 ]] || die "Set password file permissions to 600."
IFS= read -r password < "$password_file" || [[ -n "${password:-}" ]]
[[ -n "${password:-}" && "${#password}" -ge 8 ]] || die "Lab password is empty or too short."
export VCSA_ROOT_PASSWORD="$password" VCSA_SSO_PASSWORD="$password"
unset password
export ASHBURN_NONINTERACTIVE=YES
export TF_IN_AUTOMATION=1 TF_INPUT=0 PIP_NO_INPUT=1 HOMEBREW_NO_AUTO_UPDATE=1
# Prevent stale environment creds from overriding ~/.pnap/config.yaml.
unset PNAP_CLIENT_ID PNAP_CLIENT_SECRET

[[ -f ashburn/terraform.tfvars ]] || {
  cp ashburn/terraform.tfvars.example ashburn/terraform.tfvars
  chmod 600 ashburn/terraform.tfvars
  die "Created ashburn/terraform.tfvars. Enable servers and record real provider, retirement and cost approvals before retrying."
}

say "Validate Ashburn config (nothing will be deleted or replaced)"
terraform -chdir=ashburn init -input=false -no-color
terraform -chdir=ashburn validate -no-color

# These checks ensure a noninteractive invocation never invents attestations.
tf_bool() {
  printf 'var.%s\n' "$1" | terraform -chdir=ashburn console -no-color | tr -d '[:space:]'
}
for flag in enable_esxi confirm_seattle_retired confirm_esxi_image approve_hourly_costs; do
  [[ "$(tf_bool "$flag")" == true ]] ||
    die "ashburn/terraform.tfvars: $flag must be true after independently confirming the prerequisite."
done

# The user keeps enable_installer=true in terraform.tfvars as the initial-build
# choice. Post-registration cleanup persists an ignored .auto.tfvars override
# instead of mutating that file. Terraform loads this override automatically.
python3 - ashburn/terraform.tfvars <<'PY'
from pathlib import Path
import re
import sys
lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
values = [m.group(1) for line in lines
          if (m := re.fullmatch(
              r'[ \t]*enable_installer[ \t]*=[ \t]*(true|false)[ \t]*(?:#.*)?',
              line))]
if values != ["true"]:
    sys.exit("STOP: initial-build setting enable_installer must remain true in terraform.tfvars")
PY

retired_override="$root/ashburn/zz-installer-retired.auto.tfvars"
if [[ -e "$retired_override" || -L "$retired_override" ]]; then
  [[ -f "$retired_override" && ! -L "$retired_override" ]] ||
    die "Retirement override is not a regular file."
  [[ "$(tf_bool enable_installer)" == false ]] ||
    die "Expected retired installer lifecycle override to disable effective Terraform variable."
  # This is a completed lab path, not authorization to tear down or recreate
  # resources. If cleanup was interrupted, rerun register-esxi.sh instead.
  existing_resources="$(terraform -chdir=ashburn state list)" ||
    die "Cannot inspect Ashburn state for completed installer retirement."
  grep -Fxq 'pnap_server.esxi[0]' <<< "$existing_resources" ||
    die "Retirement marker found but ESXi is missing from Terraform state; manual review required."
  if grep -Fxq 'pnap_server.installer[0]' <<< "$existing_resources"; then
    die "Temporary installer still exists in state. Rerun register-esxi.sh to finish guarded cleanup."
  fi
  say "Previously completed lab: installer lifecycle override active; preserve existing vCenter"
else
  [[ "$(tf_bool enable_installer)" == true ]] ||
    die "enable_installer must be true for initial provisioning."
fi
# A real PNAP confirmation is still required; don't silently self-certify it.
[[ "${PNAP_VCENTER_SUPPORT_CONFIRMED:-}" == YES ]] ||
  die "PNAP_VCENTER_SUPPORT_CONFIRMED=YES must already be set after provider approval."

# Only permit additions of the expected resources, or no changes at all.
# Replacements, deletions and updates always require separate review.
plan_dir="$(mktemp -d "$root/private/.build-all.XXXXXXXX")"
cleanup() { rm -f -- "$plan_dir/ip.tfplan" "$plan_dir/servers.tfplan"; rmdir -- "$plan_dir" 2>/dev/null || true; }
trap cleanup EXIT
validate_plan() {
  local path="$1" permitted="$2"
  terraform -chdir=ashburn show -json "$path" | jq -e --arg allow "$permitted" '
    [(.resource_changes // [])[]
       | select(.change.actions != ["no-op"])
       | {address, actions: .change.actions}]
    | all(.[]; (.actions == ["create"] and (.address | IN($allow))))
  ' >/dev/null || die "Unexpected Terraform plan actions; no resources were changed by this step."
}

say "Provision public /29 if absent"
terraform -chdir=ashburn plan -input=false -no-color \
  -target='pnap_ip_block.esxi_29[0]' -out="$plan_dir/ip.tfplan"
validate_plan "$plan_dir/ip.tfplan" 'pnap_ip_block.esxi_29[0]'
terraform -chdir=ashburn apply -input=false -no-color -auto-approve "$plan_dir/ip.tfplan"

say "Provision ESXi and temporary Ubuntu installer if absent"
terraform -chdir=ashburn plan -input=false -no-color -out="$plan_dir/servers.tfplan"
terraform -chdir=ashburn show -json "$plan_dir/servers.tfplan" | jq -e '
  [(.resource_changes // [])[]
     | select(.change.actions != ["no-op"])
     | {address, actions: .change.actions}]
  | all(.[]; (.actions == ["create"] and (.address | IN(
       "pnap_server.esxi[0]", "pnap_server.installer[0]"))))
' >/dev/null || die "Server plan includes unexpected changes; nothing applied."
terraform -chdir=ashburn apply -input=false -no-color -auto-approve "$plan_dir/servers.tfplan"

[[ "$(terraform -chdir=ashburn output -raw esxi_id)" =~ ^[a-f0-9]{24}$ ]] || die "ESXi provisioning incomplete."
if [[ ! -f "$retired_override" ]]; then
  # New build: Ubuntu must exist before VCSA preparation.
  managed_installer="$(terraform -chdir=ashburn state pull | jq -er '
    [.resources[]? | select(.mode == "managed" and .type == "pnap_server" and .name == "installer")
     | .instances[]?.attributes.id | select(type == "string")]
    | if length == 1 then .[0] else empty end
  ')" || die "Ubuntu provisioning incomplete."
  [[ "$managed_installer" =~ ^[a-f0-9]{24}$ ]] || die "Invalid installer server ID."
fi

if [[ ! -f "$retired_override" ]]; then
say "Check and, if necessary, configure ESXi time synchronization"
synced=0
for attempt in $(seq 1 20); do
  if ntp_status="$(bash ashburn/scripts/esxi-time.sh check 2>&1)"; then
    if grep -Eiq '^[[:space:]]*Time Synchronized:[[:space:]]*true[[:space:]]*$' <<<"$ntp_status"; then
      synced=1
      break
    fi
    if [[ "${configured_ntp:-0}" == 0 ]]; then
      bash ashburn/scripts/esxi-time.sh configure </dev/null
      configured_ntp=1
    fi
  fi
  sleep 15
done
[[ "$synced" == 1 ]] || die "ESXi NTP is not synchronized; VCSA install halted."
export ESXI_NTP_SYNC_CONFIRMED=YES
else
  say "Existing VCSA: skip fresh-install NTP gate; no new deployment will run"
fi

say "Set up Ansible (once)"
if [[ ! -x ashburn/.venv/bin/ansible-playbook ]]; then
  bash ashburn/scripts/setup-ansible.sh </dev/null
fi

say "Inspect vCenter appliance VM (never overwrite an existing VM)"
# An inherited vCenter datacenter scope must not hide the standalone ESXi.
unset GOVC_DATACENTER GOVC_FOLDER
export GOVC_URL="$(terraform -chdir=ashburn output -raw esxi_management_url)"
export GOVC_URL="${GOVC_URL%/}/sdk" GOVC_USERNAME=root GOVC_INSECURE=1
export GOVC_PASSWORD="$(terraform -chdir=ashburn state pull | jq -er '
  .resources[] | select(.type == "pnap_server" and .name == "esxi")
  | .instances[0].attributes.root_password
')"
existing_vm="$(govc find / -type m -name vcsa-ash)" || die "Cannot query ESXi inventory."
if [[ "$existing_vm" == *
  say "Prepare and precheck new vCenter installation"
  bash ashburn/scripts/vcsa.sh prepare </dev/null
  bash ashburn/scripts/vcsa.sh precheck </dev/null
  say "Install vCenter with live VMware task progress"
  export VCSA_DEPLOY_APPROVED=YES
  bash ashburn/scripts/vcsa.sh deploy </dev/null
else
  say "Existing vcsa-ash VM detected: skip VCSA installation (no overwrite)"
  bash ashburn/scripts/vcsa.sh inspect </dev/null
fi

say "Register ESXi in vCenter"
bash ashburn/scripts/register-esxi.sh </dev/null

vcenter_ip="$(jq -er '.new_vcsa.network.ip' private/vcsa-config-ashburn.json)"
printf '\n========================================\n'
printf '        Ashburn lab ready\n'
printf '========================================\n'
printf 'vCenter URL : https://%s/ui\n' "$vcenter_ip"
printf 'vCenter user: administrator@vsphere.local\n'
printf 'VCSA root   : root (same local password file)\n'
printf 'VCSA SSO    : same local password file (not printed)\n'
printf 'ESXi URL    : %s\n' "$(terraform -chdir=ashburn output -raw esxi_management_url)"
printf 'ESXi user   : root (PhoenixNAP-issued credential in Terraform state)\n'
printf '========================================\n'
\n'* ]]; then
  die "Multiple vcsa-ash VMs found; refusing to guess which appliance is valid."
fi
if [[ -f "$retired_override" && -z "$existing_vm" ]]; then
  die "Retirement override exists but vcsa-ash VM is missing. Stop; never auto-redeploy over an existing lab."
fi
if [[ -z "$existing_vm" ]]; then
  say "Prepare and precheck new vCenter installation"
  bash ashburn/scripts/vcsa.sh prepare </dev/null
  bash ashburn/scripts/vcsa.sh precheck </dev/null
  say "Install vCenter with live VMware task progress"
  export VCSA_DEPLOY_APPROVED=YES
  bash ashburn/scripts/vcsa.sh deploy </dev/null
else
  say "Existing vcsa-ash VM detected: skip VCSA installation (no overwrite)"
  bash ashburn/scripts/vcsa.sh inspect </dev/null
fi

say "Register ESXi in vCenter"
bash ashburn/scripts/register-esxi.sh </dev/null

vcenter_ip="$(jq -er '.new_vcsa.network.ip' private/vcsa-config-ashburn.json)"
printf '\n========================================\n'
printf '        Ashburn lab ready\n'
printf '========================================\n'
printf 'vCenter URL : https://%s/ui\n' "$vcenter_ip"
printf 'vCenter user: administrator@vsphere.local\n'
printf 'VCSA root   : root (same local password file)\n'
printf 'VCSA SSO    : same local password file (not printed)\n'
printf 'ESXi URL    : %s\n' "$(terraform -chdir=ashburn output -raw esxi_management_url)"
printf 'ESXi user   : root (PhoenixNAP-issued credential in Terraform state)\n'
printf '========================================\n'
