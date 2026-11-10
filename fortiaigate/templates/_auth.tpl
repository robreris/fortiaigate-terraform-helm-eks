{{/* Default immutable bundle. Existing component Secret overrides use their
ordinary unprefixed keys and remain supported. */}}
{{- define "fortiaigate.authIdentityName" -}}
{{- if gt (len .Release.Name) 49 -}}
{{- printf "%s-%s-auth-identity" (.Release.Name | trunc 38 | trimSuffix "-") (.Release.Name | sha256sum | trunc 8) -}}
{{- else -}}
{{- printf "%s-auth-identity" .Release.Name -}}
{{- end -}}
{{- end -}}

{{- define "fortiaigate.authSecret" -}}
{{- if and (not .root.Values.auth.autoProvision) (not .override) -}}
{{- fail "Auth automatic provisioning is disabled; provide the required existing workload Secret names" -}}
{{- end -}}
{{- default (include "fortiaigate.authIdentityName" .root) .override -}}
{{- end -}}

{{- define "fortiaigate.authSecretItems" -}}
{{- if not .override }}
items:
{{- $prefix := .component }}
{{- $files := list "tls.crt" "tls.key" "ca.crt" }}
{{- if eq $prefix "server" }}
{{- $files = list "auth.crt" "auth.key" "ca.crt" "vault.key" "oauth-signing.crt" "oauth-signing.key" "oauth-hmac.key" }}
{{- end }}
{{- range $file := $files }}
- {key: {{ printf "%s-%s" $prefix $file | quote }}, path: {{ $file | quote }}}
{{- end }}
{{- end }}
{{- end -}}

{{- define "fortiaigate.authIngressRoutes" -}}
{{- dict "oauth" (dict "port" 9002 "protocol" "HTTP" "paths" (list "/oauth" "/.well-known/oauth-authorization-server/oauth" "/.well-known/openid-configuration/oauth" "/api/auth/sso/oidc/callback")) "scim" (dict "port" 9444 "protocol" "HTTPS" "paths" (list "/scim/v2" "/api/v1/scim")) | toJson -}}
{{- end }}
