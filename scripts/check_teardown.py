#!/usr/bin/env python3
"""Read-only AWS checks before removing controllers or diagnosing VPC teardown."""

import argparse
import json
import subprocess
import sys


def aws(region, *args):
    result = subprocess.run(
        ["aws", *args, "--region", region, "--output", "json", "--no-cli-pager"],
        capture_output=True, text=True, check=True,
    )
    # Leave CLI pagination enabled so all resources are inspected.
    return json.loads(result.stdout)


def blockers(region, vpc_id, network=False):
    """Return VPC-scoped resources; API/permission failures must propagate."""
    aws(region, "ec2", "describe-vpcs", "--vpc-ids", vpc_id)
    found = []
    for service, key in (("elbv2", "LoadBalancers"), ("elb", "LoadBalancerDescriptions")):
        for lb in aws(region, service, "describe-load-balancers")[key]:
            if lb.get("VpcId", lb.get("VPCId")) == vpc_id:
                found.append({
                    "kind": service,
                    "id": lb.get("LoadBalancerArn", lb["LoadBalancerName"]),
                    "name": lb["LoadBalancerName"],
                })
    for group in aws(region, "elbv2", "describe-target-groups")["TargetGroups"]:
        if group.get("VpcId") == vpc_id:
            found.append({"kind": "target-group", "id": group["TargetGroupArn"]})
    interfaces = aws(
        region, "ec2", "describe-network-interfaces",
        "--filters", f"Name=vpc-id,Values={vpc_id}",
    )["NetworkInterfaces"]
    for eni in interfaces:
        description = eni.get("Description", "")
        is_lb = description.startswith("ELB ") or eni.get("InterfaceType") in {
            "load_balancer", "network_load_balancer", "gateway_load_balancer",
        }
        if network or is_lb:
            public_ips = {ip["Association"]["PublicIp"]
                          for ip in eni.get("PrivateIpAddresses", [])
                          if ip.get("Association", {}).get("PublicIp")}
            if eni.get("Association", {}).get("PublicIp"):
                public_ips.add(eni["Association"]["PublicIp"])
            found.append({
                "kind": "network-interface", "id": eni["NetworkInterfaceId"],
                "subnet": eni["SubnetId"], "description": description,
                "status": eni.get("Status"),
                "requester_managed": eni.get("RequesterManaged"),
                "instance": eni.get("Attachment", {}).get("InstanceId"),
                "public_ips": sorted(public_ips),
            })
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True)
    parser.add_argument("--vpc-id", required=True)
    parser.add_argument(
        "--network", action="store_true",
        help="Report every ENI for recovery; EKS, EFS and NAT ENIs are expected before full destroy.",
    )
    args = parser.parse_args()
    try:
        found = blockers(args.region, args.vpc_id, args.network)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"AWS cleanup check failed; cleanup is NOT verified: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        return 2
    print(f"VPC {args.vpc_id} in {args.region}")
    if found:
        print(json.dumps(found, indent=2))
        print("Resources remain. Inspect their owners; this script deletes nothing.")
        return 1
    print("No load balancers, target groups or load balancer ENIs remain."
          if not args.network else
          "No load balancers, target groups or network interfaces remain.")
    print("This check does not verify EFS access points or every possible VPC dependency.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
