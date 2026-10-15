locals {
  # G5 defaults follow the maintained reference chart's shared A10G settings.
  # Other instance families retain the vendor chart defaults unless overridden.
  gpu_profile = var.gpu_tuning_profile == "auto" ? (startswith(var.gpu_node_instance_type, "g5.") ? "g5" : "chart") : var.gpu_tuning_profile
  gpu_profile_values = var.gpu_enabled && local.gpu_profile == "g5" ? [yamlencode({
    triton = {
      dlpInstancesPerGpu = 1
      dlpMaxBatchSize    = 16
      resources = {
        requests = { memory = "12Gi" }
        limits   = { memory = "25Gi" }
      }
    }
    vllm = {
      maxNumSeqs           = 64
      apiServerCount       = 1
      gpuMemoryUtilization = 0.80
      resources = {
        requests = { cpu = "1000m", memory = "8Gi" }
        limits   = { memory = "24Gi" }
      }
    }
  })] : []

  # Omit unset knobs so chart/profile defaults and advanced values files survive.
  gpu_tuning_values = var.gpu_enabled && anytrue([for value in var.gpu_tuning : value != null]) ? [yamlencode({
    triton = merge(
      { for key, value in {
        dlpInstancesPerGpu = var.gpu_tuning.triton_dlp_instances_per_gpu
        dlpMaxBatchSize    = var.gpu_tuning.triton_dlp_max_batch_size
      } : key => value if value != null },
      { resources = {
        requests = { for key, value in { memory = var.gpu_tuning.triton_memory_request } : key => value if value != null }
        limits   = { for key, value in { memory = var.gpu_tuning.triton_memory_limit } : key => value if value != null }
      } }
    )
    vllm = merge(
      { for key, value in {
        maxNumSeqs           = var.gpu_tuning.vllm_max_num_seqs
        apiServerCount       = var.gpu_tuning.vllm_api_server_count
        gpuMemoryUtilization = var.gpu_tuning.vllm_gpu_memory_utilization
        maxModelLen          = var.gpu_tuning.vllm_max_model_len
      } : key => value if value != null },
      { resources = {
        requests = { for key, value in { memory = var.gpu_tuning.vllm_memory_request } : key => value if value != null }
        limits   = { for key, value in { memory = var.gpu_tuning.vllm_memory_limit } : key => value if value != null }
      } }
    )
  })] : []

  gpu_helm_values = concat(
    local.gpu_profile_values,
    [for f in var.extra_values_files : file(f)],
    local.gpu_tuning_values,
  )
}
