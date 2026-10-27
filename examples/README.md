# Examples

Each subdirectory holds a `terraform.tfvars` snippet illustrating a deployment scenario. The Terraform stack itself lives at the repo root — these examples just supply variable values.

## Running an example

Follow the [root quickstart](../README.md#quickstart), copying your chosen scenario to a gitignored `tfvars/<name>.tfvars` file before editing it. Use the Terraform stack at the repository root and a backend state key unique to the deployment. Confirm Ready nodes after the initial bootstrap before applying the application.

Upload the deployment license in the WebUI after deployment. No license tfvars, node-ID discovery, or follow-up Terraform apply is needed. For removal, use the [staged teardown](../docs/teardown.md).

## Scenarios

| Example | What it shows |
|---------|---------------|
| [`minimal`](./minimal) | Smallest possible config — `ingress_class = "nginx"`, no GPU, no ALB controller. Assumes an nginx ingress controller is already installed in the cluster (or that the ingress resource is just placeholder). |
| [`internal-alb`](./internal-alb) | AWS ALB with `scheme: internal`. HTTP evaluation without ACM; configure ACM and internal DNS for HTTPS. Reachable only inside the VPC and connected networks. |
| [`internet-facing-alb`](./internet-facing-alb) | Public ALB with HTTPS, an ACM certificate, and a custom hostname. The ACM certificate must live in the same region as `aws_region`. |

Each example's `terraform.tfvars` uses placeholder values (account IDs, ARNs, hostnames). Replace them with values for your environment before applying.

GPU-enabled examples use `gpu_node_instance_type = "g5.2xlarge"` and `gpu_tuning_profile = "auto"`, which supplies shared A10G tuning without another values file. The development template in `tfvars/dev.tfvars.example` uses G5; the production template retains G6e. Both show optional `gpu_tuning` overrides for memory and concurrency directly in tfvars. See [GPU support](../docs/deployment-guide.md#gpu-support) for the defaults and their memory limits.
