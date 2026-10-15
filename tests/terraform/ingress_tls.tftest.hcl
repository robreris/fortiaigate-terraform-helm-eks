mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "tls" {}

variables {
  image_repository = "example.com/fortiaigate"
  ingress_class    = "alb"
  ingress_host     = "fortiaigate.example.com"
}

run "internal_http" {
  command = apply
  variables { internal = true }
  assert {
    condition     = yamldecode(local.ingress_annotation_values[0]).ingress.annotations["alb.ingress.kubernetes.io/scheme"] == "internal" && jsondecode(yamldecode(local.ingress_annotation_values[0]).ingress.annotations["alb.ingress.kubernetes.io/listen-ports"])[0].HTTP == 80
    error_message = "Internal mode without ACM must explicitly create a private HTTP listener."
  }
}

run "internal_https" {
  command = apply
  variables {
    internal            = true
    acm_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/test"
  }
  assert {
    condition     = jsondecode(yamldecode(local.ingress_annotation_values[0]).ingress.annotations["alb.ingress.kubernetes.io/listen-ports"])[0].HTTPS == 443 && local.alb_scheme == "internal"
    error_message = "Private ALBs must support ACM frontend HTTPS."
  }
}

run "external_https_legacy_annotation" {
  command = apply
  variables {
    internal = false
    ingress_annotations = {
      "alb.ingress.kubernetes.io/certificate-arn" = "arn:aws:acm:us-east-1:123456789012:certificate/test"
    }
  }
  assert {
    condition     = local.alb_https && local.alb_scheme == "internet-facing"
    error_message = "Existing certificate-arn annotations must keep working in public mode."
  }
}

run "reject_public_override_in_private_mode" {
  command = plan
  variables {
    internal = true
    ingress_annotations = {
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
    }
  }
  expect_failures = [terraform_data.ingress_configuration]
}

run "reject_acm_wrong_region" {
  command = plan
  variables {
    acm_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/test"
  }
  expect_failures = [terraform_data.ingress_configuration]
}

run "supplied_web_certificate" {
  command = apply
  variables {
    tls_certificate_path = "test-cert.pem"
    tls_private_key_path = "test-key.pem"
  }
  assert {
    condition     = nonsensitive(kubernetes_secret.tls.data["tls.crt"]) == file("test-cert.pem") && nonsensitive(kubernetes_secret.internal_tls.data["ca.crt"]) == tls_self_signed_cert.ca.cert_pem
    error_message = "Supplied web certificates must leave internal CA ownership separate."
  }
}

run "reject_incomplete_key_pair" {
  command = plan
  variables { tls_certificate_path = "test-cert.pem" }
  expect_failures = [kubernetes_secret.tls]
}

run "reject_legacy_acm_wrong_region" {
  command = plan
  variables {
    ingress_annotations = {
      "alb.ingress.kubernetes.io/certificate-arn" = "arn:aws:acm:us-west-2:123456789012:certificate/test"
    }
  }
  expect_failures = [terraform_data.ingress_configuration]
}
