"""Check exposure, per-backend health, TLS mounts and certificate rollout isolation."""
from pathlib import Path
import subprocess
import yaml

CHART = Path(__file__).resolve().parents[1] / "fortiaigate"

def render(controller, web_checksum="web-v1", scheme="internal"):
    args = ["helm", "template", "fortiaigate", str(CHART)]
    settings = {
        "fortiaigate.image.repository": "example.com/fortiaigate",
        "ingress.className": controller,
        "ingress.host": "fortiaigate.example.com",
        "tls.existingSecret": "web-tls",
        "tls.existingSecretChecksum": web_checksum,
        "tls.internalExistingSecret": "internal-tls",
        "tls.internalExistingSecretChecksum": "internal-v1",
        "postgresql.tls.certificatesSecret": "internal-tls",
        "postgresql.tls.certCAFilename": "ca.crt",
        "redis.tls.existingSecret": "internal-tls",
        "redis.tls.certCAFilename": "ca.crt",
    }
    for k, v in settings.items():
        args += ["--set-string", f"{k}={v}"]
    args += ["--set", r"ingress.annotations.alb\.ingress\.kubernetes\.io/scheme=" + scheme]
    # gpu.enabled must be a boolean, not a string (Go templates treat "false" as true).
    args += ["--set", "fortiaigate.gpu.enabled=false"]
    return list(filter(None, yaml.safe_load_all(subprocess.check_output(args, text=True))))

def pods(docs):
    return {d["metadata"]["name"]: d["spec"]["template"] for d in docs if d["kind"] == "Deployment"}

for controller in ("alb", "nginx"):
    docs = render(controller)
    ingress = next(d for d in docs if d["kind"] == "Ingress" and d["metadata"]["name"] == "fortiaigate-ingress")
    if controller == "alb":
        assert "tls" not in ingress["spec"], "ALB must not discover frontend certificates from backend TLS hosts"
        for scheme in ("internal", "internet-facing"):
            other = next(d for d in render(controller, scheme=scheme) if d["kind"] == "Ingress")
            assert other["metadata"]["annotations"]["alb.ingress.kubernetes.io/scheme"] == scheme
        for d in docs:
            if d["kind"] == "Service" and d["metadata"]["name"] in ("api", "llm-gateway", "webui"):
                expected = {"api": "/openapi.json", "llm-gateway": "/fortiaigate/health/readiness", "webui": "/ui"}
                assert d["metadata"]["annotations"]["alb.ingress.kubernetes.io/healthcheck-path"] == expected[d["metadata"]["name"]]
    else:
        assert ingress["spec"]["tls"][0]["secretName"] == "web-tls"
        assert ingress["metadata"]["annotations"]["nginx.ingress.kubernetes.io/backend-protocol"] == "HTTPS"
    workloads = pods(docs)
    rotated = pods(render(controller, web_checksum="web-v2"))
    services = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Service"}
    if controller == "alb":
        for name, protocol in (("auth-oauth", "HTTP"), ("auth-scim", "HTTPS")):
            annotations = services[name]["metadata"]["annotations"]
            assert annotations["alb.ingress.kubernetes.io/backend-protocol"] == protocol
            assert annotations["alb.ingress.kubernetes.io/healthcheck-protocol"] == "HTTP"
            assert annotations["alb.ingress.kubernetes.io/healthcheck-port"] == "9002"
            assert annotations["alb.ingress.kubernetes.io/healthcheck-path"] == "/healthz"
    else:
        for name in ("fortiaigate-auth-oauth", "fortiaigate-auth-scim"):
            auth_ingress = next(d for d in docs if d["kind"] == "Ingress" and d["metadata"]["name"] == name)
            assert auth_ingress["spec"]["tls"][0]["secretName"] == "web-tls"
    web_workloads = {"api", "llm-gateway", "webui", "mcp-gateway", "plugin-adapter"}
    for name, template in workloads.items():
        pod = template["spec"]
        volumes = {v["name"]: v for v in pod.get("volumes", [])}
        web_volume = "tls-certs" if name == "webui" else "external-tls-certs"
        if name in web_workloads:
            assert volumes[web_volume]["secret"]["secretName"] == "web-tls", name
        if name in ("api", "llm-gateway", "logd", "license-manager", "auth"):
            internal_volume = "database-tls" if name == "auth" else "tls-certs"
            assert volumes[internal_volume]["secret"]["secretName"] == "internal-tls"
            env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
            for db in ("REDIS", "POSTGRES"):
                assert env[f"{db}_SSL_CA_CERTS"] == "/etc/internal-tls/ca.crt", name
                assert env[f"{db}_SSL_CERTFILE"] == "/etc/internal-tls/tls.crt", name
                assert env[f"{db}_SSL_KEYFILE"] == "/etc/internal-tls/tls.key", name
            mounts = pod["containers"][0]["volumeMounts"]
            assert any(m["name"] == internal_volume and m["mountPath"] == "/etc/internal-tls" for m in mounts)
        changed = template["metadata"]["annotations"] != rotated[name]["metadata"]["annotations"]
        assert changed == (name in web_workloads), name
    print(f"{controller}: exposure, health checks, TLS mounts and web-only certificate rotation passed")
