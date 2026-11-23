# Internal ALB: reachable only inside the VPC and connected networks
# (VPN, Direct Connect, Transit Gateway, FortiGate-as-VPC-gateway).
# Configure ACM and internal DNS for the HTTPS listener.

aws_region   = "us-west-2"
cluster_name = "fortiaigate-internal"

# REQUIRED — your FortiAIGate image registry.
image_repository = "123456789.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-v803"

ingress_class                        = "alb"
internal                             = true
aws_load_balancer_controller_enabled = true

# Use your internal hostname and its ACM certificate in aws_region.
ingress_host        = "fortiaigate.corp.example.com"
acm_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"

gpu_enabled    = false
app_node_count = 2

# For full inference on a G5, set gpu_enabled = true. Auto supplies memory and
# concurrency settings from the maintained shared A10G reference configuration.
gpu_node_instance_type = "g5.2xlarge"
gpu_tuning_profile     = "auto"
