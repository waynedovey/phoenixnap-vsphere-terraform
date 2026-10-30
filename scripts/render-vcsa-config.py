#!/usr/bin/env python3
"""Render a vendor VCSA 8 ESXi-install template from the current Ashburn outputs.

No credentials are read or embedded; scripts/vcsa.py injects them at runtime.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse


def field(obj, keys):
    for key in keys:
        if not isinstance(obj, dict) or key not in obj:
            raise ValueError(f"Vendor template lacks required field: {'.'.join(keys)}")
        obj = obj[key]
    return obj


def assign(obj, keys, value):
    parent = field(obj, keys[:-1])
    if not isinstance(parent, dict) or keys[-1] not in parent:
        raise ValueError(f"Vendor template lacks required field: {'.'.join(keys)}")
    parent[keys[-1]] = value


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--template", type=Path, required=True,
                    help="Original vendor embedded_vCSA_on_ESXi.json")
    ap.add_argument("--output", type=Path, default=Path("private/vcsa-config-ashburn.json"))
    ap.add_argument("--stack", type=Path, default=Path("ashburn"))
    ap.add_argument("--dns", action="append", default=[], help="DNS IP (repeatable)")
    ap.add_argument("--time-source", choices=("host", "ntp"), default="host",
                    help="Time source: synced ESXi host (default) or explicit NTP")
    ap.add_argument("--ntp", default="pool.ntp.org",
                    help="NTP server when --time-source=ntp")
    ap.add_argument("--portgroup", required=True,
                    help="Existing PhoenixNAP ESXi public.<VLAN> port group")
    args = ap.parse_args()

    if not args.portgroup.startswith("public.") or not args.portgroup[7:].isdigit():
        raise ValueError("Port group must be an existing PhoenixNAP public.<VLAN> network")
    if args.time_source == "ntp" and not args.ntp.strip():
        raise ValueError("Supply an NTP server when --time-source=ntp")

    if args.output.exists():
        raise ValueError(f"Output exists: {args.output}; archive it before a new lab")

    process = subprocess.run(
        ["terraform", f"-chdir={args.stack}", "output", "-json"],
        check=True, text=True, capture_output=True,
    )
    outputs = json.loads(process.stdout)
    cidr = outputs["public_ipv4_29_cidr"]["value"]
    esxi_url = outputs["esxi_management_url"]["value"]
    subnet = ipaddress.ip_network(cidr, strict=True)
    esxi = ipaddress.ip_address(urlparse(esxi_url).hostname)
    if subnet.version != 4 or subnet.prefixlen != 29 or esxi != subnet.network_address + 2:
        raise ValueError("Unexpected subnet/ESXi placement; inspect PhoenixNAP IP allocation")

    gateway = subnet.network_address + 1
    vcsa = subnet.network_address + 3
    dns = args.dns or ["1.1.1.1", "8.8.8.8"]
    for address in dns:
        if ipaddress.ip_address(address).version != 4:
            raise ValueError("VCSA DNS servers must be IPv4 addresses")

    with args.template.open(encoding="utf-8") as source:
        config = json.load(source)

    changes = {
        ("new_vcsa", "esxi", "hostname"): str(esxi),
        ("new_vcsa", "esxi", "username"): "root",
        ("new_vcsa", "esxi", "password"): "FILL_RUNTIME",
        ("new_vcsa", "esxi", "deployment_network"): args.portgroup,
        ("new_vcsa", "esxi", "datastore"): "datastore1",
        ("new_vcsa", "appliance", "name"): "vcsa-ash",
        ("new_vcsa", "appliance", "deployment_option"): "tiny",
        ("new_vcsa", "network", "mode"): "static",
        ("new_vcsa", "network", "ip"): str(vcsa),
        ("new_vcsa", "network", "prefix"): str(subnet.prefixlen),
        ("new_vcsa", "network", "gateway"): str(gateway),
        ("new_vcsa", "network", "system_name"): str(vcsa),
        ("new_vcsa", "network", "dns_servers"): dns,
        ("new_vcsa", "os", "password"): "FILL_RUNTIME",
        ("new_vcsa", "sso", "password"): "FILL_RUNTIME",
        ("new_vcsa", "sso", "domain_name"): "vsphere.local",
    }
    for keys, value in changes.items():
        assign(config, keys, value)

    os_settings = field(config, ("new_vcsa", "os"))
    if args.time_source == "host":
        # The NTP field must be absent, not an empty server string:
        # VMware ignores Tools sync when NTP servers are configured.
        os_settings.pop("ntp_servers", None)
        os_settings["time_tools_sync"] = True
    else:
        ntp_current = os_settings.get("ntp_servers")
        os_settings["ntp_servers"] = [args.ntp] if isinstance(ntp_current, list) else args.ntp
        os_settings["time_tools_sync"] = False

    appliance = field(config, ("new_vcsa", "appliance"))
    if "thin_disk_mode" in appliance:
        appliance["thin_disk_mode"] = True
    sso = field(config, ("new_vcsa", "sso"))
    if "site_name" in sso:
        sso["site_name"] = "Default-First-Site"
    if isinstance(config.get("ceip"), dict) and isinstance(config["ceip"].get("settings"), dict):
        if "ceip_enabled" in config["ceip"]["settings"]:
            config["ceip"]["settings"]["ceip_enabled"] = False

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as destination:
            json.dump(config, destination, indent=2)
            destination.write("\n")
    except Exception:
        args.output.unlink(missing_ok=True)
        raise

    print(f"Wrote {args.output} (mode 0600; no passwords)")
    print(f"ESXi={esxi}  VCSA={vcsa}/{subnet.prefixlen}  gateway={gateway}")
    print(f"Network={args.portgroup}  Time source={args.time_source}")
    print("Confirm the VCSA IP is unused and its public network reaches the gateway.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError,
            json.JSONDecodeError) as exc:
        print(f"Cannot render VCSA config: {exc}", file=sys.stderr)
        sys.exit(2)
