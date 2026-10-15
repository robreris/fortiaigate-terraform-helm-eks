# Examples

Each subdirectory holds a `terraform.tfvars` snippet illustrating a deployment scenario. The Terraform stack itself lives at the repo root — these examples just supply variable values.

## Running an example

```bash
# From the repo root, with the appropriate backend already initialized:
terraform init -backend-config=backends/<account>.hcl -reconfigure

# New cluster only: bootstrap VPC + EKS so the providers can authenticate.
# Skip this command for updates to an already bootstrapped cluster.
terraform apply -target=module.vpc -target=module.eks \
  -var-file=examples/<name>/terraform.tfvars

# Deploy the application, or update an existing deployment with one normal apply.
terraform plan -var-file=examples/<name>/terraform.tfvars
terraform apply -var-file=examples/<name>/terraform.tfvars
```

After deploying, sign in to the WebUI and upload the deployment license. This requires no license tfvars, node-ID discovery, or second license-related apply. The initial cluster bootstrap above is required for provider connectivity and is independent of licensing.

## Scenarios

| Example | What it shows |
|---------|---------------|
| [`minimal`](./minimal) | Smallest possible config — `ingress_class = "nginx"`, no GPU, no ALB controller. Assumes an nginx ingress controller is already installed in the cluster (or that the ingress resource is just placeholder). |
| [`internal-alb`](./internal-alb) | AWS ALB with `scheme: internal`. HTTP evaluation without ACM; configure ACM and internal DNS for HTTPS. Reachable only inside the VPC and connected networks. |
| [`internet-facing-alb`](./internet-facing-alb) | Public ALB with HTTPS, an ACM certificate, and a custom hostname. The ACM certificate must live in the same region as `aws_region`. |

Each example's `terraform.tfvars` uses placeholder values (account IDs, ARNs, hostnames). Replace them with values for your environment before applying.

GPU-enabled examples use `gpu_node_instance_type = "g5.2xlarge"` and `gpu_tuning_profile = "auto"`, which supplies shared A10G tuning without another values file. The development template in `tfvars/dev.tfvars.example` uses G5; the production template retains G6e. Both show optional `gpu_tuning` overrides for memory and concurrency directly in tfvars. See [GPU support](../docs/deployment-guide.md#gpu-support) for the defaults and their memory limits.
