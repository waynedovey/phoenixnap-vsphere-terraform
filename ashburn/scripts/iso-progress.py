#!/usr/bin/env python3
"""Show read-only, safe VCSA ISO download progress on the Mac.

Polls only the Ubuntu media file's size and MEDIA_READY marker over SSH.
It never runs curl, reads passwords, prints the ISO URL or touches the download.
Works with an already-running cloud-init curl started before this script existed.
"""
import argparse
import json
import re
import subprocess
import sys
import time

# This small script runs on the Ubuntu installer, through SSH stdin.
REMOTE_STATUS = r'''
import json
from pathlib import Path

media = Path("/opt/vcsa/media")
partial = media / "VMware-VCSA-all-8.0.3-24022515.iso.partial"
iso = media / "VMware-VCSA-all-8.0.3-24022515.iso"
ready = Path("/opt/vcsa/MEDIA_READY")

result = {"state": "waiting", "bytes": 0}
try:
    if ready.is_file() and iso.is_file():
        result["state"] = "ready"
        result["bytes"] = iso.stat().st_size
    elif partial.is_file():
        result["state"] = "downloading"
        result["bytes"] = partial.stat().st_size
    elif iso.is_file():
        result["state"] = "verifying"
        result["bytes"] = iso.stat().st_size
except OSError:
    result = {"state": "unreadable", "bytes": 0}
print(json.dumps(result))
'''


def remote_status(installer_ip, known_hosts):
    cmd = [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=" + known_hosts,
        "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
        "ubuntu@" + installer_ip, "python3 -",
    ]
    try:
        result = subprocess.run(
            cmd, input=REMOTE_STATUS, text=True, capture_output=True,
            timeout=16, check=False,
        )
        if result.returncode == 0:
            info = json.loads(result.stdout)
            if (isinstance(info, dict)
                    and info.get("state") in {
                        "waiting", "downloading", "verifying", "ready", "unreadable",
                    }
                    and type(info.get("bytes")) is int
                    and 0 <= info["bytes"] < 10**14):
                return info
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return {"state": "unreachable", "bytes": 0}


def format_size(n):
    return f"{n / (1024 ** 3):.2f} GiB" if n >= 1024 ** 3 else f"{n / (1024 ** 2):.1f} MiB"


def message(info, previous, now):
    state, size = info["state"], info["bytes"]
    if state == "ready":
        return f"[ISO] Verified and mounted: {format_size(size)} — MEDIA_READY."
    if state == "verifying":
        return f"[ISO] Download complete ({format_size(size)}); awaiting checksum and read-only mount."
    if state == "downloading":
        detail = f"[ISO] Downloading: {format_size(size)} received"
        if previous is not None and size >= previous[0]:
            elapsed = max(0.001, now - previous[1])
            rate = (size - previous[0]) / elapsed / (1024 ** 2)
            detail += f" | {rate:.1f} MiB/s since last check"
            if rate < 0.01:
                detail += " (no new bytes observed; curl may be retrying)"
        else:
            detail += " | measuring transfer rate"
        return detail + " | total size not verified"
    if state == "waiting":
        return "[ISO] Ubuntu is reachable; waiting for cloud-init to begin the ISO transfer."
    if state == "unreachable":
        return "[ISO] Waiting for Ubuntu SSH; download progress will appear automatically."
    return "[ISO] Unable to read media status yet; monitoring continues."


def monitor(installer_ip, known_hosts, interval, *, get_status=remote_status,
            sleep=time.sleep, monotonic=time.monotonic, output=sys.stderr):
    previous = None
    last_message = ""
    while True:
        info = get_status(installer_ip, known_hosts)
        now = monotonic()
        text = message(info, previous, now)
        # Always print each timed measurement so slow downloads remain visible.
        print(text, file=output, flush=True)
        if info["state"] == "ready":
            return 0
        if info["state"] == "downloading":
            previous = (info["bytes"], now)
        elif info["state"] in ("waiting", "unreachable", "unreadable"):
            previous = None
        sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="Monitor VCSA ISO download (read-only)")
    parser.add_argument("--installer-ip", required=True)
    parser.add_argument("--known-hosts", required=True)
    parser.add_argument("--interval", type=int, default=15)
    args = parser.parse_args()
    if not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", args.installer_ip):
        parser.error("Installer address must be IPv4")
    if not args.known_hosts.startswith("/") or not (5 <= args.interval <= 120):
        parser.error("Use an absolute known_hosts path and 5-120 second interval")
    return monitor(args.installer_ip, args.known_hosts, args.interval)


if __name__ == "__main__":
    sys.exit(main())
