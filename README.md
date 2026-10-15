# FortiAIGate on AWS EKS

Deploy FortiAIGate 8.0.2 build0055 with Terraform and the bundled Helm chart. The stack creates a VPC, EKS cluster, EFS storage, application nodes, an optional GPU node, and an AWS Load Balancer Controller for ALB ingress.

## Before you start

- Install Terraform 1.9+, AWS CLI v2, Helm 3, and kubectl compatible with your cluster version (default: 1.31).
- Configure AWS credentials with permission to create VPC, EKS, EC2, EFS, and IAM resources. This deployment creates billable AWS resources, including GPU instances when enabled.
- Obtain the entitled FortiAIGate images and a deployment license from Fortinet. [Push the required images to your registry](docs/images.md) before applying.
- [Create an S3 state bucket and DynamoDB lock table](docs/remote-state.md) once for your account.
- For the public HTTPS quickstart below, have a hostname and an ACM certificate covering it in the deployment region, plus access to update DNS. GPU inference also needs sufficient EC2 GPU quota and available capacity.

## Quickstart

### 1. Clone and configure

```bash
git clone https://github.com/robreris/fortiaigate-terraform-helm-eks.git
cd fortiaigate-terraform-helm-eks
mkdir -p tfvars
cp examples/internet-facing-alb/terraform.tfvars tfvars/dev.tfvars
cp backends/backend.hcl.example backends/dev.hcl
```

Edit both files before continuing:

- `tfvars/dev.tfvars`: set your region, cluster name, image registry, ingress hostname, and same-region ACM certificate ARN. Restrict `alb.ingress.kubernetes.io/inbound-cidrs` to your client networks. This example enables a `g5.2xlarge` GPU with automatic tuning.
- `backends/dev.hcl`: set your state bucket, state key, region, and lock table. Use a separate state key for each deployment.

For private access, use the [internal ALB example](examples/internal-alb/terraform.tfvars) instead; it requires a connection to the VPC. See [all scenarios](examples/README.md) and [ingress/TLS options](docs/ingress-and-tls.md). Keep account files, credentials, and licenses out of git. Use the vendored Helm dependencies; do not run `helm dependency update`.

### 2. Create the cluster

Run from the repository root, using the same AWS profile, backend, and tfvars throughout deployment and teardown.

```bash
export AWS_PROFILE=your-profile
aws sts get-caller-identity  # confirm the intended account

FAIG_BACKEND="backends/dev.hcl"
FAIG_VARS="tfvars/dev.tfvars"
FAIG_NAMESPACE="fortiaigate"  # match namespace in your tfvars

terraform init -backend-config="$FAIG_BACKEND" -reconfigure
terraform validate
helm lint fortiaigate

# New cluster only: review the plan before confirming.
terraform apply -target=module.vpc -target=module.eks -var-file="$FAIG_VARS"
$(terraform output -raw configure_kubectl)
kubectl get nodes
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

The initial bootstrap makes EKS available to Terraform's Kubernetes and Helm providers. Stop if it fails or nodes are not Ready. GPU capacity shortages can extend provisioning while AWS retries; see [troubleshooting](docs/deployment-guide.md#troubleshooting).

### 3. Deploy and open FortiAIGate

```bash
terraform plan -var-file="$FAIG_VARS"
terraform apply -var-file="$FAIG_VARS"

kubectl get pods,pvc,ingress -n "$FAIG_NAMESPACE"
kubectl rollout status deployment/api -n "$FAIG_NAMESPACE" --timeout=10m
kubectl rollout status deployment/llm-gateway -n "$FAIG_NAMESPACE" --timeout=10m
kubectl rollout status deployment/license-manager -n "$FAIG_NAMESPACE" --timeout=10m
# GPU-enabled deployments using the default shared mode:
kubectl rollout status deployment/triton-vllm-server -n "$FAIG_NAMESPACE" --timeout=20m
terraform output alb_dns_name
```

Large model images take time to download and initialize; the application Helm timeout is 20 minutes. Point your ingress hostname at the ALB using your DNS provider ([Route 53 example](docs/route53-setup.md)), then open `https://<ingress_host>/ui` and upload the deployment license. License upload requires no Terraform changes or follow-up apply. Verify a policy-enforced LLM request with DLP and POLICY detectors; Ready pods alone do not verify inference.

For later updates, use a normal full plan/apply with the same tfvars; skip the cluster bootstrap. Read the [upgrade guide](docs/deployment-guide.md#upgrading-from-800) before changing an existing installation.

## Teardown

**Full teardown deletes EFS and database data.** Back up databases, EFS data, credentials, Helm values, and application Secrets (especially the master key) outside this stack first. A retained PV does not protect EFS from Terraform destruction.

Use the same profile, backend, and tfvars as deployment. If starting a new shell, restore the `FAIG_*` variables above, confirm the AWS account, initialize the backend, and refresh kubectl. Keep supplied certificate and extra values files available.

```bash
# Remove the application while its controllers and nodes still exist.
terraform destroy -target=helm_release.fortiaigate -var-file="$FAIG_VARS"
kubectl get ingress,pods,pvc -n "$FAIG_NAMESPACE"
```

**Before continuing:** confirm application Ingress, pods, and PVCs are gone, verify the ALB and target groups were deleted, and remove retained EFS access points using the [cleanup instructions](docs/teardown.md). Keep the controllers running until cleanup completes.

```bash
# Remove remaining Kubernetes resources while EKS is available.
terraform destroy \
  -target=helm_release.aws_load_balancer_controller \
  -target=helm_release.nvidia_device_plugin \
  -target=kubernetes_storage_class.efs \
  -target=kubernetes_namespace.fortiaigate \
  -var-file="$FAIG_VARS"

# Review, then destroy the remaining infrastructure.
terraform plan -destroy -var-file="$FAIG_VARS"
terraform destroy -var-file="$FAIG_VARS"
terraform state list  # should contain no managed resources
```

Review every destroy plan and stop on failures. Do not run `terraform apply` between teardown stages. The state backend, mirrored images, externally supplied ACM certificates, and DNS records remain; see the [full teardown guide](docs/teardown.md) for cleanup and verification.

## More information

| Guide | Contents |
|-------|----------|
| [Deployment and operations](docs/deployment-guide.md) | Architecture, upgrades, licensing, GPU tuning, ingress, troubleshooting |
| [Terraform reference](docs/terraform-reference.md) | Generated inputs, outputs, providers, and resources |
| [Ingress and TLS](docs/ingress-and-tls.md) | Public/private access, certificates, DNS, local UI proxy |
| [Security](SECURITY.md) | Production hardening and vulnerability reporting |
| [Contributing](CONTRIBUTING.md) | Development setup and checks |
| [Changelog](CHANGELOG.md) | Release notes |

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). FortiAIGate images are proprietary to Fortinet and require a valid entitlement.
