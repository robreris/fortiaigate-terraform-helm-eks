#!/usr/bin/env python3
"""Test ingress, TLS, and GPU inputs with mocked providers in an isolated directory.

Requires Terraform 1.9+ and installed providers (terraform init -backend=false).
Creates no AWS or Kubernetes resources and reads no local state or tfvars.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="fortiaigate-tls-tests-") as directory:
    target = Path(directory)
    for name in ("versions.tf", "variables.tf", "gpu.tf", "tls.tf", "ingress.tf", ".terraform.lock.hcl"):
        shutil.copy2(ROOT / name, target / name)
    (target / "fortiaigate").mkdir()
    shutil.copy2(ROOT / "fortiaigate/values.yaml", target / "fortiaigate/values.yaml")
    (target / "namespace.tf").write_text('''
resource "kubernetes_namespace" "fortiaigate" {
  metadata { name = var.namespace }
}
''')
    shutil.copytree(ROOT / "tests/terraform", target / "tests")
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", "test-key.pem", "-out", "test-cert.pem", "-days", "1",
        "-subj", "/CN=fortiaigate.example.com",
        "-addext", "subjectAltName=DNS:fortiaigate.example.com",
    ], cwd=target, check=True, capture_output=True)
    subprocess.run([
        "terraform", "init", "-backend=false", "-no-color",
        "-plugin-dir=" + str(ROOT / ".terraform/providers"),
    ], cwd=target, check=True)
    subprocess.run(["terraform", "test", "-no-color"], cwd=target, check=True)
