# Terraform and Helm technical notes

This document records implementation constraints that are useful when changing the AWS deployment. For deployment and teardown procedures, see the [README](../README.md).

## Infrastructure and chart behavior

- **Bootstrap and licensing:** The Helm/Kubernetes provider configurations read the endpoint and CA from `module.eks`. The initial EKS bootstrap makes that API available before applying cluster resources; later updates use a normal full apply. WebUI/admin-API deployment licensing requires no Terraform configuration or follow-up apply and does not remove the provider bootstrap dependency.
- **EFS CSI addon:** The EFS CSI driver is managed as a standalone addon in `storage.tf`, with a separate IRSA module. Its role depends on the EKS module's OIDC provider; putting the addon inside the EKS module's `cluster_addons` creates a dependency cycle.
- **Helm value precedence:** `gpu.tf` and `helm.tf` compose structured values using `yamlencode` in this order: GPU profile defaults → `extra_values_files` → explicit `gpu_tuning` fields → GPU placement → ingress annotations → TLS values. Later entries override earlier ones; Helm `set` blocks have final precedence. Unset tuning fields are omitted to preserve other defaults. Use structured YAML for lists and keys containing dots or slashes.
- **G5 tuning:** `gpu_tuning_profile = "auto"` selects the maintained reference chart's shared A10G settings for `g5.*`, with 12/8 GiB Triton/vLLM requests and 25/24 GiB limits. Limits are deliberately overcommitted relative to a 32 GiB node; validate concurrent startup peaks and inference. The earlier 6 GiB Triton cap failed during model loading. Other instance families retain vendor chart defaults, or can select the G5 profile explicitly. CPU-only deployments omit inference tuning. Deployment procedures and tfvars examples are in the README.
- **TLS resource boundaries:** The web Secret and internal Secret are intentionally separate resources with independent rotation checksums. Keep these boundaries intact when changing certificate inputs or chart mounts; user-facing certificate behavior is documented in [ingress and TLS](ingress-and-tls.md).

## Terraform file map

| File | Responsibility |
|------|----------------|
| `vpc.tf` | VPC, subnets, and NAT using `terraform-aws-modules/vpc/aws` |
| `eks.tf` | EKS cluster, application and GPU node groups, core addons |
| `storage.tf` | EFS, mount targets, EFS CSI addon and IRSA, StorageClass |
| `aws-load-balancer-controller.tf` | Controller IRSA and conditional Helm release |
| `helm.tf` | Namespace, NVIDIA device plugin, application release, Helm values |
| `gpu.tf` | Automatic G5 profile and optional inference tuning from tfvars |
| `licenses.tf` | Legacy license input validation and migration guidance |
| `tls.tf` | Generated CA, web/internal Secrets, optional supplied web certificate |
| `ingress.tf` | ALB exposure, listener, and ACM configuration checks |
| `providers.tf` | AWS, Helm, and Kubernetes providers; EKS exec authentication |
| `backend.tf` | S3 backend declaration; configuration supplied at init time |
| `outputs.tf` | Cluster, kubectl, EFS, and ALB outputs |
