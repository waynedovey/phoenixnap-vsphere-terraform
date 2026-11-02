#!/usr/bin/env python3
"""Run Ansible and show safe live VCSA progress on macOS.

VMware's progress reports are gathered read-only from its latest installer log,
scoped by a per-deploy start marker. No credentials or raw VMware logs are printed.
The percentage is PER VMWARE TASK, not an estimated overall install percentage.
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time

# This code runs ON THE EXISTING UBUNTU INSTALLER, not on the Mac.
REMOTE_STATUS = r'''
import json
from pathlib import Path
import re
import sys

run_id = sys.argv[1]
if not re.fullmatch(r"[a-f0-9]{16}", run_id):
    sys.exit(2)
marker = Path("/home/ubuntu/vcsa/.deploy-" + run_id + ".start")
result = {"phase": "Preparing VMware deployment", "percent": None, "detail": "", "active": False}
if not marker.is_file():
    print(json.dumps(result))
    sys.exit(0)

result["active"] = True
try:
    started = marker.stat().st_mtime
    files = [
        p for p in Path("/tmp").glob("vcsaCliInstaller-*/workflow_*/vcsa-cli-installer.log")
        if p.is_file() and p.stat().st_mtime >= started
    ]
    if files:
        log_path = max(files, key=lambda p: p.stat().st_mtime)
        with log_path.open("rb") as log:
            log.seek(0, 2)
            size = log.tell()
            log.seek(max(0, size - 100000))
            data = log.read().decode("utf-8", errors="replace")
        reports = data.rsplit("VCSA Deployment Progress Report", 1)
        report = reports[-1] if len(reports) > 1 else ""
        matches = list(re.finditer(
            r"(?m)^\s*Task:\s*(.+?)\.\((RUNNING|SUCCEEDED|FAILED)\s+(\d+)/100\)\s*(?:-\s*([^\r\n]*))?",
            report,
        ))
        if matches:
            task, state, count, detail = matches[-1].groups()
            result["phase"] = task.strip().rstrip(".")
            result["percent"] = min(100, int(count))
            safe_detail = (detail or "").strip()[:100]
            if re.search(r"(?i)password|passwd|secret|token|credential|private.key|authorization|api.key", safe_detail):
                safe_detail = "(sensitive VMware message omitted)"
            result["detail"] = safe_detail
            if state == "FAILED":
                result["phase"] = "VMware task failed"
            elif state == "SUCCEEDED" and result["percent"] == 100 and (
                "firstboot" in task.lower() or "first boot" in task.lower()
            ):
                result["phase"] = "Finalizing VMware deployment"
                result["percent"] = None
                result["detail"] = "Firstboot finished; awaiting installer success"
        else:
            result["phase"] = "Deploying VCSA appliance"
except (OSError, ValueError):
    result["phase"] = "Waiting for VMware status"

print(json.dumps(result))
'''


def remote_progress(ip, known_hosts, run_id):
    cmd = [
        "ssh", "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=5",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=" + known_hosts,
        "ubuntu@" + ip, "python3 - " + run_id,
    ]
    try:
        answer = subprocess.run(
            cmd, input=REMOTE_STATUS, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=12, check=False,
        )
        if answer.returncode == 0:
            value = json.loads(answer.stdout)
            if isinstance(value, dict):
                return value
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return {"phase": "Waiting for installer status", "percent": None, "detail": ""}


def render(info, elapsed, tty, tick):
    phase = re.sub(r"[^a-zA-Z0-9 .()/,_-]", "", str(info.get("phase", "")))[:52]
    detail = str(info.get("detail", ""))[:75]
    if re.search(r"(?i)password|passwd|secret|token|credential|authorization|api.key", detail):
        detail = "(sensitive VMware message omitted)"
    detail = re.sub(r"[^a-zA-Z0-9 .()/,_:-]", "", detail)
    pct = info.get("percent")
    mins, seconds = divmod(int(elapsed), 60)
    if type(pct) is int and 0 <= pct <= 100:
        segments = min(28, pct * 28 // 100)
        bar = "[" + "#" * segments + "-" * (28 - segments) + "]"
        text = f"{bar} {pct:3d}%  {phase}"
    else:
        symbols = "|/-\\"
        text = f"[{symbols[tick % len(symbols)]}] {phase}"
    text += f"  {mins:02d}:{seconds:02d}"
    if detail:
        text += "  " + detail
    if tty:
        sys.stderr.write("\r\033[2K" + text[:160])
    else:
        sys.stderr.write("[VCSA progress] " + text[:160] + "\n")
    sys.stderr.flush()


def main():
    parser = argparse.ArgumentParser(description="Display task-level VMware install progress")
    parser.add_argument("--installer-ip", required=True)
    parser.add_argument("--known-hosts", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("ansible_command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{16}", args.run_id):
        parser.error("Invalid deploy run ID")
    if not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", args.installer_ip):
        parser.error("Invalid installer IP")
    command = args.ansible_command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("Ansible command is required")

    started = time.monotonic()
    deploying = threading.Event()
    tty = sys.stderr.isatty()

    # New process session means pressing Ctrl-C on the progress display will
    # not accidentally send SIGINT to a half-installed VMware appliance.
    child = subprocess.Popen(command, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True,
                             bufsize=1, start_new_session=True)

    def relay():
        try:
            for line in child.stdout:
                if "TASK [VMware CLI deployment" in line:
                    deploying.set()
                if tty:
                    sys.stderr.write("\r\033[2K")
                    sys.stderr.flush()
                sys.stdout.write(line)
                sys.stdout.flush()
        except (OSError, UnicodeError):
            pass

    reader = threading.Thread(target=relay, daemon=True)
    reader.start()
    last_phase = None
    last_non_tty_display = 0
    tick = 0

    def ignore_interrupt(signum, frame):
        sys.stderr.write("\nVCSA deployment is still running. Ctrl-C will not interrupt it.\n"
                         "Use a separate terminal to inspect the appliance if necessary.\n")
        sys.stderr.flush()

    signal.signal(signal.SIGINT, ignore_interrupt)
    try:
        while child.poll() is None:
            if not deploying.is_set():
                time.sleep(0.4)
                continue
            info = remote_progress(args.installer_ip, args.known_hosts, args.run_id)
            phase_key = (info.get("phase"), info.get("percent"), info.get("detail"))
            now = time.monotonic()
            if tty or phase_key != last_phase or now - last_non_tty_display >= 30:
                render(info, now - started, tty, tick)
                last_non_tty_display = now
                last_phase = phase_key
            tick += 1
            if child.poll() is not None:
                break
            time.sleep(6)
        rc = child.wait()
        reader.join(timeout=3)
        if tty and deploying.is_set():
            sys.stderr.write("\n")
        if deploying.is_set():
            if rc == 0:
                sys.stderr.write("VCSA deployment: completed successfully (Ansible exit 0).\n")
            else:
                sys.stderr.write(
                    f"VCSA deployment: Ansible exited {rc}; inspect the private VMware logs.\n"
                )
        return rc
    finally:
        # Do not terminate the deployment process; incomplete VCSA provisioning
        # may leave a live appliance. Normal paths always wait for its exit.
        pass


if __name__ == "__main__":
    sys.exit(main())
