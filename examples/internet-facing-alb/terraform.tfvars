# Internet-facing ALB with HTTPS termination via ACM.
#
# IMPORTANT: The ACM certificate ARN MUST be in the same region as aws_region.
# Listener creation will fail at apply time if these don't match.
#
# After apply, create a Route 53 alias A record for ingress_host pointing at the
# ALB DNS name (see docs/route53-setup.md).

aws_region   = "us-west-2"
cluster_name = "fortiaigate-public"

# REQUIRED — your FortiAIGate image registry.
image_repository = "123456789.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"

ingress_class                        = "alb"
internal                             = false
ingress_host                         = "fortiaigate.example.com"
aws_load_balancer_controller_enabled = true

ingress_annotations = {
  "kubernetes.io/ingress.class"                = "alb"
  "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
  "alb.ingress.kubernetes.io/target-type"      = "ip"
  "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
  "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS"
  # Replace with your ACM cert ARN in us-west-2.
  "alb.ingress.kubernetes.io/certificate-arn" = "arn:aws:acm:us-west-2:123456789:certificate/00000000-0000-0000-0000-000000000000"
  "alb.ingress.kubernetes.io/inbound-cidrs"   = "0.0.0.0/0"
}

gpu_enabled    = true
app_node_count = 2

gpu_node_instance_type = "g5.2xlarge"
gpu_tuning_profile     = "auto"
# Optional overrides stay in this tfvars file; no additional values YAML needed.
# gpu_tuning = {
#   triton_memory_request = "12Gi"
#   triton_memory_limit   = "25Gi"
#   vllm_memory_request   = "8Gi"
#   vllm_memory_limit     = "24Gi"
# }

# Alternatively, use acm_certificate_arn instead of the certificate-arn annotation.
# See docs/ingress-and-tls.md for web/internal certificate separation.
