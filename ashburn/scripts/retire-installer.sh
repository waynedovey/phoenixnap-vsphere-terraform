#!/usr/bin/env bash
# Explicitly destroy the temporary Ubuntu BMC only; retain ESXi and its /29.
set -euo pipefail

cd "$(dirname "$0")/../.."
TF_CHDIR="ashburn"

SERVER_ID="$(terraform -chdir="$TF_CHDIR" output -raw installer_id 2>/dev/null || true)"
if [[ -z "$SERVER_ID" || "$SERVER_ID" == "null" ]]; then
  echo "No temporary installer server in Ashburn Terraform state."
  exit 0
fi
ESXI_ID="$(terraform -chdir="$TF_CHDIR" output -raw esxi_id 2>/dev/null || true)"
if [[ -z "$ESXI_ID" || "$ESXI_ID" == "null" ]]; then
  echo "STOP: ESXi is absent from Ashburn state. Manual review required." >&2
  exit 1
fi

PLAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ash-installer-retire.XXXXXXXX")"
trap 'rm -f -- "$PLAN_DIR/retire.tfplan"; rmdir -- "$PLAN_DIR"' EXIT
terraform -chdir="$TF_CHDIR" plan -var='enable_installer=false' -out="$PLAN_DIR/retire.tfplan"
terraform -chdir="$TF_CHDIR" show -json "$PLAN_DIR/retire.tfplan" |
  jq -e '[.resource_changes[] | select(.change.actions != ["no-op"])
        | {address: .address, actions: .change.actions}]
        == [{address: "pnap_server.installer[0]", actions: ["delete"]}]' >/dev/null || {
    echo "STOP: plan changes resources other than the installer. Nothing applied." >&2
    exit 1
  }

terraform -chdir="$TF_CHDIR" show "$PLAN_DIR/retire.tfplan"
echo "WARNING: this permanently deletes the temporary Ubuntu BMC host and its local data."
read -r -p "To retire only installer $SERVER_ID, type 'DESTROY $SERVER_ID': " ACK
if [[ "$ACK" != "DESTROY $SERVER_ID" ]]; then
  echo "Cancelled."
  exit 1
fi
terraform -chdir="$TF_CHDIR" apply "$PLAN_DIR/retire.tfplan"
echo "Verify the temporary server's default public IP allocation is no longer billed."
