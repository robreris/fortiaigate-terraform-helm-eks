mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "tls" {}

variables {
  image_repository = "example.com/fortiaigate"
}

run "g5_auto" {
  command = plan
  variables {
    gpu_enabled            = true
    gpu_node_instance_type = "g5.2xlarge"
  }
  assert {
    condition     = local.gpu_profile == "g5" && yamldecode(local.gpu_profile_values[0]).triton.resources.requests.memory == "12Gi" && yamldecode(local.gpu_profile_values[0]).triton.resources.limits.memory == "25Gi" && yamldecode(local.gpu_profile_values[0]).vllm.resources.requests.memory == "8Gi" && length(local.gpu_tuning_values) == 0
    error_message = "G5 must fit its memory requests without capping Triton at the failed 6Gi limit."
  }
}

run "g6e_preserves_chart" {
  command = plan
  variables {
    gpu_enabled            = true
    gpu_node_instance_type = "g6e.2xlarge"
  }
  assert {
    condition     = local.gpu_profile == "chart" && length(local.gpu_helm_values) == 0
    error_message = "Non-G5 auto tuning must preserve chart defaults."
  }
}

run "cpu_has_no_gpu_overrides" {
  command = plan
  variables {
    gpu_enabled            = false
    gpu_node_instance_type = "g5.2xlarge"
    gpu_tuning             = { vllm_max_num_seqs = 16 }
  }
  assert {
    condition     = length(local.gpu_profile_values) == 0 && length(local.gpu_tuning_values) == 0
    error_message = "CPU deployments must omit inference profiles and tuning."
  }
}

run "explicit_tuning_wins" {
  command = plan
  variables {
    gpu_enabled            = true
    gpu_node_instance_type = "g5.2xlarge"
    extra_values_files     = ["tests/gpu-overlay.yaml"]
    gpu_tuning             = { vllm_max_num_seqs = 16, triton_memory_limit = "26Gi" }
  }
  assert {
    condition     = length(local.gpu_helm_values) == 3 && yamldecode(local.gpu_helm_values[1]).vllm.maxNumSeqs == 48 && yamldecode(local.gpu_helm_values[2]).vllm.maxNumSeqs == 16 && yamldecode(local.gpu_helm_values[2]).triton.resources.limits.memory == "26Gi" && !contains(keys(yamldecode(local.gpu_helm_values[2]).vllm), "maxModelLen")
    error_message = "Explicit tfvars fields must follow advanced files and leave unset chart knobs alone."
  }
}

run "disable_profile" {
  command = plan
  variables {
    gpu_enabled            = true
    gpu_node_instance_type = "g5.2xlarge"
    gpu_tuning_profile     = "chart"
  }
  assert {
    condition     = length(local.gpu_profile_values) == 0
    error_message = "The chart profile must disable automatic G5 defaults."
  }
}

run "reject_unknown_profile" {
  command = plan
  variables { gpu_tuning_profile = "unknown" }
  expect_failures = [var.gpu_tuning_profile]
}

run "reject_invalid_memory" {
  command = plan
  variables { gpu_tuning = { triton_memory_limit = "0Gi" } }
  expect_failures = [var.gpu_tuning]
}

run "reject_fractional_count" {
  command = plan
  variables { gpu_tuning = { vllm_max_num_seqs = 1.5 } }
  expect_failures = [var.gpu_tuning]
}

run "reject_gpu_budget" {
  command = plan
  variables { gpu_tuning = { vllm_gpu_memory_utilization = 1 } }
  expect_failures = [var.gpu_tuning]
}

run "reject_request_above_limit" {
  command = plan
  variables { gpu_tuning = { triton_memory_request = "12Gi", triton_memory_limit = "1024Mi" } }
  expect_failures = [var.gpu_tuning]
}
