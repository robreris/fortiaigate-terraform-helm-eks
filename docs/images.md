# FortiAIGate 8.0.2 container images

For the 8.0.3 chart on this branch, see the [build 6220 ECR guide](images-build6220.md). The instructions below apply to build 0055 on `main`.

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

Set `BUILD_DIR` to the directory containing the individual Fortinet Docker `.tar` files after extracting the release bundle. Use the full version and build from the filename for `BUILD_RELEASE`, with the version immediately after the uppercase `V`. For `FAIG_api-V8.0.3-build6220-FORTINET.tar`, set `BUILD_RELEASE=V8.0.3-build6220`. The snippet reads each matching archive's `manifest.json` to find its Docker tag, including the separately versioned GPU images. Use Bash, GNU tar, jq, Docker, and AWS CLI credentials for the destination account. Allow enough local disk space for the large inference images.

Set `AWS_REGION` and `ACCOUNT_ID` for your destination. Set `ECR_PREFIX` to the path after the registry hostname in Terraform's `image_repository`, such as `fortiaigate-v803` for 8.0.3. The loop stages the matching archives present in `BUILD_DIR`, so include every Fortinet image required by the target chart.

```bash
set -euo pipefail
shopt -s nullglob
: "${AWS_REGION:?Set AWS_REGION to the destination ECR region}"
: "${ACCOUNT_ID:?Set ACCOUNT_ID to the destination AWS account ID}"
: "${BUILD_DIR:?Set BUILD_DIR to the directory containing the individual Docker archives}"
: "${BUILD_RELEASE:?Set BUILD_RELEASE to the full version and build in the filenames, such as V8.0.3-build6220}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PREFIX="${ECR_PREFIX:-fortiaigate}"
SOURCE="dops-jfrog.fortinet-us.com/docker-fortiaigate-local"

archives=("$BUILD_DIR"/FAIG_*"-${BUILD_RELEASE}-FORTINET.tar")
if (( ${#archives[@]} == 0 )); then
  printf 'No Docker archives for %s in %s\n' "$BUILD_RELEASE" "$BUILD_DIR" >&2
  exit 1
fi

declare -A image_tags
for archive in "${archives[@]}"; do
  filename=${archive##*/}
  img=${filename#FAIG_}
  img=${img%"-${BUILD_RELEASE}-FORTINET.tar"}
  if ! image_tag=$(tar --occurrence=1 -xOf "$archive" manifest.json \
    | jq -er --arg prefix "${SOURCE}/${img}:" '
        [.[] | .RepoTags[]? | select(startswith($prefix)) | ltrimstr($prefix)]
        | unique
        | if length == 1 and .[0] != "" then .[0] else error("Expected one tag for " + $prefix) end
      '); then
    printf 'Could not determine the tag for %s from %s\n' "$img" "$archive" >&2
    exit 1
  fi
  image_tags["$img"]=$image_tag
done

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

for img in "${!image_tags[@]}"; do
  image_tag=${image_tags[$img]}
  repository="${ECR_PREFIX}/${img}"
  destination="${REGISTRY}/${repository}:${image_tag}"
  docker load -i "${BUILD_DIR}/FAIG_${img}-${BUILD_RELEASE}-FORTINET.tar"
  if ! aws ecr describe-repositories --region "$AWS_REGION" \
    --repository-names "$repository" >/dev/null 2>&1; then
    aws ecr create-repository --region "$AWS_REGION" \
      --repository-name "$repository"
  fi
  docker tag "${SOURCE}/${img}:${image_tag}" "$destination"
  docker push "$destination"
done
```

Set Terraform's `image_tag` to the application tag from the archives. Confirm the chart's GPU image pins match the tags you pushed. For build 0055, use:

```hcl
image_repository = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"
image_tag        = "V8.0.2-build0055"
```

No images are loaded or pushed by Terraform itself. EKS nodes use the managed node group's ECR read permissions for same-account pulls. For other registries, configure `fortiaigate.image.pullSecrets` through `extra_values_files` and create the referenced Secret in the deployment namespace.

## Database images

The supplied chart also uses `docker.io/bitnamilegacy/postgresql:17.4.0-debian-12-r19`, `docker.io/bitnamilegacy/redis:8.2.0-debian-12-r0`, and `docker.io/bitnamilegacy/os-shell:12-debian-12-r50` (PostgreSQL volume permissions). These are not in the Fortinet archives. To mirror them, override `postgresql.image`, `redis.image`, and `postgresql.volumePermissions.image` in an `extra_values_files` overlay. Set `registry`, `repository`, and `tag` for each image.
