provider "aws" {
  region = var.aws_region
}

# Both the helm and kubernetes providers authenticate via the aws CLI exec plugin.
# This means the AWS CLI must be installed and configured with credentials that have
# eks:DescribeCluster and the ability to obtain a token for the cluster.
#
# First bootstrap module.vpc and module.eks with the account tfvars before
# planning/applying Kubernetes or Helm resources. The cluster must exist and
# authorize the caller; Terraform cannot defer every provider operation safely.

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}
