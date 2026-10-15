# Route 53 alias record for an internet-facing ALB

Use this only when `ingress_class = "alb"`, `internal = false`, and the Ingress has a populated ALB hostname. For an internal ALB with `ingress_host` set, configure that hostname in private/corporate DNS and use a client connected to the VPC. The raw ALB hostname does not match a custom host rule or its HTTPS certificate; see [ingress and TLS](ingress-and-tls.md).

## Prerequisites

- A Route 53 hosted zone that contains the value of `ingress_host` (e.g. `example.com` for `fortiaigate.example.com`)
- `kubectl` configured against the cluster
- AWS credentials allowing Route 53 hosted-zone/record discovery, record changes on the intended zone, and `elasticloadbalancing:DescribeLoadBalancers`
- Bash, and the same initialized Terraform backend/AWS profile used to deploy

## Create the alias record

Set the hosted zone name that contains `ingress_host`:

```bash
export ROUTE53_ZONE_NAME="example.com"
export APP_HOST="$(terraform output -raw ingress_host)"
export FAIG_NAMESPACE="fortiaigate"  # match your deployment
export AWS_REGION="$(terraform output -raw aws_region)"
```

Discover the ALB DNS name and hosted zone ID, then upsert an alias `A` record in Route 53:

```bash
export ALB_DNS_NAME="$(kubectl get ingress -n "$FAIG_NAMESPACE" fortiaigate-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export ROUTE53_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${ROUTE53_ZONE_NAME}." \
  --query "HostedZones[?Name=='${ROUTE53_ZONE_NAME}.' && !Config.PrivateZone].Id | [0]" \
  --output text | sed 's|/hostedzone/||')"
export ALB_ZONE_ID="$(aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --query "LoadBalancers[?DNSName=='${ALB_DNS_NAME}'].CanonicalHostedZoneId | [0]" \
  --output text)"

for value in APP_HOST AWS_REGION ALB_DNS_NAME ROUTE53_ZONE_ID ALB_ZONE_ID; do
  test "${!value}" != "" && test "${!value}" != "None" || {
    echo "${value} was not discovered"
    exit 1
  }
done

aws route53 get-hosted-zone --id "$ROUTE53_ZONE_ID" \
  --query 'HostedZone.{ID:Id,Name:Name,Private:Config.PrivateZone}'
# Confirm this is the intended public zone before submitting the change below.
```

Review the selected zone, then submit the record:

```bash
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

The discovery query excludes private zones. If your account has multiple public zones with the same name, set `ROUTE53_ZONE_ID` explicitly to the delegated public zone **before** submitting the change.

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
