// src/terraform/main.tf
// Root composition: S3 backend placeholder + modules wiring.
// Backend is configured at runtime by run.sh via CLI -backend-config arguments.

terraform {
  backend "s3" {}
}

# --- Core infra (VPC, security, ECR) ---
module "vpc" {
  source = "./modules/vpc"

  vpc_cidr             = var.vpc_cidr
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = var.tags
}

module "security" {
  source = "./modules/security"

  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.vpc_cidr
  name_prefix = "agentops"
  # Explicitly disable IPv6 in the security module so rules remain IPv4-only.
  enable_ipv6 = false
  tags        = var.tags
}

module "ecr" {
  source = "./modules/ecr"
  tags   = var.tags
}

# --- IAM required before EKS (cluster role, node role, policies) ---
module "iam_pre_eks" {
  source      = "./modules/iam_pre_eks"
  name_prefix = "agentops"
  tags        = var.tags
}

# --- EKS cluster & managed node groups — consumes iam_pre_eks outputs ---
module "eks" {
  source = "./modules/eks"

  cluster_name = var.cluster_name
  region       = var.region

  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.private_subnet_ids
  node_security_group_id = try(module.security.node_security_group_id, "")

  # IAM ARNs produced by iam_pre_eks (required)
  cluster_role_arn = try(module.iam_pre_eks.cluster_role_arn, "")
  node_role_arn    = try(module.iam_pre_eks.node_role_arn, "")

  # Policy ARNs exported by iam_pre_eks (optional / consumed downstream)
  ebs_csi_policy_arn            = try(module.iam_pre_eks.ebs_csi_managed_policy_arn, "")
  cluster_autoscaler_policy_arn = try(module.iam_pre_eks.cluster_autoscaler_policy_arn, "")

  # ECR info (convenience only)
  ecr_repository_urls = try(module.ecr.repository_url_map, {})

  # nodegroups
  system_nodegroup      = var.system_nodegroup
  inference_nodegroup   = var.inference_nodegroup
  system_node_taints    = var.system_node_taints
  inference_node_labels = var.inference_node_labels

  tags = var.tags

  # ensure essential infra (vpc, security, iam_pre_eks, ecr) exists before node bootstrap
  depends_on = [module.vpc, module.security, module.iam_pre_eks, module.ecr]
}

# --- IAM resources that require the EKS OIDC provider (IRSA roles) ---
module "iam_post_eks" {
  source = "./modules/iam_post_eks"

  name_prefix = "agentops"
  tags        = var.tags

  # use try() to avoid hard failure in plan when eks OIDC provider not yet present
  oidc_provider_arn    = try(module.eks.oidc_provider_arn, "")
  oidc_provider_issuer = try(module.eks.oidc_provider_issuer, "")

  ebs_csi_policy_arn            = try(module.iam_pre_eks.ebs_csi_managed_policy_arn, "")
  cluster_autoscaler_policy_arn = try(module.iam_pre_eks.cluster_autoscaler_policy_arn, "")

  ebs_sa_namespace        = "kube-system"
  ebs_sa_name             = "ebs-csi-controller-sa"
  autoscaler_sa_namespace = "kube-system"
  autoscaler_sa_name      = "cluster-autoscaler"

  # SG ids used to create cross-SG ingress rules required by EKS control plane <-> nodes.
  node_security_group_id    = try(module.security.node_security_group_id, "")
  cluster_security_group_id = try(module.eks.cluster_security_group_id, "")

  # ensure cluster exists and security module created before applying these IAM+SG changes
  depends_on = [module.eks, module.iam_pre_eks, module.security]
}