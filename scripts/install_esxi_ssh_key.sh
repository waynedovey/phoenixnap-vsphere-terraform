#!/usr/bin/env bash
# Run ON THE MAC. Enables SSH on an ESXi host via vSphere HTTPS and installs
# only ~/.ssh/id_ed25519.pub for root without disclosing the key to GitHub.
# SSH may be disabled again when ESXi restarts; run this on the replacement too.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v govc >/dev/null 2>&1; then
  echo "Install govc first: brew install govc" >&2
  exit 1
fi

PUBLIC_KEY_FILE="${PNAP_ESXI_PUBLIC_KEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
if [[ ! -s "$PUBLIC_KEY_FILE" ]]; then
  echo "Missing laptop SSH public key: $PUBLIC_KEY_FILE" >&2
  exit 1
fi
if ! grep -q '^ssh-ed25519 ' "$PUBLIC_KEY_FILE"; then
  echo "Expected an ssh-ed25519 public key in $PUBLIC_KEY_FILE" >&2
  exit 1
fi

ESXI_IP="${1:-}"
if [[ -z "$ESXI_IP" ]]; then
  ESXI_IP="$(terraform output -raw esxi_public_ip 2>/dev/null || true)"
fi
if [[ ! "$ESXI_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Specify the ESXi IPv4 address, e.g. $0 131.153.165.146" >&2
  exit 1
fi

echo "Target ESXi: $ESXI_IP"
echo "Public key file: $PUBLIC_KEY_FILE (contents will not be printed)"
echo "This starts TSM-SSH over the public interface on a lab host."
echo "WARNING: GOVC_INSECURE=1 skips HTTPS certificate validation for this lab."
read -r -p "Type ENABLE SSH to continue: " ACK
if [[ "$ACK" != "ENABLE SSH" ]]; then
  echo "Cancelled."
  exit 1
fi

export GOVC_URL="https://$ESXI_IP/sdk"
export GOVC_USERNAME="root"
export GOVC_INSECURE="1"

if [[ -z "${GOVC_PASSWORD:-}" ]]; then
  read -r -s -p "ESXi root password (for vSphere HTTPS): " GOVC_PASSWORD
  echo
  export GOVC_PASSWORD
fi

govc about >/dev/null
govc host.service start TSM-SSH
echo "SSH service started. SSH may prompt separately for the same root password."

# Keep existing authorised keys. Pass public key via stdin, rather than
# embedding it in a shell command or logging it. Duplicate-safe.
ssh -o ConnectTimeout=15 -o PubkeyAuthentication=no root@"$ESXI_IP" \
  'umask 077
   mkdir -p /etc/ssh/keys-root
   chmod 700 /etc/ssh/keys-root
   touch /etc/ssh/keys-root/authorized_keys
   chmod 600 /etc/ssh/keys-root/authorized_keys
   IFS= read -r new_key || [ -n "$new_key" ]
   grep -Fqx "$new_key" /etc/ssh/keys-root/authorized_keys ||
     printf "%s\n" "$new_key" >> /etc/ssh/keys-root/authorized_keys' \
  < "$PUBLIC_KEY_FILE"

echo "Verifying key-based ESXi login and reporting host version..."
ssh -o BatchMode=yes -o IdentitiesOnly=yes \
  -i "${PUBLIC_KEY_FILE%.pub}" root@"$ESXI_IP" 'vmware -vl'
echo "Key imported. Repeat after replacement provisioning, using its new IP."
