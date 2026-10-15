# FortiAIGate on AWS EKS — Terraform + Helm

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A51.9-623CE4.svg)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.31-326CE5.svg)](https://kubernetes.io/)

Deploy a [FortiAIGate](https://www.fortinet.com/products/fortiaigate) cluster on Amazon EKS with a single Terraform stack. Provisions the VPC, EKS cluster, EFS filesystem, optional GPU node group, and installs the bundled Helm chart — including PostgreSQL, Redis, and the AWS Load Balancer Controller when needed.

Use this repo when you want to **stand up a working FortiAIGate environment in one place** without hand-wiring infrastructure. The defaults favor ease of evaluation; see [`SECURITY.md`](./SECURITY.md) for production hardening.

---

## Architecture

```
AWS
├── VPC (10.0.0.0/16)
│   ├── Private subnets ×3  — EKS nodes, EFS mount targets
│   └── Public subnets  ×3  — NAT gateway, load balancers
├── EKS cluster
│   ├── App node group      — API, WebUI, LLM gateway, Guardrail, PostgreSQL, Redis, LogD
│   └── GPU node group      — Triton + vLLM inference (optional, g6e.2xlarge)
└── EFS filesystem          — shared ReadWriteMany PVC for all services
```

| Service | Role |
|---------|------|
| API | Control plane — REST API and OpenAPI endpoint |
| LLM gateway | Data plane — LLM proxy and policy enforcement |
| WebUI | Management UI |
| Triton + vLLM | DLP model inference and Natural Language policy evaluation |
| Guardrail | Dispatcher, DLP scanner, and policy guard |
| License Manager | Deployment with two replicas and leader election |
| LogD | Log aggregation daemon |
| PostgreSQL | Bitnami subchart |
| Redis | Bitnami subchart |

---

## Prerequisites

| Tool | Minimum | Notes |
|------|---------|-------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.9 | Required by [cross-variable validation](https://www.hashicorp.com/id/blog/terraform-1-9-enhances-input-variable-validations) |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | 2.x | Used by the EKS exec auth plugin |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Match cluster minor version | Within one minor of the API server; see [version skew policy](https://kubernetes.io/releases/version-skew-policy/) |
| [Helm](https://helm.sh/docs/intro/install/) | 3.x | Chart management |

You also need:

- AWS credentials with permission to create VPC, EKS, EFS, IAM, and EC2 resources
- An S3 bucket and DynamoDB lock table for Terraform state — see [`docs/remote-state.md`](./docs/remote-state.md) for one-time bootstrap
- FortiAIGate container images pushed to a registry accessible from EKS (ECR is typical). Images are proprietary to Fortinet, Inc. and require a valid entitlement. See [`docs/images.md`](./docs/images.md) for the required image list and a push-to-ECR walkthrough
- For ALB frontend HTTPS (internal or public): an issued/imported ACM certificate covering `ingress_host`, **in the same region as `aws_region`**, and DNS pointing that host to the ALB. Route 53 is optional; another DNS provider can be used
- For full inference testing: GPU instance availability and EC2 GPU quota in the selected region; set `gpu_enabled = true`
- Helm 3 and Python 3/OpenSSL 3 if validating supplied PEM certificates with `scripts/check_tls.py`. Keep the bundled Helm dependencies; do not run `helm dependency update`, which would replace local subchart fixes

---

## Quickstart

Pick a scenario from [`examples/`](./examples) — each one is a runnable `terraform.tfvars` snippet:

| Scenario | Path |
|----------|------|
| nginx ingress, no GPU, no ALB controller | [`examples/minimal/`](./examples/minimal) |
| Internal ALB (HTTP evaluation; optional ACM HTTPS) | [`examples/internal-alb/`](./examples/internal-alb) |
| Internet-facing ALB with HTTPS | [`examples/internet-facing-alb/`](./examples/internet-facing-alb) |

Run all commands from the repository root. Copy the closest scenario to a gitignored account file and edit it before deploying:

```bash
mkdir -p tfvars
cp examples/internet-facing-alb/terraform.tfvars tfvars/dev.tfvars
# For a private ALB, copy examples/internal-alb/terraform.tfvars instead.
# Edit tfvars/dev.tfvars and create backends/dev.hcl using docs/remote-state.md.
```

For a full 8.0.2 inference test, configure these values in that file as well as your registry, region, ingress, and certificate settings:

```hcl
image_tag              = "V8.0.2-build0054"
gpu_enabled            = true
gpu_node_instance_type = "g6e.2xlarge"
```

Remove any old node-keyed `licenses` map. Choose `internal` before the first deploy; use `acm_certificate_arn` for HTTPS in either ALB mode. The private example defaults to HTTP evaluation, and the minimal example requires a separately installed nginx controller. See [ingress and TLS](docs/ingress-and-tls.md).

Load and push the images in [docs/images.md](docs/images.md) before applying. For supplied PEM web certificates, run the certificate validator in the TLS guide. Keep the same AWS profile, backend, and variable file throughout deployment and teardown:

```bash
# Select credentials for the intended AWS account before continuing.
# export AWS_PROFILE=dev
aws sts get-caller-identity

FAIG_BACKEND="backends/dev.hcl"
FAIG_VARS="tfvars/dev.tfvars"
FAIG_NAMESPACE="fortiaigate"  # must match namespace in your tfvars

# Bootstrap the backend once per account using docs/remote-state.md, then initialize.
terraform init -backend-config="$FAIG_BACKEND" -reconfigure
terraform validate
helm lint fortiaigate

# Stage 1: create VPC, EKS, and node groups. Review the plan before confirming.
terraform apply -target=module.vpc -target=module.eks -var-file="$FAIG_VARS"

# Configure kubectl and confirm API authorization and Ready nodes.
$(terraform output -raw configure_kubectl)
kubectl get nodes
kubectl wait --for=condition=Ready nodes --all --timeout=10m

# Stage 2: create EFS, Secrets, controllers, device plugin, and application.
terraform plan -var-file="$FAIG_VARS"
terraform apply -var-file="$FAIG_VARS"

# Verify the deployment (the shell variables above must still be set).
kubectl get pods,pvc,ingress -n "$FAIG_NAMESPACE"
kubectl rollout status deployment/api -n "$FAIG_NAMESPACE" --timeout=10m
kubectl rollout status deployment/llm-gateway -n "$FAIG_NAMESPACE" --timeout=10m
kubectl rollout status deployment/license-manager -n "$FAIG_NAMESPACE" --timeout=10m
# For gpu_enabled=true with the default shared GPU mode:
kubectl rollout status deployment/triton-vllm-server -n "$FAIG_NAMESPACE" --timeout=20m
terraform output alb_dns_name
terraform output ingress_scheme
```

After applying, configure DNS for `ingress_host` using the ALB hostname: [Route 53 example](docs/route53-setup.md), or your public/private DNS provider. Private ALBs require a client on the VPC or a connected network. Open `https://<ingress_host>/ui` when ACM HTTPS is configured. Upload the deployment license through the authenticated admin API (`POST /api/v1/admin/licenses`), then test login, management API operations, and a policy-enforced LLM request with both DLP and POLICY detectors. Ready pods alone do not establish successful inference or license coverage.

## Two-step bootstrap (first deploy)

The Helm and Kubernetes providers obtain credentials through `aws eks get-token`, but the cluster must already exist and authorize the caller before those providers can operate. Use the two stages above for a new cluster. `kubectl get nodes` checks API access; merely obtaining an EKS token does not prove authorization.

If stage 1 fails or nodes are not Ready, fix it before stage 2. If VPC creation was incomplete, re-run the VPC target using the same tfvars before retrying stage 1. Stage 2 can take longer than a few minutes while the large model images download and initialize; the application's Helm timeout is 20 minutes.

Subsequent configuration changes normally use a full `terraform plan` and `terraform apply` with the same variable file. Targeting is reserved for this bootstrap and the staged teardown below. Local checks have passed, but the documented fresh deployment and teardown sequence still requires a live AWS test.

---

## Upgrading from 8.0.0

The bundled chart is FortiAIGate 8.0.2 build0054. Before applying:

1. Back up PostgreSQL, Redis, the shared EFS data, Helm values, and Secrets. Preserve the master-key Secret on subsequent upgrades; encrypted credentials depend on it.
2. Mirror all ten supplied image archives into your registry using [docs/images.md](./docs/images.md). The inference images use fixed tags.
3. Set `image_tag = "V8.0.2-build0054"`, remove node-keyed `licenses`, and remove any explicit `gpu_node_instance_type = "g5.2xlarge"` override (or set it to `g6e.2xlarge`). Review old extra values files against the new chart; `core` and `scanners` have been replaced by `llmGateway` and `guardrail`.
4. Review `terraform plan`. Changing the GPU instance type replaces the managed node group; schedule downtime for inference. Apply the upgrade, upload the deployment license, and check all pods become Ready.
5. Update LLM clients to the `/ai` gateway routes. The console uses `/ui`; the management API remains under `/api/`.

The `Recreate` strategy avoids waiting for a second GPU during rollout. Local validation does not establish compatibility of an existing database with 8.0.2; verify the upgrade against a backup before production use.

---

## License management

FortiAIGate 8.0.2 uses deployment licenses stored in PostgreSQL. Upload a license through the authenticated admin API (`POST /api/v1/admin/licenses`) after deployment. The license manager runs as a two-replica Deployment.

Remove the old node-keyed `licenses` map from your tfvars. The deprecated variable accepts only an empty map; Terraform no longer creates a license ConfigMap or pins services to licensed nodes.

---

## GPU support

Disabled by default. Set `gpu_enabled = true` to add a single `g6e.2xlarge` node on the `AL2023_x86_64_NVIDIA` AMI, tainted `fortiaigate-gpu=true:NoSchedule`. Triton and vLLM share its GPU in one pod (`triton-vllm-server`). Application nodes retain the `m7i.4xlarge` default.

Terraform also installs the [NVIDIA Kubernetes device plugin](https://github.com/NVIDIA/k8s-device-plugin) as a Helm release in `kube-system` with matching tolerations — no manual setup needed. Without the device plugin, Triton pods stay `Pending` with `Insufficient nvidia.com/gpu`.

The supplied chart requires the NVIDIA container runtime as the GPU node's default runtime for shared mode, including support for `NVIDIA_VISIBLE_DEVICES` on containers without a GPU request. Check the GPU probe and both serving containers become healthy. With `gpu_enabled = false`, Natural Language (POLICY) detectors fail closed; remove those detectors from active policies when running without inference.

Verify after deploy:

```bash
kubectl describe node -l fortiaigate-role=gpu | grep -A10 "Capacity:"
# Expect: nvidia.com/gpu: 1
```

---

## Ingress options

| Class | Use when | ACM cert? | Route 53? |
|-------|----------|-----------|-----------|
| `nginx` | nginx-ingress-controller already in the cluster | No | Optional |
| `alb` (`internal = true`) | All traffic enters via VPN/Direct Connect/Transit Gateway/FortiGate | For HTTPS | Optional private DNS |
| `alb` (`internal = false`) | Public internet | For HTTPS, same region as `aws_region` | Optional DNS provider |

The AWS Load Balancer Controller is installed automatically when `ingress_class = "alb"` and `aws_load_balancer_controller_enabled = true` (the default). Set `aws_load_balancer_controller_enabled = false` if a controller is already managed elsewhere.

See [internal/external ingress and TLS](docs/ingress-and-tls.md) for ACM listeners, supplied web certificates, internal database trust, DNS, and verification. `internal` controls exposure and rejects conflicting scheme annotations.

All three services share the same listener via path-based routing:

| Caller | Path | Backend |
|--------|------|---------|
| FortiGate → WebUI | `/ui` and `/` | webui (port 3000) |
| Chatbot → API | `/api/` | api (port 8000) |
| Chatbot → LLM gateway | `/ai` | llm-gateway (port 8080) |

See [`examples/`](./examples) for full annotation blocks for each scenario.

---

## Advanced: extra values files

For configuration not exposed as Terraform variables, pass additional Helm values files:

```hcl
extra_values_files = ["/path/to/my-overlay.yaml"]
```

Files merge left-to-right before the built-in `set {}` blocks, so Terraform variables take precedence over values files.

---

## Teardown

**Full teardown deletes the EFS filesystem and its data, including the databases.** `reclaim_policy = "Retain"` preserves a Kubernetes PV when its PVC is removed; it does not protect the Terraform-managed `aws_efs_file_system.fortiaigate` from destruction. See [Kubernetes reclamation](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reclaiming) and [AWS EFS deletion](https://docs.aws.amazon.com/efs/latest/ug/delete-efs-fs.html).

Before proceeding, back up PostgreSQL, Redis/EFS data, application Secrets (especially `fortiaigate-master-key` or your `api.masterKeyExistingSecret`), database credentials, and Helm values to a secure location outside this stack. The master-key Secret survives a Helm uninstall, but deleting the Terraform-owned namespace deletes it. A retained PV or Terraform state alone is not a database backup. If you need the existing EFS filesystem to survive, stop before full teardown and arrange separate storage ownership first; this procedure deletes it.

Use the same AWS credentials, backend, and tfvars used to deploy. Keep supplied PEM files and extra values files available while Terraform evaluates the configuration. Do not use `terraform apply` between teardown stages: it would recreate resources already removed.

```bash
# Adjust these to the deployment being removed; verify the AWS account.
FAIG_BACKEND="backends/dev.hcl"
FAIG_VARS="tfvars/dev.tfvars"
FAIG_NAMESPACE="fortiaigate"  # match namespace in your tfvars
aws sts get-caller-identity
terraform init -backend-config="$FAIG_BACKEND" -reconfigure
$(terraform output -raw configure_kubectl)
kubectl get nodes

# Capture these while the outputs still exist.
FAIG_REGION=$(terraform output -raw aws_region)
FAIG_EFS_ID=$(terraform output -raw efs_filesystem_id)
# For ALB deployments, also record the ALB hostname/ARN for deletion verification.
terraform output alb_dns_name

# Stage 1: remove the application while ALB/EFS controllers and nodes are still running.
# Terraform invokes Helm uninstall and updates its own state.
terraform destroy -target=helm_release.fortiaigate -var-file="$FAIG_VARS"

# Inspect cleanup before proceeding to stage 2.
kubectl get ingress,pods,pvc -n "$FAIG_NAMESPACE"
```

Proceed only when the application's Ingress, pods, and PVCs are gone. For ALB deployments, also confirm in AWS that the associated ALB and target groups have been removed. If ingress deletion is stuck, inspect its events and the AWS Load Balancer Controller logs while the controller is still available. Do not strip finalizers or remove the controller to bypass cleanup.

The EFS StorageClass retains PVs/access points after PVC deletion. Inspect the access points for this filesystem:

```bash
aws efs describe-access-points --file-system-id "$FAIG_EFS_ID" \
  --region "$FAIG_REGION" \
  --query 'AccessPoints[].{ID:AccessPointId,Path:RootDirectory.Path}' --output table
```

For a full deletion, after confirming no workloads use the filesystem and backups are complete, delete its remaining access points using `aws efs delete-access-point --access-point-id fsap-REPLACE_WITH_CONFIRMED_ID --region "$FAIG_REGION"` for each confirmed ID. They were created by the CSI driver and are not tracked as Terraform resources. AWS requires access points and mount targets to be removed before filesystem deletion; Terraform removes its managed mount targets in the final stage.

```bash
# Stage 2: remove the remaining Terraform-owned Kubernetes resources while EKS exists.
# Controller/device-plugin targets are skipped if no instances are managed by this stack.
# Namespace deletion also removes any manually created resources in that namespace.
terraform destroy \
  -target=helm_release.aws_load_balancer_controller \
  -target=helm_release.nvidia_device_plugin \
  -target=kubernetes_storage_class.efs \
  -target=kubernetes_namespace.fortiaigate \
  -var-file="$FAIG_VARS"

# Stage 3: review the remaining infrastructure destruction, then confirm it.
terraform plan -destroy -var-file="$FAIG_VARS"
terraform destroy -var-file="$FAIG_VARS"

# The Terraform state should now contain no managed resources.
terraform state list
```

Review every destroy plan. Stage 1 should remove the application; stage 2 should remove remaining managed Kubernetes objects; EKS, nodes, networking, and EFS must remain until stage 3. Stop and investigate failures before proceeding. These commands use [Terraform's targeted destroy mode](https://developer.hashicorp.com/terraform/cli/commands/destroy), keeping release state aligned with the uninstall; a manual `helm uninstall` is not needed.

The separately bootstrapped S3 state bucket and DynamoDB lock table, mirrored ECR images, externally supplied ACM certificates, and DNS records are outside this stack and remain. Remove stale DNS records and review any externally managed controllers or leftover AWS resources separately. Do not delete your state backend or backups until cleanup is verified.

---

## Troubleshooting

**`Unauthorized` on first apply** — You skipped the two-step bootstrap. See [Two-step bootstrap](#two-step-bootstrap-first-deploy).

**Node groups stuck in `Creating` for 20+ minutes** — Nodes booted but can't register with the control plane. Most common cause: incomplete VPC (no NAT gateway, no public subnets, missing default route). Check `aws ec2 describe-nat-gateways` and the private subnet route tables. If the VPC is partial, re-run `terraform apply -target=module.vpc` first.

**ALB has target groups but no listeners** — The `CreateListener` call failed AWS-side validation. The most frequent cause is an ACM certificate ARN in the wrong region; ACM is regional and doesn't replicate. Check `kubectl describe ingress -n fortiaigate fortiaigate-ingress` for the exact error, then issue a cert in the same region as `aws_region` and update `alb.ingress.kubernetes.io/certificate-arn`.

**Pods stuck in `Pending`** — Check node capacity and EFS mount status:

```bash
kubectl describe pod <pod-name> -n fortiaigate
kubectl get pvc -n fortiaigate
kubectl get pods -n kube-system | grep efs
```

**License manager not starting** — Check its Deployment logs and PostgreSQL/Redis connectivity. Licenses are uploaded through the admin API, rather than node-mounted files.

---

## Documentation

- [`examples/`](./examples) — runnable deployment scenarios
- [`docs/images.md`](./docs/images.md) — required container images and push-to-ECR walkthrough
- [`docs/remote-state.md`](./docs/remote-state.md) — S3 + DynamoDB backend bootstrap
- [`docs/route53-setup.md`](./docs/route53-setup.md) — Route 53 alias for internet-facing ALB
- [`docs/ingress-and-tls.md`](./docs/ingress-and-tls.md) — private/public ingress, ACM, and supplied/internal TLS
- [`SECURITY.md`](./SECURITY.md) — vulnerability reporting + production hardening checklist
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — dev setup, local checks, PR conventions
- [`ROADMAP.md`](./ROADMAP.md) — known gaps and planned improvements
- [`CHANGELOG.md`](./CHANGELOG.md) — release notes

---

## License

Apache License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

FortiAIGate container images themselves are proprietary to Fortinet, Inc. and require a valid entitlement.

---

## Inputs and outputs

The block below is regenerated by [terraform-docs](https://terraform-docs.io/) via the pre-commit hook in `.pre-commit-config.yaml`. Do not edit by hand — update `variables.tf` / `outputs.tf` instead.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.15 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.35 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 2.15 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.35 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_tls"></a> [tls](#provider\_tls) | ~> 4.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_aws_load_balancer_controller_irsa"></a> [aws\_load\_balancer\_controller\_irsa](#module\_aws\_load\_balancer\_controller\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | ~> 5.0 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 20.0 |
| <a name="module_irsa_efs_csi"></a> [irsa\_efs\_csi](#module\_irsa\_efs\_csi) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | ~> 5.0 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_efs_file_system.fortiaigate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.fortiaigate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_eks_addon.efs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [helm_release.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.fortiaigate](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.nvidia_device_plugin](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace.fortiaigate](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_secret.internal_tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_secret.tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_storage_class.efs](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class) | resource |
| [terraform_data.ingress_configuration](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [tls_cert_request.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_locally_signed_cert.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/locally_signed_cert) | resource |
| [tls_private_key.ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [kubernetes_ingress_v1.fortiaigate](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/ingress_v1) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_image_repository"></a> [image\_repository](#input\_image\_repository) | Container registry prefix for FortiAIGate images (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate) | `string` | n/a | yes |
| <a name="input_acm_certificate_arn"></a> [acm\_certificate\_arn](#input\_acm\_certificate\_arn) | Existing ACM certificate ARN for ALB frontend HTTPS, in aws\_region. Works for public and internal ALBs. Empty keeps HTTP unless certificate-arn is supplied through ingress\_annotations. | `string` | `""` | no |
| <a name="input_app_node_count"></a> [app\_node\_count](#input\_app\_node\_count) | Number of application nodes | `number` | `2` | no |
| <a name="input_app_node_instance_type"></a> [app\_node\_instance\_type](#input\_app\_node\_instance\_type) | EC2 instance type for application node group | `string` | `"m7i.4xlarge"` | no |
| <a name="input_aws_load_balancer_controller_chart_version"></a> [aws\_load\_balancer\_controller\_chart\_version](#input\_aws\_load\_balancer\_controller\_chart\_version) | Helm chart version for aws-load-balancer-controller from the AWS EKS charts repository. | `string` | `"1.14.0"` | no |
| <a name="input_aws_load_balancer_controller_enabled"></a> [aws\_load\_balancer\_controller\_enabled](#input\_aws\_load\_balancer\_controller\_enabled) | Install AWS Load Balancer Controller when ingress\_class is 'alb'. Disable if a controller is already managed outside this Terraform stack. | `bool` | `true` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS cluster name | `string` | `"fortiaigate"` | no |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes version for the EKS cluster | `string` | `"1.31"` | no |
| <a name="input_efs_encrypted"></a> [efs\_encrypted](#input\_efs\_encrypted) | Encrypt the EFS file system at rest with a KMS key. Disable if no suitable KMS key is available in the account. | `bool` | `true` | no |
| <a name="input_extra_values_files"></a> [extra\_values\_files](#input\_extra\_values\_files) | Additional Helm values YAML files to merge (applied left-to-right, later files take precedence) | `list(string)` | `[]` | no |
| <a name="input_gpu_enabled"></a> [gpu\_enabled](#input\_gpu\_enabled) | Add a GPU node group (g6e.2xlarge) for Triton and vLLM inference. When false, GPU inference is disabled; POLICY detectors fail closed. | `bool` | `false` | no |
| <a name="input_gpu_node_ami_type"></a> [gpu\_node\_ami\_type](#input\_gpu\_node\_ami\_type) | EKS managed node group AMI type for GPU nodes. Use AL2023\_x86\_64\_NVIDIA for CUDA 13+ container compatibility. | `string` | `"AL2023_x86_64_NVIDIA"` | no |
| <a name="input_gpu_node_instance_type"></a> [gpu\_node\_instance\_type](#input\_gpu\_node\_instance\_type) | EC2 instance type for the GPU node group | `string` | `"g6e.2xlarge"` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Image tag for all FortiAIGate service images | `string` | `"V8.0.2-build0054"` | no |
| <a name="input_ingress_annotations"></a> [ingress\_annotations](#input\_ingress\_annotations) | Additional ingress annotations. ALB scheme must agree with internal; acm\_certificate\_arn takes precedence over its annotation. Keys with dots/slashes are handled via values YAML merge. | `map(string)` | `{}` | no |
| <a name="input_ingress_class"></a> [ingress\_class](#input\_ingress\_class) | Ingress class name. Use 'nginx' for nginx-ingress or 'alb' for AWS Load Balancer Controller. | `string` | `"nginx"` | no |
| <a name="input_ingress_host"></a> [ingress\_host](#input\_ingress\_host) | Hostname for the ingress rule. Leave empty to match all hosts. | `string` | `""` | no |
| <a name="input_internal"></a> [internal](#input\_internal) | Deploy as an internal (private) service. Sets and enforces the ALB scheme to internal so it is only reachable within the VPC and connected networks. Requires ingress\_class = 'alb'. | `bool` | `false` | no |
| <a name="input_licenses"></a> [licenses](#input\_licenses) | Deprecated in 8.0.2. Leave empty and upload deployment licenses through POST /api/v1/admin/licenses. | `map(string)` | `{}` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Kubernetes namespace for the FortiAIGate deployment | `string` | `"fortiaigate"` | no |
| <a name="input_storage_size"></a> [storage\_size](#input\_storage\_size) | Size of the shared EFS-backed PVC | `string` | `"100Gi"` | no |
| <a name="input_tls_ca_certificate_path"></a> [tls\_ca\_certificate\_path](#input\_tls\_ca\_certificate\_path) | Optional PEM root CA for a supplied web certificate. Used for client trust export, not uploaded to ALB. Internal services always use the generated CA. | `string` | `""` | no |
| <a name="input_tls_certificate_path"></a> [tls\_certificate\_path](#input\_tls\_certificate\_path) | Optional PEM certificate chain for web/API pod HTTPS (and nginx frontend TLS). Requires tls\_private\_key\_path and ingress\_host. ALB frontend TLS uses ACM independently. | `string` | `""` | no |
| <a name="input_tls_private_key_path"></a> [tls\_private\_key\_path](#input\_tls\_private\_key\_path) | Unencrypted PEM private key for tls\_certificate\_path. Contents are stored in Terraform state; keep the file outside version control. | `string` | `""` | no |
| <a name="input_update_strategy"></a> [update\_strategy](#input\_update\_strategy) | Deployment update strategy. 'Recreate' avoids GPU deadlock on single-GPU nodes; 'RollingUpdate' for zero-downtime when spare capacity exists. | `string` | `"Recreate"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | ALB hostname assigned by AWS — use this to configure the FortiGate and chatbot |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | AWS region used for the deployment |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | EKS cluster name |
| <a name="output_configure_kubectl"></a> [configure\_kubectl](#output\_configure\_kubectl) | Run this command to configure kubectl for the new cluster |
| <a name="output_efs_filesystem_id"></a> [efs\_filesystem\_id](#output\_efs\_filesystem\_id) | EFS filesystem ID backing the shared PVC |
| <a name="output_ingress_host"></a> [ingress\_host](#output\_ingress\_host) | Configured ingress hostname (empty = matches all hosts) |
| <a name="output_ingress_scheme"></a> [ingress\_scheme](#output\_ingress\_scheme) | Configured ALB exposure scheme (null for other ingress controllers). |
| <a name="output_internal_tls_ca_certificate"></a> [internal\_tls\_ca\_certificate](#output\_internal\_tls\_ca\_certificate) | Generated CA for internal service and database TLS in every web certificate mode. |
| <a name="output_release_status"></a> [release\_status](#output\_release\_status) | Helm release deployment status |
| <a name="output_tls_ca_certificate"></a> [tls\_ca\_certificate](#output\_tls\_ca\_certificate) | Root CA for generated/supplied web TLS. ALB clients trust the ACM frontend certificate independently. |
<!-- END_TF_DOCS -->
