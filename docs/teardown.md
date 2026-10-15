# Teardown

Return to the [quickstart](../README.md#quickstart).

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
FAIG_VPC_ID=$(terraform output -raw vpc_id)
# Older deployments without this output: record module.vpc.aws_vpc.this[0]'s
# id from `terraform state show 'module.vpc.aws_vpc.this[0]'` instead.
# For ALB deployments, also record the ALB hostname/ARN for deletion verification.
terraform output alb_dns_name

# Stage 1: remove the application while ALB/EFS controllers and nodes are still running.
# Terraform invokes Helm uninstall and updates its own state.
terraform destroy -target=helm_release.fortiaigate -var-file="$FAIG_VARS"

# Inspect cleanup before proceeding to stage 2.
kubectl get ingress,pods,pvc -n "$FAIG_NAMESPACE"
```

Proceed only when the application's Ingress, pods, and PVCs are gone. For ALB deployments, also confirm in AWS that the associated ALB and target groups have been removed. If ingress deletion is stuck, inspect its events and the AWS Load Balancer Controller logs while the controller is still available. Do not strip finalizers or remove the controller to bypass cleanup.

Check for Ingresses and LoadBalancer Services in **all namespaces**, including any externally installed nginx controller. Remove each remaining load-balancing resource through its Kubernetes/Helm owner while its controller is still running. An external controller or shared IngressGroup can keep a load balancer alive after the application release is gone. AWS requires [Services and Ingresses to be removed before EKS deletion](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html).

```bash
kubectl get ingress,svc -A
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100

# Run after removing load-balancing workloads, before removing their controllers.
python3 scripts/check_teardown.py --region "$FAIG_REGION" --vpc-id "$FAIG_VPC_ID"
```

The read-only check lists ALB/NLB/Classic load balancers, target groups, and remaining load balancer network interfaces in this VPC. It uses the current AWS profile and requires EC2 VPC/network-interface and ELB describe permissions. Exit code 0 means these resources are gone; 1 means resources remain; 2 means the check failed and cleanup is unverified. Re-run while AWS finishes asynchronous cleanup; proceed to stage 2 only after it succeeds and EFS access-point cleanup below is complete. It deliberately checks the whole VPC rather than assuming every load balancer belongs to this release. If something must remain in this VPC, stop full teardown and resolve its ownership first.

If the Ingress sets `deletion_protection.enabled=true` in `alb.ingress.kubernetes.io/load-balancer-attributes`, explicitly change that attribute to `false` while preserving the other attributes, then let the controller reconcile before uninstalling. Simply omitting the attribute does not disable it. See the [controller's deletion-protection behavior](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/#custom-attributes).

The EFS StorageClass retains PVs/access points after PVC deletion. Inspect the access points for this filesystem:

```bash
aws efs describe-access-points --file-system-id "$FAIG_EFS_ID" \
  --region "$FAIG_REGION" \
  --query 'AccessPoints[].{ID:AccessPointId,Path:RootDirectory.Path}' --output table
```

For a full deletion, after confirming no workloads use the filesystem and backups are complete, delete its remaining access points using `aws efs delete-access-point --access-point-id fsap-REPLACE_WITH_CONFIRMED_ID --region "$FAIG_REGION"` for each confirmed ID. They were created by the CSI driver and are not tracked as Terraform resources. AWS requires access points and mount targets to be removed before filesystem deletion; Terraform removes its managed mount targets in the final stage.

```bash
# Stage 2a: delete the namespace while cleanup controllers are still available.
# Namespace deletion also removes any manually created resources in that namespace.
terraform destroy \
  -target=kubernetes_storage_class.efs \
  -target=kubernetes_namespace.fortiaigate \
  -var-file="$FAIG_VARS"

# Stage 2b: only after namespace deletion succeeds, remove the Helm controllers.
# Controller/device-plugin targets are skipped if no instances are managed by this stack.
terraform destroy \
  -target=helm_release.aws_load_balancer_controller \
  -target=helm_release.nvidia_device_plugin \
  -var-file="$FAIG_VARS"

# Stage 3: review the remaining infrastructure destruction, then confirm it.
terraform plan -destroy -var-file="$FAIG_VARS"
terraform destroy -var-file="$FAIG_VARS"

# The Terraform state should now contain no managed resources.
terraform state list
```

Review every destroy plan. Stage 1 should remove the application; stage 2 should remove remaining managed Kubernetes objects; EKS, nodes, networking, and EFS must remain until stage 3. Stop and investigate failures before proceeding. These commands use [Terraform's targeted destroy mode](https://developer.hashicorp.com/terraform/cli/commands/destroy), keeping release state aligned with the uninstall; a manual `helm uninstall` is not needed.

The separately bootstrapped S3 state bucket and DynamoDB lock table, mirrored ECR images, externally supplied ACM certificates, and DNS records are outside this stack and remain. Remove stale DNS records and review any externally managed controllers or leftover AWS resources separately. Do not delete your state backend or backups until cleanup is verified.

## Namespace stuck in Terminating

The namespace's normal `spec.finalizers: [kubernetes]` means the namespace controller must finish deleting its contents. Its presence alone does not identify the blocking resource. Check the namespace conditions for discovery failures, content deletion errors, remaining objects, or remaining object finalizers. See [Kubernetes finalizer behavior](https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/).

These commands only read cluster status and can be used while Terraform waits for deletion:

```bash
kubectl describe namespace "$FAIG_NAMESPACE"
kubectl get namespace "$FAIG_NAMESPACE" \
  -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}'
kubectl get ingress,svc,pods,pvc -n "$FAIG_NAMESPACE"
kubectl get apiservice
```

The conditions can name resource types beyond the common ones listed above; inspect those types too. For Ingress/Service finalizers, check the load balancer controller and AWS cleanup errors. For PVC protection, check which remaining pods use the claim. For discovery failures, investigate the unavailable APIService and its owning extension. Helm's `helm.sh/resource-policy: keep` on the master-key Secret is not a Kubernetes finalizer and does not itself prevent namespace deletion.

The namespace resource explicitly depends on the AWS Load Balancer Controller and EFS CSI addon, so future destroy operations keep both available until namespace deletion completes. Stage 2 also removes the namespace before uninstalling the Helm controllers. The existing one-hour namespace delete timeout allows cleanup to run; extending it does not fix a missing controller or failed discovery.

**An already running Terraform operation uses its existing dependency graph.** Editing this code does not repair that operation. Do not start a second Terraform operation, apply changes, modify state, or automatically clear finalizers while it runs. Inspect the read-only status first; after the operation finishes or is stopped cleanly, resolve the reported owner/controller problem before retrying. Force-finalizing a namespace can orphan Kubernetes and AWS resources, so there is no automatic finalizer-removal hook in this configuration.

## Recovering from subnet or internet gateway dependency errors

A subnet `DependencyViolation` usually means a network interface still occupies it. An internet gateway error mentioning "mapped public address(es)" means public addresses are still attached to resources in the VPC; AWS [will not detach that gateway](https://docs.aws.amazon.com/vpc/latest/userguide/delete-igw.html). A leftover internet-facing load balancer can cause both errors. EKS interfaces, EFS mount targets, NAT gateways, instances, and VPC endpoints can also hold subnets. The error alone does not identify which owner remains.

Use the VPC ID from the error or the remaining Terraform state, and the original region/profile. Outputs may already be gone after a partial destroy; do not run `terraform apply` to restore them.

```bash
# Inspect remaining Terraform ownership without changing state.
terraform state list
terraform state show 'module.vpc.aws_vpc.this[0]'

# Substitute the original region and VPC ID if your shell variables were lost.
python3 scripts/check_teardown.py --region "$FAIG_REGION" \
  --vpc-id "$FAIG_VPC_ID" --network
```

The `--network` report adds every network interface, its subnet, description, attached instance, requester-managed flag, and associated public addresses. EKS, EFS and NAT interfaces are expected before the final destroy; this mode diagnoses remaining resources rather than gating stage 2. A clean report is not a guarantee that every possible VPC dependency has been removed.

Resolve each reported resource by its owner:

- **Cluster and controller still available:** remove the owning Ingress/LoadBalancer Service, resolve controller errors or deletion protection, and re-run the check before continuing staged teardown.
- **Cluster already deleted:** inspect the orphaned load balancer's tags, listeners and targets in AWS to confirm ownership. Delete only the confirmed orphan through ELB, wait for deletion and its interfaces to disappear, then remove confirmed orphan target groups and controller-created security groups. Check shared IngressGroups and other workloads before deleting anything. Terraform cannot remove these controller-created resources because they are absent from its state.
- **EKS, EFS, NAT or another Terraform-managed owner remains:** inspect its destroy error and fix that first; let Terraform delete the owner and AWS release its interfaces. If a resource belongs to another stack, resolve it with that stack's owner. Do not force-detach service-managed interfaces; AWS documents their [requester-managed lifecycle](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/requester-managed-eni.html).

After cleanup, review `terraform plan -destroy -var-file="$FAIG_VARS"` and retry `terraform destroy -var-file="$FAIG_VARS"` to finish the remaining managed resources. Keep state intact; `terraform state rm` would only hide the blocked resources. Longer timeouts alone do not resolve orphaned dependencies.
