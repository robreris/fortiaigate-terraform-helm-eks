#!/usr/bin/env python3
"""Validate supplied serving certificate material before Terraform apply."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


class CertificateError(ValueError):
    pass


def openssl(*args):
    result = subprocess.run(["openssl", *args], capture_output=True)
    if result.returncode:
        # Do not echo subprocess input or private-key material.
        raise CertificateError("OpenSSL validation failed: " + result.stderr.decode().strip())
    return result.stdout


def check_certificate(certificate, private_key, hostname, ca=None):
    chain = re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        Path(certificate).read_text(), re.DOTALL,
    )
    if not chain:
        raise CertificateError("The serving certificate file must contain a PEM certificate chain.")
    with tempfile.TemporaryDirectory(prefix="fortiaigate-cert-check-") as directory:
        leaf = Path(directory) / "leaf.pem"
        leaf.write_text(chain[0] + "\n")
        # X509 checkhost may report mismatch on stdout on some OpenSSL versions;
        # verify -verify_hostname below is the authoritative hostname check.
        openssl("x509", "-in", str(leaf), "-checkend", "0", "-noout")
        certificate_public_key = openssl("x509", "-in", str(leaf), "-pubkey", "-noout")
        private_public_key = openssl("pkey", "-in", str(private_key), "-passin", "pass:", "-pubout")
        if certificate_public_key != private_public_key:
            raise CertificateError("The serving certificate and private key do not match.")
        args = ["verify", "-purpose", "sslserver", "-verify_hostname", hostname]
        if ca:
            ca_chain = re.findall(
                r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                Path(ca).read_text(), re.DOTALL,
            )
            if len(ca_chain) != 1:
                raise CertificateError("Supply exactly one root CA certificate for the client trust bundle.")
            constraints = openssl("x509", "-in", str(ca), "-noout", "-ext", "basicConstraints")
            if b"CA:TRUE" not in constraints:
                raise CertificateError("The supplied root certificate must be a CA certificate.")
            args += ["-CAfile", str(ca), "-no-CApath", "-no-CAstore"]
        if len(chain) > 1:
            intermediates = Path(directory) / "intermediates.pem"
            intermediates.write_text("\n".join(chain[1:]) + "\n")
            args += ["-untrusted", str(intermediates)]
        openssl(*args, str(leaf))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate", required=True, type=Path)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--ca", type=Path, help="Private root CA; omit to check against the system trust store")
    args = parser.parse_args()
    try:
        check_certificate(args.certificate, args.private_key, args.hostname, args.ca)
    except (CertificateError, OSError) as error:
        parser.exit(1, str(error) + "\n")
    print("Certificate chain, hostname, validity, and private key verified.")


if __name__ == "__main__":
    main()
