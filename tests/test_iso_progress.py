"""Offline ISO download monitor tests; no SSH and no PhoenixNAP calls.

python3 -m unittest discover -s tests -p 'test_iso_progress.py' -v
"""
import importlib.util
import io
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ashburn/scripts/iso-progress.py"
spec = importlib.util.spec_from_file_location("iso_progress", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IsoProgressTests(unittest.TestCase):
    def test_download_shows_bytes_and_actual_measured_throughput(self):
        first = module.message(
            {"state": "downloading", "bytes": 2 * (1024 ** 3)},
            None, 10.0,
        )
        self.assertIn("2.00 GiB", first)
        second = module.message(
            {"state": "downloading", "bytes": 2 * (1024 ** 3) + 50 * (1024 ** 2)},
            (2 * (1024 ** 3), 10.0), 20.0,
        )
        self.assertIn("5.0 MiB/s", second)
        self.assertIn("total size not verified", second)

    def test_ready_requires_verified_marker_status(self):
        text = module.message({"state": "ready", "bytes": 11 * 1024 ** 3},
                              None, 5.0)
        self.assertIn("MEDIA_READY", text)
        self.assertIn("11.00 GiB", text)

    def test_monitor_returns_after_ready_and_does_not_download(self):
        statuses = iter([
            {"state": "unreachable", "bytes": 0},
            {"state": "waiting", "bytes": 0},
            {"state": "downloading", "bytes": 1024 * 1024},
            {"state": "verifying", "bytes": 2 * 1024 * 1024},
            {"state": "ready", "bytes": 2 * 1024 * 1024},
        ])
        calls = []
        output = io.StringIO()
        result = module.monitor(
            "192.0.2.1", "/tmp/test-known-hosts", 0,
            get_status=lambda ip, hosts: (calls.append((ip, hosts)), next(statuses))[1],
            sleep=lambda _sec: None,
            monotonic=iter([0.0, 1.0, 2.0, 3.0, 4.0]).__next__,
            output=output,
        )
        self.assertEqual(result, 0)
        self.assertEqual(len(calls), 5)
        self.assertIn("Downloaded", output.getvalue().replace("Downloading", "Downloaded"))
        self.assertIn("Verified and mounted", output.getvalue())

    def test_no_untrusted_url_or_credentials_printed(self):
        message = module.message(
            {"state": "downloading", "bytes": 10000000}, (100, 1.0), 16.0,
        )
        self.assertNotIn("https:", message)
        self.assertNotIn("password", message.lower())


if __name__ == "__main__":
    unittest.main()
