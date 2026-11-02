"""Offline regression tests for fail-closed VCSA deployment reconciliation.

Run: python3 -m unittest discover -s tests -p 'test_vcsa_verify.py' -v
"""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock


script = Path(__file__).resolve().parents[1] / "ashburn" / "scripts" / "vcsa-verify.py"
spec = importlib.util.spec_from_file_location("vcsa_verify", script)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(
            installer_ip="192.0.2.20", vcsa_ip="192.0.2.21",
            known_hosts="/tmp/test-known-hosts", run_id="a" * 16,
            attempts=3, delay=0,
        )

    def test_recovers_only_with_current_run_log_vm_and_authenticated_sso(self):
        vm = mock.Mock(return_value=True)
        sso = mock.Mock(return_value=True)
        self.assertEqual(verifier.reconcile(
            self.args, status=lambda *a: "complete", vm=vm, login=sso,
            sleep=lambda seconds: None), 0)
        vm.assert_called_once_with(self.args.vcsa_ip)
        sso.assert_called_once_with(self.args.vcsa_ip)

    def test_no_recovery_from_success_log_without_sso_auth(self):
        self.assertEqual(verifier.reconcile(
            self.args, status=lambda *a: "complete",
            vm=lambda ip: True, login=lambda ip: False,
            sleep=lambda seconds: None), 1)

    def test_no_recovery_from_log_without_vm(self):
        sso = mock.Mock()
        self.assertEqual(verifier.reconcile(
            self.args, status=lambda *a: "complete",
            vm=lambda ip: False, login=sso,
            sleep=lambda seconds: None), 1)
        sso.assert_not_called()

    def test_retry_can_observe_delayed_vmware_success(self):
        states = iter(["in-progress", "complete"])
        nap = mock.Mock()
        self.assertEqual(verifier.reconcile(
            self.args, status=lambda *a: next(states),
            vm=lambda ip: True, login=lambda ip: True, sleep=nap), 0)
        nap.assert_called_once_with(0)

    def test_terminal_vmware_failure_never_gets_overridden(self):
        vm = mock.Mock()
        self.assertEqual(verifier.reconcile(
            self.args, status=lambda *a: "failed", vm=vm,
            login=lambda ip: True, sleep=lambda s: None), 1)
        vm.assert_not_called()

    def test_missing_marker_cannot_fake_success(self):
        self.assertEqual(verifier.reconcile(
            self.args, status=lambda *a: "missing-marker",
            vm=lambda ip: True, login=lambda ip: True,
            sleep=lambda s: None), 1)

    def test_unreachable_remote_cannot_fake_success(self):
        with mock.patch.object(verifier, "command", return_value=None):
            self.assertEqual(verifier.remote_status(
                self.args.installer_ip, self.args.known_hosts,
                self.args.run_id), "unreachable")

    def test_esxi_requires_matching_ip_and_power_state(self):
        found = SimpleNamespace(returncode=0, stdout="/ha-datacenter/vm/vcsa-ash\n")
        info = SimpleNamespace(
            returncode=0, stdout="Power state: poweredOn\nIP address: 192.0.2.21\n")
        with mock.patch.object(verifier, "command", side_effect=[found, info]):
            self.assertTrue(verifier.esxi_vm_matches("192.0.2.21"))
        with mock.patch.object(verifier, "command", side_effect=[found, info]):
            self.assertFalse(verifier.esxi_vm_matches("192.0.2.22"))

    def test_vcenter_requires_authenticated_inventory_not_just_about(self):
        about = SimpleNamespace(returncode=0, stdout="API type:     VirtualCenter\n")
        fail = SimpleNamespace(returncode=1, stdout="")
        ok = SimpleNamespace(returncode=0, stdout="")
        with mock.patch.dict(verifier.os.environ, {"VCSA_SSO_PASSWORD": "test-secret"}):
            with mock.patch.object(verifier, "command", side_effect=[about, fail]) as cmd:
                self.assertFalse(verifier.vcenter_authenticated("192.0.2.21"))
                env = cmd.call_args.kwargs["env"]
                self.assertEqual(env["GOVC_DATACENTER"], "")
                self.assertEqual(env["GOVC_PASSWORD"], "test-secret")
            with mock.patch.object(verifier, "command", side_effect=[about, ok]):
                self.assertTrue(verifier.vcenter_authenticated("192.0.2.21"))


if __name__ == "__main__":
    unittest.main()
