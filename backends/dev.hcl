# Backend config for the dev account.
# Usage: terraform init -backend-config=backends/dev.hcl [-reconfigure]
#
# Prerequisites: create the bucket and DynamoDB table in this account first.
#   See README.md for the one-time bootstrap commands.

bucket         = "fortiaigate-tfstate-919333998172"
key            = "fortiaigate-eks/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-state-lock"
encrypt        = true
