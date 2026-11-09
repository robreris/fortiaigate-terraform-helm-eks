"""Evaluate the VPC's actual CIDR expressions without providers, AWS, or state."""
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "vpc.tf").read_text()


def expression(name):
    match = re.search(rf"^\s*{name}\s*=\s*(.+)$", source, re.MULTILINE)
    assert match, f"Missing single-line {name} expression in vpc.tf"
    return match.group(1)


# Reuse the production expressions, evaluating them in an isolated provider-free
# configuration. Check both compatibility and overlaps, not just unique CIDRs.
with tempfile.TemporaryDirectory(prefix="fortiaigate-subnet-check-") as directory:
    target = Path(directory)
    for count in (3, 6, 15):
        config = "locals {\n"
        config += f"  azs = {json.dumps([f'zone-{i}' for i in range(count)])}\n"
        for name in ("vpc_cidr", "private_subnet_netnums"):
            config += f"  {name} = {expression(name)}\n"
        for name in ("private_subnets", "public_subnets"):
            config += f"  {name} = {expression(name)}\n"
        config += "}\n"
        (target / "main.tf").write_text(config)
        result = subprocess.check_output(
            ["terraform", "console", "-no-color"], cwd=target, text=True,
            input="jsonencode([local.private_subnets, local.public_subnets])\n",
        )
        private, public = json.loads(json.loads(result))
        assert private[:3] == ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
        assert public[:3] == ["10.0.48.0/24", "10.0.49.0/24", "10.0.50.0/24"]
        if count >= 6:
            assert private[4:6] == ["10.0.64.0/20", "10.0.80.0/20"]
        networks = [ipaddress.ip_network(cidr) for cidr in private + public]
        vpc = ipaddress.ip_network("10.0.0.0/16")
        assert all(network.subnet_of(vpc) for network in networks)
        for index, network in enumerate(networks):
            for other in networks[index + 1:]:
                assert not network.overlaps(other), f"CIDR overlap: {network} and {other}"
        print(f"{count} AZs: no subnet overlaps; existing CIDRs preserved")
