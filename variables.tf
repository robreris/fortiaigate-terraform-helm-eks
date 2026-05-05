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
}

variable "gpu_enabled" {
  description = "Add a GPU node group (g5.2xlarge) for Triton inference. When false, triton is disabled and all workloads run CPU-only."
  type        = bool
  default     = false
}

variable "gpu_node_instance_type" {
  description = "EC2 instance type for the GPU node group"
  type        = string
  default     = "g5.2xlarge"
}

variable "image_repository" {
  description = "Container registry prefix for FortiAIGate images (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate)"
  type        = string
}

variable "image_tag" {
  description = "Image tag for all FortiAIGate service images"
  type        = string
  default     = "V8.0.0-build0024"
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
}

variable "ingress_host" {
  description = "Hostname for the ingress rule. Leave empty to match all hosts."
  type        = string
  default     = ""
}

variable "ingress_annotations" {
  description = "Additional ingress annotations. Used for ALB configuration (e.g. certificate ARN, scheme). Keys with dots/slashes are handled correctly via values YAML merge."
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
}

variable "efs_encrypted" {
  description = "Encrypt the EFS file system at rest with a KMS key. Disable if no suitable KMS key is available in the account."
  type        = bool
  default     = true
}

variable "licenses" {
  description = "Map of EKS node name to local license file path. Node names are available after cluster creation via 'kubectl get nodes'. Example: { \"ip-10-0-1-100.us-east-1.compute.internal\" = \"/path/to/license.lic\" }"
  type        = map(string)
  default     = {}
}

variable "update_strategy" {
  description = "Deployment update strategy. 'Recreate' avoids GPU deadlock on single-GPU nodes; 'RollingUpdate' for zero-downtime when spare capacity exists."
  type        = string
  default     = "Recreate"
}

variable "extra_values_files" {
  description = "Additional Helm values YAML files to merge (applied left-to-right, later files take precedence)"
  type        = list(string)
  default     = []
}

variable "internal" {
  description = "Deploy as an internal (private) service. Sets the ALB scheme to 'internal' so it is only reachable within the VPC and connected networks. Requires ingress_class = 'alb'."
  type        = bool
  default     = false
}
