#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
root=${1:?Usage: auth-pki.sh OUTPUT_DIRECTORY}
mkdir -p "$root"
if [[ -f "$root/.complete" ]]; then
  for file in server/auth.crt server/auth.key server/ca.crt server/vault.key server/oauth-signing.key server/oauth-signing.crt server/oauth-hmac.key api/tls.crt api/tls.key api/ca.crt mcp/tls.crt mcp/tls.key mcp/ca.crt adapter/tls.crt adapter/tls.key; do
    [[ -s "$root/$file" ]] || { echo "Incomplete existing Auth identity: $file. Restore the original; do not rotate keys." >&2; exit 1; }
  done
  # A client identity added after the PKI was made, issued by the kept issuer.
  late_identity() {
    local dir=$1 cn=$2 uri=$3 label=$4
    if [[ ! -d "$root/$dir" ]]; then
      [[ -s "$root/issuer/ca.crt" && -s "$root/issuer/ca.key" ]] || { echo "Restore the original issuer to add the $label workload identity." >&2; exit 1; }
      mkdir -m 700 "$root/$dir"
      openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$cn" -keyout "$root/$dir/tls.key" -out "$root/$dir/request.csr" >/dev/null 2>&1
      printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=URI:%s\n' "$uri" >"$root/$dir/extensions"
      openssl x509 -req -in "$root/$dir/request.csr" -CA "$root/issuer/ca.crt" -CAkey "$root/issuer/ca.key" -CAcreateserial -days 400 -extfile "$root/$dir/extensions" -out "$root/$dir/tls.crt" >/dev/null 2>&1
      cp "$root/issuer/ca.crt" "$root/$dir/ca.crt"
      rm "$root/$dir/request.csr" "$root/$dir/extensions"
      chmod 600 "$root/$dir/"*
      if [[ $(id -u) == 0 ]]; then chown -R 10001:10001 "$root/$dir"; fi
    fi
    for file in "$dir/tls.crt" "$dir/tls.key" "$dir/ca.crt"; do
      [[ -s "$root/$file" ]] || { echo "Incomplete $label identity: $file. Restore the original." >&2; exit 1; }
    done
  }
  late_identity llm llm-gateway spiffe://faig/deployment/llm-gateway LLM
  late_identity plugin-mcp plugin-adapter-mcp spiffe://faig/deployment/plugin-adapter-mcp 'plugin MCP'
  exit 0
fi
[[ -z "$(find "$root" -mindepth 1 ! -type d -print -quit)" ]] || { echo 'Partial Auth identity exists. Restore or inspect it before retry.' >&2; exit 1; }
mkdir -p "$root"/{issuer,server,api,mcp,llm,plugin-mcp,adapter}
openssl req -x509 -newkey rsa:3072 -nodes -days 825 -subj '/CN=FortiAIGate workload CA' -keyout "$root/issuer/ca.key" -out "$root/issuer/ca.crt" >/dev/null 2>&1
leaf() {
  local dir=$1 name=$2 usage=$3 san=$4
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$name" -keyout "$dir/tls.key" -out "$dir/request.csr" >/dev/null 2>&1
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=%s\n' "$usage" "$san" >"$dir/extensions"
  openssl x509 -req -in "$dir/request.csr" -CA "$root/issuer/ca.crt" -CAkey "$root/issuer/ca.key" -CAcreateserial -days 400 -extfile "$dir/extensions" -out "$dir/tls.crt" >/dev/null 2>&1
  cp "$root/issuer/ca.crt" "$dir/ca.crt"
  rm "$dir/request.csr" "$dir/extensions"
}
leaf "$root/server" auth serverAuth 'DNS:auth,DNS:localhost,IP:127.0.0.1'
mv "$root/server/tls.crt" "$root/server/auth.crt"; mv "$root/server/tls.key" "$root/server/auth.key"
leaf "$root/api" api clientAuth 'URI:spiffe://faig/deployment/api'
leaf "$root/mcp" mcp-gateway clientAuth 'URI:spiffe://faig/deployment/mcp-gateway'
leaf "$root/llm" llm-gateway clientAuth 'URI:spiffe://faig/deployment/llm-gateway'
leaf "$root/plugin-mcp" plugin-adapter-mcp clientAuth 'URI:spiffe://faig/deployment/plugin-adapter-mcp'
leaf "$root/adapter" plugin-adapter serverAuth 'DNS:plugin-adapter'
openssl req -x509 -newkey rsa:3072 -nodes -days 400 -subj '/CN=FortiAIGate OAuth signing' -keyout "$root/server/oauth-signing.key" -out "$root/server/oauth-signing.crt" >/dev/null 2>&1
openssl rand -out "$root/server/vault.key" 32
openssl rand -out "$root/server/oauth-hmac.key" 32
# The operator retains the issuer. Mount only each workload's own directory.
find "$root" -type d -exec chmod 700 {} +
find "$root" -type f -exec chmod 600 {} +
touch "$root/.complete"
if [[ $(id -u) == 0 ]]; then
  chown -R 10001:10001 "$root"/{server,api,mcp,llm,plugin-mcp,adapter}
fi
printf 'Auth identity is ready. Preserve this directory in the encrypted recovery backup.\n'
