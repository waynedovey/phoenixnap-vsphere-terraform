"""Offline regressions for ESXi NTP polling and live ISO monitor wiring.

python3 -m unittest discover -s tests -p 'test_ntp_iso_workflow.py' -v
"""
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "ashburn/scripts/build-all.sh"
VCSA = ROOT / "ashburn/scripts/vcsa.sh"
MONITOR = ROOT / "ashburn/scripts/iso-progress.py"


class NtpIsoWorkflowTests(unittest.TestCase):
    def test_shell_syntax(self):
        for script in (BUILD, VCSA):
            process = subprocess.run(["bash", "-n", str(script)],
                                     text=True, capture_output=True)
            self.assertEqual(process.returncode, 0, process.stderr)

    def test_ntp_match_accepts_both_esxi_formats(self):
        # Matches both legacy printed variants, not false or unrelated text.
        pattern = re.compile(
            r"^[ \t]*Time[ \t]*Synchronized:[ \t]*true[ \t]*$", re.I | re.M)
        self.assertIsNotNone(pattern.search("TimeSynchronized: true"))
        self.assertIsNotNone(pattern.search("Time Synchronized: true"))
        self.assertIsNone(pattern.search("TimeSynchronized: false"))
        source = BUILD.read_text()
        self.assertIn("Time[[:space:]]*Synchronized:", source)

    def test_wait_is_bounded_and_does_not_restart_ntp_every_poll(self):
        source = BUILD.read_text()
        self.assertIn("ntp_attempts=40", source)
        self.assertIn("ntp_interval=15", source)
        self.assertIn('if [[ "$configured_ntp" == 0 ]]', source)
        self.assertIn('if (( attempt < ntp_attempts )); then', source)
        self.assertIn('[[ "$synced" == 1 ]]', source)

    def test_iso_monitor_starts_before_ntp_and_uses_same_instance(self):
        source = BUILD.read_text()
        self.assertLess(source.index("iso_monitor_pid=$!"),
                        source.index('say "Check ESXi NTP'))
        self.assertIn('VCSA_ISO_MONITOR_EXTERNAL=YES', source)
        self.assertIn('kill "$iso_monitor_pid"', source)
        self.assertIn("ashburn/scripts/iso-progress.py", source)

    def test_manual_prepare_monitor_does_not_run_second_download(self):
        source = VCSA.read_text()
        self.assertIn('if [[ "$stage" == prepare', source)
        self.assertIn('VCSA_ISO_MONITOR_EXTERNAL', source)
        self.assertIn("trap cleanup_iso_progress EXIT", source)
        monitor = MONITOR.read_text()
        self.assertNotIn("curl --", monitor)
        self.assertIn("VMware-VCSA-all-8.0.3-24022515.iso.partial", monitor)
        self.assertIn("/opt/vcsa/MEDIA_READY", monitor)
        playbook = (ROOT / "ashburn/ansible/vcsa.yml").read_text()
        self.assertIn("sudo timeout 7200 cloud-init status --wait", playbook)


if __name__ == "__main__":
    unittest.main()
