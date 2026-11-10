"""Render upgrade-critical configurations. Requires helm and PyYAML."""
from pathlib import Path
import json
import subprocess
import yaml

CHART = Path(__file__).resolve().parents[1] / "fortiaigate"
REPO = "example.com/fortiaigate-v803"
INVENTORY = json.loads((CHART.parent / "docs/build6207-images.json").read_text())
TAGS = {image["image"]: image["tag"] for image in INVENTORY["images"]}

for mode in ("cpu", "shared", "dedicated"):
    args = ["helm", "template", "fortiaigate", str(CHART), "--namespace", "fortiaigate"]
    settings = {
        "fortiaigate.image.repository": REPO,
        "fortiaigate.gpu.enabled": str(mode != "cpu").lower(),
        "fortiaigate.updateStrategy": "Recreate",
        "vllm.gpuAttach": "shared" if mode == "cpu" else mode,
        "fortiaigate.gpuWorkloadPlacement.nodeSelector.fortiaigate-role": "gpu",
        "fortiaigate.gpuWorkloadPlacement.tolerations[0].key": "fortiaigate-gpu",
        "fortiaigate.gpuWorkloadPlacement.tolerations[0].operator": "Equal",
        "fortiaigate.gpuWorkloadPlacement.tolerations[0].effect": "NoSchedule",
        "ingress.className": "alb",
        "tls.existingSecret": "external-tls",
        "tls.existingSecretChecksum": "rotation-checksum",
        "tls.internalExistingSecret": "internal-tls",
        "tls.internalExistingSecretChecksum": "internal-rotation-checksum",
        "postgresql.tls.certificatesSecret": "internal-tls",
        "redis.tls.existingSecret": "internal-tls",
        "storage.storageClass": "efs-sc",
    }
    if mode == "shared":
        settings.update({
            "fabric.enabled": "true",
            "inferenceHooks.enabled": "true",
            "inferenceHooks.card.signingSecret": "whsec_render-test",
        })
        args += ["--set-string", "inferenceHooks.card.endpointId=abcdef0123456789abcdef0123456789",
                 "--set", "inferenceHooks.ingress.sourceRanges[0]=192.0.2.0/24"]
    for key, value in settings.items():
        args += ["--set", f"{key}={value}"]
    args += ["--set-string", "fortiaigate.gpuWorkloadPlacement.tolerations[0].value=true",
             "--set", r"ingress.annotations.alb\.ingress\.kubernetes\.io/scheme=internal"]
    docs = list(filter(None, yaml.safe_load_all(subprocess.check_output(args, text=True))))
    workloads = {d["metadata"]["name"]: d for d in docs if d["kind"] in ("Deployment", "StatefulSet", "DaemonSet")}
    assert not {"core", "language-scanner", "code-scanner"} & workloads.keys()
    assert workloads["license-manager"]["kind"] == "Deployment"
    images = set()
    for name, workload in workloads.items():
        pod = workload["spec"]["template"]["spec"]
        affinity = pod.get("affinity", {}).get("nodeAffinity", {})
        assert "requiredDuringSchedulingIgnoredDuringExecution" not in affinity, name
        for volume in pod.get("volumes", []):
            if volume["name"] == "tls-certs":
                expected_secret = "external-tls" if name == "webui" else "internal-tls"
                assert volume["secret"]["secretName"] == expected_secret, name
        for c in pod.get("containers", []) + pod.get("initContainers", []):
            if c["image"].startswith(REPO):
                images.add(c["image"])
    excluded = set()
    if mode == "cpu":
        excluded.update(("custom-triton", "vllm-server", "faig-models"))
    if mode != "shared":
        excluded.update(("fabric", "inference-hooks"))
    expected = {f"{REPO}/{name}:{tag}" for name, tag in TAGS.items() if name not in excluded}
    assert images == expected, (mode, images ^ expected)
    gpu_names = {"triton-vllm-server"} if mode == "shared" else {"triton-server", "vllm-server"} if mode == "dedicated" else set()
    assert {n for n in workloads if n.startswith(("triton", "vllm"))} == gpu_names
    for name in gpu_names:
        pod = workloads[name]["spec"]["template"]["spec"]
        assert pod["nodeSelector"] == {"fortiaigate-role": "gpu"}
        assert pod["tolerations"][0]["value"] == "true"
        assert workloads[name]["spec"]["strategy"]["type"] == "Recreate"
        # Shared serving containers consume one card in total.
        gpu_count = sum(c.get("resources", {}).get("limits", {}).get("nvidia.com/gpu", 0) for c in pod["containers"])
        assert gpu_count == 1, (name, gpu_count)
    ingress = next(d for d in docs if d["kind"] == "Ingress")
    annotations = ingress["metadata"]["annotations"]
    assert annotations["alb.ingress.kubernetes.io/scheme"] == "internal"
    assert annotations["alb.ingress.kubernetes.io/target-type"] == "ip"
    assert annotations["alb.ingress.kubernetes.io/backend-protocol"] == "HTTPS"
    routes = {p["path"]: p["backend"]["service"]["name"] for p in ingress["spec"]["rules"][0]["http"]["paths"]}
    expected_routes = {
        "/api/v1/plugins/claude-code": "plugin-adapter-mcp",
        "/oauth": "auth-oauth",
        "/.well-known/oauth-authorization-server/oauth": "auth-oauth",
        "/.well-known/openid-configuration/oauth": "auth-oauth",
        "/api/auth/sso/oidc/callback": "auth-oauth",
        "/scim/v2": "auth-scim",
        "/api/v1/scim": "auth-scim",
        "/api/": "api",
        "/ui": "webui",
        "/ai": "llm-gateway",
        "/plugin": "plugin-adapter",
        "/mcp/gateways": "mcp-gateway",
        "/.well-known/oauth-protected-resource/mcp/gateways": "mcp-gateway",
        "/": "webui",
    }
    if mode == "shared":
        expected_routes["/inference-hooks"] = "inference-hooks"
        conditions = json.loads(annotations["alb.ingress.kubernetes.io/conditions.inference-hooks"])
        assert conditions == [{"field": "source-ip", "sourceIpConfig": {"values": ["192.0.2.0/24"]}}]
    assert routes == expected_routes, (mode, routes)
    assert list(routes).index("/api/auth/sso/oidc/callback") < list(routes).index("/api/")
    assert sum(d["kind"] == "Ingress" for d in docs) == 1
    assert not any(d["kind"] == "Secret" and d["metadata"]["name"] in {"external-tls", "internal-tls"} for d in docs)
    assert any(d["kind"] == "Job" and d["metadata"]["name"].startswith("fortiaigate-auth-identity-") for d in docs)
    assert not any(d["kind"] == "Job" and d["metadata"]["name"] == "fortiaigate-schema-preflight" for d in docs)
    for name in ("fortiaigate-postgresql", "fortiaigate-redis-master"):
        volumes = workloads[name]["spec"]["template"]["spec"]["volumes"]
        assert any(v.get("persistentVolumeClaim", {}).get("claimName") == "fortiaigate-storage" for v in volumes)
    claim = next(d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"] == "fortiaigate-storage")
    assert claim["spec"]["storageClassName"] == "efs-sc"

    # Offline upgrade renders need dummy passwords because Helm lookup has no cluster.
    args += ["--is-upgrade", "--set",
             "global.redis.password=render-only,postgresql.auth.password=render-only,postgresql.auth.postgresPassword=render-only"]
    upgrade = list(filter(None, yaml.safe_load_all(subprocess.check_output(args, text=True))))
    job = next(d for d in upgrade if d["kind"] == "Job" and d["metadata"]["name"] == "fortiaigate-schema-preflight")
    assert job["metadata"]["annotations"]["helm.sh/hook"] == "pre-upgrade"
    pod = job["spec"]["template"]["spec"]
    preflight = pod["containers"][0]
    assert preflight["image"] == f"{REPO}/api:{INVENTORY['release']}"
    assert {"name": "POSTGRES_SSL_CA_CERTS", "value": "/etc/internal-tls/ca.crt"} in preflight["env"]
    assert {"name": "postgres-tls", "mountPath": "/etc/internal-tls", "readOnly": True} in preflight["volumeMounts"]
    assert pod["volumes"][0]["secret"]["secretName"] == "internal-tls"
    print(f"{mode}: image, storage, GPU, ALB, Auth and schema preflight renders passed")
