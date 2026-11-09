data "aws_availability_zones" "available" {
  state = "available"

  # EKS nodes use regional Availability Zones, not Local or Wavelength Zones.
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_ec2_instance_type_offerings" "gpu" {
  count = var.gpu_enabled ? 1 : 0

  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.gpu_node_instance_type]
  }
}

locals {
  # Retain the original first three subnet indexes and append the remaining AZs.
  azs      = sort(data.aws_availability_zones.available.names)
  vpc_cidr = "10.0.0.0/16"

  # /20 block 3 (10.0.48.0/20) contains the public /24 subnets. Use block 6
  # for private index 3, preserving blocks 4 and 5 already created by an
  # interrupted AZ expansion as well as the original first three subnets.
  private_subnet_netnums = concat([0, 1, 2, 6, 4, 5], range(7, 16))

  # Offerings indicate support, not live capacity. Let Auto Scaling try every
  # supported AZ instead of repeatedly attempting zones without this GPU type.
  gpu_subnet_ids = var.gpu_enabled ? [
    for index, az in local.azs : module.vpc.private_subnets[index]
    if contains(data.aws_ec2_instance_type_offerings.gpu[0].locations, az)
  ] : []
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = local.vpc_cidr
  azs  = local.azs

  # One private /20 subnet per AZ, keeping the original CIDRs at indexes 0–2.
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, local.private_subnet_netnums[k])]
  # Public /24 subnets for NAT gateway and load balancers
  public_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
