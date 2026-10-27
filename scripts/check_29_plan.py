#!/usr/bin/env python3
"""Fail-closed validation of a phoenixNAP /29 migration Terraform plan."""

import json
import subprocess
import sys
from decimal import Decimal, InvalidOperation


EXPECTED_SERVER = "pnap_server.esxi[0]"
EXPECTED_BLOCK = "pnap_ip_block.lab_public_ipv4[0]"
MAX_USD_HOURLY = Decimal("0.50")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def value_of_output(plan, name):
    output = plan.get("output_changes", {}).get(name, {})
    require(output.get("after_unknown") is not True, f"{name}: price is unknown")
    raw_value = output.get("after")
    require(raw_value is not None, f"{name}: pricing output missing")
    try:
        value = Decimal(str(raw_value))
    except InvalidOperation as error:
        raise ValueError(f"{name}: invalid price") from error
    require(value.is_finite() and value > 0, f"{name}: price must be positive and finite")
    return value


def validate(plan, phase):
    require(phase in ("retire", "create"), "mode must be retire or create")
    expected = (
        {EXPECTED_SERVER: ["delete"]}
        if phase == "retire"
        else {EXPECTED_BLOCK: ["create"], EXPECTED_SERVER: ["create"]}
    )
    actual = {}
    for resource in plan.get("resource_changes", []):
        actions = resource.get("change", {}).get("actions", [])
        if actions != ["no-op"]:
            actual[resource["address"]] = actions
    require(actual == expected, f"Unexpected Terraform actions. Expected {expected}; actual {actual}")

    if phase == "retire":
        server = next(resource for resource in plan["resource_changes"] if resource["address"] == EXPECTED_SERVER)
        old_settings = server["change"].get("before") or {}
        require(old_settings.get("delete_ip_blocks") is True, "Old host must be deleted with delete_ip_blocks=true so its /30 is released")
        print("PASS: only the original ESXi host is deleted, with delete_ip_blocks=true for its /30")
        return

    server = value_of_output(plan, "quoted_server_usd_per_hour")
    per_ip = value_of_output(plan, "quoted_ipv4_usd_per_address_hour")
    total = value_of_output(plan, "quoted_total_usd_per_hour")
    require(total == server + Decimal(8) * per_ip, "Quote does not equal server + all eight /29 addresses")
    require(total <= MAX_USD_HOURLY, f"US${total}/hour exceeds the US$0.50/hour limit")
    print(f"PASS: Seattle /29 quote = US${server}/h server + 8 x US${per_ip}/h IPv4 = US${total}/h")
    print("PASS: only one /29 and one ESXi server will be purchased; no deletions or replacements")


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: check_29_plan.py retire|create <path-to-tfplan>")
    phase, path = sys.argv[1:]
    result = subprocess.run(["terraform", "show", "-json", path], capture_output=True, text=True, check=True)
    validate(json.loads(result.stdout), phase)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"STOP: {exc}", file=sys.stderr)
        sys.exit(1)
