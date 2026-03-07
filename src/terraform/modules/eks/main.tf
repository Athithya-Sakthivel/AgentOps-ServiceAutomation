// src/terraform/modules/eks/main.tf
// EKS cluster + managed nodegroups.
// Compatible with OpenTofu/Terraform >=1.11.5 and hashicorp/aws 6.x.
//
// Notes:
// - The module requires the caller to provide a node_security_group_id (SG attached to worker nodes).
//   The module creates the control-plane ingress rule that allows worker-node SG -> control-plane:443
//   so kubelet on nodes can register the node during bootstrap.
// - If you use a custom EC2 Launch Template for node bootstrap, supply launch_template_id / version.
// - This module intentionally does NOT attempt to pre-validate computed module outputs (they may be unknown
//   during plan). Ensure your root module wires and depends_on modules correctly.

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "vpc_id" {
  description = "VPC id"
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs (two AZs)."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Security group ID used by worker nodes (required). Pass module.security.node_security_group_id from root."
  type        = string

  validation {
    condition     = var.node_security_group_id != ""
    error_message = "node_security_group_id must be provided to this module (pass module.security.node_security_group_id from root)."
  }
}

variable "endpoint_security_group_id" {
  description = "Optional SG used for VPC interface endpoints (passed for reference)."
  type        = string
  default     = ""
}

variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS control plane (from iam_pre_eks)"
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for EC2 nodegroups (from iam_pre_eks)"
  type        = string
}

variable "ebs_csi_policy_arn" {
  description = "ARN of the EBS CSI managed policy (from iam_pre_eks)."
  type        = string
  default     = ""
}

variable "cluster_autoscaler_policy_arn" {
  description = "ARN of the Cluster Autoscaler policy (from iam_pre_eks)."
  type        = string
  default     = ""
}

variable "ecr_repository_urls" {
  description = "Map of ECR logical name -> repo URL (convenience)."
  type        = map(string)
  default     = {}
}

variable "system_nodegroup" {
  description = "System nodegroup sizing object."
  type = object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
  })
}

variable "inference_nodegroup" {
  description = "Inference nodegroup sizing object."
  type = object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
  })
}

variable "system_node_taints" {
  description = "List of taints for system nodegroup (structured: key,value,effect)."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = [{ key = "node-role", value = "system", effect = "NO_SCHEDULE" }]

  validation {
    condition     = alltrue([for t in var.system_node_taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)])
    error_message = "Each system_node_taints[].effect must be one of: NO_SCHEDULE, NO_EXECUTE, PREFER_NO_SCHEDULE"
  }
}

variable "inference_node_labels" {
  description = "Labels for inference nodegroup"
  type        = map(string)
  default     = {}
}

variable "enabled_cluster_log_types" {
  description = "Control-plane log types to enable."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "tags" {
  description = "Tags applied to resources"
  type        = map(string)
  default     = {}
}

# Optional: support a custom launch template for nodegroups (reduces failure modes when you manage AMI/user-data centrally)
variable "launch_template_id" {
  description = "Optional EC2 Launch Template ID for managed nodegroups (leave empty to let EKS create/choose instances)."
  type        = string
  default     = ""
}

variable "launch_template_version" {
  description = "Optional Launch Template version (string). Use empty string to let AWS default ($Latest)."
  type        = string
  default     = ""
}

locals {
  merged_tags = merge({ ManagedBy = "agentops-serviceautomation", Name = var.cluster_name, Environment = lookup(var.tags, "Environment", "") }, var.tags)
}

#########################
# EKS cluster (private)
#########################
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids = var.subnet_ids

    endpoint_public_access  = false
    endpoint_private_access = true
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  tags = local.merged_tags
}

# Expose cluster security group id (control plane SG) for use by other modules/root.
output "cluster_security_group_id" {
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description = "Control-plane security group id created/managed by the EKS control plane"
}

# Allow worker nodes to reach control plane on TCP/443.
# This rule must exist before nodegroups attempt to bootstrap and register.
resource "aws_security_group_rule" "allow_nodes_to_control_plane" {
  description              = "Allow worker nodes to contact control plane (kube-apiserver) on TCP/443"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  source_security_group_id = var.node_security_group_id
}

# Retrieve TLS certificate for issuer and compute SHA1 fingerprint for the OIDC provider.
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint
  ]

  tags = local.merged_tags
}

#########################
# Node group: system (stateful workloads)
# depends on the control-plane SG rule to exist first
#########################
resource "aws_eks_node_group" "system" {
  depends_on = [aws_security_group_rule.allow_nodes_to_control_plane]

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = var.system_nodegroup.desired_size
    min_size     = var.system_nodegroup.min_size
    max_size     = var.system_nodegroup.max_size
  }

  instance_types = [var.system_nodegroup.instance_type]

  dynamic "taint" {
    for_each = var.system_node_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  dynamic "launch_template" {
    for_each = var.launch_template_id != "" ? [1] : []
    content {
      id      = var.launch_template_id
      version = var.launch_template_version != "" ? var.launch_template_version : "$Latest"
    }
  }

  tags = local.merged_tags
}

#########################
# Node group: inference (stateless inference + auth)
# depends on the control-plane SG rule to exist first
#########################
resource "aws_eks_node_group" "inference" {
  depends_on = [aws_security_group_rule.allow_nodes_to_control_plane]

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-inference"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  scaling_config {
    desired_size = var.inference_nodegroup.desired_size
    min_size     = var.inference_nodegroup.min_size
    max_size     = var.inference_nodegroup.max_size
  }

  instance_types = [var.inference_nodegroup.instance_type]

  labels = var.inference_node_labels

  dynamic "launch_template" {
    for_each = var.launch_template_id != "" ? [1] : []
    content {
      id      = var.launch_template_id
      version = var.launch_template_version != "" ? var.launch_template_version : "$Latest"
    }
  }

  tags = local.merged_tags
}

#########################
# Outputs (cluster info)
#########################
output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  description = "Base64-encoded certificate authority data for the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the aws_iam_openid_connect_provider"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_issuer" {
  description = "OIDC issuer host/path without https://"
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}