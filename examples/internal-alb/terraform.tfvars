# Internal ALB: reachable only inside the VPC and connected networks
# (VPN, Direct Connect, Transit Gateway, FortiGate-as-VPC-gateway).
# HTTP evaluation needs no ACM. For HTTPS, configure ACM and your internal DNS.

aws_region   = "us-west-2"
cluster_name = "fortiaigate-internal"

# REQUIRED — your FortiAIGate image registry.
image_repository = "123456789.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"

ingress_class                        = "alb"
internal                             = true
aws_load_balancer_controller_enabled = true

# ingress_host is optional for internal ALBs — callers use the ALB DNS name directly.
# Surface it after apply with:  terraform output alb_dns_name

gpu_enabled    = false
app_node_count = 2

# For full inference on a G5, set gpu_enabled = true. Auto supplies memory and
# concurrency settings from the maintained shared A10G reference configuration.
gpu_node_instance_type = "g5.2xlarge"
gpu_tuning_profile     = "auto"

# Recommended for console/API HTTPS (certificate must be in aws_region):
# ingress_host        = "fortiaigate.corp.example.com"
# acm_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/<id>"
