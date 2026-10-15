output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region used for the deployment"
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID for teardown checks and dependency troubleshooting"
  value       = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl for the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "efs_filesystem_id" {
  description = "EFS filesystem ID backing the shared PVC"
  value       = aws_efs_file_system.fortiaigate.id
}

output "release_status" {
  description = "Helm release deployment status"
  value       = helm_release.fortiaigate.status
}

output "ingress_host" {
  description = "Configured ingress hostname (empty = matches all hosts)"
  value       = var.ingress_host
}

data "kubernetes_ingress_v1" "fortiaigate" {
  metadata {
    name      = "fortiaigate-ingress"
    namespace = var.namespace
  }
  depends_on = [helm_release.fortiaigate]
}

output "alb_dns_name" {
  description = "ALB hostname assigned by AWS — use this to configure the FortiGate and chatbot"
  value       = try(data.kubernetes_ingress_v1.fortiaigate.status[0].load_balancer[0].ingress[0].hostname, "not yet assigned — run: kubectl get ingress fortiaigate-ingress -n ${var.namespace}")
}

output "tls_ca_certificate" {
  description = "Root CA for generated/supplied web TLS. ALB clients trust the ACM frontend certificate independently."
  value       = local.web_trusted_root
}

output "internal_tls_ca_certificate" {
  description = "Generated CA for internal service and database TLS in every web certificate mode."
  value       = tls_self_signed_cert.ca.cert_pem
}

output "ingress_scheme" {
  description = "Configured ALB exposure scheme (null for other ingress controllers)."
  value       = var.ingress_class == "alb" ? local.alb_scheme : null
}
