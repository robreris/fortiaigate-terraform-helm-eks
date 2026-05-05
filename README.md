# FortiAIGate AWS EKS Terraform + Helm Deployment

Deploys a FortiAIGate cluster on AWS EKS using Terraform and the bundled Helm chart.

## Architecture

```
AWS
├── VPC (10.0.0.0/16)
│   ├── Private subnets ×3  — EKS nodes, EFS mount targets
│   └── Public subnets  ×3  — NAT gateway, load balancers
├── EKS cluster
│   ├── App node group      — API, WebUI, Core, Scanners, PostgreSQL, Redis, LogD
│   └── GPU node group      — Triton inference server (optional, g5.2xlarge)
└── EFS filesystem          — shared ReadWriteMany PVC for all services
```

FortiAIGate services deployed by the Helm chart:

| Service | Role |
|---------|------|
| API | Control plane — REST API and OpenAPI endpoint |
| Core (AIFlow) | Data plane — LLM proxy and policy enforcement |
| WebUI | Management UI |
| Triton | GPU inference server for all 5 AI security models |
| Scanners (×8) | CPU-only scanner clients (language, code, prompt injection, sensitive, toxicity, anonymize, deanonymize, custom rule) |
| License Manager | DaemonSet — one pod per licensed node |
| LogD | Log aggregation daemon |
| PostgreSQL | Bitnami subchart |
| Redis | Bitnami subchart |

---

## Prerequisites

### Tools

| Tool | Minimum version | Notes |
|------|----------------|-------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.5 | |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | 2.x | Must be in `PATH` — used by the EKS exec auth plugin |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.28+ | For verifying the deployment |
| [Helm](https://helm.sh/docs/intro/install/) | 3.x | For chart management if needed |

### AWS

- AWS credentials configured (`aws configure`, environment variables, or an IAM instance/pod role)
- Sufficient IAM permissions to create VPC, EKS, EFS, IAM roles, and EC2 instances
- FortiAIGate container images pushed to a registry accessible from EKS (e.g. ECR)
- For internet-facing AWS ALB ingress: an ACM certificate in the same AWS region as `aws_region`
- For internet-facing ALB with custom DNS: an existing Route 53 hosted zone for the domain used by `ingress_host`

### GPU (optional)

When `gpu_enabled = true`, the NVIDIA Kubernetes device plugin is required for the GPU node to advertise `nvidia.com/gpu` resources to the scheduler. Terraform installs it automatically — no manual action needed. See [NVIDIA device plugin](#nvidia-device-plugin) for details and troubleshooting.

### Images

All FortiAIGate images must be available at `<image_repository>/<service>:<image_tag>`. The expected service names are:

```
api
core
webui
logd
license_manager
scanner
custom-triton
triton-models
```

Example for ECR with repository prefix `123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate`:
```
123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate/api:V8.0.0-build0024
123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate/core:V8.0.0-build0024
...
```

---

## Remote state (S3 + DynamoDB)

State is stored in S3, with one bucket and one DynamoDB lock table per AWS account. This keeps state isolated — switching AWS credentials is all that is needed to switch accounts.

### One-time bootstrap per account

Run these commands once with credentials for the target account active. Choose a bucket name that is globally unique, e.g. include the account ID.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="fortiaigate-tfstate-${ACCOUNT_ID}"
REGION="us-west-2"   # match the region you will deploy into

# S3 bucket (us-east-1 is the S3 default region and rejects LocationConstraint)
if [ "${REGION}" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${REGION}"
```

### Backend config files

The `backends/` directory contains one `.hcl` file per account. These files are committed to the repo (they contain no secrets — only bucket and table names). Fill in the placeholder values after running the bootstrap above.

```
backends/
├── dev.hcl
└── prod.hcl
```

Each file looks like:

```hcl
bucket         = "fortiaigate-tfstate-<account-id>"
key            = "fortiaigate-eks/terraform.tfstate"
region         = "us-west-2"
dynamodb_table = "terraform-state-lock"
encrypt        = true
```

### Variable files

The `tfvars/` directory contains one `.tfvars` file per account. Actual `.tfvars` files are gitignored (they contain account IDs, certificate ARNs, and node names). Committed `.tfvars.example` files serve as templates.

```
tfvars/
├── dev.tfvars.example    ← committed template
├── dev.tfvars            ← local only (gitignored)
├── prod.tfvars.example   ← committed template
└── prod.tfvars           ← local only (gitignored)
```

### Day-to-day workflow

```bash
# 1. Activate credentials for the target account
export AWS_PROFILE=dev   # or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

# 2. Initialize (first time on this machine, or when switching accounts)
terraform init -backend-config=backends/dev.hcl -reconfigure

# 3. Plan / apply
terraform apply -var-file=tfvars/dev.tfvars
```

Use `-reconfigure` (not `-migrate-state`) when switching between accounts — you are pointing at a different backend, not copying state between them.

---

## Deployment

### 1. Configure variables

Copy the example for the target account and fill in the real values:

```bash
cp tfvars/dev.tfvars.example tfvars/dev.tfvars
```

Edit `tfvars/dev.tfvars` and set at minimum:

```hcl
image_repository = "123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate"
```

For an internet-facing AWS ALB, also set:

```hcl
ingress_class = "alb"
ingress_host  = "fortiaigate.example.com"
aws_load_balancer_controller_enabled = true
ingress_annotations = {
  "kubernetes.io/ingress.class"                = "alb"
  "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
  "alb.ingress.kubernetes.io/target-type"      = "ip"
  "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
  "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS"
  "alb.ingress.kubernetes.io/certificate-arn"  = "arn:aws:acm:<aws_region>:123456789:certificate/..."
}
```

For an internal (private) ALB — reachable only within the VPC and connected networks:

```hcl
ingress_class                        = "alb"
aws_load_balancer_controller_enabled = true
internal                             = true
ingress_annotations = {}
```

After apply, retrieve the ALB hostname from the `alb_dns_name` output (see [Verify the deployment](#5-verify-the-deployment)) and configure callers to use it. No ACM certificate or Route 53 entry is required.

The ACM certificate ARN (internet-facing only) must be in the same region as `aws_region`. If `aws_load_balancer_controller_enabled = false`, this stack still creates the Ingress object, but an ALB is created only if an AWS Load Balancer Controller is already installed and watching the cluster.

See [Variable reference](#variable-reference) for all options.

### 2. Initialize Terraform

Pass the backend config for the target account:

```bash
terraform init -backend-config=backends/dev.hcl
```

If you have previously initialized with a different backend (e.g. switching from local state or another account), add `-reconfigure`:

```bash
terraform init -backend-config=backends/dev.hcl -reconfigure
```

### 3. Deploy the cluster and application

> **Note:** The Kubernetes and Helm providers need a live cluster endpoint to authenticate. On the very first deployment the cluster doesn't exist yet, so a single `terraform apply` will fail with `Unauthorized` errors. Always use the two-step approach below.

**Step 3a — bootstrap VPC and EKS cluster (≈10–15 min):**

```bash
terraform apply -target=module.vpc -target=module.eks -var-file=tfvars/dev.tfvars
```

Once complete, run a kubeconfig update and confirm the cluster control plane is reachable before continuing:

```bash
aws eks update-kubeconfig --region <aws_region> --name <cluster_name>

aws eks get-token --cluster-name <cluster_name> --region <aws_region>
```

A successful response (a JSON object containing a bearer token) means the EKS API server is up and Terraform's Kubernetes and Helm providers will be able to authenticate.

**Step 3b - apply licenses**

Licenses are mapped per node. First, retrieve node names after the initial apply:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers
```

Then, add the `licenses` map to `tfvars/dev.tfvars` (or whichever account file you are using):

```hcl
licenses = {
  "ip-10-0-1-100.us-east-1.compute.internal" = "/path/to/node1.lic"
  "ip-10-0-2-200.us-east-1.compute.internal" = "/path/to/node2.lic"
}
```

Terraform creates a `fortiaigate-license-config` ConfigMap in the `fortiaigate` namespace and updates the Helm release to reference it. The license-manager DaemonSet picks up the new ConfigMap automatically.

**Step 3c — deploy EFS, storage, and FortiAIGate (≈5–10 min):**

```bash
terraform apply -var-file=tfvars/dev.tfvars
```

Terraform provisions the remaining resources in order:
1. VPC, subnets, NAT gateway *(already complete)*
2. EKS cluster and node groups *(already complete)*
3. EFS filesystem and CSI driver
4. AWS Load Balancer Controller when `ingress_class = "alb"` and `aws_load_balancer_controller_enabled = true`
5. FortiAIGate namespace, license ConfigMap, and Helm release

Subsequent `terraform apply` runs (e.g. to update variables or licenses) can be run as a single step — the two-step bootstrap is only needed on the initial deployment.

### 4. Configure kubectl

```bash
$(terraform output -raw configure_kubectl)
# equivalent to:
# aws eks update-kubeconfig --region us-east-1 --name fortiaigate
```

### 5. Verify the deployment

```bash
kubectl get pods -n fortiaigate
kubectl get ingress -n fortiaigate
kubectl get pvc -n fortiaigate
```

All pods should reach `Running` state within a few minutes of the Helm release completing.

If using AWS ALB ingress, also confirm the ALB controller is installed and the Ingress has an ALB DNS name:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get ingress -n fortiaigate fortiaigate-ingress
```

Wait until the ingress `ADDRESS` column is populated. The `alb_dns_name` Terraform output surfaces the same hostname:

```bash
terraform output alb_dns_name
```

For an internal deployment, this is the hostname to configure on callers:

| Caller | URL |
|--------|-----|
| FortiGate → WebUI | `https://<alb_dns_name>/` |
| Chatbot → API | `https://<alb_dns_name>/api/` |
| Chatbot → Core | `https://<alb_dns_name>/v1/` |

### 6. Publish Route 53 DNS for internet-facing AWS ALB

Use this step only when `ingress_class = "alb"`, `internal = false`, and the Ingress has a populated ALB hostname. For internal deployments, skip this step and use the `alb_dns_name` output directly.

Set the hosted zone name that contains `ingress_host`:

```bash
export ROUTE53_ZONE_NAME="example.com"
export APP_HOST="$(terraform output -raw ingress_host)"
export AWS_REGION="$(terraform output -raw aws_region)"
```

Discover the ALB DNS name and hosted zone ID, then upsert an alias `A` record in Route 53:

```bash
export ALB_DNS_NAME="$(kubectl get ingress -n fortiaigate fortiaigate-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export ROUTE53_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROUTE53_ZONE_NAME}." \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_NAME}.'].Id | [0]" \
  --output text | sed 's|/hostedzone/||')"
export ALB_ZONE_ID="$(aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS_NAME}'].CanonicalHostedZoneId | [0]" \
  --output text)"

for value in AWS_REGION ALB_DNS_NAME ROUTE53_ZONE_ID ALB_ZONE_ID; do
  test "${!value}" != "" && test "${!value}" != "None" || {
    echo "${value} was not discovered"
    exit 1
  }
done

cat > /tmp/fortiaigate-route53-change.json <<EOF
{
  "Comment": "Point ${APP_HOST} to the FortiAIGate ALB",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${APP_HOST}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_ZONE_ID}",
          "DNSName": "dualstack.${ALB_DNS_NAME}",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --change-batch file:///tmp/fortiaigate-route53-change.json
```

If `ROUTE53_ZONE_ID` resolves to the wrong hosted zone because you have both public and private zones with the same name, set `ROUTE53_ZONE_ID` manually to the public hosted zone ID and rerun the `change-resource-record-sets` command.

Verify DNS after Route 53 propagation:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${APP_HOST}.']"

aws route53 test-dns-answer \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --record-name "${APP_HOST}" \
  --record-type A
```

---

## Adding/updating licenses

To update the licenses associated with cluster nodes:

**Step 1** — retrieve node names:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers
```

**Step 2** — update the `licenses` map in `tfvars/<account>.tfvars`:

```hcl
licenses = {
  "ip-10-0-1-100.us-east-1.compute.internal" = "/path/to/node1.lic"
  "ip-10-0-2-200.us-east-1.compute.internal" = "/path/to/node2.lic"
}
```

**Step 3** — re-apply:

```bash
terraform apply -var-file=tfvars/<account>.tfvars
```

---

## GPU support

GPU is disabled by default. To enable a GPU node group (one `g5.2xlarge` node running the Triton inference server):

```hcl
gpu_enabled = true
```

The GPU node group uses the `AL2_x86_64_GPU` AMI (Amazon Linux 2 with NVIDIA drivers and the container toolkit pre-installed). The node is tainted `fortiaigate-gpu=true:NoSchedule` and Triton is scheduled there exclusively.

> **Note:** GPU nodes are expensive (~$1.20/hr). Set `gpu_enabled = false` for development and testing. Without GPU, Triton is disabled and AI model inference will not function.

---

## Ingress options

### NGINX (default)

```hcl
ingress_class = "nginx"
ingress_host  = "fortiaigate.example.com"  # optional
```

The NGINX ingress controller must be installed in the cluster separately (e.g. via the `ingress-nginx` Helm chart).

### AWS ALB (internet-facing)

```hcl
ingress_class = "alb"
ingress_host  = "fortiaigate.example.com"
aws_load_balancer_controller_enabled = true
ingress_annotations = {
  "kubernetes.io/ingress.class"                = "alb"
  "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
  "alb.ingress.kubernetes.io/target-type"      = "ip"
  "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
  "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS"
  "alb.ingress.kubernetes.io/certificate-arn"  = "arn:aws:acm:us-east-1:123456789:certificate/..."
}
```

The ACM certificate ARN must be in the same AWS region as this deployment. The AWS Load Balancer Controller creates the ALB but does not create Route 53 records; manage DNS separately (see [step 6](#6-publish-route-53-dns-for-internet-facing-aws-alb)).

### AWS ALB (internal)

For deployments where all traffic enters through a private network (VPN, Direct Connect, Transit Gateway, or a FortiGate acting as a VPC gateway):

```hcl
ingress_class                        = "alb"
aws_load_balancer_controller_enabled = true
internal                             = true
```

Setting `internal = true` configures the ALB with `scheme: internal`, placing it in the private subnets (already tagged `kubernetes.io/role/internal-elb: 1`). The ALB is reachable only from within the VPC and connected networks — no public IP, no ACM certificate required, and no Route 53 entry needed.

The AWS Load Balancer Controller automatically manages the ALB security group (inbound open on the listener port) and adds the corresponding inbound rule to the EKS node security group. No manual security group configuration is required.

After `terraform apply`, retrieve the ALB hostname and configure callers accordingly:

```bash
terraform output alb_dns_name
```

All three services are exposed via path-based routing on the same ALB listener:

| Caller | Path | Backend |
|--------|------|---------|
| FortiGate → WebUI | `/` | webui (port 3000) |
| Chatbot → API | `/api/` | api (port 8000) |
| Chatbot → Core | `/v1/` | core (port 8080) |

When `ingress_class = "alb"` and `aws_load_balancer_controller_enabled = true`, Terraform installs the AWS Load Balancer Controller in `kube-system` using IRSA and the AWS EKS Helm chart. Set `aws_load_balancer_controller_enabled = false` only if the controller is already managed outside this stack.

---

## Advanced: extra values files

For configuration not exposed as Terraform variables, pass additional Helm values files:

```hcl
extra_values_files = ["/path/to/my-overlay.yaml"]
```

Files are merged left-to-right before the built-in `set {}` blocks, so Terraform variables take precedence over values files.

---

## Variable reference

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | `"us-east-1"` | AWS region |
| `cluster_name` | string | `"fortiaigate"` | EKS cluster name |
| `cluster_version` | string | `"1.31"` | Kubernetes version |
| `app_node_instance_type` | string | `"m7i.4xlarge"` | App node instance type |
| `app_node_count` | number | `2` | Number of app nodes |
| `gpu_enabled` | bool | `false` | Add GPU node group for Triton |
| `gpu_node_instance_type` | string | `"g5.2xlarge"` | GPU node instance type |
| `image_repository` | string | **required** | Registry prefix for FortiAIGate images |
| `image_tag` | string | `"V8.0.0-build0024"` | Image tag |
| `namespace` | string | `"fortiaigate"` | Kubernetes namespace |
| `ingress_class` | string | `"nginx"` | Ingress class (`nginx` or `alb`) |
| `ingress_host` | string | `""` | Ingress hostname (empty = match all) |
| `ingress_annotations` | map(string) | `{}` | Extra ingress annotations |
| `aws_load_balancer_controller_enabled` | bool | `true` | Install AWS Load Balancer Controller when `ingress_class = "alb"` |
| `aws_load_balancer_controller_chart_version` | string | `"1.14.0"` | AWS Load Balancer Controller Helm chart version |
| `storage_size` | string | `"100Gi"` | Shared EFS PVC size |
| `licenses` | map(string) | `{}` | Node name → local license file path |
| `update_strategy` | string | `"Recreate"` | `Recreate` or `RollingUpdate` |
| `extra_values_files` | list(string) | `[]` | Additional Helm values files to merge |
| `internal` | bool | `false` | Set ALB scheme to `internal`; requires `ingress_class = "alb"` |

---

## Teardown

Best practice is to delete Helm-managed workloads first, wait for Kubernetes cleanup to finish, and then destroy the Terraform-managed infrastructure. This avoids `context deadline exceeded` errors caused by Terraform deleting cluster infrastructure while Helm releases, load balancers, PVCs, or controller finalizers are still terminating.

### 1. Configure kubectl

```bash
$(terraform output -raw configure_kubectl)
```

### 2. List Helm releases

```bash
helm list -A
```

Expected releases for this stack are:

- `fortiaigate` in the `fortiaigate` namespace
- `aws-load-balancer-controller` in `kube-system` when `ingress_class = "alb"` and `aws_load_balancer_controller_enabled = true`

### 3. Delete application Helm releases first

```bash
helm uninstall fortiaigate -n fortiaigate --wait --timeout 20m
```

Wait for application resources to terminate:

```bash
kubectl get pods,pvc,ingress -n fortiaigate
kubectl wait --for=delete ingress/fortiaigate-ingress -n fortiaigate --timeout=20m
kubectl wait --for=delete pod --all -n fortiaigate --timeout=20m
```

If the namespace is empty except for Helm history or retained resources, continue. If resources remain, inspect them before destroying the cluster:

```bash
kubectl get all,pvc,ingress,secrets,configmaps -n fortiaigate
kubectl describe ingress fortiaigate-ingress -n fortiaigate
```

### 4. Delete infrastructure controller Helm releases

If Terraform installed the AWS Load Balancer Controller, remove it after the application ingress has been deleted and the ALB has been cleaned up:

```bash
helm uninstall aws-load-balancer-controller -n kube-system --wait --timeout 10m
```

Confirm no AWS Load Balancer Controller pods remain:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### 5. Destroy Terraform resources

After Helm releases are gone, run:

```bash
terraform destroy -var-file=tfvars/<account>.tfvars
```

If `terraform destroy` still times out, rerun it after checking for stuck Kubernetes resources:

```bash
kubectl get namespaces
kubectl get all,pvc,ingress -A
helm list -A
```

> **Note:** The EFS filesystem has `reclaim_policy = Retain`. After `terraform destroy`, the EFS filesystem and its data remain in AWS and must be deleted manually if no longer needed.

---

## NVIDIA device plugin

The [NVIDIA Kubernetes device plugin](https://github.com/NVIDIA/k8s-device-plugin) is a DaemonSet that runs on GPU nodes and advertises `nvidia.com/gpu` as a schedulable resource. Without it, the Kubernetes scheduler cannot allocate GPU resources and the Triton pod will stay `Pending` with:

```
Insufficient nvidia.com/gpu
```

The `AL2_x86_64_GPU` AMI ships with NVIDIA drivers and the container toolkit pre-installed. The device plugin is the only additional component needed for Kubernetes to see and schedule against the GPU.

### Automatic installation

When `gpu_enabled = true`, Terraform installs the device plugin automatically as a Helm release in `kube-system`. The DaemonSet is configured to tolerate the `fortiaigate-gpu=true:NoSchedule` taint so it schedules on the GPU node. No manual action is required on a fresh deployment.

### Manual installation

If you need to install or reinstall the device plugin outside of Terraform (e.g. after manually resizing the GPU node group):

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update nvdp
helm upgrade --install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --set tolerations[0].key=fortiaigate-gpu \
  --set tolerations[0].operator=Equal \
  --set-string tolerations[0].value=true \
  --set tolerations[0].effect=NoSchedule
kubectl rollout status ds/nvidia-device-plugin-daemonset -n kube-system --timeout=120s
```

### Verifying GPU resource availability

After the device plugin is running, confirm the GPU node is advertising resources:

```bash
kubectl get pods -n kube-system | grep nvidia
kubectl describe node -l fortiaigate-role=gpu | grep -A10 "Capacity:"
```

`nvidia.com/gpu: 1` should appear in both the `Capacity` and `Allocatable` sections. If it is missing, check that the device plugin DaemonSet pod is `Running` on the GPU node.

---

## Troubleshooting

**`Unauthorized` errors when creating Kubernetes resources**

This happens on the first deployment when the cluster doesn't exist yet. Follow the two-step process in [Deploy the cluster and application](#3-deploy-the-cluster-and-application), using `aws eks get-token` to confirm the cluster is ready before running the second `terraform apply`.

**Pods stuck in `Pending`**

Check node capacity and EFS mount status:

```bash
kubectl describe pod <pod-name> -n fortiaigate
kubectl get pvc -n fortiaigate
```

**License manager not starting**

Verify node names in the `licenses` variable match exactly what `kubectl get nodes` returns. The license-manager DaemonSet uses node affinity keyed on the names in the ConfigMap.

**EFS CSI driver not ready**

The StorageClass waits for the addon and mount targets, but the addon pods take a minute to start after the cluster is created. If PVCs are stuck in `Pending`, check:

```bash
kubectl get pods -n kube-system | grep efs
```
