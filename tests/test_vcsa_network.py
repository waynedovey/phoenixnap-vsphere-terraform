"""Regression tests for ESXi public management vs VCSA VM port groups.

python3 -m unittest discover -s tests -p 'test_vcsa_network.py' -v
"""
import importlib.util
from pathlib import Path
import unittest


module_file = Path(__file__).resolve().parents[1] / "ashburn" / "scripts" / "vcsa-network.py"
spec = importlib.util.spec_from_file_location("vcsa_network", module_file)
vcsa_network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vcsa_network)


PUBLIC_ONLY = """Name:                    private.3
Virtual switch:          vSwitch0
VLAN ID:                 3
Active ports:            1

Name:                    public.2
Virtual switch:          vSwitch0
VLAN ID:                 2
Active ports:            1
"""
WITH_VM = PUBLIC_ONLY + """Name:                    vcsa-public
Virtual switch:          vSwitch0
VLAN ID:                 2
Active ports:            0
"""
WRONG_VM = PUBLIC_ONLY + """Name:                    vcsa-public
Virtual switch:          vSwitch0
VLAN ID:                 3
Active ports:            0
"""


class VC SANetworkTests(unittest.TestCase):
    def test_creates_dedicated_vm_group_matching_public_vlan(self):
        plan = vcsa_network.plan(PUBLIC_ONLY)
        self.assertEqual(plan["management_portgroup"], "public.2")
        self.assertEqual(plan["vm_portgroup"], "vcsa-public")
        self.assertEqual(plan["vswitch"], "vSwitch0")
        self.assertEqual(plan["vlan_id"], 2)
        self.assertTrue(plan["create"])

    def test_idempotent_existing_vm_group(self):
        plan = vcsa_network.plan(WITH_VM, require_existing=True)
        self.assertFalse(plan["create"])

    def test_refuse_wrong_vlan(self):
        with self.assertRaisesRegex(ValueError, "unexpected switch/VLAN"):
            vcsa_network.plan(WRONG_VM)

    def test_require_existing_rejects_missing_vm_group(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            vcsa_network.plan(PUBLIC_ONLY, require_existing=True)

    def test_refuse_ambiguous_public_management_groups(self):
        two = PUBLIC_ONLY + """Name:                    public.5
Virtual switch:          vSwitch0
VLAN ID:                 5
"""
        with self.assertRaisesRegex(ValueError, "exactly one"):
            vcsa_network.plan(two)

    def test_refuse_mismatch_between_management_name_and_vlan(self):
        with self.assertRaisesRegex(ValueError, "disagree"):
            vcsa_network.plan(PUBLIC_ONLY.replace("VLAN ID:                 2", "VLAN ID:                 5"))

    def test_refuse_missing_port_groups(self):
        with self.assertRaises(ValueError):
            vcsa_network.plan("")


if __name__ == "__main__":
    unittest.main()
