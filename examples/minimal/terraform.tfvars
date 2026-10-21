# Minimal config: nginx ingress, no GPU, no ALB controller.
# Assumes nginx-ingress-controller is already installed in the cluster
# (e.g. via the ingress-nginx Helm chart, managed separately from this stack).

aws_region   = "us-east-1"
cluster_name = "fortiaigate-minimal"

# REQUIRED — your FortiAIGate image registry.
image_repository = "123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate"

ingress_class = "nginx"
ingress_host  = "fortiaigate.example.com"

# Skip ALB controller installation since we're using nginx.
aws_load_balancer_controller_enabled = false

# CPU-only — Triton/AI inference is disabled.
gpu_enabled    = false
app_node_count = 2
# GPU tuning is ignored while gpu_enabled is false.
gpu_tuning_profile = "auto"
