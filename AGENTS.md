# Repository guidance

This repository contains Terraform infrastructure and a locally maintained Helm chart for FortiAIGate on AWS EKS. Use the README quickstart and linked deployment/teardown guides for procedures; avoid repeating those procedures here.

## Working in this repository

- Preserve AWS-specific adaptations in `fortiaigate/` when updating chart content. The chart contains local fixes and EKS integrations; do not replace it wholesale with an upstream archive.
- Preserve Terraform resource addresses and review plans for replacement or destruction, especially for EFS, the EKS cluster, and node groups.
- Keep account-specific tfvars, credentials, license material, Terraform state and plans, and rendered secret values out of version control.
- Helm values are composed in `helm.tf`; follow the precedence and structured-value guidance in [`docs/technical-notes.md`](docs/technical-notes.md).
- Keep `README.md` deployment instructions and relevant docs current when changing workflows. Add user-visible changes to `CHANGELOG.md`.
- Use the vendored chart dependencies. Do not run `helm dependency update`, which can replace the locally maintained subchart versions and fixes.

## Useful references

- [`README.md`](README.md): prerequisites, quickstart, verification, and teardown overview.
- [`docs/deployment-guide.md`](docs/deployment-guide.md): upgrades, configuration, and troubleshooting.
- [`docs/teardown.md`](docs/teardown.md): staged destruction, backups, and cleanup.
- [`CONTRIBUTING.md`](CONTRIBUTING.md): development setup and local checks.
- [`docs/technical-notes.md`](docs/technical-notes.md): Terraform and Helm architecture constraints.
- [`docs/ingress-and-tls.md`](docs/ingress-and-tls.md): ingress exposure and certificate behavior.
- [`docs/remote-state.md`](docs/remote-state.md): remote backend setup.
- [`docs/images.md`](docs/images.md): image inventory and registry workflow.
