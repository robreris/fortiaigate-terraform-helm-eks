"""Render actual Terraform GPU values through Helm without AWS, state, or providers."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="fortiaigate-gpu-render-") as directory:
    target = Path(directory)
    for name in ("variables.tf", "gpu.tf"):
        shutil.copy2(ROOT / name, target / name)
    subprocess.run(["terraform", "init", "-backend=false", "-no-color"],
                   cwd=target, check=True, capture_output=True)
    overlay = target / "advanced.yaml"
    overlay.write_text("vllm:\n  maxNumSeqs: 48\n")
    cases = {
        "g5": {"gpu_enabled": True, "gpu_node_instance_type": "g5.2xlarge"},
        "g6e": {"gpu_enabled": True, "gpu_node_instance_type": "g6e.2xlarge"},
        "cpu": {"gpu_enabled": False, "gpu_node_instance_type": "g5.2xlarge"},
        "custom": {
            "gpu_enabled": True,
            "gpu_node_instance_type": "g5.2xlarge",
            "extra_values_files": [str(overlay)],
            "gpu_tuning": {"vllm_max_num_seqs": 16, "triton_memory_limit": "26Gi"},
        },
    }
    for name, variables in cases.items():
        var_file = target / "case.tfvars.json"
        var_file.write_text(json.dumps({"image_repository": "example.com/fortiaigate", **variables}))
        result = subprocess.check_output(
            ["terraform", "console", "-var-file=" + str(var_file)],
            cwd=target, input="jsonencode(local.gpu_helm_values)\n", text=True)
        values = json.loads(json.loads(result))
        args = ["helm", "template", "fortiaigate", str(ROOT / "fortiaigate"),
                "--set", "fortiaigate.image.repository=example.com/fortiaigate",
                "--set", "fortiaigate.gpu.enabled=" + str(variables["gpu_enabled"]).lower(),
                "--set", "fortiaigate.updateStrategy=Recreate",
                "--set", "vllm.gpuAttach=shared"]
        for index, value in enumerate(values):
            path = target / f"values-{index}.yaml"
            path.write_text(value)
            args += ["-f", str(path)]
        docs = [d for d in yaml.safe_load_all(subprocess.check_output(args, text=True)) if d]
        pods = [d for d in docs if d["kind"] == "Deployment" and
                d["metadata"]["name"] == "triton-vllm-server"]
        if name == "cpu":
            assert not pods and not values
        else:
            deployment = pods[0]
            containers = {c["name"]: c for c in deployment["spec"]["template"]["spec"]["containers"]}
            triton, vllm = containers["triton"], containers["vllm"]
            requested = sum(int(c["resources"]["requests"]["memory"].removesuffix("Gi"))
                            for c in containers.values())
            assert requested == (36 if name == "g6e" else 20), (name, requested)
            assert deployment["spec"]["strategy"]["type"] == "Recreate"
            assert sum(c["resources"]["limits"].get("nvidia.com/gpu", 0)
                       for c in containers.values()) == 1
            assert "--max-model-len=16384" in vllm["args"]
            if name in ("g5", "custom"):
                assert triton["resources"]["limits"]["memory"] == ("26Gi" if name == "custom" else "25Gi")
                assert vllm["resources"]["limits"]["memory"] == "24Gi"
                assert "--api-server-count=1" in vllm["args"]
                assert f"--max-num-seqs={16 if name == 'custom' else 64}" in vllm["args"]
        print(f"{name}: Terraform values rendered through Helm successfully")
