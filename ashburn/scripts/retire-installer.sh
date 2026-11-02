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

# Use JSON output so a null installer ID is handled reliably on repeat runs.
if ! server_id_json="$(terraform -chdir="$tf" output -json installer_id)"; then
  echo "STOP: unable to read Ashburn installer state. No deletion attempted." >&2
  exit 1
fi
if [[ "$server_id_json" == null ]]; then
  echo "No temporary Ashburn installer in Terraform state; nothing to delete."
  exit 0
fi
if ! server_id="$(jq -er 'select(type == "string")' <<<"$server_id_json")"; then
  echo "STOP: invalid installer state output." >&2
  exit 1
fi
if ! [[ "$server_id" =~ ^[a-f0-9]{24}$ ]]; then
  echo "STOP: unexpected installer server ID; no deletion attempted." >&2
  exit 1
fi

esxi_id="$(terraform -chdir="$tf" output -raw esxi_id)"
[[ "$esxi_id" =~ ^[a-f0-9]{24}$ ]] || {
  echo "STOP: ESXi is absent from Ashburn state; no deletion attempted." >&2
  exit 1
}

# Fail closed if Terraform is not tracking exactly the expected ASH Ubuntu BMC.
terraform -chdir="$tf" state pull | jq -e --arg id "$server_id" '
  [.resources[] | select(.mode == "managed" and .type == "pnap_server" and .name == "installer")
   | .instances[]?.attributes
   | select(.id == $id and .hostname == "vcsa-installer-ash"
            and .location == "ASH" and .delete_ip_blocks == true)
  ] | length == 1
' >/dev/null || {
  echo "STOP: server identity or installer network settings differ from expected state." >&2
  exit 1
}

tfvars="$root/ashburn/terraform.tfvars"
[[ -f "$tfvars" && ! -L "$tfvars" ]] || {
  echo "STOP: missing or unsafe ashburn/terraform.tfvars; no deletion attempted." >&2
  exit 1
}

# Confirm the local variable is safely writable BEFORE destroying anything.
# After retirement, leaving enable_installer=true would recreate this server
# during the next normal terraform apply.
python3 - "$tfvars" check <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
pattern = re.compile(r'^([ \t]*enable_installer[ \t]*=[ \t]*)(true|false)([ \t]*(?:#.*)?(?:\r?\n)?)$')
matches = [line for line in lines if pattern.fullmatch(line)]
if len(matches) != 1:
    sys.exit("STOP: expected exactly one uncommented enable_installer = true/false in tfvars")
PY

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

# Keep the ignored tfvars consistent with the desired retired state. Do this
# before applying so an interrupted cleanup cannot accidentally recreate
# the installer during the next Terraform plan. The saved deletion plan has
# already been validated and explicitly sets enable_installer=false.
python3 - "$tfvars" write <<'PY'
from pathlib import Path
import os
import re
import stat
import sys
import tempfile

path = Path(sys.argv[1])
pattern = re.compile(r'^([ \t]*enable_installer[ \t]*=[ \t]*)(true|false)([ \t]*(?:#.*)?(?:\r?\n)?)$')
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
matches = [i for i, line in enumerate(lines) if pattern.fullmatch(line)]
if len(matches) != 1:
    sys.exit("STOP: tfvars changed unexpectedly; no deletion attempted")
i = matches[0]
lines[i] = pattern.sub(r'\g<1>false\g<3>', lines[i])
mode = stat.S_IMODE(path.stat().st_mode)
fd, temp_name = tempfile.mkstemp(prefix=".terraform.tfvars.", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as temp:
        temp.writelines(lines)
        temp.flush()
        os.fsync(temp.fileno())
    os.chmod(temp_name, mode & 0o600)
    os.replace(temp_name, path)
except BaseException:
    try:
        os.unlink(temp_name)
    except OSError:
        pass
    raise
PY

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
echo "Installer retired. enable_installer=false saved in ignored ashburn/terraform.tfvars."
echo "Verify PhoenixNAP Servers / IP allocations and billing are updated."
