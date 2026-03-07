// src/terraform/modules/iam_pre_eks/main.tf
// Pre-EKS IAM: cluster & node roles, cluster-autoscaler policy, CI ECR push policy.
// Stable, deterministic outputs consumed by eks and iam_post_eks.

variable "name_prefix" {
  type    = string
  default = "agentops"
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  name_prefix = var.name_prefix
  common_tags = merge({ ManagedBy = "agentops-serviceautomation" }, var.tags)
}

resource "aws_iam_role" "cluster" {
  name = "${local.name_prefix}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster_attach" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${local.name_prefix}-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_attach_eks_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_attach_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_attach_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name = "${local.name_prefix}-cluster-autoscaler-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "ci_ecr_push" {
  name = "${local.name_prefix}-ci-ecr-push-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories"
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = local.common_tags
}

output "cluster_role_arn" {
  description = "ARN of EKS cluster IAM role"
  value       = aws_iam_role.cluster.arn
}

output "node_role_arn" {
  description = "ARN of EC2 node IAM role"
  value       = aws_iam_role.node.arn
}

output "cluster_autoscaler_policy_arn" {
  description = "ARN of the Cluster Autoscaler policy"
  value       = aws_iam_policy.cluster_autoscaler.arn
}

output "ci_ecr_push_policy_arn" {
  description = "ARN of the CI ECR push policy"
  value       = aws_iam_policy.ci_ecr_push.arn
}

output "ebs_csi_managed_policy_arn" {
  description = "Recommended managed policy ARN for EBS CSI"
  value       = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}