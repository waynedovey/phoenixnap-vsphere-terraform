#!/usr/bin/env bash
# Operator-approved, two-phase migration from the first /30 server to a /29.
set -euo pipefail

OLD_ESXI_ID="6ae0430e5f894da540fb7126"
OLD_ESXI_IP="131.153.165.146"
MODE="${1:-}"

if [[ "$MODE" != "quote" && "$MODE" != "verify" && "$MODE" != "retire" && "$MODE" != "create" ]]; then
  echo "Usage: bash scripts/rebuild_29.sh quote|verify|retire|create" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

# Dedicated read-only pricing root. Its only blocks are data sources and
# outputs: no billable resources, no root state, no approval preconditions.
if [[ "$MODE" == "quote" ]]; then
  echo "Reading public-IP SKUs and pricing across all locations (including GLOBAL)."
  echo "This configuration has NO managed resources and cannot purchase IPs."
  terraform -chdir=quote init -backend=false -input=false
  terraform -chdir=quote validate
  terraform -chdir=quote plan -input=false -no-color
  echo "Please share public_ip_catalog and seattle_server_plans before any retire/create action."
  exit 0
fi

terraform validate

PLAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pnap29-${MODE}.XXXXXXXX")"
PLAN_FILE="$PLAN_DIR/plan.tfplan"
QUOTE_FILE="$PLAN_DIR/quote.tfplan"
trap 'rm -f -- "$PLAN_FILE" "$QUOTE_FILE"; rmdir -- "$PLAN_DIR"' EXIT

quote_only() {
  echo "Checking the live account-specific Seattle quote; this plan will NOT be applied."
  terraform plan \
    -var='enable_provisioning=true' \
    -var='confirm_previous_server_retired=true' \
    -var='approve_hourly_costs=true' \
    -out="$QUOTE_FILE"
  python3 scripts/check_29_plan.py quote "$QUOTE_FILE"
  echo "Quote passed. Any server/network changes shown above are a PREVIEW ONLY."
}

if [[ "$MODE" == "verify" ]]; then
  quote_only
  echo "Verified: pricing and approved /29 SKU passed; no Terraform plan was applied."
  exit 0
fi

if [[ "$MODE" == "retire" ]]; then
  # Price-check the future /29 before permanently deleting the old host.
  quote_only
  CURRENT_ID="$(terraform output -raw esxi_server_id 2>/dev/null || true)"
  if [[ "$CURRENT_ID" != "$OLD_ESXI_ID" ]]; then
    echo "STOP: current state server ID '$CURRENT_ID' does not match expected $OLD_ESXI_ID" >&2
    exit 1
  fi

  terraform plan -var='enable_provisioning=false' -out="$PLAN_FILE"
  python3 scripts/check_29_plan.py retire "$PLAN_FILE"
  terraform show "$PLAN_FILE"
  echo "WARNING: this permanently deletes ESXi host $OLD_ESXI_IP and its VMs/datastores."
  read -r -p "To confirm, type 'DESTROY $OLD_ESXI_ID': " ACK
  if [[ "$ACK" != "DESTROY $OLD_ESXI_ID" ]]; then
    echo "Cancelled."
    exit 1
  fi
  terraform apply "$PLAN_FILE"
  echo "Retired. Verify in phoenixNAP that the previous /30 allocation has also been deleted and is no longer billing."
  echo "Then run: bash scripts/rebuild_29.sh create"
else
  if terraform state list | grep -Fqx 'pnap_server.esxi[0]'; then
    echo "STOP: ESXi remains in Terraform state; run 'retire' first." >&2
    exit 1
  fi

  echo "Confirm phoenixNAP shows the previous server $OLD_ESXI_ID and its /30 IP block as deleted."
  read -r -p "Type 'OLD IP RELEASED' to continue: " ACK
  if [[ "$ACK" != "OLD IP RELEASED" ]]; then
    echo "Cancelled."
    exit 1
  fi

  terraform plan \
    -var='enable_provisioning=true' \
    -var='confirm_previous_server_retired=true' \
    -var='approve_hourly_costs=true' \
    -out="$PLAN_FILE"
  python3 scripts/check_29_plan.py create "$PLAN_FILE"
  terraform show "$PLAN_FILE"

  echo "WARNING: approving this will purchase an hourly /29 and create a new, billable ESXi host."
  read -r -p "To approve purchase and deployment, type 'BUY SEA /29': " ACK
  if [[ "$ACK" != "BUY SEA /29" ]]; then
    echo "Cancelled."
    exit 1
  fi
  terraform apply "$PLAN_FILE"
  terraform output esxi_management_url
  terraform output esxi_public_ip
  terraform output seattle_public_ipv4_cidr
  echo "After deployment, select an unused /29 address for vCenter and configure its gateway, port group and DNS."
fi
