"""Static regression guards for the temporary installer lifecycle (no cloud access).

Run: python3 -m unittest discover -s tests -p 'test_build_all_lifecycle.py' -v
"""
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "ashburn/scripts/build-all.sh"
RETIRE = ROOT / "ashburn/scripts/retire-installer.sh"
REGISTER = ROOT / "ashburn/scripts/register-esxi.sh"
IGNORE = ROOT / ".gitignore"


class BuildAllLifecycleTests(unittest.TestCase):
    def test_bash_parses(self):
        for path in (BUILD, RETIRE, REGISTER):
            result = subprocess.run(["bash", "-n", str(path)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, path.name + ": " + result.stderr)

    def test_user_tfvars_never_written_by_retirement(self):
        body = RETIRE.read_text()
        self.assertIn('zz-installer-retired.auto.tfvars', body)
        self.assertIn('enable_installer = false', body)
        self.assertNotIn('python3 - "$tfvars" write', body)
        self.assertNotIn('os.replace(temp_name, path)', body)
        self.assertIn('*.auto.tfvars', IGNORE.read_text())

    def test_only_temporary_installer_is_destroyed(self):
        body = RETIRE.read_text()
        self.assertIn('address: "pnap_server.installer[0]", actions: ["delete"]', body)
        self.assertIn('STOP: Terraform plan is NOT an installer-only deletion', body)
        self.assertNotIn('terraform -chdir="$tf" destroy', body)

    def test_cleanup_runs_after_registration_and_is_noninteractive(self):
        body = REGISTER.read_text()
        self.assertLess(body.index('ansible/register-esxi.yml"'),
                        body.index('retire-installer.sh" --yes'))

    def test_build_all_runs_once_and_adopts_completed_lab(self):
        body = BUILD.read_text()
        self.assertEqual(body.count('say "Register ESXi in vCenter"'), 1)
        self.assertEqual(body.count('say "Provision public /29 if absent"'), 1)
        self.assertEqual(body.count('bash ashburn/scripts/vcsa.sh deploy </dev/null'), 1)
        self.assertIn('Adopting installed vCenter', body)
        self.assertIn('enable_installer must remain true in terraform.tfvars', body)
        self.assertIn('Installer retired, but vcsa-ash VM is absent', body)
        self.assertNotIn('output -raw installer_id', body)


if __name__ == "__main__":
    unittest.main()
