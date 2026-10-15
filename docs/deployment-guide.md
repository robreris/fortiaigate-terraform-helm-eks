# Deployment and operations

Start with the [README quickstart](../README.md#quickstart). This guide covers architecture, upgrades, configuration, and troubleshooting. For removal, follow the [teardown guide](teardown.md).

## Architecture

```
AWS
├── VPC (10.0.0.0/16)
│   ├── Private subnets ×3  — EKS nodes, EFS mount targets
│   └── Public subnets  ×3  — NAT gateway, load balancers
├── EKS cluster
│   ├── App node group      — API, WebUI, LLM gateway, Guardrail, PostgreSQL, Redis, LogD
│   └── GPU node group      — Triton + vLLM inference (optional, g6e.2xlarge)
└── EFS filesystem          — shared ReadWriteMany PVC for all services
```

| Service | Role |
|---------|------|
| API | Control plane — REST API and OpenAPI endpoint |
| LLM gateway | Data plane — LLM proxy and policy enforcement |
| WebUI | Management UI |
| Triton + vLLM | DLP model inference and Natural Language policy evaluation |
| Guardrail | Dispatcher, DLP scanner, and policy guard |
| License Manager | Deployment with two replicas and leader election |
| LogD | Log aggregation daemon |
| PostgreSQL | Bitnami subchart |
| Redis | Bitnami subchart |

## Two-step bootstrap (first deploy)

The Helm and Kubernetes providers obtain credentials through `aws eks get-token`, but the cluster must already exist and authorize the caller before those providers can operate. Use the two stages in the [quickstart](../README.md#quickstart) for a new cluster. `kubectl get nodes` checks API access; merely obtaining an EKS token does not prove authorization.

This bootstrap is independent of licensing. The old node-bound license discovery/configuration workflow is gone; deployment licenses are uploaded in the WebUI after the application is deployed. Removing that license step does not remove the initial provider dependency on EKS. [HashiCorp's Kubernetes provider guidance](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs) recommends separate apply operations for cluster creation and Kubernetes resources.

If stage 1 fails or nodes are not Ready, fix it before stage 2. If VPC creation was incomplete, re-run the VPC target using the same tfvars before retrying stage 1. Stage 2 can take longer than a few minutes while the large model images download and initialize; the application's Helm timeout is 20 minutes.

Subsequent configuration changes normally use a full `terraform plan` and `terraform apply` with the same variable file. Targeting is reserved for this bootstrap and the [staged teardown](teardown.md). Local checks have passed, but the documented fresh deployment and teardown sequence still requires a live AWS test.

## Updating from build0054 to build0055

Set `image_tag = "V8.0.2-build0055"` in your tfvars, including any existing
account-specific overrides, and publish the seven application images with that
tag. The build0055 vendor chart is identical to build0054's, and its Triton,
vLLM, and model-carrier image versions are unchanged. Keep their exact pinned
tags listed in [the image inventory](images.md).

Back up application data and Secrets before upgrading, then review a full
`terraform plan` with the same tfvars before applying. This image update does
not require changing GPU node types, GPU tuning, TLS, licensing, or storage.

## Upgrading from 8.0.0

The bundled chart is FortiAIGate 8.0.2 build0055. Before applying:

1. Back up PostgreSQL, Redis, the shared EFS data, Helm values, and Secrets. Preserve the master-key Secret on subsequent upgrades; encrypted credentials depend on it.
2. Mirror all ten supplied image archives into your registry using [docs/images.md](images.md). The inference images use fixed tags.
3. Set `image_tag = "V8.0.2-build0055"` and remove node-keyed `licenses`. Use the default `g6e.2xlarge`, or retain `g5.2xlarge` with [automatic G5 tuning](#gpu-support). Review old extra values files against the new chart; `core` and `scanners` have been replaced by `llmGateway` and `guardrail`.
4. Review `terraform plan`. Changing the GPU instance type replaces the managed node group; schedule downtime for inference. Apply the upgrade, upload the deployment license, and check all pods become Ready.
5. Update LLM clients to the `/ai` gateway routes. The console uses `/ui`; the management API remains under `/api/`.

The `Recreate` strategy avoids waiting for a second GPU during rollout. Local validation does not establish compatibility of an existing database with 8.0.2; verify the upgrade against a backup before production use.

## License management

FortiAIGate 8.0.2 uses deployment licenses stored in PostgreSQL. After deployment, sign in to the WebUI and upload the license. Automation can use the authenticated admin API (`POST /api/v1/admin/licenses`). The license manager runs as a two-replica Deployment.

Remove the old node-keyed `licenses` map from your tfvars. The deprecated variable accepts only an empty map; Terraform no longer creates a license ConfigMap or pins services to licensed nodes. Do not discover node IDs or add license material to Terraform configuration. Uploading or renewing a license does not require Terraform or Helm changes. The initial EKS bootstrap described above is a separate infrastructure dependency.

## GPU support

Disabled by default. Set `gpu_enabled = true` to add a single `g6e.2xlarge` node on the `AL2023_x86_64_NVIDIA` AMI, tainted `fortiaigate-gpu=true:NoSchedule`. Triton and vLLM share its GPU in one pod (`triton-vllm-server`). Application nodes retain the `m7i.4xlarge` default.

To use a `g5.2xlarge`, configure only your deployment tfvars:

```hcl
gpu_enabled            = true
gpu_node_instance_type = "g5.2xlarge"
gpu_tuning_profile     = "auto"
```

`auto` selects the maintained reference chart's shared A10G settings for G5 instances. Other instance families retain the vendor defaults. Set `gpu_tuning_profile = "g5"` to explicitly select those settings, or `"chart"` to disable automatic tuning. CPU-only deployments omit GPU tuning entirely.

| G5 setting | Triton | vLLM |
|------------|--------|------|
| Host RAM request | 12 GiB | 8 GiB |
| Host RAM limit | 25 GiB | 24 GiB |
| Model instances / API processes | 1 | 1 |
| Maximum batch / concurrent sequences | 16 | 64 |
| GPU budget | Shares the remaining GPU memory | 80% |

The combined 20 GiB memory request fits a G5 node. Limits permit model startup to use more memory and exceed the node's total RAM when added together; simultaneous peaks can still exhaust the node. Validate model startup and inference under your workload, checking for `OOMKilled`, CUDA memory errors, and insufficient KV cache. Retaining the existing instance type avoids replacing its node group.

Optional overrides also live in tfvars; omitted fields inherit their profile/chart defaults:

```hcl
gpu_tuning = {
  triton_memory_request = "12Gi"
  triton_memory_limit   = "25Gi"
  vllm_memory_request   = "8Gi"
  vllm_memory_limit     = "24Gi"
  vllm_max_num_seqs     = 32
}
```

`gpu_tuning` also supports `triton_dlp_instances_per_gpu`, `triton_dlp_max_batch_size`, `vllm_api_server_count`, `vllm_gpu_memory_utilization`, and `vllm_max_model_len`. Memory quantities must use positive whole `Mi` or `Gi` units. When changing context length, review the policy scanner's chunk/rule lengths together with it, as described in the chart values. `extra_values_files` remains optional for advanced chart settings. Merge precedence is profile defaults → extra values files → explicit `gpu_tuning` fields → mandatory placement/ingress/TLS → Helm `set` values.

If you used the earlier `values-g5.yaml`, remove its entry from `extra_values_files` and set `gpu_tuning_profile = "auto"`. Keep any unrelated files. The old overlay's 6 GiB Triton limit caused startup OOM kills; the reference settings restore its 25 GiB limit.

Terraform also installs the [NVIDIA Kubernetes device plugin](https://github.com/NVIDIA/k8s-device-plugin) as a Helm release in `kube-system` with matching tolerations — no manual setup needed. Without the device plugin, Triton pods stay `Pending` with `Insufficient nvidia.com/gpu`.

The supplied chart requires the NVIDIA container runtime as the GPU node's default runtime for shared mode, including support for `NVIDIA_VISIBLE_DEVICES` on containers without a GPU request. Check the GPU probe and both serving containers become healthy. With `gpu_enabled = false`, Natural Language (POLICY) detectors fail closed; remove those detectors from active policies when running without inference.

Verify after deploy:

```bash
kubectl describe node -l fortiaigate-role=gpu | grep -A10 "Capacity:"
# Expect: nvidia.com/gpu: 1
```

## Ingress options

| Class | Use when | ACM cert? | Route 53? |
|-------|----------|-----------|-----------|
| `nginx` | nginx-ingress-controller already in the cluster | No | Optional |
| `alb` (`internal = true`) | All traffic enters via VPN/Direct Connect/Transit Gateway/FortiGate | For HTTPS | Optional private DNS |
| `alb` (`internal = false`) | Public internet | For HTTPS, same region as `aws_region` | Optional DNS provider |

The AWS Load Balancer Controller is installed automatically when `ingress_class = "alb"` and `aws_load_balancer_controller_enabled = true` (the default). Set `aws_load_balancer_controller_enabled = false` if a controller is already managed elsewhere.

See [internal/external ingress and TLS](ingress-and-tls.md) for ACM listeners, supplied web certificates, internal database trust, DNS, and verification. `internal` controls exposure and rejects conflicting scheme annotations.

All three services share the same listener via path-based routing:

| Caller | Path | Backend |
|--------|------|---------|
| FortiGate → WebUI | `/ui` and `/` | webui (port 3000) |
| Chatbot → API | `/api/` | api (port 8000) |
| Chatbot → LLM gateway | `/ai` | llm-gateway (port 8080) |

See [`examples/`](../examples) for full annotation blocks for each scenario.

## Advanced: extra values files

For configuration not exposed as Terraform variables, pass additional Helm values files:

```hcl
extra_values_files = ["/path/to/my-overlay.yaml"]
```

Files merge left-to-right before the built-in `set {}` blocks, so Terraform variables take precedence over values files.

## Troubleshooting

**`Unauthorized` on first apply** — Confirm the intended AWS identity, EKS access permissions, and `kubectl get nodes` access. For a new cluster, complete the [initial EKS bootstrap](#two-step-bootstrap-first-deploy) before applying Helm/Kubernetes resources. This is independent of application licensing.

**Node groups stuck in `Creating` for 20+ minutes** — Check the node group health and its Auto Scaling group activity history. Repeated `InsufficientInstanceCapacity` errors indicate AWS cannot currently supply the requested instance type in the selected Availability Zones; the group retries until capacity becomes available. If instances launch but cannot register, inspect NAT gateways and private subnet routes. If the VPC is partial, re-run the VPC bootstrap with the same tfvars before retrying EKS.

**ALB has target groups but no listeners** — The `CreateListener` call failed AWS-side validation. The most frequent cause is an ACM certificate ARN in the wrong region; ACM is regional and doesn't replicate. Check `kubectl describe ingress -n fortiaigate fortiaigate-ingress` for the exact error, then issue a cert in the same region as `aws_region` and update `alb.ingress.kubernetes.io/certificate-arn`.

**Pods stuck in `Pending`** — Check node capacity and EFS mount status:

```bash
kubectl describe pod <pod-name> -n fortiaigate
kubectl get pvc -n fortiaigate
kubectl get pods -n kube-system | grep efs
```

**`Insufficient memory` for `triton-vllm-server`** — Vendor chart defaults request 36 GiB of host RAM (12 GiB + 24 GiB), so a 32 GiB `g5.2xlarge` cannot schedule them. Keep `gpu_tuning_profile = "auto"` to use the [G5 defaults](#gpu-support), and inspect explicit overrides or extra values files if requests still exceed node capacity. Review a full plan before applying; changing instance type replaces the GPU node group. Successful scheduling still requires live model-startup verification.

**PostgreSQL `certificate authentication failed`** — PostgreSQL compares the client certificate CN with the database username. Apply the current TLS configuration, which issues a separate internal certificate with CN matching `postgresql.auth.username`, and the updated license-manager template with explicit database certificate paths. Use the same backend and tfvars, review the full plan, then apply. Internal certificate checksums roll database servers and clients; allow those rollouts to finish before verifying API, gateway, and license-manager readiness. Back up existing application data before the rollout. No database or EFS deletion is needed. See [certificate behavior](ingress-and-tls.md#web-and-internal-certificates).

**License manager not starting** — Check its Deployment logs and PostgreSQL connectivity, including client certificate errors above. Licenses are uploaded through the admin API, rather than node-mounted files.
