"""Unit tests for automatic PhoenixNAP ESXi TLS SHA-256 pinning.

Run from repository root:
  python3 -m unittest discover -s tests -p 'test_pin_esxi_cert.py' -v
"""
import importlib.util
import io
from contextlib import redirect_stderr
from pathlib import Path
import tempfile
import unittest
from unittest import mock


helper_path = Path(__file__).resolve().parents[1] / "ashburn" / "scripts" / "pin-esxi-cert.py"
spec = importlib.util.spec_from_file_location("pin_esxi_cert", helper_path)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

SERVER_ID = "6ae7fcff2702997d57bd4fe7"
OTHER_SERVER_ID = "a4e7fcff2702997d57bd4fe9"
CERT_ONE = "a" * 64
CERT_TWO = "b" * 64


class CertificatePinTests(unittest.TestCase):
    def test_first_use_creates_mode_600_pin(self):
        with tempfile.TemporaryDirectory() as root, redirect_stderr(io.StringIO()) as notice:
            base = Path(root) / "certs"
            actual = helper.pin_fingerprint(SERVER_ID, CERT_ONE, base)
            saved = base / f"esxi-{SERVER_ID}.sha256"
            self.assertEqual(actual, CERT_ONE)
            self.assertEqual(saved.read_text().strip(), CERT_ONE)
            self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
            self.assertIn("trust on first use", notice.getvalue().lower())

    def test_repeat_use_accepts_matching_certificate(self):
        with tempfile.TemporaryDirectory() as root, redirect_stderr(io.StringIO()):
            base = Path(root)
            helper.pin_fingerprint(SERVER_ID, CERT_ONE, base)
            self.assertEqual(helper.pin_fingerprint(SERVER_ID, CERT_ONE, base), CERT_ONE)

    def test_repeat_use_rejects_changed_certificate(self):
        with tempfile.TemporaryDirectory() as root, redirect_stderr(io.StringIO()):
            base = Path(root)
            helper.pin_fingerprint(SERVER_ID, CERT_ONE, base)
            with self.assertRaisesRegex(ValueError, "certificate changed"):
                helper.pin_fingerprint(SERVER_ID, CERT_TWO, base)
            self.assertEqual((base / f"esxi-{SERVER_ID}.sha256").read_text().strip(), CERT_ONE)

    def test_new_server_id_can_pin_a_new_certificate(self):
        with tempfile.TemporaryDirectory() as root, redirect_stderr(io.StringIO()):
            base = Path(root)
            helper.pin_fingerprint(SERVER_ID, CERT_ONE, base)
            self.assertEqual(helper.pin_fingerprint(OTHER_SERVER_ID, CERT_TWO, base), CERT_TWO)

    def test_refuses_invalid_server_id(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError):
                helper.pin_fingerprint("../another-host", CERT_ONE, Path(root))

    def test_live_probe_returns_sha256_of_peer_der_certificate(self):
        fake_socket = mock.MagicMock()
        fake_socket.__enter__.return_value = fake_socket
        fake_tls = mock.MagicMock()
        fake_tls.__enter__.return_value.getpeercert.return_value = b"example-der-certificate"
        fake_context = mock.MagicMock()
        fake_context.wrap_socket.return_value = fake_tls
        with mock.patch.object(helper.socket, "create_connection", return_value=fake_socket) as connect:
            with mock.patch.object(helper.ssl, "SSLContext", return_value=fake_context):
                self.assertEqual(
                    helper.fingerprint_for("https://192.240.198.138/"),
                    helper.hashlib.sha256(b"example-der-certificate").hexdigest(),
                )
            connect.assert_called_once_with(("192.240.198.138", 443), timeout=15)


if __name__ == "__main__":
    unittest.main()
