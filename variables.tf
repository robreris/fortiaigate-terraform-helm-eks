variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "fortiaigate"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "app_node_instance_type" {
  description = "EC2 instance type for application node group"
  type        = string
  default     = "m7i.4xlarge"
}

variable "app_node_count" {
  description = "Number of application nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.app_node_count >= 1
    error_message = "app_node_count must be at least 1."
  }
}

variable "gpu_enabled" {
  description = "Add a GPU node group (g6e.2xlarge) for Triton and vLLM inference. When false, GPU inference is disabled; POLICY detectors fail closed."
  type        = bool
  default     = false
}

variable "gpu_node_instance_type" {
  description = "EC2 instance type for the GPU node group"
  type        = string
  default     = "g6e.2xlarge"
}

variable "gpu_node_ami_type" {
  description = "EKS managed node group AMI type for GPU nodes. Use AL2023_x86_64_NVIDIA for CUDA 13+ container compatibility."
  type        = string
  default     = "AL2023_x86_64_NVIDIA"

  validation {
    condition     = contains(["AL2023_x86_64_NVIDIA", "AL2_x86_64_GPU"], var.gpu_node_ami_type)
    error_message = "gpu_node_ami_type must be either AL2023_x86_64_NVIDIA or AL2_x86_64_GPU."
  }
}

variable "image_repository" {
  description = "Container registry prefix for FortiAIGate images (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate)"
  type        = string

  validation {
    condition     = length(var.image_repository) > 0
    error_message = "image_repository is required and must point at a registry containing the FortiAIGate images."
  }
}

variable "image_tag" {
  description = "Image tag for all FortiAIGate service images"
  type        = string
  default     = "V8.0.2-build0054"
}

variable "namespace" {
  description = "Kubernetes namespace for the FortiAIGate deployment"
  type        = string
  default     = "fortiaigate"
}

variable "ingress_class" {
  description = "Ingress class name. Use 'nginx' for nginx-ingress or 'alb' for AWS Load Balancer Controller."
  type        = string
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "alb"], var.ingress_class)
    error_message = "ingress_class must be either 'nginx' or 'alb'."
  }
}

variable "ingress_host" {
  description = "Hostname for the ingress rule. Leave empty to match all hosts."
  type        = string
  default     = ""
}

variable "ingress_annotations" {
  description = "Additional ingress annotations. ALB scheme must agree with internal; acm_certificate_arn takes precedence over its annotation. Keys with dots/slashes are handled via values YAML merge."
  type        = map(string)
  default     = {}
}

variable "aws_load_balancer_controller_enabled" {
  description = "Install AWS Load Balancer Controller when ingress_class is 'alb'. Disable if a controller is already managed outside this Terraform stack."
  type        = bool
  default     = true
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Helm chart version for aws-load-balancer-controller from the AWS EKS charts repository."
  type        = string
  default     = "1.14.0"
}

variable "storage_size" {
  description = "Size of the shared EFS-backed PVC"
  type        = string
  default     = "100Gi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi|Ti)$", var.storage_size))
    error_message = "storage_size must be a Kubernetes quantity with a binary suffix (e.g. '100Gi', '500Mi', '1Ti')."
  }
}

variable "efs_encrypted" {
  description = "Encrypt the EFS file system at rest with a KMS key. Disable if no suitable KMS key is available in the account."
  type        = bool
  default     = true
}

variable "licenses" {
  description = "Deprecated in 8.0.2. Leave empty and upload deployment licenses through POST /api/v1/admin/licenses."
  type        = map(string)
  default     = {}

  validation {
    condition     = length(var.licenses) == 0
    error_message = "FortiAIGate 8.0.2 uses deployment licenses. Remove the node-keyed licenses map and upload the license through POST /api/v1/admin/licenses after deployment."
  }
}

variable "update_strategy" {
  description = "Deployment update strategy. 'Recreate' avoids GPU deadlock on single-GPU nodes; 'RollingUpdate' for zero-downtime when spare capacity exists."
  type        = string
  default     = "Recreate"

  validation {
    condition     = contains(["Recreate", "RollingUpdate"], var.update_strategy)
    error_message = "update_strategy must be either 'Recreate' or 'RollingUpdate'."
  }
}

variable "extra_values_files" {
  description = "Additional Helm values YAML files to merge (applied left-to-right, later files take precedence)"
  type        = list(string)
  default     = []
}

variable "internal" {
  description = "Deploy as an internal (private) service. Sets and enforces the ALB scheme to internal so it is only reachable within the VPC and connected networks. Requires ingress_class = 'alb'."
  type        = bool
  default     = false

  validation {
    condition     = !var.internal || var.ingress_class == "alb"
    error_message = "internal = true is only supported with ingress_class = 'alb'."
  }
}

variable "acm_certificate_arn" {
  description = "Existing ACM certificate ARN for ALB frontend HTTPS, in aws_region. Works for public and internal ALBs. Empty keeps HTTP unless certificate-arn is supplied through ingress_annotations."
  type        = string
  default     = ""

  validation {
    condition     = var.acm_certificate_arn == "" || can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/.+$", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be an ACM certificate ARN."
  }
}

variable "tls_certificate_path" {
  description = "Optional PEM certificate chain for web/API pod HTTPS (and nginx frontend TLS). Requires tls_private_key_path and ingress_host. ALB frontend TLS uses ACM independently."
  type        = string
  default     = ""

  validation {
    condition     = var.tls_certificate_path == "" ? true : can(regex("-----BEGIN CERTIFICATE-----", file(var.tls_certificate_path)))
    error_message = "tls_certificate_path must point to a readable PEM certificate chain."
  }
}

variable "tls_private_key_path" {
  description = "Unencrypted PEM private key for tls_certificate_path. Contents are stored in Terraform state; keep the file outside version control."
  type        = string
  default     = ""

  validation {
    condition     = var.tls_private_key_path == "" ? true : can(regex("-----BEGIN (RSA |EC )?PRIVATE KEY-----", file(var.tls_private_key_path)))
    error_message = "tls_private_key_path must point to a readable unencrypted PEM private key."
  }
}

variable "tls_ca_certificate_path" {
  description = "Optional PEM root CA for a supplied web certificate. Used for client trust export, not uploaded to ALB. Internal services always use the generated CA."
  type        = string
  default     = ""

  validation {
    condition     = var.tls_ca_certificate_path == "" ? true : can(regex("-----BEGIN CERTIFICATE-----", file(var.tls_ca_certificate_path)))
    error_message = "tls_ca_certificate_path must point to a readable PEM certificate."
  }
}
