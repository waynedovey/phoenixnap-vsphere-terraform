"""Offline tests for installer cleanup with missing Terraform root outputs.

Runs with a fake terraform executable. Never contacts PhoenixNAP.
python3 -m unittest discover -s tests -p 'test_installer_retirement_state.py' -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ESXI_ID = "6ae8339b084284f4ded10384"
INSTALLER_ID = "6ae8339c2702997d57bd5021"


@unittest.skipUnless(shutil.which("jq"), "jq required for cleanup script")
class RetireStateTests(unittest.TestCase):
    def run_retirement(self, include_installer, safe_plan=False):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "ashburn/scripts").mkdir(parents=True)
            (base / "ashburn/terraform.tfvars").write_text(
                'enable_esxi = true\nenable_installer = true\n')
            source = ROOT / "ashburn/scripts/retire-installer.sh"
            shutil.copy2(source, base / "ashburn/scripts/retire-installer.sh")
            (base / "bin").mkdir()
            fake = base / "bin/terraform"
            fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["TF_CALLS"]).open("a") as output:
    output.write(" ".join(args) + "\\n")
if args[-2:] == ["state", "pull"]:
    print(Path(os.environ["TF_STATE"]).read_text())
elif "console" in args:
    # The ignored, auto-loaded lifecycle override makes the effective var false.
    print("false" if Path("ashburn/zz-installer-retired.auto.tfvars").exists() else "true")
elif "plan" in args:
    print("Mock terraform: plan created")
elif "show" in args:
    if os.environ["TF_PLAN_SAFE"] == "1":
        print(json.dumps({"resource_changes": [
            {"address": "pnap_server.installer[0]",
             "change": {"actions": ["delete"], "before": {
                "id": os.environ["INSTALLER_ID"], "hostname": "vcsa-installer-ash",
                "location": "ASH", "delete_ip_blocks": True}}}]}))
    else:
        # Deliberately unsafe plan: MUST be rejected without deletion.
        print(json.dumps({"resource_changes": [
            {"address": "pnap_server.esxi[0]",
             "change": {"actions": ["delete"], "before": {
               "id": "other", "hostname": "esxi-01",
               "location": "ASH", "delete_ip_blocks": False}}}]}))
elif "apply" in args and os.environ["TF_PLAN_SAFE"] == "1":
    state = Path(os.environ["TF_STATE"])
    data = json.loads(state.read_text())
    data["resources"] = [r for r in data["resources"] if r["name"] != "installer"]
    state.write_text(json.dumps(data))
    print("Mock terraform: installer deleted")
elif args[-2:] == ["state", "list"]:
    data = json.loads(Path(os.environ["TF_STATE"]).read_text())
    for resource in data["resources"]:
        print("pnap_server." + resource["name"] + "[0]")
else:
    print("unexpected mock Terraform call: " + repr(args), file=sys.stderr)
    sys.exit(13)
""")
            fake.chmod(0o700)
            resources = [{
                "mode": "managed", "type": "pnap_server", "name": "esxi",
                "instances": [{"attributes": {"id": ESXI_ID, "hostname": "esxi-01"}}],
            }]
            if include_installer:
                resources.append({
                    "mode": "managed", "type": "pnap_server", "name": "installer",
                    "instances": [{"attributes": {
                        "id": INSTALLER_ID, "hostname": "vcsa-installer-ash",
                        "location": "ASH", "delete_ip_blocks": True}}],
                })
            state = base / "state.json"
            state.write_text(json.dumps({"version": 4, "resources": resources}))
            calls = base / "calls.txt"
            env = os.environ.copy()
            env.update({
                "PATH": str(base / "bin") + os.pathsep + env["PATH"],
                "TF_STATE": str(state), "TF_CALLS": str(calls),
                "TF_PLAN_SAFE": "1" if safe_plan else "0",
                "INSTALLER_ID": INSTALLER_ID,
            })
            result = subprocess.run(
                ["bash", str(base / "ashburn/scripts/retire-installer.sh"), "--yes"],
                env=env, capture_output=True, text=True, timeout=15,
            )
            marker = base / "ashburn/zz-installer-retired.auto.tfvars"
            return (result, calls.read_text(),
                    (base / "ashburn/terraform.tfvars").read_text(),
                    marker.read_text() if marker.exists() else None,
                    json.loads(state.read_text()))

    def test_missing_root_outputs_does_not_block_resource_detection(self):
        result, calls, tfvars, marker, state = self.run_retirement(include_installer=True)
        # Reaches the plan, which intentionally rejects ESXi deletion.
        self.assertIn("Terraform plan is NOT an installer-only deletion", result.stderr)
        self.assertIn("state pull", calls)
        self.assertIn("plan", calls)
        self.assertNotIn("output", calls)
        self.assertNotIn("apply", calls)
        self.assertIn("enable_installer = true", tfvars)
        self.assertIsNone(marker)

    def test_approved_installer_only_plan_retires_without_changing_user_tfvars(self):
        result, calls, tfvars, marker, state = self.run_retirement(
            include_installer=True, safe_plan=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installer retired.", result.stdout)
        self.assertIn("enable_installer = true", tfvars)
        self.assertIn("enable_installer = false", marker)
        self.assertIn("apply", calls)
        self.assertEqual([r["name"] for r in state["resources"]], ["esxi"])

    def test_absent_installer_is_idempotent_without_outputs(self):
        result, calls, tfvars, marker, state = self.run_retirement(include_installer=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to delete", result.stdout)
        self.assertNotIn("plan", calls)
        self.assertNotIn("apply", calls)
        self.assertNotIn("output", calls)
        self.assertIn("enable_installer = true", tfvars)
        self.assertIn("enable_installer = false", marker)
        self.assertIn("console", calls)


if __name__ == "__main__":
    unittest.main()
