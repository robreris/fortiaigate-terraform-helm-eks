# Internal and external ingress, DNS, and TLS

This EKS implementation follows the sister AKS repo's separation of web TLS and internal/database TLS. AWS Load Balancer Controller manages the ALB in both modes; there is no separate Terraform-managed gateway or trusted-root upload.

## Exposure and listeners

| Setting | Internal ALB | Internet-facing ALB |
|---------|--------------|---------------------|
| `ingress_class` | `alb` | `alb` |
| `internal` | `true` | `false` |
| Frontend subnets | Tagged private subnets | Tagged public subnets |
| Client connectivity | VPC, peering, VPN, Direct Connect or Transit Gateway | Internet, subject to security groups |
| HTTPS frontend certificate | ACM certificate in `aws_region` | ACM certificate in `aws_region` |
| DNS | Corporate/private DNS alias or CNAME to the ALB hostname | Public DNS alias or CNAME to the ALB hostname |

`internal` controls exposure. Conflicting `alb.ingress.kubernetes.io/scheme` values in `ingress_annotations` fail with an explanatory error. Terraform's exposure values also take precedence over `extra_values_files`.

Use an ACM certificate for browser/API HTTPS in either mode:

```hcl
ingress_class       = "alb"
internal            = true  # false for an internet-facing ALB
ingress_host        = "fortiaigate.example.com"
acm_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/your-certificate-id"
aws_region          = "us-west-2"
```

This selects an HTTPS listener on 443. Existing `ingress_annotations` containing `alb.ingress.kubernetes.io/certificate-arn` remain supported; the dedicated variable takes precedence. The ACM certificate must cover `ingress_host`. An imported corporate certificate can be used in ACM; clients must trust its issuer. PEM files supplied to Kubernetes do not configure the ALB listener.

Without an ACM ARN, Terraform explicitly selects HTTP on 80. This is an evaluation mode: browser-to-ALB traffic is plaintext. Use ACM and HTTPS for normal console/API testing, including workflows that require secure cookies. Pod/backend TLS remains enabled. The chart omits Ingress `spec.tls` for ALB so a generated pod certificate or placeholder hostname cannot unintentionally drive frontend ACM discovery.

For custom HTTP-to-HTTPS redirection with an ACM certificate, set both listeners and the redirect annotation:

```hcl
ingress_annotations = {
  "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\":80},{\"HTTPS\":443}]"
  "alb.ingress.kubernetes.io/ssl-redirect" = "443"
}
```

The controller merges these settings with target type `ip` and HTTPS backend/health-check protocols. Each backend Service defines its own health path: API `/openapi.json`, WebUI `/ui`, gateway `/fortiaigate/health/readiness`. Override `ingress.healthcheck` in an extra values file if a later application build changes these endpoints. Service-level annotations override an Ingress-level health path.

AWS references: [controller annotations and precedence](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/) and [ALB target groups](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html). ALB encrypts HTTPS backend traffic without validating target certificates; the AKS Application Gateway private-root upload is therefore unnecessary here.

## Web and internal certificates

Terraform creates a per-deployment CA and a serving certificate covering the ingress host, localhost, and the 8.0.2 Kubernetes Service DNS names. It creates two Secrets:

- `fortiaigate-tls-secret`: API, LLM gateway, WebUI, and the nginx frontend.
- `fortiaigate-internal-tls-secret`: guardrail services, LogD, license manager, PostgreSQL, Redis, and database client mounts. Its `ca.crt` is the generated CA.

The Secrets use separate keys and leaf certificates signed by the same generated CA. The internal certificate's common name matches `postgresql.auth.username` (default `fortiaigate_postgres_user`), including overrides from `extra_values_files`, because PostgreSQL uses certificate authentication. Its DNS SANs cover the same service names for server verification. Database clients, including the license manager, receive explicit certificate, key, and CA paths. Changing the ingress hostname does not change the database identity.

To supply a web certificate independently:

```hcl
ingress_host            = "fortiaigate.example.com"
tls_certificate_path    = "/secure/fortiaigate-fullchain.pem"
tls_private_key_path    = "/secure/fortiaigate.key"
# Only for a private issuer; used for client trust export:
# tls_ca_certificate_path = "/secure/company-root-ca.pem"
```

The full chain must have the leaf first, then intermediates. The key must be unencrypted and match it. Validate the material before applying:

```bash
python3 scripts/check_tls.py \
  --certificate /secure/fortiaigate-fullchain.pem \
  --private-key /secure/fortiaigate.key \
  --hostname fortiaigate.example.com
# Add --ca /secure/company-root-ca.pem for a private issuer.
```

For nginx, that web Secret is also the frontend certificate. For ALB, configure ACM separately. This repo does not install cert-manager or copy the AKS Azure DNS-01 integration.

Replacing supplied web certificate files and applying rolls API, gateway, and WebUI. Internal service/database certificates and their checksums remain independent. Export public CA material with `terraform output -raw tls_ca_certificate` or `terraform output -raw internal_tls_ca_certificate`. Serving keys reside in Terraform state; use the protected remote backend and keep PEM inputs out of Git.

For an existing deployment, the new generated CA and separate internal Secret change database/server trust. Schedule a rollout window and back up data before applying. The namespace, web Secret, and existing serving private-key resource addresses remain stable. Changing web certificate sources later retains the internal CA.

## Deploy and verify

Follow the README's two-stage bootstrap. Choose exposure before the first apply; changing the scheme later may replace the ALB and its DNS name, and requires a rollout window and DNS updates.

After the full apply:

```bash
terraform output alb_dns_name
terraform output ingress_scheme
kubectl get ingress,pods -n fortiaigate
kubectl describe ingress fortiaigate-ingress -n fortiaigate
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=100
```

Point `ingress_host` to the ALB hostname in the DNS clients use. Private DNS must resolve from the connected network; this stack does not create VPN/peering connectivity or DNS records. ALB addresses can change; use aliases or CNAMEs rather than pinning the resolved IPs. Verify `/ui`, authenticated API calls, and inference from a client on the correct network. Check target-group health for all three backends in AWS.

For access before ingress/DNS is ready, `node scripts/ui-proxy.mjs` creates local port-forwards and serves the UI, API, and `/ai` on one HTTPS origin. It uses your current kubeconfig, binds to localhost, and does not test ALB reachability or DNS. Use `FAIG_NAMESPACE` to select a different namespace.

Offline validation: `helm lint fortiaigate`, `python3 tests/check_chart.py`, `python3 tests/check_ingress_tls.py`, `python3 -m unittest discover -s tests -p test_tls_material.py`, and `python3 scripts/test_tls.py` (Terraform 1.7+ with initialized providers). The last command uses a temporary configuration with mocked providers and reads no account tfvars or state. Live AWS behavior remains to be tested.
