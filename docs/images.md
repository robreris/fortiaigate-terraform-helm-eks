# Container images

FortiAIGate 8.0.2 build0055 uses the following images under `var.image_repository`. The tags below were verified against the Docker manifests in the supplied 8.0.2 build0055 archives.

[build0055-images.json](build0055-images.json) records the supplied chart archive SHA-256 and the full image configuration digests from all ten Docker archives. Chart render checks use this inventory for their expected image tags. The local chart retains the vendor image references alongside the EKS scheduling, ingress, and Terraform-managed TLS adaptations; `gpu_tuning_profile` and `gpu_tuning` in tfvars adjust runtime sizing independently.

| Image | Tag | Use |
|-------|-----|-----|
| api | V8.0.2-build0055 | Management API |
| llm-gateway | V8.0.2-build0055 | LLM data plane |
| webui | V8.0.2-build0055 | Console |
| logd | V8.0.2-build0055 | Logs |
| license_manager | V8.0.2-build0055 | Deployment licensing |
| guardrail | V8.0.2-build0055 | Scan dispatcher |
| guardrail-scanner | V8.0.2-build0055 | DLP scanner and policy guard (one shared image) |
| custom-triton | 25.11-onnx-trt-agt-rpt-s1 | GPU inference |
| vllm-server | 0.28.0-rpt-s1 | Natural Language policy inference and GPU probe |
| faig-models | 0.0.5-s1 | Encrypted models for both engines |

The first seven images follow `var.image_tag`, whose default is `V8.0.2-build0055`. The final three tags are pinned in the supplied chart and ignore that variable. Mirror them with their exact tags. GPU inference images are needed when `gpu_enabled = true`.

The three GPU image tags are unchanged from build0054 and match the supplied
build0055 archive manifests. The chart expects these exact vendor tags, without
the content-derived hash suffixes used by the separate daily-update workflow.
When reusing a registry populated by that workflow, also publish the images
under the exact tags above. Changing `image_tag` affects only the seven
application images.

When adding vendor tag aliases to an existing ECR repository, verify the ECR image manifest's `config.digest` against the archive's `config_digest` in the inventory first. This identifies the supplied image even when several registry tags share a version prefix. For build0055, the matching suffixed GPU tags are:

| Image | Matching existing tag |
|-------|-----------------------|
| custom-triton | `25.11-onnx-trt-agt-rpt-s1-f9cfa981387c` |
| vllm-server | `0.28.0-rpt-s1-de3bc45e4715` |
| faig-models | `0.0.5-s1-5cc19cd9478f` |

The suffixes above are configuration digest prefixes, not ECR manifest digests. After verification, add the exact vendor tag from the inventory to the matching ECR manifest. Keep existing suffixed tags; no layer upload or chart tag change is needed. Kubernetes retries image pulls automatically once the required tags are available.

The old `core`, `scanner`, and `triton-models` images are no longer used.

## Load and push to ECR

This loads the ten Fortinet archives locally, creates ECR repositories, and pushes the verified tags. It requires Docker, AWS CLI credentials, and access to the supplied image archives. Set `BUILD_DIR` to the directory containing those archives. The large inference archives require sufficient local disk space.

```bash
set -euo pipefail
AWS_REGION="us-west-2"
ACCOUNT_ID="123456789012"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
: "${BUILD_DIR:?Set BUILD_DIR to the directory containing the supplied build0055 image archives}"
SOURCE="dops-jfrog.fortinet-us.com/docker-fortiaigate-local"
TAG="V8.0.2-build0055"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

for img in api llm-gateway webui logd license_manager guardrail guardrail-scanner custom-triton vllm-server faig-models; do
  docker load -i "${BUILD_DIR}/FAIG_${img}-${TAG}-FORTINET.tar"
  if ! aws ecr describe-repositories --region "$AWS_REGION" \
    --repository-names "fortiaigate/${img}" >/dev/null 2>&1; then
    aws ecr create-repository --region "$AWS_REGION" \
      --repository-name "fortiaigate/${img}"
  fi
  case "$img" in
    custom-triton) image_tag="25.11-onnx-trt-agt-rpt-s1" ;;
    vllm-server) image_tag="0.28.0-rpt-s1" ;;
    faig-models) image_tag="0.0.5-s1" ;;
    *) image_tag="$TAG" ;;
  esac
  docker tag "${SOURCE}/${img}:${image_tag}" "${REGISTRY}/fortiaigate/${img}:${image_tag}"
  docker push "${REGISTRY}/fortiaigate/${img}:${image_tag}"
done
```

Then configure Terraform:

```hcl
image_repository = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"
image_tag        = "V8.0.2-build0055"
```

No images are loaded or pushed by Terraform itself. EKS nodes use the managed node group's ECR read permissions for same-account pulls. For other registries, configure `fortiaigate.image.pullSecrets` through `extra_values_files` and create the referenced Secret in the deployment namespace.

## Database images

The supplied chart also uses `docker.io/bitnamilegacy/postgresql:17.4.0-debian-12-r19`, `docker.io/bitnamilegacy/redis:8.2.0-debian-12-r0`, and `docker.io/bitnamilegacy/os-shell:12-debian-12-r50` (PostgreSQL volume permissions). These are not in the Fortinet archives. To mirror them, override `postgresql.image`, `redis.image`, and `postgresql.volumePermissions.image` in an `extra_values_files` overlay. Set `registry`, `repository`, and `tag` for each image.
