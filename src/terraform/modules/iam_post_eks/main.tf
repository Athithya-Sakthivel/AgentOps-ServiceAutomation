// src/terraform/modules/iam_post_eks/main.tf
// Post-EKS IAM + optional control-plane <-> node SG rules.
// IRSA roles are created unconditionally; SG rules are created only when
// the operator explicitly enables them via module variable `create_sg_rules = true`.
// This avoids accidental duplicate-rule attempts and plan-time unknown count issues.

variable "name_prefix" {
  type    = string
  default = "agentops"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "oidc_provider_arn" {
  type    = string
  default = ""
}

variable "oidc_provider_issuer" {
  type        = string
  description = "OIDC issuer host/path (without https://)"
  default     = ""
}

variable "ebs_csi_policy_arn" {
  type    = string
  default = ""
}

variable "cluster_autoscaler_policy_arn" {
  type    = string
  default = ""
}

variable "ebs_sa_namespace" {
  type    = string
  default = "kube-system"
}

variable "ebs_sa_name" {
  type    = string
  default = "ebs-csi-controller-sa"
}

variable "autoscaler_sa_namespace" {
  type    = string
  default = "kube-system"
}

variable "autoscaler_sa_name" {
  type    = string
  default = "cluster-autoscaler"
}

variable "node_security_group_id" {
  description = "Worker node security group id (from modules/security)."
  type        = string
  default     = ""
}

variable "cluster_security_group_id" {
  description = "EKS control-plane security group id (from modules/eks)."
  type        = string
  default     = ""
}

# Explicit operator-controlled flag. Default false to avoid accidental duplicate SG-rule creation.
variable "create_sg_rules" {
  description = "When true, the module will create control-plane <-> node SG rules. Set to true only after cluster and node SGs exist and you have confirmed rules are not already present."
  type        = bool
  default     = false
}

locals {
  name_prefix = var.name_prefix
  common_tags = merge({ ManagedBy = "agentops-serviceautomation" }, var.tags)
}

########################
# IRSA Roles (EBS CSI, Cluster Autoscaler)
########################
resource "aws_iam_role" "ebs_csi_irsa" {
  name = "${local.name_prefix}-ebs-csi-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            ("${var.oidc_provider_issuer}:sub") = "system:serviceaccount:${var.ebs_sa_namespace}:${var.ebs_sa_name}"
            ("${var.oidc_provider_issuer}:aud") = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_attach" {
  role       = aws_iam_role.ebs_csi_irsa.name
  policy_arn = var.ebs_csi_policy_arn
}

resource "aws_iam_role" "cluster_autoscaler_irsa" {
  name = "${local.name_prefix}-cluster-autoscaler-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            ("${var.oidc_provider_issuer}:sub") = "system:serviceaccount:${var.autoscaler_sa_namespace}:${var.autoscaler_sa_name}"
            ("${var.oidc_provider_issuer}:aud") = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler_attach" {
  role       = aws_iam_role.cluster_autoscaler_irsa.name
  policy_arn = var.cluster_autoscaler_policy_arn
}

########################
# Control-plane <-> Nodes SG rules (explicit)
# - Created only if create_sg_rules = true.
# - Operator must ensure the SG IDs are correct and that identical rules don't already exist.
########################

resource "aws_security_group_rule" "nodes_to_api_https" {
  count = var.create_sg_rules ? 1 : 0

  security_group_id        = var.cluster_security_group_id
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.node_security_group_id
  description              = "Allow worker nodes to call EKS API server (TCP/443)"
}

resource "aws_security_group_rule" "api_to_kubelet" {
  count = var.create_sg_rules ? 1 : 0

  security_group_id        = var.node_security_group_id
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = var.cluster_security_group_id
  description              = "Allow EKS control plane to reach kubelet on workers (TCP/10250)"
}

########################
# Outputs
########################

output "ebs_csi_irsa_role_arn" {
  value       = aws_iam_role.ebs_csi_irsa.arn
  description = "ARN of the EBS CSI IRSA role"
}

output "cluster_autoscaler_irsa_role_arn" {
  value       = aws_iam_role.cluster_autoscaler_irsa.arn
  description = "ARN of the Cluster Autoscaler IRSA role"
}

output "cluster_node_sg_rules_applied" {
  description = "True if create_sg_rules was true (operator intent)."
  value       = var.create_sg_rules
}