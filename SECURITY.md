# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report security issues directly to Fortinet PSIRT:

- Web: <https://www.fortiguard.com/psirt>
- Email: <psirt@fortinet.com>

Include:

- The affected file(s) and Terraform version
- A description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept
- Your suggested remediation, if any

## Scope

This policy covers the Terraform and Helm code in this repository, including:

- Default IAM policies attached by the modules
- Default network exposure (security groups, ALB schemes, EKS endpoint access)
- Default secret handling (TLS certificates, license storage)

It does **not** cover vulnerabilities in upstream dependencies (Terraform providers, third-party Helm charts, AWS-managed addons) — report those to the relevant upstream project. It also does not cover FortiAIGate container image vulnerabilities, which are reported through the standard Fortinet support channels.

## Production hardening

The defaults in this repository favor ease of evaluation, not production security posture. Before deploying to a production environment, review at minimum:

- EKS endpoint settings in `eks.tf` — public access is enabled by default; restrict to known CIDRs or disable in favor of private endpoint access. These module settings are not currently exposed as tfvars.
- NAT settings in `vpc.tf` — `single_nat_gateway = true`; change the module configuration for multi-AZ resilience. No NAT topology variable is currently exposed.
- Web and internal TLS — configure ACM for the ALB HTTPS listener; use supplied PEM files for a separately issued web certificate. ACM does not replace pod/database certificates. Monitor and renew the generated one-year leaf certificates; see [ingress and TLS](docs/ingress-and-tls.md).
- EFS encryption (`efs_encrypted`) — defaults to `true` and uses the AWS-managed key. A customer-managed KMS key requires an infrastructure change; no key-selection variable is exposed.
- Public ALB access — restrict `alb.ingress.kubernetes.io/inbound-cidrs` to the intended clients, or use internal ingress.
- IAM scopes attached via the EKS, EFS CSI, and ALB controller IRSA modules — review the AWS-managed policies used and apply least-privilege overrides where appropriate
