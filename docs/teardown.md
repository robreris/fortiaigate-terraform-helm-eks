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
