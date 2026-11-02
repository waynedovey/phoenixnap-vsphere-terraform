#!/usr/bin/env python3
"""Resolve the Ubuntu SSH address from a PhoenixNAP pnap_server in Terraform state.

The pnap_server *resource* exposes public_ip_addresses (possibly a range).
Unlike the pnap_server *data source*, it does not expose primary_ip_address.
The default PhoenixNAP Linux public allocation is /31, with its second
address used by the installer and its first address used as the gateway.
Never guess an address from a larger or ambiguous allocation.
"""
import ipaddress
import json
import re
import sys


def fail(message):
    raise ValueError(message)


def ipv4(value):
    try:
        address = ipaddress.ip_address(value)
        return address if isinstance(address, ipaddress.IPv4Address) else None
    except ValueError:
        return None


def ip_from_assignment(entry):
    if not isinstance(entry, str):
        fail("Non-string public IP assignment in Terraform state")
    entry = entry.strip()
    single = ipv4(entry)
    if single:
        return single

    # Some versions of the BMC API expose a /31 allocation as CIDR.
    if "/" in entry:
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError as exc:
            fail(f"Unexpected public IP assignment format: {exc}")
        if isinstance(network, ipaddress.IPv4Network) and network.prefixlen == 31:
            return network.broadcast_address
        fail("Only a single IPv4 or an unambiguous /31 allocation is supported")

    # Other versions present the /31 as "start - end".
    match = re.fullmatch(r"\s*(\d{1,3}(?:\.\d{1,3}){3})\s*-\s*(\d{1,3}(?:\.\d{1,3}){3})\s*", entry)
    if match:
        lower = ipv4(match.group(1))
        upper = ipv4(match.group(2))
        if lower is None or upper is None:
            fail("Invalid IPv4 in PhoenixNAP public range")
        if int(upper) != int(lower) + 1 or int(lower) % 2:
            fail("Public IPv4 range is not a /31: refusing to guess an SSH address")
        return upper
    fail("Unrecognized public IP assignment; inspect public_ip_addresses in Terraform state")


def resolve(state):
    servers = [
        instance["attributes"]
        for resource in state.get("resources", [])
        if resource.get("type") == "pnap_server" and resource.get("name") == "installer"
        for instance in resource.get("instances", [])
        if isinstance(instance.get("attributes"), dict)
    ]
    if len(servers) != 1:
        fail("Expected exactly one managed Ashburn Ubuntu installer resource")
    attrs = servers[0]
    primary = ipv4(attrs.get("primary_ip_address", ""))
    if primary:
        return primary

    assignments = attrs.get("public_ip_addresses")
    if not isinstance(assignments, list) or not assignments:
        fail("Installer has no public_ip_addresses in Terraform state")
    candidates = [ip_from_assignment(entry) for entry in assignments if isinstance(entry, str) and ":" not in entry]
    if len(candidates) == 1:
        return candidates[0]

    # A provider might expand a /31 into two plain IPv4 entries.
    if len(candidates) == 2 and len(set(candidates)) == 2:
        first, second = sorted(candidates)
        if int(second) == int(first) + 1 and int(first) % 2 == 0:
            return second
    fail("Ambiguous public IPv4 allocation: refusing to guess the installer SSH IP")


if __name__ == "__main__":
    try:
        result = resolve(json.load(sys.stdin))
        print(result)
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"Cannot derive Ubuntu SSH IPv4: {exc}", file=sys.stderr)
        sys.exit(1)
