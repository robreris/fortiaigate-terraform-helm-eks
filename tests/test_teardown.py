"""Exercise cleanup decisions without AWS credentials or Terraform state."""

import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "check_teardown", Path(__file__).resolve().parents[1] / "scripts/check_teardown.py",
)
teardown = importlib.util.module_from_spec(spec)
spec.loader.exec_module(teardown)


class CleanupTests(unittest.TestCase):
    def check(self, v2=None, classic=None, groups=None, enis=None, network=False):
        replies = [
            {"Vpcs": [{"VpcId": "vpc-stack"}]},
            {"LoadBalancers": v2 or []},
            {"LoadBalancerDescriptions": classic or []},
            {"TargetGroups": groups or []},
            {"NetworkInterfaces": enis or []},
        ]
        with patch.object(teardown, "aws", side_effect=replies) as api:
            result = teardown.blockers("us-west-2", "vpc-stack", network)
        self.assertIn("Name=vpc-id,Values=vpc-stack", api.call_args.args)
        return result

    def test_scopes_modern_classic_and_target_groups_to_vpc(self):
        result = self.check(
            v2=[{"VpcId": "vpc-stack", "LoadBalancerArn": "arn:lb", "LoadBalancerName": "app"},
                {"VpcId": "vpc-other", "LoadBalancerName": "other"}],
            classic=[{"VPCId": "vpc-stack", "LoadBalancerName": "legacy"}],
            groups=[{"VpcId": "vpc-stack", "TargetGroupArn": "arn:tg"},
                    {"VpcId": "vpc-other", "TargetGroupArn": "arn:other"}],
        )
        self.assertEqual([r["id"] for r in result], ["arn:lb", "legacy", "arn:tg"])

    def test_waits_for_lb_eni_after_lb_disappears(self):
        eni = {"NetworkInterfaceId": "eni-lb", "SubnetId": "subnet-public",
               "Description": "ELB app/test/123", "RequesterManaged": True}
        self.assertEqual(self.check(enis=[eni])[0]["id"], "eni-lb")
        eni["Description"] = ""
        eni["InterfaceType"] = "network_load_balancer"
        self.assertEqual(self.check(enis=[eni])[0]["id"], "eni-lb")

    def test_controller_gate_allows_expected_infrastructure_enis(self):
        eni = {"NetworkInterfaceId": "eni-efs", "SubnetId": "subnet-private",
               "Description": "EFS mount target"}
        self.assertEqual(self.check(enis=[eni]), [])
        self.assertEqual(self.check(enis=[eni], network=True)[0]["id"], "eni-efs")

    def test_network_diagnostics_include_public_addresses(self):
        eni = {"NetworkInterfaceId": "eni-nat", "SubnetId": "subnet-public",
               "Association": {"PublicIp": "192.0.2.1"},
               "PrivateIpAddresses": [{"Association": {"PublicIp": "192.0.2.2"}}]}
        result = self.check(enis=[eni], network=True)
        self.assertEqual(result[0]["public_ips"], ["192.0.2.1", "192.0.2.2"])

    def test_check_failure_never_reports_success(self):
        with patch("sys.argv", ["check_teardown", "--region", "us-west-2", "--vpc-id", "vpc-stack"]), \
             patch.object(teardown, "aws", side_effect=subprocess.CalledProcessError(1, "aws")), \
             patch("sys.stderr"):
            self.assertEqual(teardown.main(), 2)

    def test_cli_blocks_remaining_resources_and_accepts_cleanup(self):
        for resources, expected in (([{"id": "eni-lb"}], 1), ([], 0)):
            with self.subTest(resources=resources), \
                 patch("sys.argv", ["check_teardown", "--region", "us-west-2", "--vpc-id", "vpc-stack"]), \
                 patch.object(teardown, "blockers", return_value=resources), \
                 patch("sys.stdout"):
                self.assertEqual(teardown.main(), expected)

    def test_cli_keeps_pagination_and_only_uses_read_operation(self):
        with patch.object(teardown.subprocess, "run") as run:
            run.return_value.stdout = '{"NetworkInterfaces": []}'
            teardown.aws("us-west-2", "ec2", "describe-network-interfaces")
        command = run.call_args.args[0]
        self.assertNotIn("--no-paginate", command)
        self.assertEqual(command[:3], ["aws", "ec2", "describe-network-interfaces"])


if __name__ == "__main__":
    unittest.main()
