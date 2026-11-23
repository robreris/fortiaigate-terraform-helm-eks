#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_DIR:?Set BUILD_DIR to the Fortinet image archive directory}"
: "${AWS_REGION:?Set AWS_REGION to the destination ECR region}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build=${1:-6220}
if [[ "$build" != 6220 && "$build" != 6207 ]]; then
  printf 'Unsupported FortiAIGate build: %s\n' "$build" >&2
  exit 1
fi
inventory="$script_dir/../docs/build${build}-images.json"
release=$(jq -er '.release' "$inventory")
source=$(jq -er '.source_repository' "$inventory")
images=$(jq -er --arg cpu_only "${CPU_ONLY:-0}" '
  .images[]
  | select($cpu_only != "1" or (.image | IN("custom-triton", "faig-models", "vllm-server") | not))
  | [.image, .tag, (.config_digest // "archive")] | @tsv
' "$inventory")

declare -A config_digests
missing_archive=false
while IFS=$'\t' read -r image _ _; do
  archive="${BUILD_DIR}/FAIG_${image}-${release}-FORTINET.tar"
  if [[ ! -r "$archive" || ! -s "$archive" ]]; then
    printf 'Archive missing, empty, or unreadable: %s\n' "$archive" >&2
    missing_archive=true
  fi
done <<< "$images"
if [[ "$missing_archive" == true ]]; then
  exit 1
fi

while IFS=$'\t' read -r image tag expected_digest; do
  if [[ "$expected_digest" == archive ]]; then
    archive="${BUILD_DIR}/FAIG_${image}-${release}-FORTINET.tar"
    local_image="${source}/${image}:${tag}"
    # Use the exact image's config from the supplied Docker archive when the
    # release inventory could not record its digest.
    config_path=$(tar --occurrence=1 -xOf "$archive" manifest.json \
      | jq -er --arg ref "$local_image" '
          map(select(.RepoTags | index($ref))) | if length == 1 then
            .[0].Config
          else
            error("Expected one manifest entry for " + $ref)
          end')
    config_hash=$(tar --occurrence=1 -xOf "$archive" -- "$config_path" | sha256sum)
    expected_digest="sha256:${config_hash%% *}"
  fi
  config_digests[$image]=$expected_digest
done <<< "$images"

export AWS_PAGER=""
account_id=$(aws sts get-caller-identity --region "$AWS_REGION" \
  --query Account --output text)
registry="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
repository_prefix="fortiaigate-v803"
printf 'Destination: %s/%s\n' "$registry" "$repository_prefix"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry"

ecr_config_digest() {
  aws ecr batch-get-image --region "$AWS_REGION" \
    --repository-name "$1" --image-ids "imageTag=$2" --output json \
    | jq -er '
        if (.images | length) == 1 then
          .images[0].imageManifest | fromjson | .config.digest // error("Missing image config digest")
        elif (.failures | length) == 1 and .failures[0].failureCode == "ImageNotFound" then
          ""
        else
          error("Unexpected ECR response: " + (.failures | tostring))
        end'
}

while IFS=$'\t' read -r image tag _; do
  expected_digest=${config_digests[$image]}
  archive="${BUILD_DIR}/FAIG_${image}-${release}-FORTINET.tar"
  repository="${repository_prefix}/${image}"
  destination="${registry}/${repository}:${tag}"
  if ! result=$(aws ecr describe-repositories --region "$AWS_REGION" \
    --repository-names "$repository" 2>&1); then
    if [[ "$result" != *"(RepositoryNotFoundException)"* ]]; then
      printf '%s\n' "$result" >&2
      exit 1
    fi
    aws ecr create-repository --region "$AWS_REGION" \
      --repository-name "$repository" --query repository.repositoryUri --output text
  fi

  existing_digest=$(ecr_config_digest "$repository" "$tag")
  if [[ "$existing_digest" == "$expected_digest" ]]; then
    printf 'Already verified %s\n' "$destination"
    continue
  fi
  if [[ -n "$existing_digest" ]]; then
    printf 'Tag conflict for %s: expected %s, found %s\n' \
      "$destination" "$expected_digest" "$existing_digest" >&2
    exit 1
  fi

  docker load --input "$archive"
  local_image="${source}/${image}:${tag}"
  loaded_digest=$(docker image inspect --format '{{.Id}}' "$local_image")
  if [[ "$loaded_digest" != "$expected_digest" ]]; then
    printf 'Loaded image mismatch for %s: expected %s, found %s\n' \
      "$local_image" "$expected_digest" "$loaded_digest" >&2
    exit 1
  fi

  docker tag "$local_image" "$destination"
  docker push "$destination"
  pushed_digest=$(ecr_config_digest "$repository" "$tag")
  if [[ "$pushed_digest" != "$expected_digest" ]]; then
    printf 'ECR verification failed for %s: expected %s, found %s\n' \
      "$destination" "$expected_digest" "$pushed_digest" >&2
    exit 1
  fi
  printf 'Verified %s\n' "$destination"
done <<< "$images"
