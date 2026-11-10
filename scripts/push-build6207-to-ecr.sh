#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_DIR:?Set BUILD_DIR to the build 6207 archive directory}"
: "${AWS_REGION:?Set AWS_REGION to the destination ECR region}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
inventory="$script_dir/../docs/build6207-images.json"
release=$(jq -er '.release' "$inventory")
source=$(jq -er '.source_repository' "$inventory")
images=$(jq -er '.images[] | [.image, .tag, .config_digest] | @tsv' "$inventory")

while IFS=$'\t' read -r image tag expected_digest; do
  archive="${BUILD_DIR}/FAIG_${image}-${release}-FORTINET.tar"
  if [[ ! -r "$archive" ]]; then
    printf 'Archive missing or unreadable: %s\n' "$archive" >&2
    exit 1
  fi
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

while IFS=$'\t' read -r image tag expected_digest; do
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
