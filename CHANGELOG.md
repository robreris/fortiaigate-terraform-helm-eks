# Changelog

## Unreleased

- Correct deploy/teardown documentation: staged Terraform teardown, explicit EFS data deletion/access-point cleanup, backup requirements, 8.0.2 verification, and the Terraform 1.9 minimum required by cross-variable validation.

- Adapt the sister AKS repo's generated-CA and separate web/internal TLS pattern, including supplied PEM certificates, CA outputs, and local UI proxy.
- Enforce internal/public ALB exposure, add independent ACM frontend configuration, avoid unintended certificate discovery, and use service-specific ALB health checks.
- Add isolated mocked Terraform ingress/TLS tests, real certificate validation, and ALB/nginx render checks.

- Upgrade the bundled chart to FortiAIGate 8.0.2 build0054 from the supplied Fortinet archive, including LLM gateway, guardrail, vLLM, and encrypted model images.
- Default GPU nodes to `g6e.2xlarge`; co-locate Triton and vLLM on the single GPU, preserving taint tolerations and `Recreate` rollouts.
- Replace node-keyed license ConfigMaps and affinity with deployment licensing through the admin API. Reject non-empty legacy `licenses` maps with migration guidance.
- Preserve EFS, Terraform-managed TLS and rotation checksums, and ingress annotation merging; route the console at `/ui` and LLM traffic at `/ai`.
- Document verified image archive tags and the upgrade procedure; validate CPU, shared-GPU, and dedicated-GPU chart renders in CI using the bundled dependencies.


All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Apache-2.0 LICENSE and NOTICE files.
- `CONTRIBUTING.md` covering development setup, local checks, and PR conventions.
- `SECURITY.md` with vulnerability reporting (Fortinet PSIRT) and a production-hardening checklist.
- `ROADMAP.md` (migrated from `TODO.txt`).
- `examples/` directory with `minimal`, `internal-alb`, and `internet-facing-alb` scenarios.
- `docs/remote-state.md` — S3 + DynamoDB backend bootstrap (moved out of README).
- `docs/route53-setup.md` — Route 53 alias setup for internet-facing ALB (moved out of README).
- `docs/images.md` — required container image list, scanner type mapping, and push-to-ECR walkthrough.
- GitHub Actions CI: `terraform fmt -check`, `terraform validate`, `tflint`, `helm lint` on PRs and pushes to `main`.
- `.tflint.hcl` configuring the AWS plugin and the recommended Terraform preset.
- `.terraform-docs.yml` and `.pre-commit-config.yaml` so the README input table stays in sync with `variables.tf`.
- Variable `validation {}` blocks on `app_node_count`, `ingress_class`, `update_strategy`, `storage_size`, `internal`, and `image_repository`.

### Changed
- `.terraform.lock.hcl` is now tracked in git for reproducible provider selections.
- `TODO.txt` replaced by `ROADMAP.md` (committed, organized by area).
- README rewritten as a navigation hub: badges + elevator pitch, single Quickstart pointing at `examples/`, troubleshooting consolidated. Hand-maintained variable table replaced by an auto-generated `terraform-docs` block. Long-form remote-state bootstrap and Route 53 walkthroughs moved into `docs/`. ~25 KB → ~11 KB.

### Removed
- `TODO.txt`.
