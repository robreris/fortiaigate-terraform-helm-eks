# Stage FortiAIGate 8.0.3 build 6207 images in ECR

Fortinet supplies 18 prebuilt Docker image archives for this release. Load them into Docker, then mirror them to a private ECR registry. The Helm and Docker Compose archives are separate release artifacts.

Use these images with the bundled 8.0.3 chart on `v803`. For 8.0.2 deployments on `main`, use the [build 0055 image instructions](images.md).

## Image inventory

The [build 6207 inventory](build6207-images.json) records the exact tags and Docker image config digests from the supplied archives, plus the vendor Helm archive SHA-256.

| Images | Tag |
|--------|-----|
| `action-guard`, `api`, `auth`, `fabric`, `guardrail`, `guardrail-scanner`, `inference-hooks`, `license_manager`, `llm-gateway`, `logd`, `mcp-gateway`, `observability`, `plugin-adapter`, `plugin-adapter-mcp`, `webui` | `V8.0.3-build6207` |
| `custom-triton` | `25.11-onnx-trt-agt-rpt-s1` |
| `faig-models` | `0.0.5-s1` |
| `vllm-server` | `0.28.0-1-rpt-s1` |

The script mirrors the full release, including images used only by optional features. Triton and the model carrier have the same tags and config digests as build 0055 and can be reused if they are already present under the destination repository prefix. The 8.0.3 vLLM image has a new tag and config digest.

The vendor chart also references the same [Bitnami database images](images.md#database-images) as build 0055. Those images ship separately from the Fortinet archives.

## Load and push

Run from the repository root with Bash, a running Docker daemon, AWS CLI credentials, and `jq`. Use credentials for the destination account with permission to describe and create ECR repositories, read image manifests, and push images. The supplied Docker archives total about 43 GiB. Allow additional space in Docker's storage for loaded layers.

Run the [upload script](../scripts/push-build6207-to-ecr.sh) from the repository root. Set `BUILD_DIR` to the directory containing the build 6207 archives and `AWS_REGION` to the destination ECR region. If you use a named AWS profile, add `AWS_PROFILE=your-ecr-profile` before `bash`.

```bash
BUILD_DIR="/path/to/v803-builds/build6207" AWS_REGION="us-west-2" bash scripts/push-build6207-to-ecr.sh
```

The script prints the destination registry before authenticating, creates missing repositories under `fortiaigate-v803/<image>`, and verifies the config digest for each exact ECR tag. A repeat run skips matching images and stops if a tag points to a different config digest.

For a large upload that outlasts the 12-hour ECR login, rerun the script to refresh the login and resume. See [AWS's private ECR push instructions](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html) for the push permissions.

Use the printed destination for `image_repository` in your deployment tfvars on `v803`.

```hcl
image_repository = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-v803"
image_tag        = "V8.0.3-build6207"
```

The chart pins the three inference image tags separately.
