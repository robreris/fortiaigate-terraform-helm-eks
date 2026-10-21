# Separate serving TLS from internal/database trust, following the AKS pattern.
locals {
  supplied_tls         = var.tls_certificate_path != ""
  supplied_certificate = local.supplied_tls ? file(var.tls_certificate_path) : ""
  supplied_private_key = var.tls_private_key_path != "" ? sensitive(file(var.tls_private_key_path)) : ""
  tls_common_name      = var.ingress_host != "" ? var.ingress_host : "fortiaigate.local"
  # Match Helm's left-to-right auth overrides for certificate authentication.
  postgresql_username = merge(
    yamldecode(file("${path.module}/fortiaigate/values.yaml")).postgresql.auth,
    [for f in var.extra_values_files : try(yamldecode(file(f)).postgresql.auth, {})]...
  ).username
  internal_certificate = "${tls_locally_signed_cert.internal.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
  web_certificate      = local.supplied_tls ? local.supplied_certificate : "${tls_locally_signed_cert.fortiaigate.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
  web_private_key      = local.supplied_tls ? local.supplied_private_key : tls_private_key.fortiaigate.private_key_pem
  web_trusted_root     = local.supplied_tls ? (var.tls_ca_certificate_path != "" ? file(var.tls_ca_certificate_path) : "") : tls_self_signed_cert.ca.cert_pem
}

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  is_ca_certificate = true

  subject {
    common_name  = "FortiAIGate ${var.cluster_name} CA"
    organization = "FortiAIGate"
  }

  validity_period_hours = 43800 # 5 years

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

resource "tls_private_key" "fortiaigate" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "fortiaigate" {
  private_key_pem = tls_private_key.fortiaigate.private_key_pem

  subject {
    common_name  = local.tls_common_name
    organization = "FortiAIGate"
  }

  # Cover ingress and in-cluster service DNS names for certificate verification.
  dns_names = distinct(compact(concat(
    [var.ingress_host, "localhost"],
    flatten([
      for svc in ["llm-gateway", "api", "webui", "license-manager", "fortiaigate-postgresql", "fortiaigate-redis-master", "guardrail", "dlp-scanner", "policy-guard", "logd"] : [
        svc,
        "${svc}.${var.namespace}",
        "${svc}.${var.namespace}.svc",
        "${svc}.${var.namespace}.svc.cluster.local",
      ]
    ]),
  )))
}

resource "tls_locally_signed_cert" "fortiaigate" {
  cert_request_pem   = tls_cert_request.fortiaigate.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}


resource "tls_private_key" "internal" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "internal" {
  private_key_pem = tls_private_key.internal.private_key_pem

  subject {
    # PostgreSQL cert authentication compares the client CN with the DB role.
    common_name  = local.postgresql_username
    organization = "FortiAIGate"
  }

  dns_names = tls_cert_request.fortiaigate.dns_names
}

resource "tls_locally_signed_cert" "internal" {
  cert_request_pem   = tls_cert_request.internal.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 8760
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth", "client_auth"]
}

resource "kubernetes_secret" "tls" {
  metadata {
    name      = "fortiaigate-tls-secret"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }
    annotations = {
      "meta.helm.sh/release-name"      = "fortiaigate"
      "meta.helm.sh/release-namespace" = kubernetes_namespace.fortiaigate.metadata[0].name
    }
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = local.web_certificate
    "tls.key" = local.web_private_key
    "ca.crt"  = local.web_trusted_root
  }
  lifecycle {
    precondition {
      condition     = (var.tls_certificate_path != "") == (var.tls_private_key_path != "")
      error_message = "Set both tls_certificate_path and tls_private_key_path, or leave both empty."
    }
    precondition {
      condition     = !local.supplied_tls || trimspace(var.ingress_host) != ""
      error_message = "Supplied web TLS requires ingress_host."
    }
    precondition {
      condition     = var.tls_ca_certificate_path == "" || local.supplied_tls
      error_message = "tls_ca_certificate_path requires a supplied serving certificate."
    }
  }
}

resource "kubernetes_secret" "internal_tls" {
  metadata {
    name      = "fortiaigate-internal-tls-secret"
    namespace = kubernetes_namespace.fortiaigate.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = local.internal_certificate
    "tls.key" = tls_private_key.internal.private_key_pem
    "ca.crt"  = tls_self_signed_cert.ca.cert_pem
  }
}
