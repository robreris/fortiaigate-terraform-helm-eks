{{/*
Expand the name of the chart.
*/}}
{{- define "fortiaigate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "fortiaigate.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "fortiaigate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "fortiaigate.labels" -}}
helm.sh/chart: {{ include "fortiaigate.chart" . }}
{{ include "fortiaigate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "fortiaigate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fortiaigate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "fortiaigate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fortiaigate.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper namespace
*/}}
{{- define "fortiaigate.namespace" -}}
{{- .Release.Namespace }}
{{- end }}

{{/*
Name of the Secret holding the master key that seals credential secrets at
rest (go-common/secret). Every writer and resolver of credential values —
api, llm-gateway, guardrail — MUST resolve to the SAME name, which is why this
is the one place the fallback chain is written:

  api.masterKeyExistingSecret -> chart-generated default

The chart-generated default is templates/master-key-secret.yaml, rendered
only when the override is not set. Do not inline this fallback elsewhere —
a second copy is how two services end up on different keys.
*/}}
{{- define "fortiaigate.masterKeySecretName" -}}
{{- .Values.api.masterKeyExistingSecret | default (printf "%s-master-key" (include "fortiaigate.fullname" .)) -}}
{{- end }}

{{/*
The internal TLS certificate (templates/tls-secrets.yaml) in this render, as
JSON: "renew" (the chart generates it now), "revision" (the release revision
that generated it), "notAfter" (when it expires, RFC 3339 UTC), "days" (the
validity it is generated with) and "names" (its DNS names,
fortiaigate.internalTlsNames). Decided by fortiaigate.internalTlsDecide from
the Secret as it is in the cluster.

It reads only .Release, so the PostgreSQL and Redis sub-charts can call it too
(through fortiaigate.internalTlsRevision, in their podAnnotations in
values.yaml). That is also why the validity and the renewal margin are
constants in fortiaigate.internalTlsDecide and not values: in a sub-chart,
.Values is the sub-chart's own. For the same reason it cannot renew on a chart
version change: in a sub-chart, .Chart is the sub-chart's too.
*/}}
{{- define "fortiaigate.internalTls" -}}
{{- include "fortiaigate.internalTlsDecide" (dict "secret" (lookup "v1" "Secret" .Release.Namespace "fortiaigate-tls-secret") "revision" .Release.Revision "names" (include "fortiaigate.internalTlsNames" .)) -}}
{{- end }}

{{/*
Whether the deployment's own pods talk mutual TLS, "true" or empty:
tls.mutual, which needs tls.enabled. The guardrail pool (guardrail,
dlp-scanner, policy-guard), the licence manager, Triton's gRPC port and vLLM
then require the client's certificate (FAIG_INTERNAL_TLS_CLIENT_AUTH, Triton's
--grpc-use-ssl-mutual, vLLM's --ssl-cert-reqs), and every pod that dials one
presents the internal pair, whose key usage allows client authentication
(FAIG_INTERNAL_TLS_CERT_FILE/KEY_FILE, FAIG_GUARDRAIL_TLS_CERT_FILE/KEY_FILE).
PostgreSQL and Redis have their own switches, postgresql.tls.certCAFilename
and redis.tls.authClients, and their clients always present the pair.
*/}}
{{- define "fortiaigate.internalMtls" -}}
{{- if and .Values.tls.enabled .Values.tls.mutual -}}true{{- end -}}
{{- end }}

{{/*
The DNS names the internal certificate carries (beside IP 127.0.0.1), comma
separated: every Service a pod dials over TLS with it and checks by name, and
localhost. A listener the ingress routes to (mcp-gateway's :8443,
plugin-adapter's) serves the external certificate instead, so it is not
named here. A name added here regenerates the certificate on the next upgrade
(fortiaigate.internalTlsDecide), because a client that checks a name the
certificate lacks refuses every connection.

The list must not depend on any value of this chart: the PostgreSQL and Redis
sub-charts make the same decision in their own context (their podAnnotations,
checksum/internal-tls), where .Values is theirs. A name that depended on, say,
an enabled switch would make them keep the certificate this chart renews: they
would not restart, and would serve the old certificate to clients that trust
only the new one.
*/}}
{{- define "fortiaigate.internalTlsNames" -}}
{{- join "," (list "localhost" "guardrail" "dlp-scanner" "policy-guard" "license-manager" "triton-server" "vllm-server" "action-guard" "observability" (printf "%s-postgresql" .Release.Name) (printf "%s-redis-master" .Release.Name)) -}}
{{- end }}

{{/*
The URL its callers (plugin-adapter, mcp-gateway) take for a
companion service in the deployment, from "root", "name" and "port": with
tls.enabled https, where the service serves the internal certificate, which
names it, and under tls.mutual serves only the pods that present the internal
pair; http otherwise.
*/}}
{{- define "fortiaigate.companionURL" -}}
{{- ternary "https" "http" .root.Values.tls.enabled }}://{{ .name }}:{{ .port }}
{{- end }}

{{/*
REDIS_URL of action-guard and observability, in the redis-py form they read:
database "db" of the shared Redis, from "root" and "db". With
redis.tls.enabled, Redis is verified against the internal certificate, which
names <release>-redis-master, and the internal pair is the client
certificate, which redis.tls.authClients requires. The kubelet expands
$(REDIS_PASSWORD) from the variable declared before it.
*/}}
{{- define "fortiaigate.companionRedisURL" -}}
{{- $root := .root -}}
{{- $at := printf "%s-redis-master:%v/%v" $root.Release.Name $root.Values.redis.master.service.port .db -}}
{{- if $root.Values.redis.tls.enabled -}}
{{- $m := include "fortiaigate.internalTlsMountPath" $root -}}
rediss://:$(REDIS_PASSWORD)@{{ $at }}?ssl_cert_reqs=required&ssl_ca_certs={{ include "fortiaigate.internalTlsCAFile" $root }}&ssl_certfile={{ $m }}/tls.crt&ssl_keyfile={{ $m }}/tls.key
{{- else -}}
redis://:$(REDIS_PASSWORD)@{{ $at }}
{{- end -}}
{{- end }}

{{/*
fortiaigate.internalTls's decision, from "secret" (the Secret, or an empty map
when there is none), "revision" (.Release.Revision) and "names"
(fortiaigate.internalTlsNames). The chart generates the certificate, valid 10
years:
  - when there is no Secret, or it has no internal-tls-revision annotation: the
    first install, or the first upgrade from 8.0.2, which kept the external
    certificate under this name;
  - when its internal-tls-names annotation is not "names": a name was added.
    The first 8.0.3 charts wrote no such annotation, and their certificate
    lacks triton-server and vllm-server, so it is regenerated once;
  - when it expires in fewer than 5 years. Customers upgrade more often than
    that, so the certificate is renewed before it expires and nobody has to
    delete the Secret by hand.
A not-after annotation that does not parse reads as already expired: renewed.
Every pod that uses the certificate restarts when it is renewed, PostgreSQL,
Redis, Triton and vLLM included (fortiaigate.internalTlsRevision). That
interrupts traffic for about a minute (75 s of failed LLM requests measured on
a lab box, 2026-10-25, before the engines served TLS): old and new pods cannot
verify each other until all have restarted, and llm-gateway reads PostgreSQL
on every request. The engines take longer, minutes of model load, and DLP and
POLICY detectors fail closed until they are back. Accepted, once in 5+ years;
the measurement and what a fix would take are docs/known-issues.md #102.
*/}}
{{- define "fortiaigate.internalTlsDecide" -}}
{{- $days := 3650 -}}
{{- $renewWithin := "+43800h" -}}
{{- $layout := "2006-01-02T15:04:05Z07:00" -}}
{{- $ann := dig "metadata" "annotations" dict .secret -}}
{{- $revision := get $ann "fortiaigate.io/internal-tls-revision" -}}
{{- $notAfter := get $ann "fortiaigate.io/internal-tls-not-after" -}}
{{- /* A Secret from 3a88459d8, which wrote no expiry, has no names either:
  the names rule renews it, so its missing expiry needs no default. */ -}}
{{- $renew := or (not $revision) (ne (get $ann "fortiaigate.io/internal-tls-names") .names) (lt (int64 (unixEpoch (toDate $layout $notAfter))) (int64 (unixEpoch (now | dateModify $renewWithin)))) -}}
{{- if $renew -}}
{{- $revision = toString .revision -}}
{{- $notAfter = dateInZone $layout (now | dateModify (printf "+%dh" (mul 24 $days))) "UTC" -}}
{{- end -}}
{{- toJson (dict "renew" $renew "revision" $revision "notAfter" $notAfter "days" $days "names" .names) -}}
{{- end }}

{{/*
The release revision that generated the internal TLS certificate. Each pod
that uses the certificate carries its sha256sum as checksum/internal-tls, so
the pod restarts when the certificate is generated or renewed, and at no other
time.
*/}}
{{- define "fortiaigate.internalTlsRevision" -}}
{{- (include "fortiaigate.internalTls" . | fromJson).revision -}}
{{- end }}

{{/*
The EXTERNAL certificate (tls.cert / tls.key) in this render, as JSON: "crt"
and "key" (base64, as fortiaigate-external-tls-secret holds them) and "kept"
(the Secret they were kept from, or empty when they come from the chart's
files). Decided by fortiaigate.externalTlsDecide from the two files and the
Secrets as they are in the cluster. Call it only with tls.enabled: nothing
serves the certificate otherwise.
*/}}
{{- define "fortiaigate.externalTls" -}}
{{- $certPath := .Values.tls.cert | default "" -}}
{{- $keyPath := .Values.tls.key | default "" -}}
{{- include "fortiaigate.externalTlsDecide" (dict "crt" (tpl (.Files.Get $certPath) .) "key" (tpl (.Files.Get $keyPath) .) "certPath" $certPath "keyPath" $keyPath "external" (lookup "v1" "Secret" .Release.Namespace "fortiaigate-external-tls-secret") "legacy" (lookup "v1" "Secret" .Release.Namespace "fortiaigate-tls-secret")) -}}
{{- end }}

{{/*
fortiaigate.externalTls's decision, from "crt" and "key" (the contents of the
files tls.cert and tls.key name, through tpl; .Files.Get answers "" for a file
the chart does not have), "certPath" and "keyPath" (the two values, for the
messages), "external" (fortiaigate-external-tls-secret as it is in the
cluster) and "legacy" (fortiaigate-tls-secret as it is), each an empty map
when there is none:
  - both files in the chart: the pair is theirs;
  - neither: nothing is being replaced, so the release keeps the pair it
    serves, from fortiaigate-external-tls-secret, or, on the first upgrade
    from 8.0.2, from fortiaigate-tls-secret without its internal-tls-revision
    annotation, where 8.0.2 kept it (fortiaigate.internalTlsDecide);
  - neither and nothing to keep (a first install, or `helm template` and
    --dry-run=client, where lookup finds nothing), or only one of the two:
    the render fails and names the path.
Until Mantis 1369114 the chart rendered a missing file as a null tls.crt and
tls.key, which an upgrade applied over the certificate the release served.
*/}}
{{- define "fortiaigate.externalTlsDecide" -}}
{{- $hasCrt := ne (trim .crt) "" -}}
{{- $hasKey := ne (trim .key) "" -}}
{{- if and $hasCrt $hasKey -}}
{{- toJson (dict "crt" (b64enc .crt) "key" (b64enc .key) "kept" "") -}}
{{- else if or $hasCrt $hasKey -}}
{{- $missing := ternary (list "tls.key" .keyPath "key") (list "tls.cert" .certPath "certificate") $hasCrt -}}
{{- $there := ternary (list "tls.cert" .certPath) (list "tls.key" .keyPath) $hasCrt -}}
{{- fail (printf "%s (%s) is not in the chart, or is empty, while %s (%s) is: copy the %s that goes with it into the chart at %s. With neither file in the chart, an upgrade keeps the certificate the release already serves." (index $missing 0) (index $missing 1) (index $there 0) (index $there 1) (index $missing 2) (index $missing 1)) -}}
{{- else -}}
{{- $from := "" -}}
{{- $data := dict -}}
{{- if and (dig "data" "tls.crt" "" .external) (dig "data" "tls.key" "" .external) -}}
{{- $from = "fortiaigate-external-tls-secret" -}}
{{- $data = .external.data -}}
{{- else if and (not (hasKey (dig "metadata" "annotations" dict .legacy) "fortiaigate.io/internal-tls-revision")) (dig "data" "tls.crt" "" .legacy) (dig "data" "tls.key" "" .legacy) -}}
{{- $from = "fortiaigate-tls-secret" -}}
{{- $data = .legacy.data -}}
{{- end -}}
{{- if not $from -}}
{{- fail (printf "tls.cert (%s) and tls.key (%s) are not in the chart, and there is no external certificate in the cluster to keep (Secret fortiaigate-external-tls-secret): copy the certificate and its key into the chart at those paths. helm template and helm upgrade --dry-run=client cannot read that Secret; check an upgrade with --dry-run=server." .certPath .keyPath) -}}
{{- end -}}
{{- toJson (dict "crt" (get $data "tls.crt") "key" (get $data "tls.key") "kept" $from) -}}
{{- end -}}
{{- end }}

{{/*
Checksum of each pod that serves the external certificate (Auth, webui, api,
llm-gateway, plugin-adapter, mcp-gateway): the sha256sum of the certificate
and key it serves (fortiaigate.externalTls), so the pod restarts when they
change, and not when an upgrade keeps them. It is the sum the chart has always
taken of the two files. Without tls.enabled nothing serves it: the sum of
nothing.
*/}}
{{- define "fortiaigate.externalTlsChecksum" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecretChecksum -}}
{{- else if .Values.tls.enabled -}}
{{- $external := include "fortiaigate.externalTls" . | fromJson -}}
{{- printf "%s%s" (b64dec $external.crt) (b64dec $external.key) | sha256sum -}}
{{- else -}}
{{- "" | sha256sum -}}
{{- end -}}
{{- end }}

{{/*
How the pre-upgrade schema preflight (templates/schema-preflight.yaml)
verifies PostgreSQL, from "secret" (fortiaigate-tls-secret as it is in the
cluster, or an empty map when there is none) and "live" (true when the render
reads a cluster: the release's PostgreSQL password Secret was found):
"verify-full", "verify-ca" or "missing".

The hook runs before Helm changes anything, so it dials the PostgreSQL that is
running, which serves the certificate in the Secret as it is NOW, not the one
this render may generate (fortiaigate.internalTlsDecide):
  - "verify-full", the chain and the name, as api does: a Secret with the
    internal-tls-revision annotation holds the internal certificate, which
    names <release>-postgresql in every 8.0.3 chart. Also under `helm
    template`, where lookup finds nothing.
  - "verify-ca", the chain only: a Secret without that annotation is the one
    8.0.2 kept under this name, the external certificate (tls.cert), which
    names no Service. 8.0.2's default, files/certificate/dflt.crt, has no
    subjectAltName at all, so verify-full refused every upgrade from 8.0.2
    ("x509: certificate is not valid for any names", Mantis 1365714).
    PostgreSQL's certificate must still chain to the Secret's tls.crt: what
    8.0.2's own clients check (pgx reads their sslmode=require with a root
    certificate as verify-ca). Only the first upgrade from 8.0.2 sees it: that
    upgrade replaces the certificate and restarts PostgreSQL with the new one.
  - "missing": the cluster has the release but not the Secret, so nothing can
    verify the PostgreSQL that is running. The Secret was deleted, or
    PostgreSQL ran without TLS until this upgrade. The hook refuses to render
    rather than wait for a volume that never mounts.
*/}}
{{- define "fortiaigate.schemaPreflightTls" -}}
{{- if not .secret -}}
{{- ternary "missing" "verify-full" .live -}}
{{- else if get (dig "metadata" "annotations" dict .secret) "fortiaigate.io/internal-tls-revision" -}}
verify-full
{{- else -}}
verify-ca
{{- end -}}
{{- end }}

{{/*
The Secret (key "internal-token") holding FAIG_INTERNAL_TOKEN, the service
secret mcp-gateway, plugin-adapter and the companions (FAIG_MCP_ADMISSION_KEY)
read: an operator's, or the one internal-token-secret.yaml generates.
*/}}
{{- define "fortiaigate.internalTokenSecretName" -}}
{{- .Values.fortiaigate.internalTokenExistingSecret | default (printf "%s-internal-token" (include "fortiaigate.fullname" .)) -}}
{{- end }}

{{/*
The model name clients call on the vLLM policyGuard server, independent of the
weights directory the pod serves from.

HARDCODED, deliberately not a value: it is an INTERNAL contract between two
templates -- vllm-server.yaml passes it as --served-model-name, and
guardrail.yaml passes the same string to policy-guard as
POLICYGUARD_VLLM_MODEL. A customer who repointed it would break every POLICY
scan (the scanner asks for a model vLLM does not serve, and every scan fails
closed to a 503). Defined ONCE here rather than written literally in both
templates so the two cannot drift apart.
*/}}
{{- define "fortiaigate.policyGuardModelName" -}}
policyguard
{{- end }}

{{/*
Whether the policyGuard vLLM server actually runs in this deployment.

There is deliberately NO vllm.enabled flag. Two things decide it:

  fortiaigate.gpu.enabled   does this deployment have GPUs at all? ("Set to
                            false to run on non-GPU nodes.") A HARD gate — it
                            wins even when vllm.replicas is 1.
  vllm.replicas             the operator's own switch: 0 forces vLLM off on a
                            GPU deployment, 1+ runs it.

Why gpu.enabled has to override rather than merely advise: vLLM has NO CPU
fallback. The image is the upstream CUDA build, whose compiled kernels
(vllm._C / _C_AVX512 / _C_AVX2) are GPU-only, so on a GPU-less node it dies
during ARGUMENT PARSING with "Failed to infer device type" and then
CrashLoopBackOffs forever — no chart value can rescue it. (Triton survives the
same node only because its config.pbtxt is KIND_AUTO and onnxruntime has a CPU
execution provider. vLLM has no equivalent.) Letting a GPU-less deployment ask
for vLLM would guarantee that crash loop, so the flag that says "no GPUs here"
is authoritative.

Both vllm-server.yaml (does the workload exist?) and guardrail.yaml (does
policy-guard address it, or run the clean-returning stub?) resolve through this
one helper, so the workload and the scanner pointed at it cannot disagree.

A missing value reads as OFF: `int` of nil is 0, so a values file that somehow
drops vllm.replicas renders no vLLM rather than silently starting a multi-GB
GPU pod.
*/}}
{{- define "fortiaigate.vllmEnabled" -}}
{{- if and ((.Values.fortiaigate.gpu).enabled) (gt (int ((.Values.vllm).replicas)) 0) -}}
true
{{- end -}}
{{- end }}

{{/*
GPU placement plan for the policyGuard vLLM server, as JSON, so that
triton-server.yaml, vllm-server.yaml, guardrail.yaml and NOTES.txt read the
SAME decision:

  mode         shared | dedicated — vllm.gpuAttach with "auto" resolved.
               shared = vLLM shares Triton's GPU (implemented as co-location:
               a second container in the Triton pod); dedicated = vLLM gets
               GPUs of its own (the standalone vllm-server Deployment)
  requested    vllm.gpuAttach as written (NOTES.txt says "resolved by auto")
  known        the node inventory was readable. True on install/upgrade;
               false when rendered offline (`helm template`, client dry-run)
  total        GPUs allocatable on schedulable nodes, by vLLM's resource name
  nodes        nodes carrying that resource
  tritonCards  cards triton-server takes from the same pool (replicas x gpuCount)
  vllmCards    cards vLLM would need on its own (replicas x gpuCount)
  spare        total - tritonCards
  timeSliced   a node advertises GPU time-slicing (feature-discovery labels)

auto picks dedicated when the spare cards cover vLLM's need and shared
otherwise — so one card is shared (vLLM rides in the Triton pod, then named
triton-vllm-server, on Triton's card), a second card is taken. Offline it
cannot know and picks shared, the single-GPU shape; the next install or
upgrade resolves it for
real. auto never widens the GPU footprint: gpuCount says how many cards vLLM
may take, auto only decides whether it gets them or shares Triton's.
*/}}
{{- define "fortiaigate.vllmGpuPlan" -}}
{{- $vllm := .Values.vllm | default dict -}}
{{- $triton := .Values.triton | default dict -}}
{{- $requested := $vllm.gpuAttach | default "auto" -}}
{{- if not (has $requested (list "auto" "shared" "dedicated")) -}}
{{- fail (printf "vllm.gpuAttach must be \"auto\", \"shared\" (vLLM shares Triton's GPU, inside the Triton pod) or \"dedicated\" (vLLM gets GPUs of its own), got %q. The earlier spellings colocated and shared-runtime are now \"shared\"; device-plugin is \"dedicated\"" $requested) -}}
{{- end -}}
{{- $res := dig "resources" "limits" "gpuResourceName" "nvidia.com/gpu" $vllm -}}
{{- $tritonRes := dig "resources" "limits" "gpuResourceName" "nvidia.com/gpu" $triton -}}
{{- $vllmCards := mul (int ($vllm.replicas | default 0)) (int (dig "resources" "limits" "gpuCount" 1 $vllm)) -}}
{{- $tritonCards := 0 -}}
{{- if eq $tritonRes $res -}}
{{- $tritonCards = mul (int ($triton.replicas | default 0)) (int (dig "resources" "limits" "gpuCount" 1 $triton)) -}}
{{- end -}}
{{- $known := false -}}
{{- $total := 0 -}}
{{- $nodes := 0 -}}
{{- $timeSliced := false -}}
{{- $list := lookup "v1" "Node" "" "" -}}
{{- if $list -}}
{{- range $list.items -}}
{{- $known = true -}}
{{- if not ((.spec | default dict).unschedulable) -}}
{{- $alloc := (.status | default dict).allocatable | default dict -}}
{{- $n := int (index $alloc $res | default 0) -}}
{{- if gt $n 0 -}}
{{- $total = add $total $n -}}
{{- $nodes = add1 $nodes -}}
{{- end -}}
{{- $labels := (.metadata | default dict).labels | default dict -}}
{{- if or (gt (int (index $labels "nvidia.com/gpu.replicas" | default 0)) 1) (eq (index $labels "nvidia.com/gpu.sharing-strategy" | default "") "time-slicing") -}}
{{- $timeSliced = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $spare := sub $total $tritonCards -}}
{{- $mode := $requested -}}
{{- if eq $requested "auto" -}}
{{- if and $known (gt $vllmCards 0) (ge $spare $vllmCards) -}}
{{- $mode = "dedicated" -}}
{{- else -}}
{{- $mode = "shared" -}}
{{- end -}}
{{- end -}}
{{- dict "mode" $mode "requested" $requested "known" $known "total" $total "nodes" $nodes "tritonCards" $tritonCards "vllmCards" $vllmCards "spare" $spare "timeSliced" $timeSliced "resource" $res | toJson -}}
{{- end }}

{{/*
The --gpu-memory-utilization vLLM is started with. An explicit
vllm.gpuMemoryUtilization wins, then the fortiaigate.gpu.type profile's
(files/gpu-profiles.yaml; none of the shipped profiles sets one); empty in
both lets the mode decide: 0.85 on a card of its own (dedicated, not
time-sliced), 0.80 when the card is shared with Triton (shared). NOTES.txt
prints the resolved figure.
*/}}
{{- define "fortiaigate.vllmGpuMemoryUtilization" -}}
{{- $set := include "fortiaigate.gpuParam" (dict "root" . "section" "vllm" "key" "gpuMemoryUtilization" "explicit" (.Values.vllm).gpuMemoryUtilization "what" "vllm.gpuMemoryUtilization") -}}
{{- if $set -}}
{{- $set -}}
{{- else -}}
{{- $plan := include "fortiaigate.vllmGpuPlan" . | fromJson -}}
{{- if and (eq $plan.mode "dedicated") (not $plan.timeSliced) -}}
0.85
{{- else -}}
0.80
{{- end -}}
{{- end -}}
{{- end }}


{{/*
Failure-policy env pins (fortiaigate.failurePolicy.*, #91). Emitted into BOTH
the llm-gateway and the api containers: the gateway applies the policy on every
request, api's manual Check Health sends failThreshold attempts and its
runtime-defaults surface reports the pinned values — so the two pods must read
the SAME env, and one helper is how they cannot drift.

A knob is rendered ONLY when it is set. Empty string, a whitespace-only string
and null all mean "not pinned: the org's Runtime Defaults document governs". A
literal 0 (a legal retryTimes = one attempt) MUST render, which rules out
`with`/`if` on the value (both treat 0 as false). Trimmed, because a
`retryTimes: " "` would otherwise render a FAIG_FAILURE_POLICY_* variable the
process then reads as blank — an operator sees the pin in the pod env while the
org document governs, which is the silent fallback #91 rules out. `default
dict` covers a values file that sets failurePolicy itself to null (Helm then
deletes the key).

A set knob is VALIDATED HERE, at render time, by the same rule
go-common/failpolicy.FromEnv applies at startup (strconv.ParseInt base 10,
32-bit; retryTimes >= 0, failThreshold and cooldownMinutes >= 1). The pod
refuses a bad pin anyway, but only after the upgrade has rolled BOTH
deployments into a crashloop; `helm upgrade` refusing it keeps the running
pods. See fortiaigate.failurePolicyPin for the per-type rules and why the value
is re-printed rather than passed through.

Two more refusals ride along, both for the same reason — a pin the operator
believes in that the pods never see:
  - a key under fortiaigate.failurePolicy that is not one of the three knobs
    (a misspelt `failTreshold` would otherwise pin nothing, silently);
  - api.runtimeDefaults.{failThreshold,cooldownMinutes}, the Helm keys a
    reverted upstream mechanism shipped on br_8-0-2_dev for about a day
    (FAIG_BREAKER_* on the api pod, BELOW the stored org document). Nothing
    reads them now, and the replacement has the OPPOSITE precedence, so the
    move is refused loudly rather than dropped. Unset, "" and an empty map
    render fine, so a --reuse-values upgrade from that chart passes unless the
    operator actually set one.

Usage, inside a container's env list:
  {{- with (include "fortiaigate.failurePolicyEnv" . | trim) }}
  {{- . | nindent 8 }}
  {{- end }}
*/}}
{{- define "fortiaigate.failurePolicyEnv" -}}
{{- $rd := (.Values.api).runtimeDefaults -}}
{{- $flipped := "The precedence flipped with the move: an api.runtimeDefaults value was only a default that any field of an org's stored Runtime Defaults document beat, while a fortiaigate.failurePolicy pin OVERRIDES every org's stored document deployment-wide (and a PATCH of that field answers 422). Then remove api.runtimeDefaults" -}}
{{- if kindIs "map" $rd -}}
{{- range $key := list "failThreshold" "cooldownMinutes" -}}
{{- $old := index $rd $key -}}
{{- if and (not (kindIs "invalid" $old)) (ne (toString $old | trim) "") -}}
{{- fail (printf "api.runtimeDefaults.%s=%v is retired (#91): set fortiaigate.failurePolicy.%s instead. %s" $key $old $key $flipped) -}}
{{- end -}}
{{- end -}}
{{- else if and (not (kindIs "invalid" $rd)) (ne (toString $rd | trim) "") -}}
{{- fail (printf "api.runtimeDefaults is retired (#91): set fortiaigate.failurePolicy.{failThreshold,cooldownMinutes} instead. %s" $flipped) -}}
{{- end -}}
{{- $knobs := list (list "retryTimes" "FAIG_FAILURE_POLICY_RETRY_TIMES" 0) (list "failThreshold" "FAIG_FAILURE_POLICY_FAIL_THRESHOLD" 1) (list "cooldownMinutes" "FAIG_FAILURE_POLICY_COOLDOWN_MINUTES" 1) -}}
{{- $fp := (.Values.fortiaigate).failurePolicy | default dict -}}
{{- if not (kindIs "map" $fp) -}}
{{- fail (printf "fortiaigate.failurePolicy must be a map of retryTimes, failThreshold and cooldownMinutes, got %#v" $fp) -}}
{{- end -}}
{{- range $key := keys $fp | sortAlpha -}}
{{- if not (has $key (list "retryTimes" "failThreshold" "cooldownMinutes")) -}}
{{- fail (printf "fortiaigate.failurePolicy.%s is not a failure-policy knob; the knobs are retryTimes, failThreshold and cooldownMinutes (a misspelt key would pin nothing)" $key) -}}
{{- end -}}
{{- end -}}
{{- range $knob := $knobs }}
{{- $n := include "fortiaigate.failurePolicyPin" (dict "key" (printf "fortiaigate.failurePolicy.%s" (index $knob 0)) "value" (index $fp (index $knob 0)) "min" (index $knob 2)) }}
{{- if ne $n "" }}
- name: {{ index $knob 1 }}
  value: {{ $n | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
One failure-policy pin, validated and re-printed as plain decimal digits — or
"" when it is not pinned. Args: key (the values path, for the message), value,
min. Fails the render on anything go-common/failpolicy.FromEnv would refuse, so
a pin that renders is a pin both pods accept.

Re-printed, never passed through with toString, because of what Helm hands a
template. A number in a values FILE arrives as float64 (the YAML is decoded as
JSON), and toString prints a float64 of a million or more in exponent form:
`failThreshold: 1000000` would render "1e+06", which ParseInt refuses, and both
pods would crashloop on a value the operator wrote correctly. So, per type:
  - nil (unset, `null`): not pinned;
  - string (--set-string, a quoted YAML value): trimmed; blank = not pinned;
    otherwise it must be what ParseInt(s, 10, 32) accepts — an optional sign
    and decimal digits. Leading zeros are stripped before the conversion
    because sprig's int64 parses in base 0, where "010" is octal 8 and
    ParseInt reads 10; more than 10 significant digits is out of range before
    int64 could overflow;
  - float64 (a values-file number): must be integral — 1.5 is refused, and so
    is anything outside int32 before the int64 conversion, whose result for an
    out-of-range float Go leaves to the platform. An integral float is
    indistinguishable from the integer after Helm's decode, so `3.0` in a file
    renders "3";
  - int / int64 (--set, which parses integers itself): used as is;
  - anything else — a bool (`--set ...=true`), a map, a list — is refused.
Then the range: min (0 for retryTimes, 1 for the other two) to 2147483647.
*/}}
{{- define "fortiaigate.failurePolicyPin" -}}
{{- $v := .value -}}
{{- $n := 0 -}}
{{- $set := false -}}
{{- $why := printf "%s must be a whole number from %d to 2147483647, or empty to leave it unpinned; got %#v" .key .min $v -}}
{{- if kindIs "invalid" $v -}}
{{- else if kindIs "string" $v -}}
{{- $s := trim $v -}}
{{- if ne $s "" -}}
{{- if not (regexMatch "^[+-]?[0-9]+$" $s) -}}
{{- fail $why -}}
{{- end -}}
{{- $digits := regexReplaceAll "^[+-]?0*" $s "" | default "0" -}}
{{- if gt (len $digits) 10 -}}
{{- fail $why -}}
{{- end -}}
{{- $n = int64 $digits -}}
{{- if hasPrefix "-" $s -}}
{{- $n = sub 0 $n -}}
{{- end -}}
{{- $set = true -}}
{{- end -}}
{{- else if or (kindIs "float64" $v) (kindIs "float32" $v) -}}
{{- $f := float64 $v -}}
{{- if ne (floor $f) $f -}}
{{- fail $why -}}
{{- end -}}
{{- if or (lt $f -2147483648.0) (gt $f 2147483647.0) -}}
{{- fail (printf "%s must be a whole number from %d to 2147483647, or empty to leave it unpinned; got %.0f" .key .min $f) -}}
{{- end -}}
{{- $n = int64 $f -}}
{{- $set = true -}}
{{- else if has (kindOf $v) (list "int" "int8" "int16" "int32" "int64" "uint" "uint8" "uint16" "uint32" "uint64") -}}
{{- $n = int64 $v -}}
{{- $set = true -}}
{{- else -}}
{{- fail $why -}}
{{- end -}}
{{- if $set -}}
{{- if or (lt $n (int64 .min)) (gt $n 2147483647) -}}
{{- fail $why -}}
{{- end -}}
{{- printf "%d" $n -}}
{{- end -}}
{{- end }}

{{/*
PER-CARD TUNING PROFILES — files/gpu-profiles.yaml, selected by
fortiaigate.gpu.type. The file's header has the model; in short: a profile
per card the product was tuned on, every profile inheriting `default`, and
for each knob the precedence  value set in values.yaml > selected profile >
default. The values.yaml knobs the profiles govern ship EMPTY so the chart
can tell "not set" from "set to the old default" (Helm merges values.yaml
into the user's file before any template runs, so a non-empty default would
be indistinguishable from a customer's choice).

The knobs, by section, and whether `default` may leave one empty. This map
is the schema: the file's loader refuses a profile key that is not here
(a misspelt key would otherwise tune nothing, silently), and `default` must
set every key that may not be empty. A new knob is added HERE, in the file,
at its one render site (through fortiaigate.gpuParam / gpuParamInt), in
NOTES.txt and in k8s/tests/test_gpu_profiles_render.py — CLAUDE.md's
"New GPU-sized knob" bullet.
*/}}
{{- define "fortiaigate.gpuProfileKeys" -}}
{{- dict "triton" (dict "dlpInstancesPerGpu" false "dlpMaxBatchSize" false "cpuLimit" false) "vllm" (dict "maxModelLen" false "maxNumSeqs" false "apiServerCount" false "blockSize" true "gpuMemoryUtilization" true "cpuLimit" false "cpuRequest" false) "guardrail" (dict "dlpQueueChars" false "policyQueueChars" false) | toJson -}}
{{- end }}

{{/*
The table, parsed and checked, as JSON. Fails the render with the file and
the profile named when the file is missing, does not parse, has no
`default`, a profile is not a map, a section or key is not in
fortiaigate.gpuProfileKeys, or `default` leaves a required knob unset.
*/}}
{{- define "fortiaigate.gpuProfiles" -}}
{{- $file := "files/gpu-profiles.yaml" -}}
{{- $raw := .Files.Get $file -}}
{{- if not $raw -}}
{{- fail (printf "%s is missing from the chart" $file) -}}
{{- end -}}
{{- $t := fromYaml $raw -}}
{{- if hasKey $t "Error" -}}
{{- fail (printf "%s does not parse: %s" $file (index $t "Error")) -}}
{{- end -}}
{{- $schema := include "fortiaigate.gpuProfileKeys" . | fromJson -}}
{{- if not (kindIs "map" (index $t "default")) -}}
{{- fail (printf "%s has no `default` profile (a map); every other profile inherits it" $file) -}}
{{- end -}}
{{- range $name, $p := $t -}}
{{- if not (kindIs "map" $p) -}}
{{- fail (printf "%s: profile %q must be a map with a description and triton / vllm / guardrail sections, got %#v" $file $name $p) -}}
{{- end -}}
{{- range $sec, $body := $p -}}
{{- if eq $sec "description" -}}
{{- else if eq $sec "devOnly" -}}
{{- if not (kindIs "bool" $body) -}}
{{- fail (printf "%s: profile %q: devOnly must be true or false, got %#v" $file $name $body) -}}
{{- end -}}
{{- else if not (hasKey $schema $sec) -}}
{{- fail (printf "%s: profile %q has an unknown section %q; the sections are description, devOnly, triton, vllm and guardrail" $file $name $sec) -}}
{{- else if not (kindIs "map" $body) -}}
{{- fail (printf "%s: profile %q: %s must be a map of knobs, got %#v" $file $name $sec $body) -}}
{{- else -}}
{{- range $k, $v := $body -}}
{{- if not (hasKey (index $schema $sec) $k) -}}
{{- fail (printf "%s: profile %q: %s.%s is not a knob the chart reads (a misspelt key would tune nothing); %s takes %s" $file $name $sec $k $sec (keys (index $schema $sec) | sortAlpha | join ", ")) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $sec, $ks := $schema -}}
{{- range $k, $mayBeEmpty := $ks -}}
{{- $v := include "fortiaigate.gpuScalar" (dict "v" (index $t "default" $sec $k) "what" (printf "%s default %s.%s" $file $sec $k)) -}}
{{- if and (eq $v "") (not $mayBeEmpty) -}}
{{- fail (printf "%s: the default profile must set %s.%s; every other profile inherits it" $file $sec $k) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $t | toJson -}}
{{- end }}

{{/*
The profile in use, as JSON:
  name       the profile the knobs come from: fortiaigate.gpu.type when the
             table has it, else "default"
  requested  fortiaigate.gpu.type as written, trimmed ("" when unset)
  fallback   true when requested is set but not in the table (NOTES.txt warns)
  known      the profile names NOTES.txt may list, sorted: every profile
             except those marked devOnly (the development environment's
             cards, selectable but not advertised)
  params     default with the selected profile merged over it
*/}}
{{- define "fortiaigate.gpuProfile" -}}
{{- $t := include "fortiaigate.gpuProfiles" . | fromJson -}}
{{- $gpu := ((.Values.fortiaigate).gpu) | default dict -}}
{{- $req := "" -}}
{{- if kindIs "map" $gpu -}}
{{- $rawType := index $gpu "type" -}}
{{- if not (kindIs "invalid" $rawType) -}}
{{- $req = toString $rawType | trim -}}
{{- end -}}
{{- end -}}
{{- $name := "default" -}}
{{- $fallback := false -}}
{{- if eq $req "" -}}
{{- else if hasKey $t $req -}}
{{- $name = $req -}}
{{- else -}}
{{- $fallback = true -}}
{{- end -}}
{{- $params := deepCopy (index $t "default") -}}
{{- if ne $name "default" -}}
{{- $params = mergeOverwrite $params (index $t $name) -}}
{{- end -}}
{{- $known := list -}}
{{- range $n, $p := $t -}}
{{- if not (index $p "devOnly") -}}
{{- $known = append $known $n -}}
{{- end -}}
{{- end -}}
{{- dict "name" $name "requested" $req "fallback" $fallback "known" (sortAlpha $known) "params" $params | toJson -}}
{{- end }}

{{/*
One knob's value as a plain string, "" when unset. Args: v, what (for the
message). nil and a blank string are unset. A number is re-printed: an
integral float — which is what a YAML number is after Helm's decode — in
plain decimal, never exponent form (a float64 of a million prints as 1e+06
through toString, and both the dispatcher's and Triton's parsers refuse
that). A boolean is refused: no knob here is one, and `--set x=true` would
otherwise render the word.
*/}}
{{- define "fortiaigate.gpuScalar" -}}
{{- $v := .v -}}
{{- if kindIs "invalid" $v -}}
{{- else if kindIs "string" $v -}}
{{- trim $v -}}
{{- else if or (kindIs "float64" $v) (kindIs "float32" $v) -}}
{{- $f := float64 $v -}}
{{- if eq (floor $f) $f -}}
{{- printf "%d" (int64 $f) -}}
{{- else -}}
{{- printf "%v" $f -}}
{{- end -}}
{{- else if kindIs "bool" $v -}}
{{- fail (printf "%s cannot be a boolean, got %v" (.what | default "a GPU-tuning knob") $v) -}}
{{- else -}}
{{- toString $v -}}
{{- end -}}
{{- end }}

{{/*
A knob, resolved: the explicit values.yaml value when it is set, else the
selected profile's (which already has default under it). "" only when both
are empty, which the schema allows for blockSize and gpuMemoryUtilization
alone. Args: root, section, key, explicit (the values.yaml value: nil, "",
or set), what (the values.yaml path, for messages).
*/}}
{{- define "fortiaigate.gpuParam" -}}
{{- $e := include "fortiaigate.gpuScalar" (dict "v" .explicit "what" .what) -}}
{{- if ne $e "" -}}
{{- $e -}}
{{- else -}}
{{- $gp := include "fortiaigate.gpuProfile" .root | fromJson -}}
{{- include "fortiaigate.gpuScalar" (dict "v" (index $gp.params .section .key) "what" (printf "files/gpu-profiles.yaml %s %s.%s" $gp.name .section .key)) -}}
{{- end -}}
{{- end }}

{{/*
Where fortiaigate.gpuParam's answer came from, for NOTES.txt. Same args.
*/}}
{{- define "fortiaigate.gpuParamSource" -}}
{{- $e := include "fortiaigate.gpuScalar" (dict "v" .explicit "what" .what) -}}
{{- if ne $e "" -}}
{{- printf "set in values.yaml" -}}
{{- else -}}
{{- $gp := include "fortiaigate.gpuProfile" .root | fromJson -}}
{{- printf "profile %s" $gp.name -}}
{{- end -}}
{{- end }}

{{/*
fortiaigate.gpuParam for a knob that must be a whole number: the digits,
normalised (leading zeros dropped), or "" when unset everywhere. Fails the
render naming the values.yaml path and the source when the value is not
digits, is below min, or is too long for a 64-bit parser (the dispatcher's
Atoi would refuse it and silently fall back to its built-in default). Args:
those of gpuParam plus min.
*/}}
{{- define "fortiaigate.gpuParamInt" -}}
{{- $s := include "fortiaigate.gpuParam" . -}}
{{- if ne $s "" -}}
{{- $src := include "fortiaigate.gpuParamSource" . -}}
{{- if not (regexMatch "^[0-9]+$" $s) -}}
{{- fail (printf "%s must be a whole number of %d or more, or empty to take the fortiaigate.gpu.type profile's value; got %q (%s)" .what (int .min) $s $src) -}}
{{- end -}}
{{- $s = regexReplaceAll "^0+" $s "" | default "0" -}}
{{- if gt (len $s) 18 -}}
{{- fail (printf "%s is too large: %s (%s)" .what $s $src) -}}
{{- end -}}
{{- if lt (int64 $s) (int64 .min) -}}
{{- fail (printf "%s must be %d or more, got %s (%s)" .what (int .min) $s $src) -}}
{{- end -}}
{{- end -}}
{{- $s -}}
{{- end }}

{{/*
One line of NOTES.txt: label, the resolved value, its source. Args: root,
label, section, key, explicit.
*/}}
{{- define "fortiaigate.gpuParamLine" -}}
{{- $args := merge (dict "what" .label) . -}}
{{- $v := include "fortiaigate.gpuParam" $args -}}
{{- printf "%-32s %-16s (%s)" .label (ternary $v "<engine default>" (ne $v "")) (include "fortiaigate.gpuParamSource" $args) -}}
{{- end }}

{{/*
"true" when vllm.extraArgs already carries --flag, bare or as --flag=value.
The chart then renders no copy of its own for that flag: the operator's
spelling wins over vllm.<knob> and the profile alike, and an upgrade with a
values file from before the knobs existed (extraArgs carrying
--max-num-seqs=512 and --api-server-count=2) renders exactly the arguments
it did. NOTES.txt says which flags extraArgs overrode. Args: root, flag.
*/}}
{{- define "fortiaigate.vllmExtraArgHas" -}}
{{- $hit := false -}}
{{- range ((.root.Values.vllm).extraArgs | default list) -}}
{{- $a := toString . | trim -}}
{{- if or (eq $a $.flag) (hasPrefix (printf "%s=" $.flag) $a) -}}
{{- $hit = true -}}
{{- end -}}
{{- end -}}
{{- if $hit -}}true{{- end -}}
{{- end }}

{{/*
"true" when vLLM reports, per request, the prompt tokens it took from its
prefix cache (--enable-prompt-tokens-details): policy-guard takes the rules
and the template out and the scan's usage report gives the rest as the POLICY
kv_cache_hit_tokens (2026-11-18). vllm.promptTokensDetails false — the boolean
or the string "false" (--set-string, a quoted value) — turns it off; a values
file that has no such key (one copied before it existed) keeps it on. In
vllm.extraArgs the LAST of --enable-prompt-tokens-details and
--no-enable-prompt-tokens-details decides, as it does for vLLM (the chart
renders its own flag before the extraArgs, and only when they carry none).
Both the vLLM arguments and policy-guard's
POLICYGUARD_VLLM_PROMPT_TOKENS_DETAILS read this one answer, so they cannot
disagree. Args: the root context.
*/}}
{{- define "fortiaigate.vllmPromptTokensDetails" -}}
{{- $v := (.Values.vllm | default dict) -}}
{{- $arg := "" -}}
{{- range ($v.extraArgs | default list) -}}
{{- $a := toString . | trim -}}
{{- if or (eq $a "--enable-prompt-tokens-details") (hasPrefix "--enable-prompt-tokens-details=" $a) -}}
{{- $arg = "on" -}}
{{- else if eq $a "--no-enable-prompt-tokens-details" -}}
{{- $arg = "off" -}}
{{- end -}}
{{- end -}}
{{- if eq $arg "on" -}}
true
{{- else if and (ne $arg "off") (ne (toString $v.promptTokensDetails) "false") -}}
true
{{- end -}}
{{- end }}

{{/* Shared storage must resolve identically inside the PostgreSQL/Redis
subchart contexts. Their .Chart.Name is not the parent chart's name. For a
custom parent fullnameOverride, set global.fortiaigateStorageClaim too. */}}
{{- define "fortiaigate.storageClaim" -}}
{{- if .Values.global.fortiaigateStorageClaim -}}
{{- .Values.global.fortiaigateStorageClaim -}}
{{- else if contains "fortiaigate" .Release.Name -}}
{{- printf "%s-storage" (.Release.Name | trunc 63 | trimSuffix "-") -}}
{{- else -}}
{{- printf "%s-storage" (printf "%s-fortiaigate" .Release.Name | trunc 63 | trimSuffix "-") -}}
{{- end -}}
{{- end -}}

{{/*
The unified Ingress and backend Services use ingress.controllerType when set
for a custom class name, then fall back to ingress.className.
*/}}
{{- define "fortiaigate.ingressController" -}}
{{- default .Values.ingress.className .Values.ingress.controllerType -}}
{{- end }}

{{/*
ingress-nginx strict path validation rejects the dot in .well-known for
Prefix/Exact. ImplementationSpecific keeps these metadata URLs literal without
enabling regex or changing the ordinary application paths. Other controllers
retain their existing Prefix behavior.
*/}}
{{- define "fortiaigate.metadataPathType" -}}
{{- if eq (include "fortiaigate.ingressController" .) "nginx" -}}
ImplementationSpecific
{{- else -}}
Prefix
{{- end -}}
{{- end }}

{{/*
Traefik dials an Ingress backend over HTTPS only when the backend's SERVICE
says so; no Ingress annotation can, so ingress.annotations cannot either.
With tls.enabled every backend the platform Ingress routes listens with TLS,
and each of those Services includes this: the scheme, and the
ServersTransport the dial uses (ingress.traefik.serversTransport, else the
one traefik-servers-transport.yaml renders). Empty off Traefik or TLS.
*/}}
{{- define "fortiaigate.traefikBackendAnnotations" -}}
{{- if and .Values.tls.enabled (eq (include "fortiaigate.ingressController" .) "traefik") -}}
traefik.ingress.kubernetes.io/service.serversscheme: https
traefik.ingress.kubernetes.io/service.serverstransport: {{ include "fortiaigate.traefikServersTransport" . | quote }}
{{- end -}}
{{- end }}

{{/*
The ServersTransport reference: the operator's (<namespace>-<name>@kubernetescrd),
or the chart's own. A reference Traefik cannot resolve drops the route at
runtime, so a malformed one is refused here.
*/}}
{{- define "fortiaigate.traefikServersTransport" -}}
{{- with ((.Values.ingress).traefik).serversTransport -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*@[a-z]+$" .) -}}
{{- fail (printf "ingress.traefik.serversTransport=%q: expected <namespace>-<name>@kubernetescrd" .) -}}
{{- end -}}
{{- . -}}
{{- else -}}
{{- printf "%s-fortiaigate-backend-tls@kubernetescrd" .Release.Namespace -}}
{{- end -}}
{{- end }}

{{/* The Terraform-managed web and internal Secrets keep their existing names. */}}
{{- define "fortiaigate.tlsSecretName" -}}
{{- default "fortiaigate-external-tls-secret" .Values.tls.existingSecret -}}
{{- end }}

{{- define "fortiaigate.internalTlsSecretName" -}}
{{- default "fortiaigate-tls-secret" .Values.tls.internalExistingSecret -}}
{{- end }}

{{- define "fortiaigate.internalTlsChecksum" -}}
{{- if .Values.tls.internalExistingSecret -}}
{{- .Values.tls.internalExistingSecretChecksum -}}
{{- else -}}
{{- include "fortiaigate.internalTlsRevision" . | sha256sum -}}
{{- end -}}
{{- end }}

{{- define "fortiaigate.internalTlsMountPath" -}}
{{- if .Values.tls.internalExistingSecret -}}
{{- .Values.tls.internalMountPath -}}
{{- else -}}
{{- .Values.tls.mountPath -}}
{{- end -}}
{{- end }}

{{- define "fortiaigate.internalTlsCAFile" -}}
{{- $name := ternary "ca.crt" "tls.crt" (not (empty .Values.tls.internalExistingSecret)) -}}
{{- printf "%s/%s" (include "fortiaigate.internalTlsMountPath" .) $name -}}
{{- end -}}

{{/*
"true" when the dotted key .path (e.g. "llmGateway.env.upstreamTls.verify") is
present in .values, whatever its value; empty otherwise. NOTES.txt names with
it the keys that moved out of the chart and that a values file still sets. It
never fails the render: a step that is not a map ends the walk.
*/}}
{{- define "fortiaigate.valuesHas" -}}
{{- $cur := .values -}}
{{- $found := true -}}
{{- range $k := splitList "." .path -}}
{{- if not (kindIs "map" $cur) -}}
{{- $found = false -}}
{{- else if not (hasKey $cur $k) -}}
{{- $found = false -}}
{{- $cur = "" -}}
{{- else -}}
{{- $cur = index $cur $k -}}
{{- end -}}
{{- end -}}
{{- if $found }}true{{ end -}}
{{- end }}

{{/* Common public routes use HTTPS. Merge optional annotations by key so a
certificate or subnet setting cannot remove IP targets, TLS or timeouts. */}}
{{- define "fortiaigate.ingressAnnotations" -}}
{{- $class := include "fortiaigate.ingressController" . -}}
{{- $defaults := dict -}}
{{- if eq $class "alb" -}}
{{- $defaults = dict
  "alb.ingress.kubernetes.io/scheme" "internet-facing"
  "alb.ingress.kubernetes.io/target-type" "ip"
  "alb.ingress.kubernetes.io/backend-protocol" "HTTPS"
  "alb.ingress.kubernetes.io/healthcheck-protocol" "HTTPS"
  "alb.ingress.kubernetes.io/listen-ports" "[{\"HTTPS\":443}]"
  "alb.ingress.kubernetes.io/ssl-policy" "ELBSecurityPolicy-TLS13-1-2-2021-06"
  "alb.ingress.kubernetes.io/load-balancer-attributes" "idle_timeout.timeout_seconds=600" -}}
{{- else if eq $class "nginx" -}}
{{- $defaults = dict
  "nginx.ingress.kubernetes.io/app-root" "/ui"
  "nginx.ingress.kubernetes.io/proxy-body-size" "64m"
  "nginx.ingress.kubernetes.io/proxy-read-timeout" "600"
  "nginx.ingress.kubernetes.io/proxy-send-timeout" "600"
  "nginx.ingress.kubernetes.io/proxy-buffering" "off"
  "nginx.ingress.kubernetes.io/backend-protocol" "HTTPS"
  "nginx.ingress.kubernetes.io/ssl-redirect" "true"
  "nginx.ingress.kubernetes.io/force-ssl-redirect" "false" -}}
{{- else if eq $class "traefik" -}}
{{- $defaults = dict "traefik.ingress.kubernetes.io/router.entrypoints" "websecure"
  "traefik.ingress.kubernetes.io/router.middlewares" "default-redirect-https@kubernetescrd" -}}
{{- end -}}
{{- $annotations := mergeOverwrite $defaults (deepCopy (.Values.ingress.annotations | default dict)) -}}
{{- range $key, $value := $annotations }}
{{ $key }}: {{ $value | quote }}
{{- end -}}
{{- end -}}

{{/* Per-Service checks use the target's real HTTPS listener and health path.
The Auth Service's two public ports both implement /healthz. */}}
{{- define "fortiaigate.publicBackendAnnotations" -}}
{{- if eq (include "fortiaigate.ingressController" .root) "alb" }}
alb.ingress.kubernetes.io/healthcheck-protocol: "HTTPS"
alb.ingress.kubernetes.io/healthcheck-port: "traffic-port"
alb.ingress.kubernetes.io/healthcheck-path: {{ .path | quote }}
alb.ingress.kubernetes.io/success-codes: {{ default "200" .successCodes | quote }}
{{- else -}}
{{- include "fortiaigate.traefikBackendAnnotations" .root -}}
{{- end -}}
{{- end -}}

{{/*
A component's free-form `env:` map (guardrail.<component>.env, actionGuard.env,
observability.env, mcpGateway.env, fabric.env), rendered LAST in its
container's env list. A container never carries one name twice (Mantis
1354184): the kubelet would keep the last entry with nothing saying which won,
and `helm upgrade` cannot patch such a list: it fails ("The order in patch
list ... doesn't match $setElementOrder list") or drops the second entry with
no error. So each key of the map is one of:

  - owned: a name the chart sets in this container itself (wiring, a Secret,
    a TLS path, a connection setting). The render FAILS, naming the key and
    what to set instead. The list is every name the chart MAY set there, not
    the ones this render happens to set, so a values file renders or fails
    alike with or without GPUs, TLS or vLLM.
  - skip: a name rendered elsewhere: a tunable the chart renders ONCE, the
    map's value first (SCANNER_CACHE_MAX_BYTES, the dispatcher's two GPU
    queue sizes), or a retired name, which NOTES.txt names.
  - anything else: NAME=value, in key order.
A tunable the chart renders only when the map lacks it (action-guard's
EVENT_BUS_ENABLED, observability's DB_POOL_SIZE) is neither: the map's entry
is then the only one.

Args (dict): env (the map; nil renders nothing), path (its values path, for
the message), owned (list of names), skip (list of names).

Usage, last in a container's env list:
  {{- with (include "fortiaigate.extraEnv" (dict "env" .Values.x.env "path" "x.env" "owned" $owned) | trim) }}
  {{- . | nindent 8 }}
  {{- end }}

k8s/tests/test_env_overrides_render.py sets, in its map, each name every one
of these containers is rendered with, and fails on a second entry or on a
value the map did not win: a name a template starts to set must join its
owned list, or its skip list if it is rendered once from the map.
*/}}
{{- define "fortiaigate.extraEnv" -}}
{{- $owned := .owned | default list -}}
{{- $skip := .skip | default list -}}
{{- $path := .path -}}
{{- range $k, $v := (.env | default dict) }}
{{- if has $k $owned }}
{{- fail (printf "%s.%s: the chart sets %s in this container itself; %s. Remove it from %s." $path $k $k (include "fortiaigate.extraEnvHint" $k) $path) }}
{{- else if not (has $k $skip) }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
What to do instead, for fortiaigate.extraEnv's refusal of an owned name.
*/}}
{{- define "fortiaigate.extraEnvHint" -}}
{{- $by := dict
  "FORTIAIGATE_LOG_LEVEL" "set fortiaigate.env.logLevel instead"
  "LOG_LEVEL" "set fortiaigate.env.logLevel instead"
  "GUARDRAIL_MAX_REQUEST_BYTES" "set guardrail.env.maxRequestBytes instead, which plugin-adapter sizes its body limit from too"
  "GUARDRAIL_SHORT_CIRCUIT_DEFAULT" "set guardrail.env.shortCircuitDefault instead"
  "GUARDRAIL_METERING_METRICS_ENDPOINTS" "add yours under guardrail.externalMetering instead"
  "GUARDRAIL_METERING_ENDPOINTS" "add yours under guardrail.externalMetering instead"
  "GUARDRAIL_METERING_SERVICE_PAIRS" "add yours under guardrail.externalMetering instead"
  "POLICYGUARD_VLLM_URL" "it is the vLLM server the chart deploys (the vllm section)"
  "POLICYGUARD_VLLM_MODEL" "it must be the name the chart's vLLM serves the model under, or every POLICY scan fails closed"
  "POLICYGUARD_VLLM_PROMPT_TOKENS_DETAILS" "it follows the flags the chart starts vLLM with"
  "POLICYGUARD_STUB" "it is set where no vLLM runs (fortiaigate.gpu.enabled false, or vllm.replicas 0)"
  "TRITON_TLS" "it follows tls.enabled"
  "FAIG_MASTER_KEY" "it comes from the chart's Secret"
  "FAIG_INTERNAL_TOKEN" "it comes from the chart's Secret"
  "FAIG_MCP_ADMISSION_KEY" "it comes from the chart's Secret"
  "POSTGRES_PASSWORD" "it comes from the chart's Secret"
  "REDIS_PASSWORD" "it comes from the chart's Secret"
  "FAIG_DATABASE_URL" "it follows the postgresql section"
  "POSTGRES_USER" "it follows the postgresql section"
  "POSTGRES_DB" "it follows the postgresql section"
  "POSTGRES_HOST" "it follows the postgresql section"
  "POSTGRES_PORT" "it follows the postgresql section"
  "REDIS_URL" "it follows the redis section"
  "REDIS_HOST" "it follows the redis section"
  "REDIS_PORT" "it follows the redis section"
  "REDIS_CLUSTER" "it follows the redis section"
  "PV_SIZE" "set storage.size instead"
  "UPSTREAM_ALLOWED_HOSTS" "set mcpGateway.egress.allowedHosts instead"
  "MCP_GATEWAY_ORGANIZATION_ID" "the bundled Auth sets it up"
  "FAIG_SETUP_ORGANIZATION" "the bundled Auth sets it up"
  "FABRIC_MTLS_BIND_SERIAL" "set fabric.bindSerial instead"
  "FABRIC_ORG_ID" "set fabric.orgId instead"
  "GOMEMLIMIT" "set fabric.goMemLimit instead"
  "FAIG_MEMORY_LIMIT_BYTES" "it follows fabric.resources.limits.memory"
  "FABRIC_INSTREAM_WINDOW_CHARS" "set fabric.inStream.windowChars instead"
  "FABRIC_INSTREAM_HOLDBACK_CHARS" "set fabric.inStream.holdbackChars instead"
-}}
{{- if hasKey $by . -}}{{ get $by . }}
{{- else if hasPrefix "REDIS_SSL_" . -}}it follows redis.tls.enabled
{{- else if hasPrefix "POSTGRES_SSL_" . -}}it follows postgresql.tls.enabled
{{- else if or (hasPrefix "FAIG_INTERNAL_TLS_" .) (hasPrefix "FORTIAIGATE_SSL_" .) (hasPrefix "FAIG_GUARDRAIL_TLS" .) -}}it follows tls.enabled and tls.mutual
{{- else if hasPrefix "FAIG_AUTH_" . -}}it names the bundled Auth and its workload certificate
{{- else -}}it is the chart's wiring and cannot be overridden
{{- end -}}
{{- end }}
