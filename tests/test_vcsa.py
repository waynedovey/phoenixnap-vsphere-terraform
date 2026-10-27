import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from vcsa import render_config  # noqa: E402


TEMPLATE = {
    "__version": "vendor-defined",
    "new_vcsa": {
        "esxi": {
            "hostname": "192.0.2.20",
            "username": "root",
            "password": "SHOULD_BE_OVERWRITTEN",
            "deployment_network": "VM Network",
            "datastore": "datastore1",
        },
        "appliance": {"name": "vcsa-01", "deployment_option": "tiny"},
        "network": {
            "mode": "static",
            "system_name": "vcsa.example.test",
            "ip": "192.0.2.21",
            "prefix": "24",
            "gateway": "192.0.2.1",
            "dns_servers": ["192.0.2.53"],
        },
        "os": {"password": "PLACEHOLDER", "ntp_servers": ["192.0.2.53"]},
        "sso": {"password": "PLACEHOLDER", "domain_name": "vsphere.local"},
    },
}
CREDS = {
    "ESXI_ROOT_PASSWORD": "only-in-memory-1",
    "VCSA_ROOT_PASSWORD": "only-in-memory-2",
    "VCSA_SSO_PASSWORD": "only-in-memory-3",
}


class VcsaTemplateTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.template = Path(self.folder.name) / "vendor.json"
        self.template.write_text(json.dumps(TEMPLATE), encoding="utf-8")

    def test_injects_secrets_without_changing_original(self):
        config = render_config(self.template, CREDS)
        self.assertEqual(config["new_vcsa"]["esxi"]["password"], CREDS["ESXI_ROOT_PASSWORD"])
        self.assertEqual(config["new_vcsa"]["os"]["password"], CREDS["VCSA_ROOT_PASSWORD"])
        self.assertEqual(config["new_vcsa"]["sso"]["password"], CREDS["VCSA_SSO_PASSWORD"])
        self.assertNotIn("only-in-memory", self.template.read_text(encoding="utf-8"))

    def test_missing_secret_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "ESXI_ROOT_PASSWORD"):
            render_config(self.template, {})

    def test_nonstatic_network_fails_closed(self):
        data = json.loads(self.template.read_text(encoding="utf-8"))
        data["new_vcsa"]["network"]["mode"] = "dhcp"
        self.template.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "static"):
            render_config(self.template, CREDS)


if __name__ == "__main__":
    unittest.main()
