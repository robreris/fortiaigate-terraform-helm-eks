# Examples

Each subdirectory holds a `terraform.tfvars` snippet illustrating a deployment scenario. The Terraform stack itself lives at the repo root — these examples just supply variable values.

## Running an example

```bash
# From the repo root, with the appropriate backend already initialized:
terraform init -backend-config=backends/<account>.hcl -reconfigure

# First deploy: bootstrap VPC + EKS so the kubernetes/helm providers can authenticate.
terraform apply -target=module.vpc -target=module.eks \
  -var-file=examples/<name>/terraform.tfvars

# Then apply the rest.
terraform apply -var-file=examples/<name>/terraform.tfvars
```

## Scenarios

| Example | What it shows |
|---------|---------------|
| [`minimal`](./minimal) | Smallest possible config — `ingress_class = "nginx"`, no GPU, no ALB controller. Assumes an nginx ingress controller is already installed in the cluster (or that the ingress resource is just placeholder). |
| [`internal-alb`](./internal-alb) | AWS ALB with `scheme: internal`. HTTP evaluation without ACM; configure ACM and internal DNS for HTTPS. Reachable only inside the VPC and connected networks. |
| [`internet-facing-alb`](./internet-facing-alb) | Public ALB with HTTPS, an ACM certificate, and a custom hostname. The ACM certificate must live in the same region as `aws_region`. |

Each example's `terraform.tfvars` uses placeholder values (account IDs, ARNs, hostnames). Replace them with values for your environment before applying.
