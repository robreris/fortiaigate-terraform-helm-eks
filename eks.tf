module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id = module.vpc.vpc_id
  # Preserve the existing control-plane and default application node subnets.
  subnet_ids = slice(module.vpc.private_subnets, 0, min(3, length(local.azs)))

  # Public endpoint allows kubectl access from outside the VPC.
  # For production, restrict cluster_endpoint_public_access_cidrs or disable public access.
  cluster_endpoint_public_access = true

  # Grant the IAM identity running Terraform admin access via an EKS Access Entry.
  # Without this, the cluster creator has no Kubernetes API permissions in module v20+.
  enable_cluster_creator_admin_permissions = true

  # Core addons. The EFS CSI driver is managed separately in storage.tf
  # to avoid a circular dependency with its IRSA role.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  eks_managed_node_groups = merge(
    {
      app = {
        instance_types = [var.app_node_instance_type]
        min_size       = 1
        max_size       = var.app_node_count + 2
        desired_size   = var.app_node_count
        labels = {
          fortiaigate-role = "app"
        }
        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = 250
              volume_type           = "gp3"
              delete_on_termination = true
            }
          }
        }
      }
    },
    var.gpu_enabled ? {
      gpu = {
        instance_types = [var.gpu_node_instance_type]
        subnet_ids     = local.gpu_subnet_ids
        # Use the AL2023 NVIDIA AMI by default so GPU containers with CUDA 13+
        # runtimes have a compatible host driver.
        ami_type     = var.gpu_node_ami_type
        min_size     = 0
        max_size     = 1
        desired_size = 1
        labels = {
          fortiaigate-role = "gpu"
        }
        taints = {
          fortiaigate_gpu = {
            key    = "fortiaigate-gpu"
            value  = "true"
            effect = "NO_SCHEDULE"
          }
        }
        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = 250
              volume_type           = "gp3"
              delete_on_termination = true
            }
          }
        }
      }
    } : {}
  )
}
