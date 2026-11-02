"""Offline tests for Ashburn Ubuntu primary-IP discovery.

Run from repository root:
  python3 -m unittest discover -s tests -p 'test_resolve_installer_ip.py' -v
"""
import importlib.util
from pathlib import Path
import unittest


resolver_path = Path(__file__).resolve().parents[1] / "ashburn" / "scripts" / "resolve-installer-ip.py"
spec = importlib.util.spec_from_file_location("resolve_installer_ip", resolver_path)
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


def state_with(ips, primary=None):
    attrs = {"public_ip_addresses": ips}
    if primary is not None:
        attrs["primary_ip_address"] = primary
    return {
        "resources": [{
            "type": "pnap_server", "name": "installer",
            "instances": [{"attributes": attrs}],
        }],
    }


class InstallerIPTests(unittest.TestCase):
    def test_plain_ip(self):
        self.assertEqual(str(resolver.resolve(state_with(["131.153.155.201"]))), "131.153.155.201")

    def test_slash_31(self):
        self.assertEqual(str(resolver.resolve(state_with(["131.153.155.200/31"]))), "131.153.155.201")

    def test_range(self):
        self.assertEqual(str(resolver.resolve(state_with(["131.153.155.200 - 131.153.155.201"]))), "131.153.155.201")

    def test_two_plain_ips(self):
        self.assertEqual(str(resolver.resolve(state_with(["131.153.155.201", "131.153.155.200"]))), "131.153.155.201")

    def test_explicit_primary_takes_priority(self):
        self.assertEqual(str(resolver.resolve(state_with(["131.153.155.200/31"], "131.153.155.201"))), "131.153.155.201")

    def test_refuse_ambiguous(self):
        with self.assertRaises(ValueError):
            resolver.resolve(state_with(["131.153.155.200/29"]))

    def test_refuse_empty(self):
        with self.assertRaises(ValueError):
            resolver.resolve(state_with([]))


if __name__ == "__main__":
    unittest.main()
