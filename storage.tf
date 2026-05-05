# The FortiAIGate chart's shared PVC uses accessModes: [ReadWriteMany], which EBS
# (gp2/gp3) does not support. EFS provides RWX access and is the standard solution
# on EKS. This file sets up the EFS filesystem, the EFS CSI driver (with IRSA), and
# the StorageClass that the Helm chart references.

# IAM role for the EFS CSI driver controller (via IRSA).
# Defined here rather than in eks.tf to break the circular dependency:
# module.eks needs the IRSA ARN for the addon, but IRSA needs the OIDC ARN from
# module.eks. By using a separate aws_eks_addon resource (below), eks.tf has no
# dependency on this module.
module "irsa_efs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

# EFS CSI driver managed addon with IRSA attached.
# Separate from cluster_addons in eks.tf to avoid circular dependency.
resource "aws_eks_addon" "efs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  resolve_conflicts_on_update = "PRESERVE"
  service_account_role_arn    = module.irsa_efs_csi.iam_role_arn

  depends_on = [module.eks]
}

# Security group for EFS mount targets — allows inbound NFS only from EKS nodes.
resource "aws_security_group" "efs" {
  name_prefix = "${var.cluster_name}-efs-"
  description = "EFS NFS access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
    description     = "NFS from EKS node security group"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_efs_file_system" "fortiaigate" {
  creation_token   = var.cluster_name
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = var.efs_encrypted

  tags = {
    Name = var.cluster_name
  }
}

# One mount target per private subnet so every AZ can reach EFS.
resource "aws_efs_mount_target" "fortiaigate" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.fortiaigate.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# StorageClass used by the FortiAIGate Helm chart (storage.storageClass = "efs-sc").
# Uses EFS Access Points (efs-ap) for per-PVC directory isolation.
resource "kubernetes_storage_class" "efs" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.fortiaigate.id
    directoryPerms   = "700"
    uid              = "1001"
    gid              = "1001"
  }

  depends_on = [aws_eks_addon.efs_csi, aws_efs_mount_target.fortiaigate]
}
