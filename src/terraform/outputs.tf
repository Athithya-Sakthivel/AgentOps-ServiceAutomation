// src/terraform/outputs.tf
// Aggregated stable outputs for CI / operators / kubeconfig automation.

output "vpc_id" {
  description = "VPC ID created by modules/vpc"
  value       = try(module.vpc.vpc_id, "")
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ)"
  value       = try(module.vpc.private_subnet_ids, [])
}

output "private_subnet_ipv4_cidrs" {
  description = "IPv4 CIDRs of private subnets"
  value       = try(module.vpc.private_subnet_ipv4_cidrs, [])
}

output "private_subnet_ipv6_cidrs" {
  description = "IPv6 CIDRs assigned to private subnets"
  value       = try(module.vpc.private_subnet_ipv6_cidrs, [])
}

output "ipv6_cidr_block" {
  description = "VPC IPv6 CIDR block (may be empty until assigned)"
  value       = try(module.vpc.ipv6_cidr_block, "")
}

output "availability_zones" {
  description = "AZs selected by the VPC module (two AZs)"
  value       = try(module.vpc.availability_zones, [])
}

output "node_security_group_id" {
  description = "Security Group ID attached to worker nodes"
  value       = try(module.security.node_security_group_id, "")
}

output "vpc_endpoints_security_group_id" {
  description = "Security Group ID to attach to VPC interface endpoints"
  value       = try(module.security.vpc_endpoints_security_group_id, "")
}

output "ecr_repository_urls" {
  description = "Map of ECR logical name -> repository URL"
  value       = try(module.ecr.repository_url_map, {})
}

output "ecr_repository_arns" {
  description = "Map of ECR logical name -> repository ARN"
  value       = try(module.ecr.repository_arn_map, {})
}

# IAM outputs (pre-EKS)
output "iam_cluster_role_arn" {
  description = "EKS control plane role ARN (iam_pre_eks)"
  value       = try(module.iam_pre_eks.cluster_role_arn, "")
}

output "iam_node_role_arn" {
  description = "EC2 node role ARN (iam_pre_eks)"
  value       = try(module.iam_pre_eks.node_role_arn, "")
}

output "cluster_autoscaler_policy_arn" {
  description = "Cluster Autoscaler policy ARN (iam_pre_eks)"
  value       = try(module.iam_pre_eks.cluster_autoscaler_policy_arn, "")
}

output "ebs_csi_managed_policy_arn" {
  description = "AWS-managed EBS CSI policy ARN referenced by iam_pre_eks"
  value       = try(module.iam_pre_eks.ebs_csi_managed_policy_arn, "")
}

# EKS outputs
output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = try(module.eks.cluster_name, "")
}

output "eks_cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = try(module.eks.cluster_endpoint, "")
}

output "eks_cluster_ca_data" {
  description = "EKS cluster CA data (base64)"
  value       = try(module.eks.cluster_ca_data, "")
}

output "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN (for IRSA)"
  value       = try(module.eks.oidc_provider_arn, "")
}

# Post-EKS IRSA role ARNs produced by iam_post_eks
output "ebs_csi_irsa_role_arn" {
  description = "ARN of the post-EKS EBS CSI IRSA role"
  value       = try(module.iam_post_eks.ebs_csi_irsa_role_arn, "")
}

output "cluster_autoscaler_irsa_role_arn" {
  description = "ARN of the post-EKS Cluster Autoscaler IRSA role"
  value       = try(module.iam_post_eks.cluster_autoscaler_irsa_role_arn, "")
}