#!/usr/bin/env python3
"""Run Broadcom's VCSA 8 CLI installer using its own JSON deployment template.

No VCSA software is bundled. Passwords are injected from environment variables
into a temporary mode-0600 JSON file, deleted after the command exits.
This script NEVER runs as part of terraform apply.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


REQUIRED_PASSWORD_ENVS = {
    "ESXI_ROOT_PASSWORD": ("new_vcsa", "esxi", "password"),
    "VCSA_ROOT_PASSWORD": ("new_vcsa", "os", "password"),
    "VCSA_SSO_PASSWORD": ("new_vcsa", "sso", "password"),
}

REQUIRED_SETTINGS = {
    "ESXi host address": ("new_vcsa", "esxi", "hostname"),
    "ESXi port group": ("new_vcsa", "esxi", "deployment_network"),
    "ESXi datastore": ("new_vcsa", "esxi", "datastore"),
    "VCSA VM name": ("new_vcsa", "appliance", "name"),
    "VCSA FQDN": ("new_vcsa", "network", "system_name"),
    "VCSA static IP": ("new_vcsa", "network", "ip"),
    "VCSA prefix": ("new_vcsa", "network", "prefix"),
    "VCSA gateway": ("new_vcsa", "network", "gateway"),
    "VCSA DNS": ("new_vcsa", "network", "dns_servers"),
    "VCSA NTP": ("new_vcsa", "os", "ntp_servers"),
    "SSO domain": ("new_vcsa", "sso", "domain_name"),
}


def get_nested(tree, path):
    current = tree
    for key in path:
        if not isinstance(current, dict) or key not in current:
            raise ValueError(f"Missing template field: {'.'.join(path)}")
        current = current[key]
    return current


def set_nested(tree, path, value):
    parent = get_nested(tree, path[:-1])
    if not isinstance(parent, dict) or path[-1] not in parent:
        raise ValueError(f"Missing template field: {'.'.join(path)}")
    parent[path[-1]] = value


def render_config(template_path, env):
    with open(template_path, encoding="utf-8") as source:
        config = json.load(source)

    if not isinstance(config, dict) or "new_vcsa" not in config:
        raise ValueError("Use Broadcom's VCSA 8 *install* template for ESXi, not an upgrade template.")

    for label, path in REQUIRED_SETTINGS.items():
        value = get_nested(config, path)
        if value is None or value == "" or value == [] or (
            isinstance(value, str)
            and (value.strip().startswith(("FILL_", "YOUR_", "<", "CHANGE_")) or value.strip() in {"localhost", "0.0.0.0"})
        ):
            raise ValueError(f"Fill in {label} ({'.'.join(path)}) before running.")

    if get_nested(config, ("new_vcsa", "network", "mode")) != "static":
        raise ValueError("VCSA must use a reserved, reachable static IP.")
    if get_nested(config, ("new_vcsa", "esxi", "datastore")) != "datastore1":
        raise ValueError("Expected initial datastore 'datastore1'. Confirm disks before changing this.")

    missing = [name for name in REQUIRED_PASSWORD_ENVS if not env.get(name)]
    if missing:
        raise ValueError("Set these password environment variables: " + ", ".join(missing))
    for name, path in REQUIRED_PASSWORD_ENVS.items():
        set_nested(config, path, env[name])

    return config


def installer_executable(iso_root):
    platforms = {"darwin": "mac", "linux": "lin64", "win32": "win32"}
    platform_dir = platforms.get(sys.platform)
    if not platform_dir:
        raise ValueError(f"Unsupported workstation: {sys.platform}")
    binary = "vcsa-deploy.exe" if platform_dir == "win32" else "vcsa-deploy"
    path = iso_root / "vcsa-cli-installer" / platform_dir / binary
    if not path.is_file():
        raise ValueError(f"Installer not found: {path}. Mount a legitimate VMware VCSA 8 ISO.")
    return path


def main():
    parser = argparse.ArgumentParser(description="VCSA 8 CLI bootstrap with private temporary JSON")
    parser.add_argument("action", choices=("check", "precheck", "deploy"))
    parser.add_argument("--template", default=os.environ.get("VCSA_CONFIG", "private/vcsa-config.json"))
    parser.add_argument("--installer-dir", default=os.environ.get("VCSA_INSTALLER_DIR"))
    args = parser.parse_args()

    try:
        config = render_config(Path(args.template), os.environ)
        print("VCSA template structure and required environment variables: OK.")

        if args.action == "check":
            print("Local check complete. No API call, installation or charge was made.")
            return 0

        if not args.installer_dir:
            raise ValueError("Set VCSA_INSTALLER_DIR to the mounted VCSA 8 ISO root.")
        installer = installer_executable(Path(args.installer_dir).expanduser())

        if args.action == "deploy":
            if os.environ.get("PNAP_VCENTER_SUPPORT_CONFIRMED") != "YES":
                raise ValueError("Set PNAP_VCENTER_SUPPORT_CONFIRMED=YES only after written phoenixNAP confirmation.")
            if os.environ.get("VCSA_DEPLOY_APPROVED") != "YES":
                raise ValueError("Set VCSA_DEPLOY_APPROVED=YES only after explicit deployment approval.")
            if input("Type DEPLOY-VCENTER to create a vCenter VM: ").strip() != "DEPLOY-VCENTER":
                print("Cancelled.")
                return 1

        # TemporaryDirectory is private on POSIX. JSON itself uses mode 0600.
        with tempfile.TemporaryDirectory(prefix="vcsa-") as temporary:
            rendered = Path(temporary) / "install.json"
            fd = os.open(str(rendered), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as outfile:
                json.dump(config, outfile, indent=2)

            command = [str(installer), "install", "--accept-eula", "--acknowledge-ceip"]
            if args.action == "precheck":
                command.append("--precheck-only")
            command.append(str(rendered))
            print("Running VMware CLI installer: " + args.action)
            print("Its logs might include connection details. Keep them private.")
            return subprocess.run(command, check=False).returncode
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"VCSA: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
