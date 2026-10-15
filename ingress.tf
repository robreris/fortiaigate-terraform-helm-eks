locals {
  # AWS frontend TLS is independent of pod TLS. Preserve the legacy ARN annotation.
  alb_certificate_arn = var.acm_certificate_arn != "" ? var.acm_certificate_arn : lookup(var.ingress_annotations, "alb.ingress.kubernetes.io/certificate-arn", "")
  alb_https           = local.alb_certificate_arn != ""
  alb_scheme          = var.internal ? "internal" : "internet-facing"
  ingress_annotation_values = [yamlencode({
    ingress = {
      annotations = merge(
        var.ingress_class == "alb" ? merge(
          { "alb.ingress.kubernetes.io/listen-ports" = jsonencode(local.alb_https ? [{ HTTPS = 443 }] : [{ HTTP = 80 }]) },
          local.alb_https ? { "alb.ingress.kubernetes.io/certificate-arn" = local.alb_certificate_arn } : {},
        ) : {},
        var.ingress_annotations,
        # Exposure and an explicitly configured certificate cannot be overridden by extras.
        var.ingress_class == "alb" ? { "alb.ingress.kubernetes.io/scheme" = local.alb_scheme } : {},
        var.ingress_class == "alb" && var.acm_certificate_arn != "" ? { "alb.ingress.kubernetes.io/certificate-arn" = var.acm_certificate_arn } : {},
      )
    }
  })]

}

resource "terraform_data" "ingress_configuration" {
  input = local.alb_scheme
  lifecycle {
    precondition {
      condition     = var.ingress_class != "alb" || lookup(var.ingress_annotations, "alb.ingress.kubernetes.io/scheme", local.alb_scheme) == local.alb_scheme
      error_message = "The ALB scheme annotation conflicts with internal. Set internal=true for private exposure or false for internet-facing exposure, and remove the conflicting annotation."
    }
    precondition {
      condition = local.alb_certificate_arn == "" || (var.ingress_class == "alb" && alltrue([
        for arn in split(",", local.alb_certificate_arn) : try(split(":", trimspace(arn))[3], "") == var.aws_region
      ]))
      error_message = "acm_certificate_arn requires ingress_class=alb and a certificate in aws_region."
    }
  }

}
