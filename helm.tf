resource "kubernetes_namespace" "fortiaigate" {
  metadata {
    name = var.namespace
  }

  timeouts {
    delete = "1h"
  }

  depends_on = [module.eks]
}

locals {
  # GPU placement values — only included when gpu_enabled = true.
  # Using yamlencode avoids the set{} block limitation with YAML lists (tolerations).
  gpu_values = var.gpu_enabled ? [yamlencode({
    fortiaigate = {
      gpuWorkloadPlacement = {
        nodeSelector = { fortiaigate-role = "gpu" }
        tolerations = [{
          key      = "fortiaigate-gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
      }
    }
    # This stack has one GPU: co-locate both engines on that card.
    vllm = {
      gpuAttach = "shared"
    }
  })] : []

  # Terraform owns the TLS Secret, so pass both the name and a stable checksum
  # into Helm. Pod template annotations use the checksum to trigger rollouts
  # when Terraform regenerates the certificate.
  tls_secret_name     = kubernetes_secret.tls.metadata[0].name
  tls_secret_checksum = sha256(local.web_certificate)
  tls_values = [yamlencode({
    tls = {
      existingSecret                 = local.tls_secret_name
      existingSecretChecksum         = local.tls_secret_checksum
      internalExistingSecret         = kubernetes_secret.internal_tls.metadata[0].name
      internalExistingSecretChecksum = sha256(local.internal_certificate)
      internalMountPath              = "/etc/internal-tls"
    }
    postgresql = {
      tls = {
        certificatesSecret = kubernetes_secret.internal_tls.metadata[0].name
        certCAFilename     = "ca.crt"
      }
      primary = {
        podAnnotations = {
          "checksum/tls" = sha256(local.internal_certificate)
        }
      }
    }
    redis = {
      tls = {
        existingSecret = kubernetes_secret.internal_tls.metadata[0].name
        certCAFilename = "ca.crt"
      }
      master = {
        podAnnotations = {
          "checksum/tls" = sha256(local.internal_certificate)
        }
      }
    }
  })]
}

resource "helm_release" "nvidia_device_plugin" {
  count = var.gpu_enabled ? 1 : 0

  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = "0.14.5"
  namespace  = "kube-system"

  set {
    name  = "nodeSelector.fortiaigate-role"
    value = "gpu"
  }
  set {
    name  = "tolerations[0].key"
    value = "fortiaigate-gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "true"
    type  = "string"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [module.eks]
}

resource "helm_release" "fortiaigate" {
  name      = "fortiaigate"
  chart     = "${path.module}/fortiaigate"
  namespace = kubernetes_namespace.fortiaigate.metadata[0].name
  timeout   = 1200

  depends_on = [
    kubernetes_storage_class.efs,
    kubernetes_secret.tls,
    kubernetes_secret.internal_tls,
    terraform_data.ingress_configuration,
    helm_release.aws_load_balancer_controller,
    helm_release.nvidia_device_plugin,
  ]

  # Values are merged left-to-right; later entries take precedence.
  # Advanced files override profile defaults; explicit tfvars tuning and
  # mandatory placement/ingress/TLS settings take precedence over those files.
  values = concat(
    local.gpu_helm_values,
    local.gpu_values,
    local.ingress_annotation_values,
    local.tls_values,
  )

  set {
    name  = "fortiaigate.image.repository"
    value = var.image_repository
  }
  set {
    name  = "fortiaigate.image.tag"
    value = var.image_tag
  }
  set {
    name  = "fortiaigate.gpu.enabled"
    value = tostring(var.gpu_enabled)
  }
  set {
    name  = "fortiaigate.updateStrategy"
    value = var.update_strategy
  }
  set {
    name  = "ingress.className"
    value = var.ingress_class
  }
  set {
    name  = "ingress.host"
    value = var.ingress_host
  }
  set {
    name  = "storage.storageClass"
    value = "efs-sc"
  }
  set {
    name  = "storage.size"
    value = var.storage_size
  }
}
