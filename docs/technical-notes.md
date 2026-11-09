# Terraform and Helm technical notes

This document records implementation constraints that are useful when changing the AWS deployment. For deployment, start with the [README](../README.md); for removal, follow the [teardown guide](teardown.md).

## Infrastructure and chart behavior

- **AZ placement:** `vpc.tf` uses all available standard regional AZs in sorted order, preserving the original first-three subnet indexes for existing regions. EKS control-plane and default application subnets remain the first three; GPU subnets include every available AZ offering `gpu_node_instance_type`. Adding/removing AZs can affect indexed subnets and EFS mount targets; review plans for replacements. Instance offerings do not report free capacity.
- **Subnet CIDRs:** Public `/24` subnets start at `10.0.48.0/24`, inside `/20` block 3. Private `/20` netnums are `0, 1, 2, 6, 4, 5`, then `7` onward: index 3 uses `10.0.96.0/20` to avoid the public range while preserving private indexes 4 and 5 from partial AZ expansions. Never allocate private `/20` block 3. Verify all public/private CIDRs are disjoint when changing this allocation.
- **Bootstrap and licensing:** The Helm/Kubernetes provider configurations read the endpoint and CA from `module.eks`. The initial EKS bootstrap makes that API available before applying cluster resources; later updates use a normal full apply. WebUI/admin-API deployment licensing requires no Terraform configuration or follow-up apply and does not remove the provider bootstrap dependency.
- **EFS CSI addon:** The EFS CSI driver is managed as a standalone addon in `storage.tf`, with a separate IRSA module. Its role depends on the EKS module's OIDC provider; putting the addon inside the EKS module's `cluster_addons` creates a dependency cycle.
- **Namespace teardown:** The application namespace depends on the AWS Load Balancer Controller release and EFS CSI addon so reverse destroy ordering keeps those controllers available through namespace deletion. Keep these dependencies on the namespace as well as the application release: retained or manually created namespaced objects can outlive Helm uninstall. Do not add automatic finalizer removal; investigate namespace conditions and the owning controllers instead.
- **Helm value precedence:** `gpu.tf` and `helm.tf` compose structured values using `yamlencode` in this order: GPU profile defaults → `extra_values_files` → explicit `gpu_tuning` fields → GPU placement → ingress annotations → TLS values. Later entries override earlier ones; Helm `set` blocks have final precedence. Unset tuning fields are omitted to preserve other defaults. Use structured YAML for lists and keys containing dots or slashes.
- **G5 tuning:** `gpu_tuning_profile = "auto"` selects the maintained reference chart's shared A10G settings for `g5.*`, with 12/8 GiB Triton/vLLM requests and 25/24 GiB limits. Limits are deliberately overcommitted relative to a 32 GiB node; validate concurrent startup peaks and inference. The earlier 6 GiB Triton cap failed during model loading. Other instance families retain vendor chart defaults, or can select the G5 profile explicitly. CPU-only deployments omit inference tuning. See the [quickstart](../README.md#quickstart) and [GPU tuning guide](deployment-guide.md#gpu-support).
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
