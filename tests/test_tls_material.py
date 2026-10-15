"""Validate real certificate chains and reject unsafe supplied material offline."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_tls", ROOT / "scripts/check_tls.py")
check_tls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_tls)


class TLSMaterialChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="fortiaigate-cert-fixture-")
        cls.path = Path(cls.temp.name)

        def openssl(*args):
            subprocess.run(["openssl", *args], cwd=cls.path, check=True, capture_output=True)

        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-keyout", "ca.key", "-out", "ca.pem", "-subj", "/CN=Test CA",
                "-addext", "basicConstraints=critical,CA:TRUE")
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
                "-out", "server.csr", "-subj", "/CN=fortiaigate.example.com")
        (cls.path / "extensions.txt").write_text(
            "subjectAltName=DNS:fortiaigate.example.com\nbasicConstraints=CA:FALSE\n"
            "extendedKeyUsage=serverAuth\n")
        openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                "-CAcreateserial", "-out", "server.pem", "-days", "1", "-extfile", "extensions.txt")
        openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                "-CAserial", "ca.srl", "-out", "expired.pem", "-days", "-1", "-extfile", "extensions.txt")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check(self, certificate="server.pem", key="server.key", hostname="fortiaigate.example.com", ca="ca.pem"):
        check_tls.check_certificate(self.path / certificate, self.path / key, hostname,
                                    self.path / ca if ca else None)

    def test_valid_private_ca(self):
        self.check()

    def test_mismatched_key(self):
        with self.assertRaisesRegex(check_tls.CertificateError, "do not match"):
            self.check(key="ca.key")

    def test_wrong_hostname(self):
        with self.assertRaises(check_tls.CertificateError):
            self.check(hostname="wrong.example.com")

    def test_expired_certificate(self):
        with self.assertRaises(check_tls.CertificateError):
            self.check(certificate="expired.pem")

    def test_untrusted_private_ca(self):
        with self.assertRaises(check_tls.CertificateError):
            self.check(ca=None)

    def test_leaf_is_not_a_root_ca(self):
        with self.assertRaisesRegex(check_tls.CertificateError, "must be a CA"):
            self.check(ca="server.pem")
