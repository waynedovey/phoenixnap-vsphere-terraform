#!/usr/bin/env bash
# Check or explicitly configure the ESXi host's NTP without enabling SSH.
# Run with: bash ashburn/scripts/esxi-time.sh check|configure
set -Eeuo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

mode="${1:-check}"
case "$mode" in
  check|configure) ;;
  *) echo "Usage: bash ashburn/scripts/esxi-time.sh check|configure" >&2; exit 2 ;;
esac
for cmd in terraform jq govc; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

esxi_url="$(terraform -chdir=ashburn output -raw esxi_management_url)"
[[ "$esxi_url" == https://* ]] || { echo "ESXi management URL is missing." >&2; exit 1; }
export GOVC_URL="${esxi_url%/}/sdk" GOVC_USERNAME=root GOVC_INSECURE=1
export GOVC_PASSWORD="$(terraform -chdir=ashburn state pull | jq -er '
  .resources[]
  | select(.type == "pnap_server" and .name == "esxi")
  | .instances[0].attributes.root_password
')"
trap 'unset GOVC_PASSWORD' EXIT

echo "ESXi: ${esxi_url%/}"
if [[ "$mode" == configure ]]; then
  echo "This changes ESXi NTP servers to 0.pool.ntp.org and 1.pool.ntp.org."
  echo "Confirm your network permits UDP 123 to these servers."
  read -r -p "Type CONFIGURE-ESXI-NTP to continue: " approval
  [[ "$approval" == CONFIGURE-ESXI-NTP ]] || { echo "Cancelled."; exit 1; }
  govc host.esxcli system ntp set -s 0.pool.ntp.org -s 1.pool.ntp.org -e 1
fi

govc host.esxcli system ntp get
echo
echo "Required before VCSA precheck or deploy: Time Synchronized: true."
echo "If still false after NTP server changes, recheck and investigate; do not deploy."
