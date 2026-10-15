# Roadmap

Known gaps in the 8.0.2 branch and planned improvements. File an issue if you'd like to pick one up.

## Reliability

- [ ] **Track local Helm chart content in Terraform.** Add a deterministic hash of the files under `fortiaigate/` to release values so template edits trigger an upgrade instead of producing a no-op apply.
- [ ] **Complete workload health checks.** API, WebUI, and LogD currently lack Kubernetes probes. LLM gateway and guardrail have readiness probes; license manager and GPU engines have readiness/liveness probes. Add missing probes using verified endpoints and appropriate model startup windows.
- [ ] **Add Kubernetes schema validation.** CI already renders ALB/nginx configurations and asserts per-Service health paths. Add a schema validator to catch invalid Kubernetes fields beyond the existing render assertions.
- [ ] **Verify the bare-root console behavior.** Documentation uses `/ui`; the Ingress routes `/` to WebUI. Verify that all supported ingress modes redirect the bare root consistently, and add a redirect where needed.

## Architecture

- [ ] **Revisit shared EFS persistence layout.** One RWX EFS PVC backs application data, PostgreSQL, and Redis. Consider separate persistence per workload or external database services for production isolation and performance.

## Security defaults

- [ ] **Restrict EKS public endpoint.** `eks.tf` enables public access without a CIDR allowlist. Expose a CIDR setting or support private-only access.
- [ ] **Multi-AZ NAT.** `single_nat_gateway = true` introduces an AZ-level single point of failure; make this configurable.
- [ ] **Automate certificate renewal.** ALB ACM and supplied PEM web certificates are supported. Generated web/internal leaf certificates last one year and the CA lasts five years. Add proactive renewal and verify rollout before expiration; current resources have no early-renewal window.

## Lifecycle

- [ ] **Protect persistent data from full destruction.** The [teardown guide](docs/teardown.md) documents EFS data loss. Add optional retention or separate storage ownership; `reclaim_policy = "Retain"` only protects the Kubernetes PV.
- [ ] **Validate and advance the EKS default.** `1.31` standard support ended November 26, 2025; extended support ends November 26, 2026. Select and test a newer default before then using the [AWS support calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
- [ ] **Complete end-to-end lifecycle validation.** Test fresh deployment, license upload, DLP/POLICY inference, upgrade with existing data, and staged teardown. Passing render and mock-provider tests does not establish these behaviors.

## Implemented

- Deployment licensing replaces node-bound license files and scheduling affinity; upload licenses in the WebUI or authenticated admin API without another Terraform apply.
- GPU placement, shared Triton/vLLM mode, NVIDIA device plugin installation, and automatic G5 tuning are managed by Terraform.
- Web/internal TLS Secrets are separate; checksum annotations trigger affected workload rollouts on certificate changes.
- ALB frontend HTTPS uses ACM independently of pod TLS; tests cover exposure, backend health paths, and certificate mount/rotation behavior.
- Build0055 image tags and configuration digests are recorded in the image inventory and checked by chart render tests.
