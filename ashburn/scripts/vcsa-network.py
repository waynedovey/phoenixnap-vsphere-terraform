#!/usr/bin/env python3
"""Discover the public VMkernel VLAN and validate a dedicated VCSA VM port group.

Input: output of 'govc host.portgroup.info'.
Do not attach VMs to PhoenixNAP's public.<VLAN> VMkernel management port group:
VMkernel and VM traffic require separate port groups on standard switches.
Output: JSON plan (name, VLAN, vswitch, create boolean). Never change the
management port group, switch, uplinks or VLAN itself.
"""
import argparse
import json
import re
import sys

VM_PORTGROUP = "vcsa-public"


def parse_portgroups(output):
    entries = []
    for line in output.splitlines():
        m = re.fullmatch(r"Name:\s*(.*?)\s*", line)
        if m:
            entries.append({"name": m.group(1)})
            continue
        if not entries:
            continue
        m = re.fullmatch(r"Virtual switch:\s*(.*?)\s*", line)
        if m:
            entries[-1]["vswitch"] = m.group(1)
            continue
        m = re.fullmatch(r"VLAN ID:\s*(\d+)\s*", line)
        if m:
            entries[-1]["vlan"] = int(m.group(1))
    return entries


def plan(output, require_existing=False):
    entries = parse_portgroups(output)
    public = [p for p in entries if re.fullmatch(r"public\.\d+", p["name"])]
    if len(public) != 1:
        raise ValueError(
            "Expected exactly one PhoenixNAP public.<VLAN> port group; "
            "refusing to guess the management VLAN."
        )
    mgmt = public[0]
    if "vlan" not in mgmt or not mgmt.get("vswitch"):
        raise ValueError("Missing VLAN/vSwitch for existing public management network")
    if int(mgmt["name"].split(".")[1]) != mgmt["vlan"]:
        raise ValueError("Public port group name and configured VLAN disagree")
    if not 0 <= mgmt["vlan"] <= 4094:
        raise ValueError("Unsupported public VLAN ID")
    vms = [p for p in entries if p["name"] == VM_PORTGROUP]
    if len(vms) > 1:
        raise ValueError("Multiple vcsa-public port groups found; refusing to change networking")
    if vms:
        vm = vms[0]
        if vm.get("vswitch") != mgmt["vswitch"] or vm.get("vlan") != mgmt["vlan"]:
            raise ValueError(
                "Existing vcsa-public has an unexpected switch/VLAN; "
                "inspect it manually. ESXi management is unchanged."
            )
    elif require_existing:
        raise ValueError("The dedicated vcsa-public VM port group is missing")
    return {
        "management_portgroup": mgmt["name"],
        "vm_portgroup": VM_PORTGROUP,
        "vswitch": mgmt["vswitch"],
        "vlan_id": mgmt["vlan"],
        "create": not bool(vms),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-existing", action="store_true")
    args = parser.parse_args()
    try:
        print(json.dumps(plan(sys.stdin.read(), args.require_existing), sort_keys=True))
        return 0
    except ValueError as exc:
        print(f"VCSA network validation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
