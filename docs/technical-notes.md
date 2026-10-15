# Terraform and Helm technical notes

This document records implementation constraints that are useful when changing the AWS deployment. For deployment and teardown procedures, see the [README](../README.md).

## Infrastructure and chart behavior

- **EFS CSI addon:** The EFS CSI driver is managed as a standalone addon in `storage.tf`, with a separate IRSA module. Its role depends on the EKS module's OIDC provider; putting the addon inside the EKS module's `cluster_addons` creates a dependency cycle.
- **Helm value precedence:** `helm.tf` composes structured values using `yamlencode` in this order: `extra_values_files` → GPU values → ingress annotations → TLS values. Later entries override earlier ones; Helm `set` blocks have final precedence. Use structured YAML for lists and keys containing dots or slashes. The README documents the public extra-values interface.
- **TLS resource boundaries:** The web Secret and internal Secret are intentionally separate resources with independent rotation checksums. Keep these boundaries intact when changing certificate inputs or chart mounts; user-facing certificate behavior is documented in [ingress and TLS](ingress-and-tls.md).

## Terraform file map

| File | Responsibility |
|------|----------------|
| `vpc.tf` | VPC, subnets, and NAT using `terraform-aws-modules/vpc/aws` |
| `eks.tf` | EKS cluster, application and GPU node groups, core addons |
| `storage.tf` | EFS, mount targets, EFS CSI addon and IRSA, StorageClass |
| `aws-load-balancer-controller.tf` | Controller IRSA and conditional Helm release |
| `helm.tf` | Namespace, NVIDIA device plugin, application release, Helm values |
| `licenses.tf` | Legacy license input validation and migration guidance |
| `tls.tf` | Generated CA, web/internal Secrets, optional supplied web certificate |
| `ingress.tf` | ALB exposure, listener, and ACM configuration checks |
| `providers.tf` | AWS, Helm, and Kubernetes providers; EKS exec authentication |
| `backend.tf` | S3 backend declaration; configuration supplied at init time |
| `outputs.tf` | Cluster, kubectl, EFS, and ALB outputs |
