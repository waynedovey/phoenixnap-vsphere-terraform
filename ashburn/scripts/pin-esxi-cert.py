#!/usr/bin/env python3
"""Trust-on-first-use (TOFU) ESXi TLS certificate pin, scoped to PhoenixNAP server ID.

This removes manual VCSA_ESXI_CERT_SHA256 exports without disabling later
certificate-change detection. First-use pinning is NOT independent verification
of ESXi identity: for higher assurance compare the displayed fingerprint using
a trusted PhoenixNAP management channel before precheck/deploy.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import socket
import ssl
import sys
from urllib.parse import urlsplit


def fingerprint_for(url):
    target = urlsplit(url)
    if (target.scheme != "https" or not target.hostname or target.username
            or target.password or target.query or target.fragment
            or target.path not in ("", "/")):
        raise ValueError("Expected a plain HTTPS ESXi management URL without credentials")
    host = target.hostname
    port = target.port or 443

    # ESXi uses a self-signed certificate. Retrieve DER without CA validation,
    # then compare against the local, server-ID-specific saved fingerprint.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((host, port), timeout=15) as sock:
        with context.wrap_socket(sock, server_hostname=host) as tls:
            cert_der = tls.getpeercert(binary_form=True)
    if not cert_der:
        raise ValueError("ESXi presented no TLS certificate")
    return hashlib.sha256(cert_der).hexdigest()


def pin_fingerprint(server_id, fingerprint, pin_dir):
    if not re.fullmatch(r"[0-9a-fA-F]{24}", server_id):
        raise ValueError("Invalid PhoenixNAP ESXi server ID")
    if not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise ValueError("Invalid ESXi certificate SHA-256")
    pin_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if pin_dir.is_symlink():
        raise ValueError("Certificate pin directory must not be a symlink")
    path = pin_dir / f"esxi-{server_id.lower()}.sha256"
    if path.is_symlink():
        raise ValueError("ESXi certificate pin must not be a symlink")

    if path.exists():
        expected = path.read_text(encoding="ascii").strip().replace(":", "").lower()
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError(f"Malformed ESXi certificate pin at {path}")
        if expected != fingerprint:
            raise ValueError(
                f"ESXi TLS certificate changed for server {server_id}! "
                f"Saved: {expected}; observed: {fingerprint}. "
                f"STOP: investigate before changing {path}."
            )
        print(f"ESXi TLS certificate matches existing per-server pin: {path}", file=sys.stderr)
    else:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            # A competing invocation may have just saved a pin.
            return pin_fingerprint(server_id, fingerprint, pin_dir)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write(fingerprint + "\n")
        print(f"New ESXi certificate pinned (trust on first use) for server {server_id}", file=sys.stderr)
        print(f"Fingerprint: SHA256:{fingerprint}", file=sys.stderr)
        print(f"Stored in {path}; first-use identity has NOT been independently verified.", file=sys.stderr)
    return fingerprint


def main():
    parser = argparse.ArgumentParser(description="Pin ESXi TLS certificate per PhoenixNAP server ID")
    parser.add_argument("--url", required=True, help="Terraform ESXi management URL")
    parser.add_argument("--server-id", required=True, help="PhoenixNAP ESXi server ID")
    parser.add_argument("--pin-dir", default="private/certs")
    args = parser.parse_args()
    try:
        current = fingerprint_for(args.url)
        print(pin_fingerprint(args.server_id, current, Path(args.pin_dir)))
        return 0
    except (OSError, ValueError, UnicodeError) as exc:
        print(f"ESXi certificate pinning failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
