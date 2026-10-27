# Remote state (S3 + DynamoDB)

State is stored in S3 with a DynamoDB lock table. Select the matching AWS credentials, backend configuration, and tfvars together when switching accounts. Multiple deployments can share a bucket and lock table, but each needs its own state key. Switching Git branches does not change remote state; applying different branch configuration against the same key changes the same deployment.

## One-time bootstrap per account

Run these commands once with credentials for the target account active. Choose a globally unique bucket name (including the account ID works well).

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="fortiaigate-tfstate-${ACCOUNT_ID}"
REGION="us-west-2"   # state backend region; match backends/dev.hcl

# S3 bucket (us-east-1 is the S3 default region and rejects LocationConstraint)
if [ "${REGION}" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
else
  aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
fi
aws s3api put-bucket-versioning --bucket "${BUCKET}" --region "${REGION}" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "${BUCKET}" --region "${REGION}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "${BUCKET}" --region "${REGION}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${REGION}"
aws dynamodb wait table-exists --table-name terraform-state-lock --region "${REGION}"
```

## Backend config files

The `backends/` directory holds one `.hcl` file per account. Only `backends/*.hcl.example` files are committed — actual `*.hcl` files are gitignored so account IDs stay out of git.

Copy the template and fill in your bucket name and region:

```bash
cp backends/backend.hcl.example backends/dev.hcl
$EDITOR backends/dev.hcl
```

Each file looks like:

```hcl
bucket         = "fortiaigate-tfstate-<aws-account-id>"
key            = "fortiaigate-eks/terraform.tfstate"
region         = "us-west-2"
dynamodb_table = "terraform-state-lock"
encrypt        = true
```

## Day-to-day workflow

```bash
# 1. Activate credentials for the target account
export AWS_PROFILE=dev   # or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

# 2. Initialize (first time on this machine, or when switching accounts)
terraform init -backend-config=backends/dev.hcl -reconfigure

# 3. New cluster only: bootstrap AWS infrastructure before Helm/Kubernetes.
# Skip this step for updates to an existing cluster.
terraform apply -target=module.vpc -target=module.eks -var-file=tfvars/dev.tfvars

# 4. Plan / apply the application (the single-apply workflow for later updates).
terraform plan -var-file=tfvars/dev.tfvars
terraform apply -var-file=tfvars/dev.tfvars
```

Upload deployment licenses in the WebUI after deployment; no follow-up Terraform apply is required for licensing. The new-cluster bootstrap exists so Terraform's Kubernetes and Helm providers can reach EKS, independently of how licenses are managed.

After bootstrap, refresh kubectl and verify Ready nodes as shown in the [quickstart](../README.md#quickstart) before the full apply. For removal, follow the [staged teardown](teardown.md); the state bucket and lock table remain outside the stack.

Use `-reconfigure` (not `-migrate-state`) when switching between accounts — you are pointing at a different backend, not copying state between them.
