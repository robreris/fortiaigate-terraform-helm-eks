# Stage FortiAIGate 8.0.3 build 6220 images in ECR

Mirror the vendor Docker archives to ECR before deploying the chart on `v803`. The [image inventory](build6220-images.json) records the chart archive SHA-256, exact image tags, and the config digests verified from the supplied archives.

| Images | Tag |
|--------|-----|
| `action-guard`, `api`, `auth`, `device-adapter`, `fabric`, `guardrail`, `guardrail-scanner`, `license_manager`, `llm-gateway`, `logd`, `mcp-gateway`, `observability`, `plugin-adapter`, `plugin-adapter-mcp`, `webui` | `V8.0.3-build6220` |
| `custom-triton` | `25.11-onnx-trt-agt-rpt-s1` |
| `faig-models` | `0.0.6-s1` |
| `vllm-server` | `0.28.0-1-rpt-s1` |

The supplied build directory is missing the WebUI archive, and the vLLM archive is empty with a partial download alongside it. Obtain the complete Fortinet archives for both images before full staging. The script derives their config digests from the exact image references in the completed archives. Triton matches the 6207 config digest and can be reused at the same destination tag. The separately distributed [Bitnami database images](images.md#database-images) keep their existing tags.

## Load and push

Run from the repository root with Bash, Docker, GNU tar, jq, and AWS CLI credentials with private ECR push and repository creation permissions. Allow disk space for the loaded images. Set `AWS_PROFILE` if you use a named AWS profile. [AWS ECR push permissions](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html)

```bash
BUILD_DIR="/path/to/v803-builds/build6220" AWS_REGION="us-west-2" bash scripts/push-images-to-ecr.sh
```

For a CPU-only deployment, prefix the command with `CPU_ONLY=1` to omit the three inference images. The WebUI archive is required in both modes.

The script prints the destination registry, creates missing repositories under `fortiaigate-v803/<image>`, and checks each ECR tag's config digest. It skips images whose exact tag and digest already match and stops on a tag conflict. Rerun the script to resume after a transfer error or expired ECR login.

Set the printed prefix in your deployment tfvars.

```hcl
image_repository = "123456789012.dkr.ecr.us-west-2.amazonaws.com/fortiaigate-v803"
image_tag        = "V8.0.3-build6220"
```
