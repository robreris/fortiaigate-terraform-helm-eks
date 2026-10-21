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

variable "gpu_tuning_profile" {
  description = "Inference defaults: auto selects g5 for G5 instances and chart otherwise; g5 uses shared A10G reference settings; chart retains vendor defaults."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "g5", "chart"], var.gpu_tuning_profile)
    error_message = "gpu_tuning_profile must be auto, g5, or chart."
  }
}

variable "gpu_tuning" {
  description = "Optional inference overrides in tfvars. Unset fields inherit profile/chart values. Memory uses whole Mi/Gi quantities. Explicit fields override extra_values_files."
  type = object({
    triton_memory_request        = optional(string)
    triton_memory_limit          = optional(string)
    triton_dlp_instances_per_gpu = optional(number)
    triton_dlp_max_batch_size    = optional(number)
    vllm_memory_request          = optional(string)
    vllm_memory_limit            = optional(string)
    vllm_max_num_seqs            = optional(number)
    vllm_api_server_count        = optional(number)
    vllm_gpu_memory_utilization  = optional(number)
    vllm_max_model_len           = optional(number)
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([for value in [
      var.gpu_tuning.triton_memory_request, var.gpu_tuning.triton_memory_limit,
      var.gpu_tuning.vllm_memory_request, var.gpu_tuning.vllm_memory_limit,
    ] : value == null ? true : can(regex("^[1-9][0-9]*(Mi|Gi)$", value))])
    error_message = "GPU memory overrides must be positive whole Mi/Gi quantities, e.g. 8192Mi or 12Gi."
  }
  validation {
    condition = alltrue([for value in [
      var.gpu_tuning.triton_dlp_instances_per_gpu, var.gpu_tuning.triton_dlp_max_batch_size,
      var.gpu_tuning.vllm_max_num_seqs, var.gpu_tuning.vllm_api_server_count,
      var.gpu_tuning.vllm_max_model_len,
    ] : value == null ? true : value >= 1 && floor(value) == value])
    error_message = "GPU instance counts, batch sizes, concurrency, API process counts, and context lengths must be positive whole numbers."
  }
  validation {
    condition     = var.gpu_tuning.vllm_gpu_memory_utilization == null ? true : var.gpu_tuning.vllm_gpu_memory_utilization > 0 && var.gpu_tuning.vllm_gpu_memory_utilization < 1
    error_message = "vllm_gpu_memory_utilization must be greater than 0 and less than 1."
  }
  validation {
    condition = alltrue([for pair in [
      [var.gpu_tuning.triton_memory_request, var.gpu_tuning.triton_memory_limit],
      [var.gpu_tuning.vllm_memory_request, var.gpu_tuning.vllm_memory_limit],
      ] : pair[0] == null || pair[1] == null ? true : try(
      tonumber(regex("^([0-9]+)", pair[0])[0]) * (endswith(pair[0], "Gi") ? 1024 : 1) <=
      tonumber(regex("^([0-9]+)", pair[1])[0]) * (endswith(pair[1], "Gi") ? 1024 : 1), false
    )])
    error_message = "An explicit GPU memory request must not exceed its explicit limit."
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
  default     = "V8.0.2-build0055"
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
  description = "Optional advanced Helm values files, merged left-to-right after GPU profile defaults and before explicit gpu_tuning, placement, ingress, and TLS settings."
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
