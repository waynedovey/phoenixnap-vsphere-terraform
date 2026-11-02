#!/usr/bin/env bash
# Retire ONLY the Terraform-managed temporary Ashburn VCSA installer.
# Never delete ESXi, datastore1, the VCSA VM, or the dedicated ESXi /29.
set -Eeuo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
tf=ashburn

mode="${1:-manual}"
case "$mode" in
  manual|--yes) ;;
  *) echo "Usage: bash ashburn/scripts/retire-installer.sh [--yes]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Too many arguments." >&2; exit 2; }

for cmd in terraform jq python3; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }
done

# Read the managed resource instances from Terraform state, not root outputs.
# An existing workspace can have valid resources but missing/stale output values.
# Never run terraform apply merely to refresh outputs before verifying deletion.
if ! state_json="$(terraform -chdir="$tf" state pull)"; then
  echo "STOP: cannot read Ashburn Terraform state; no deletion attempted." >&2
  exit 1
fi

# Require exactly one real ESXi resource so an empty/wrong state cannot pass.
if ! esxi_id="$(jq -er '
  [.resources[]? | select(.mode == "managed" and .type == "pnap_server" and .name == "esxi")
   | .instances[]?.attributes.id | select(type == "string")]
  | if length == 1 then .[0] else empty end
' <<<"$state_json")"; then
  echo "STOP: expected one managed Ashburn ESXi server in Terraform state." >&2
  exit 1
fi
[[ "$esxi_id" =~ ^[a-f0-9]{24}$ ]] || {
  echo "STOP: ESXi state identifier is invalid; no deletion attempted." >&2
  exit 1
}

# Keep the user's terraform.tfvars unchanged. Terraform automatically loads
# *.auto.tfvars AFTER terraform.tfvars, so an ignored lifecycle override can
# prevent a retired temporary server from being recreated on the next apply.
tfvars="$root/ashburn/terraform.tfvars"
[[ -f "$tfvars" && ! -L "$tfvars" ]] || {
  echo "STOP: missing or unsafe ashburn/terraform.tfvars." >&2
  exit 1
}
python3 - "$tfvars" <<'PY'
from pathlib import Path
import re
import sys
lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
matches = [line for line in lines if re.fullmatch(
    r'[ \t]*enable_installer[ \t]*=[ \t]*(true|false)[ \t]*(?:#.*)?', line)]
if len(matches) != 1:
    sys.exit("STOP: expected one active enable_installer assignment in terraform.tfvars")
PY

override="$root/ashburn/zz-installer-retired.auto.tfvars"
persist_retirement() {
  # Fail closed on an unexpected local override or symlink. Never overwrite a
  # user file or mutate ashburn/terraform.tfvars.
  python3 - "$override" <<'PY'
from pathlib import Path
import os
import sys
path = Path(sys.argv[1])
expected = ("# Managed by ashburn/scripts/retire-installer.sh.\n"
            "# Temporary VCSA installer retired; terraform.tfvars is unchanged.\n"
            "enable_installer = false\n")
if path.is_symlink():
    sys.exit("STOP: installer retirement override is a symlink")
if path.exists():
    if not path.is_file() or path.read_text(encoding="utf-8") != expected:
        sys.exit("STOP: unexpected retirement override contents; inspect manually")
else:
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(expected)
PY
  # Prove the override has the expected effect without modifying infrastructure.
  local effective
  effective="$(printf 'var.enable_installer\n' | terraform -chdir="$tf" console -no-color)" || {
    echo "STOP: cannot evaluate installer lifecycle override." >&2
    return 1
  }
  [[ "$effective" == false ]] || {
    echo "STOP: installer lifecycle override did not disable Terraform provisioning." >&2
    return 1
  }
}

# Resolve ONLY the temporary installer with the expected resource name.
# Absent is an idempotent no-op; duplicate or unexpected instances fail closed.
if ! installer_records="$(jq -ce '
  [.resources[]? | select(.mode == "managed" and .type == "pnap_server" and .name == "installer")
   | .instances[]?.attributes
   | {id, hostname, location, delete_ip_blocks}]
' <<<"$state_json")"; then
  echo "STOP: cannot identify temporary installer in Terraform state." >&2
  exit 1
fi
installer_count="$(jq -r 'length' <<<"$installer_records")"
if [[ "$installer_count" == 0 ]]; then
  # On a repeated registration, retain disabled desired state even though the
  # installer no longer exists. Never create an unwanted Ubuntu server later.
  persist_retirement
  echo "Installer already absent; lifecycle override persists without changing terraform.tfvars."
  exit 0
fi
if [[ "$installer_count" != 1 ]]; then
  echo "STOP: expected exactly one installer resource, got $installer_count." >&2
  exit 1
fi
if ! server_id="$(jq -er '
  .[0] | select(.hostname == "vcsa-installer-ash"
                and .location == "ASH" and .delete_ip_blocks == true)
  | .id | select(type == "string")
' <<<"$installer_records")"; then
  echo "STOP: installer identity or networking differs from expected Ashburn server." >&2
  exit 1
fi
[[ "$server_id" =~ ^[a-f0-9]{24}$ ]] || {
  echo "STOP: unexpected installer server ID; no deletion attempted." >&2
  exit 1
}
echo "Found temporary installer from Terraform managed state: $server_id"

plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/ash-installer-retire.XXXXXXXX")"
trap 'rm -f -- "$plan_dir/retire.tfplan"; rmdir -- "$plan_dir" 2>/dev/null || true' EXIT

# The saved plan is explicit about removing the installer; never rely on
# implicit -destroy or -target, and reject all unrelated drift or changes.
terraform -chdir="$tf" plan -input=false -lock-timeout=30s \
  -var='enable_installer=false' -out="$plan_dir/retire.tfplan"

terraform -chdir="$tf" show -json "$plan_dir/retire.tfplan" |
  jq -e --arg id "$server_id" '
    [(.resource_changes // [])[]
     | select(.change.actions != ["no-op"])
     | {address, actions: .change.actions, id: .change.before.id,
        hostname: .change.before.hostname, location: .change.before.location,
        delete_ip_blocks: .change.before.delete_ip_blocks}]
    == [{address: "pnap_server.installer[0]", actions: ["delete"],
         id: $id, hostname: "vcsa-installer-ash", location: "ASH",
         delete_ip_blocks: true}]
  ' >/dev/null || {
    echo "STOP: Terraform plan is NOT an installer-only deletion. No changes applied." >&2
    exit 1
  }

echo "Verified plan: destroy only vcsa-installer-ash (PhoenixNAP ID $server_id)."
echo "ESXi host, vcsa-ash VM, datastore1 and ESXi /29 are not in the deletion plan."

if [[ "$mode" != --yes ]]; then
  echo "WARNING: this permanently destroys the temporary Ubuntu server and its local ISO/logs."
  read -r -p "Type 'DESTROY $server_id' to continue: " answer
  [[ "$answer" == "DESTROY $server_id" ]] || {
    echo "Cancelled; no changes applied."
    exit 1
  }
fi

# Persist the ignored, auto-loaded Terraform override BEFORE applying the
# already verified saved plan. Even if apply is interrupted, future plans will
# not recreate a retired installer. User terraform.tfvars remains unchanged.
persist_retirement

terraform -chdir="$tf" apply -input=false -lock-timeout=30s "$plan_dir/retire.tfplan"

# A successful provider operation must also be reflected in Terraform state.
# Verify state retrieval succeeded; do not mistake an API/state failure for success.
if ! remaining_state="$(terraform -chdir="$tf" state list)"; then
  echo "STOP: unable to verify updated Terraform state; check PhoenixNAP portal." >&2
  exit 1
fi
if grep -Fxq 'pnap_server.installer[0]' <<< "$remaining_state"; then
  echo "WARNING: installer still appears in Terraform state; check PhoenixNAP portal." >&2
  exit 1
fi
echo "Installer retired. Ignored ashburn/zz-installer-retired.auto.tfvars prevents reprovisioning."\necho "User ashburn/terraform.tfvars was NOT modified."
echo "Verify PhoenixNAP Servers / IP allocations and billing are updated."
