# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Apache-2.0 LICENSE and NOTICE files, contribution guidance, security policy, and project roadmap.
- Runnable examples for nginx, internal ALB, and internet-facing ALB deployments.
- Guides for remote state, image mirroring, Route 53, ingress/TLS, deployment operations, and staged teardown.
- A generated [Terraform reference](docs/terraform-reference.md), maintained through terraform-docs and pre-commit.
- Automatic G5 inference defaults and validated `gpu_tuning` overrides in tfvars: 12/8 GiB Triton/vLLM memory requests and 25/24 GiB limits. Explicit tuning and advanced Helm overlays remain supported.
- Separate generated web/internal TLS certificates, supplied PEM web certificates, independent ACM frontend HTTPS, CA outputs, and a local UI proxy.
- Build0055 chart/archive fingerprints and exact image tags in the [image inventory](docs/images.md).
- CI formatting, Terraform validation, TFLint, Helm lint, chart/GPU/ingress render checks, mocked Terraform validation tests, and real certificate checks.

### Changed

- Upgrade the locally maintained chart and application image defaults from 8.0.0 to FortiAIGate 8.0.2 build0055. Preserve EKS placement, EFS, TLS, and ingress adaptations. The vendor chart and pinned GPU image versions are unchanged from build0054.
- Default GPU nodes to `g6e.2xlarge` with the AL2023 NVIDIA AMI. Co-locate Triton and vLLM on one GPU and use `Recreate` rollouts; G5 examples select automatic A10G tuning.
- Replace node-bound license ConfigMaps and affinity with deployment licensing in PostgreSQL. Upload licenses through the WebUI or authenticated admin API; reject non-empty legacy `licenses` maps.
- Route the console at `/ui`, management API at `/api/`, and LLM gateway at `/ai`.
- Fix PostgreSQL certificate authentication with an internal certificate CN matching the database username and explicit license-manager database certificate paths/mounts. Retain Terraform resource addresses and independent web/internal rotation checksums.
- Enforce internal/public ALB exposure, configure ACM independently, avoid unintended certificate discovery, and use per-Service health-check paths.
- Document the Terraform 1.9 minimum, first-deploy EKS bootstrap, normal full applies for later updates, EFS data deletion, access-point cleanup, and master-key backups.
- Condense the README to the quickstart and teardown overview; preserve detailed operations and generated reference in linked docs.
- Refresh roadmap, security/TLS guidance, development checks, account/backend selection, and DNS examples for the current branch. Correct EKS support dates and remove obsolete licensing and workload claims.
- Track `.terraform.lock.hcl` for reproducible provider selections.

### Removed

- `TODO.txt` and `CLAUDE.md`; use `ROADMAP.md`, `AGENTS.md`, and `docs/technical-notes.md`.
- Duplicate Unreleased sections and superseded intermediate upgrade descriptions.
