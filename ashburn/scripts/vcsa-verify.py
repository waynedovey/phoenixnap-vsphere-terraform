#!/usr/bin/env python3
"""Read-only reconciliation after a nonzero VCSA installer/Ansible exit.

Retries health checks, NOT VCSA installation. A partial VM is never deleted,
reset, overwritten or automatically redeployed. Raw logs and secrets stay private.
"""
import argparse
from datetime import datetime, timezone
import json
import os
import re
import subprocess
import sys
import time

# Executed using python3 on Ubuntu over SSH. Returns ONLY safe status fields.
REMOTE_CHECK = r'''
from datetime import datetime, timezone
from pathlib import Path
import json
import re
import sys

run_id = sys.argv[1]
if not re.fullmatch(r"[a-f0-9]{16}", run_id):
    sys.exit(2)
marker = Path("/home/ubuntu/vcsa/.deploy-" + run_id + ".start")
result = {"state": "missing-marker"}
if marker.is_file():
    start = marker.stat().st_mtime
    candidates = []
    for path in Path("/tmp").glob("vcsaCliInstaller-*/workflow_*/vcsa-cli-installer.log"):
        try:
            folder = path.parents[1].name
            match = re.fullmatch(
                r"vcsaCliInstaller-(\d{4}-\d{2}-\d{2}-\d{2}-\d{2})-[^/]+", folder)
            if not match or not path.is_file() or path.stat().st_mtime < start:
                continue
            # VMware includes the creation minute in each per-install log folder.
            # Do not use a previous install log whose mtime was later updated.
            created = datetime.strptime(match.group(1), "%Y-%m-%d-%H-%M").replace(
                tzinfo=timezone.utc).timestamp()
            if created + 65 < start:
                continue
            candidates.append(path)
        except (ValueError, OSError):
            continue
    result = {"state": "no-current-log"}
    if candidates:
        latest = max(candidates, key=lambda p: p.stat().st_mtime)
        try:
            # Deployment success and login-summary task are written near the end.
            with latest.open("rb") as log:
                log.seek(0, 2)
                log.seek(max(0, log.tell() - 256000))
                data = log.read().decode("utf-8", errors="replace")
            complete = "Successfully completed VCSA deployment." in data
            login = bool(re.search(
                r"\[SUCCEEDED\].*ApplianceLoginSummaryTask: Provide appliance login information",
                data,
            ))
            failed = "The VCSA deployment has failed" in data
            result = {"state": "complete" if complete and login and not failed else
                      "failed" if failed else "in-progress"}
        except (OSError, UnicodeError):
            result = {"state": "log-unreadable"}
print(json.dumps(result))
'''


def command(argv, *, env=None, timeout=14, input_text=None):
    try:
        return subprocess.run(argv, env=env, input=input_text, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None


def remote_status(installer, known_hosts, run_id):
    result = command([
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=" + known_hosts,
        "ubuntu@" + installer, "python3 - " + run_id,
    ], input_text=REMOTE_CHECK, timeout=18)
    if result is None or result.returncode != 0:
        return "unreachable"
    try:
        state = json.loads(result.stdout)["state"]
        if state in {"complete", "failed", "in-progress", "missing-marker",
                     "no-current-log", "log-unreadable"}:
            return state
    except (ValueError, KeyError, TypeError):
        pass
    return "unreadable-status"


def esxi_vm_matches(expected_ip):
    """Requires one vcsa-ash VM, powered on, with the expected guest IP."""
    env = os.environ.copy()  # GOVC_URL/GOVC_PASSWORD already target ESXi.
    env["GOVC_DATACENTER"] = ""
    env["GOVC_FOLDER"] = ""
    found = command(["govc", "find", "/", "-type", "m", "-name", "vcsa-ash"],
                    env=env)
    if found is None or found.returncode != 0:
        return False
    paths = [line.strip() for line in found.stdout.splitlines() if line.strip()]
    if len(paths) != 1:
        return False
    info = command(["govc", "vm.info", paths[0]], env=env)
    if info is None or info.returncode != 0:
        return False
    return bool(
        re.search(r"(?m)^\s*Power state:\s*poweredOn\s*$", info.stdout)
        and re.search(r"(?m)^\s*IP address:\s*" + re.escape(expected_ip)
                      + r"\s*$", info.stdout)
    )


def vcenter_authenticated(expected_ip):
    """Require an actual SSO-authenticated inventory operation, not HTTP 200."""
    password = os.environ.get("VCSA_SSO_PASSWORD")
    if not password:
        return False
    env = os.environ.copy()
    env.update({
        "GOVC_URL": "https://" + expected_ip + "/sdk",
        "GOVC_USERNAME": os.environ.get(
            "ASHBURN_VCENTER_USERNAME", "administrator@vsphere.local"),
        "GOVC_PASSWORD": password,
        "GOVC_INSECURE": "1",
        "GOVC_DATACENTER": "",
        "GOVC_FOLDER": "",
    })
    about = command(["govc", "about"], env=env)
    if about is None or about.returncode != 0 or not re.search(
            r"API type:\s+VirtualCenter", about.stdout):
        return False
    inventory = command(["govc", "find", "/", "-type", "d"], env=env)
    return inventory is not None and inventory.returncode == 0


def reconcile(args, *, status=remote_status, vm=esxi_vm_matches,
              login=vcenter_authenticated, sleep=time.sleep):
    for attempt in range(args.attempts):
        state = status(args.installer_ip, args.known_hosts, args.run_id)
        if state == "complete" and vm(args.vcsa_ip) and login(args.vcsa_ip):
            print("RECOVERED: this run's VMware completion and login-summary "
                  "tasks succeeded; vcsa-ash is powered on at the expected IP; "
                  "authenticated vCenter inventory is working. "
                  "No second deployment was attempted.")
            return 0
        if state == "failed":
            print("NOT RECOVERED: VMware reported deployment failure in the "
                  "current-run log. Check vcsa.sh diagnose and inspect; "
                  "manual investigation is required.", file=sys.stderr)
            return 1
        if attempt < args.attempts - 1:
            print("VCSA verification %d/%d: %s; retrying read-only checks in %ds. "
                  "No installation retry." % (
                      attempt + 1, args.attempts, state, args.delay),
                  file=sys.stderr, flush=True)
            sleep(args.delay)
    print("NOT RECOVERED: could not verify VMware completion, matching powered-on "
          "VM and authenticated vCenter readiness. Do not redeploy blindly. "
          "Run vcsa.sh inspect and vcsa.sh diagnose.", file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser(description="Reconcile completed VCSA without redeploying")
    parser.add_argument("--installer-ip", required=True)
    parser.add_argument("--vcsa-ip", required=True)
    parser.add_argument("--known-hosts", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempts", type=int, default=16)
    parser.add_argument("--delay", type=int, default=15)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{16}", args.run_id):
        parser.error("Invalid deployment run ID")
    for address in [args.installer_ip, args.vcsa_ip]:
        if not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", address):
            parser.error("Expected IPv4 address")
    if not (1 <= args.attempts <= 32 and 0 <= args.delay <= 60):
        parser.error("Invalid verification retry budget")
    return reconcile(args)


if __name__ == "__main__":
    sys.exit(main())
