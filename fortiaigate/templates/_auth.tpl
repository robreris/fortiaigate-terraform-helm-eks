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

{{/* Whether device-adapter (managed devices) runs: deviceAdapter.enabled,
its default, with managed AgentGuard. Development mode
(pluginAdapter.legacyDevAuth) sets no internal token to sign its device
admissions with, so it is left out there. "true" or empty. */}}
{{- define "fortiaigate.deviceAdapterOn" -}}
{{- if and (eq (toString (.Values.deviceAdapter).enabled) "true") (ne (toString (.Values.pluginAdapter).legacyDevAuth) "true") -}}true{{- end -}}
{{- end -}}

{{/* Whether device-adapter gets its own Auth workload identity, with which it
resolves the device users' sign-ins: a Secret named for it
(deviceAdapter.workloadTlsSecretName), or the bundled Auth's identity bundle
when that bundle has it. A bundle made before device-adapter had an identity
(2026-11-02) has no device-tls.crt, and an automatic one is never rewritten:
mounting it would keep the whole plugin-adapter pod from starting, so
device-adapter runs without sign-in there (NOTES.txt says so), as it does
with a manually provided bundle without a device identity. A render with no
cluster (helm template) sees no bundle and takes the new one, which has it.
"true" or empty. */}}
{{- define "fortiaigate.deviceAdapterAuth" -}}
{{- if include "fortiaigate.deviceAdapterOn" . -}}
{{- if (.Values.deviceAdapter).workloadTlsSecretName -}}true
{{- else if .Values.auth.autoProvision -}}
{{- $bundle := (lookup "v1" "Secret" .Release.Namespace (include "fortiaigate.authIdentityName" .)) | default dict -}}
{{- if or (not $bundle) (hasKey ($bundle.data | default dict) "device-tls.crt") -}}true{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
