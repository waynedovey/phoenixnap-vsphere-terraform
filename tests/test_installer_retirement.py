"""Offline tests for the guarded Ashburn installer cleanup.

Run from repository root:
  python3 -m unittest discover -s tests -p 'test_installer_retirement.py' -v
No Terraform apply, cloud resources or credentials are needed.
"""
import json
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
RETIRE = ROOT / "ashburn/scripts/retire-installer.sh"
REGISTER = ROOT / "ashburn/scripts/register-esxi.sh"
SID = "6ae8339c2702997d57bd5021"


class InstallerRetirementTests(unittest.TestCase):
    def test_bash_syntax_of_both_scripts(self):
        for path in [RETIRE, REGISTER]:
            result = subprocess.run(
                ["bash", "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_registration_gate_precedes_automatic_retirement(self):
        source = REGISTER.read_text()
        self.assertLess(source.index('register-esxi.yml"'), source.index('retire-installer.sh" --yes'))
        self.assertIn("if ! bash", source)
        self.assertIn('exit 1', source)

    def test_cleanup_persists_ignored_override_before_apply(self):
        source = RETIRE.read_text()
        self.assertIn('zz-installer-retired.auto.tfvars', source)
        self.assertIn('enable_installer = false', source)
        self.assertLess(source.index('persist_retirement\n\nterraform'),
                        source.index('terraform -chdir="$tf" apply'))
        self.assertNotIn('python3 - "$tfvars" write', source)
        self.assertIn('state list', source)

    @unittest.skipUnless(shutil.which("jq"), "jq is not installed")
    def test_only_exact_installer_delete_is_permitted(self):
        source = RETIRE.read_text()
        key = 'terraform -chdir="$tf" show -json "$plan_dir/retire.tfplan" |'
        self.assertIn(key, source)
        after = source.split(key, 1)[1]
        expression = after.split('jq -e --arg id "$server_id" ', 1)[1].split(
            "\n  ' >/dev/null", 1)[0].strip()
        self.assertTrue(expression.startswith("'"))
        jq_filter = expression[1:]

        def change(address="pnap_server.installer[0]", actions=None,
                   server_id=SID, hostname="vcsa-installer-ash",
                   location="ASH", delete_ip_blocks=True):
            return {
                "address": address,
                "change": {
                    "actions": actions or ["delete"],
                    "before": {
                        "id": server_id,
                        "hostname": hostname,
                        "location": location,
                        "delete_ip_blocks": delete_ip_blocks,
                    },
                },
            }

        def approved(changes):
            run = subprocess.run(
                ["jq", "-e", "--arg", "id", SID, jq_filter],
                input=json.dumps({"resource_changes": changes}),
                capture_output=True, text=True,
            )
            return run.returncode == 0

        self.assertTrue(approved([change()]))
        self.assertTrue(approved([
            change(), change(address="pnap_server.esxi[0]", actions=["no-op"])
        ]))
        self.assertFalse(approved([]))
        self.assertFalse(approved([change(actions=["delete", "create"])]))
        self.assertFalse(approved([change(server_id="another-server")]))
        self.assertFalse(approved([change(hostname="esxi-01")]))
        self.assertFalse(approved([change(location="SEA")]))
        self.assertFalse(approved([change(delete_ip_blocks=False)]))
        self.assertFalse(approved([
            change(), change(address="pnap_server.esxi[0]")
        ]))
        self.assertFalse(approved([
            change(), change(address="pnap_ip_block.esxi_29[0]")
        ]))


if __name__ == "__main__":
    unittest.main()
