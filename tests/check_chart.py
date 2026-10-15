"""Render upgrade-critical configurations. Requires helm and PyYAML."""
from pathlib import Path
import subprocess
import yaml

CHART = Path(__file__).resolve().parents[1] / "fortiaigate"
REPO = "example.com/fortiaigate"
TAGS = {
    **dict.fromkeys([
        "api", "llm-gateway", "webui", "logd", "license_manager",
        "guardrail", "guardrail-scanner",
    ], "V8.0.2-build0054"),
    "custom-triton": "25.11-onnx-trt-agt-rpt-s1",
    "vllm-server": "0.28.0-rpt-s1",
    "faig-models": "0.0.5-s1",
}

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
        "postgresql.tls.certificatesSecret": "external-tls",
        "redis.tls.existingSecret": "external-tls",
    }
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
                assert volume["secret"]["secretName"] == "external-tls", name
        for c in pod.get("containers", []) + pod.get("initContainers", []):
            if c["image"].startswith(REPO):
                images.add(c["image"])
                if name not in {"triton-server", "triton-vllm-server", "vllm-server"}:
                    assert workload["spec"]["template"]["metadata"]["annotations"]["checksum/tls"] == "rotation-checksum", name
    expected = {f"{REPO}/{name}:{tag}" for name, tag in TAGS.items()
                if mode != "cpu" or name not in ("custom-triton", "vllm-server", "faig-models")}
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
    assert routes == {"/api/": "api", "/ui": "webui", "/ai": "llm-gateway", "/": "webui"}
    assert not any(d["kind"] == "Secret" and d["metadata"]["name"] == "external-tls" for d in docs)
    print(f"{mode}: images, GPU placement/allocation, TLS, licensing, and ingress passed")
