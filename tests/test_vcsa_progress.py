"""Tests for terminal VCSA deployment progress without contacting live ESXi.

python3 -m unittest discover -s tests -p 'test_vcsa_progress.py' -v
"""
import importlib.util
import io
from contextlib import redirect_stderr
from pathlib import Path
import unittest
from unittest import mock


code = Path(__file__).resolve().parents[1] / "ashburn" / "scripts" / "vcsa-progress.py"
spec = importlib.util.spec_from_file_location("vcsa_progress", code)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class ProgressTests(unittest.TestCase):
    def test_progress_has_phase_scoped_bar_and_elapsed(self):
        buffer = io.StringIO()
        with redirect_stderr(buffer):
            monitor.render(
                {"phase": "Run firstboot scripts", "percent": 92,
                 "detail": "Starting VMware Content Library Service"},
                elapsed=615, tty=False, tick=1)
        result = buffer.getvalue()
        self.assertIn("92%", result)
        self.assertIn("10:15", result)
        self.assertIn("Run firstboot scripts", result)

    def test_finalizing_is_indeterminate(self):
        buffer = io.StringIO()
        with redirect_stderr(buffer):
            monitor.render(
                {"phase": "Finalizing VMware deployment", "percent": None,
                 "detail": "Firstboot finished; awaiting installer success"},
                elapsed=650, tty=False, tick=2)
        result = buffer.getvalue()
        self.assertIn("Finalizing VMware deployment", result)
        self.assertNotIn("100%", result)

    def test_redacts_suspicious_detail(self):
        buffer = io.StringIO()
        with redirect_stderr(buffer):
            monitor.render(
                {"phase": "Install RPMs", "percent": 20,
                 "detail": "password=do-not-print"},
                elapsed=5, tty=False, tick=0)
        self.assertNotIn("do-not-print", buffer.getvalue())
        self.assertIn("sensitive VMware message omitted", buffer.getvalue())

    def test_remote_status_parses_json_only(self):
        fake = mock.Mock(returncode=0, stdout='{"phase":"Install RPMs","percent":38,"detail":"","active":true}')
        with mock.patch.object(monitor.subprocess, "run", return_value=fake) as fn:
            state = monitor.remote_progress("192.0.2.10", "/tmp/test-known-hosts", "a" * 16)
        self.assertEqual(state["percent"], 38)
        self.assertEqual(fn.call_args.kwargs["input"], monitor.REMOTE_STATUS)

    def test_remote_failure_does_not_fake_completion(self):
        fake = mock.Mock(returncode=255, stdout="")
        with mock.patch.object(monitor.subprocess, "run", return_value=fake):
            state = monitor.remote_progress("192.0.2.10", "/tmp/test-known-hosts", "a" * 16)
        self.assertIsNone(state["percent"])
        self.assertIn("Waiting", state["phase"])


if __name__ == "__main__":
    unittest.main()
