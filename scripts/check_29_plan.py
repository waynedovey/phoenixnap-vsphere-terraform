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
    require(phase in ("quote", "retire", "create"), "mode must be quote, retire or create")
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
    # Quote mode never applies the plan. Existing servers may show proposed
    # network changes in the preview; only the live rate is used in this mode.
    if phase != "quote":
        require(actual == expected, f"Unexpected Terraform actions. Expected {expected}; actual {actual}")

    if phase == "retire":
        server = next(resource for resource in plan["resource_changes"] if resource["address"] == EXPECTED_SERVER)
        old_settings = server["change"].get("before") or {}
        require(old_settings.get("delete_ip_blocks") is True, "Old host must be deleted with delete_ip_blocks=true so its /30 is released")
        print("PASS: only the original ESXi host is deleted, with delete_ip_blocks=true for its /30")
        return

    server = value_of_output(plan, "quoted_server_usd_per_hour")
    full_range = value_of_output(plan, "quoted_public_ipv4_29_usd_per_hour")
    total = value_of_output(plan, "quoted_total_usd_per_hour")

    # Independently verify the exact account SKU selected by Terraform.
    sku_output = plan.get("output_changes", {}).get("quoted_public_ip_skus", {})
    require(sku_output.get("after_unknown") is not True, "GLOBAL /29 SKU is unknown")
    selected_skus = sku_output.get("after") or []
    require(bool(selected_skus), "Approved GLOBAL /29 SKU is missing from the live catalog")
    for row in selected_skus:
        require(row.get("product_code") == "range-29", "Unexpected IP product code")
        require(row.get("sku") == "W0I2-DIVY-ZJVP", "Unexpected IP SKU")
        require(row.get("location") == "GLOBAL", "IP SKU must have GLOBAL billing location")
        require(row.get("pricing_model") == "HOURLY", "IP SKU must have HOURLY pricing")
        require(row.get("price_unit") == "HOUR", "IP SKU must have HOUR price units")
        try:
            sku_rate = Decimal(str(row.get("rate")))
        except InvalidOperation as error:
            raise ValueError("Invalid /29 SKU rate") from error
        require(sku_rate == full_range, "Live /29 SKU rate does not match quoted full-range charge")

    # API price for range-29 is for the *entire /29*, not per address.
    recomputed = server + full_range
    require(abs(total - recomputed) <= Decimal("0.000001"), "Quote must equal server + ONE full /29 range")
    require(max(total, recomputed) <= MAX_USD_HOURLY, f"US$${total}/hour exceeds the US$0.50/hour limit")
    print(f"PASS: Seattle /29 quote = US$${server}/h server + US$${full_range}/h /29 range = US$${total}/h")

    if phase == "quote":
        print("QUOTE ONLY: this plan must never be applied to the running /30-backed host")
    else:
        print("PASS: only one /29 and one ESXi server will be purchased; no deletions or replacements")


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: check_29_plan.py quote|retire|create <path-to-tfplan>")
    phase, path = sys.argv[1:]
    result = subprocess.run(["terraform", "show", "-json", path], capture_output=True, text=True, check=True)
    validate(json.loads(result.stdout), phase)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"STOP: {exc}", file=sys.stderr)
        sys.exit(1)
