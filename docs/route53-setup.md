# Route 53 alias record for an internet-facing ALB

Use this only when `ingress_class = "alb"`, `internal = false`, and the Ingress has a populated ALB hostname. For internal deployments, callers use the `alb_dns_name` output directly — no Route 53 entry is needed.

## Prerequisites

- A Route 53 hosted zone that contains the value of `ingress_host` (e.g. `example.com` for `fortiaigate.example.com`)
- `kubectl` configured against the cluster
- AWS credentials with `route53:ChangeResourceRecordSets` on the hosted zone

## Create the alias record

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

CHANGE_FILE="$(mktemp)"
trap 'rm -f "$CHANGE_FILE"' EXIT
cat > "$CHANGE_FILE" <<EOF
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
  --change-batch "file://${CHANGE_FILE}"
```

If `ROUTE53_ZONE_ID` resolves to the wrong hosted zone because both public and private zones share the same name, set `ROUTE53_ZONE_ID` manually to the public hosted zone ID and rerun the `change-resource-record-sets` command.

## Verify

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${APP_HOST}.']"

aws route53 test-dns-answer \
  --hosted-zone-id "${ROUTE53_ZONE_ID}" \
  --record-name "${APP_HOST}" \
  --record-type A
```
