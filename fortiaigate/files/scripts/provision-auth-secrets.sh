#!/usr/bin/env bash
set -Eeuo pipefail
# KUBECONFIG or kubectl --context selection remains the operator's choice.
namespace=${1:?Usage: provision-auth-secrets.sh NAMESPACE PERSISTENT_PKI_DIRECTORY [PREFIX]}
directory=${2:?Persistent private PKI directory required}
prefix=${3:-faig-auth}
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$here/auth-pki.sh" "$directory"
for pair in 'server:server' 'api:api' 'mcp:mcp' 'llm:llm' 'plugin-mcp:plugin-mcp' 'adapter:adapter'; do
  name=${pair%:*}; folder=${pair#*:}
  # Refuse replacement: existing vault/signing material may protect stored data.
  if kubectl -n "$namespace" get secret "$prefix-$name" >/dev/null 2>&1; then
    for file in "$directory/$folder"/*; do
      [[ -f "$file" ]] || continue
      leaf=${file##*/}
      expected=$(base64 <"$file" | tr -d '\n')
      actual=$(kubectl -n "$namespace" get secret "$prefix-$name" -o "go-template={{ index .data \"$leaf\" }}")
      [[ "$actual" == "$expected" ]] || { echo "Existing Secret $prefix-$name does not match this PKI directory. Restore the matching PKI; no Secret was changed." >&2; exit 1; }
    done
    echo "Preserved matching Secret $prefix-$name"
  else
    kubectl -n "$namespace" create secret generic "$prefix-$name" --from-file="$directory/$folder"
  fi
done
