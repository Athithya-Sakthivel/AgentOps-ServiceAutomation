// src/terraform/modules/security/main.tf
// Security module (OpenTofu v1.11.5 + aws provider v6.x).
// Creates worker node SG and an interface-endpoints SG.

variable "vpc_id" {
  description = "VPC ID where security groups will be created."
  type        = string
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR block for the VPC (used for internal allow rules)."
  type        = string
}

variable "ipv6_cidr_block" {
  description = "VPC IPv6 CIDR block (if assigned by VPC module). Provide empty string if not available."
  type        = string
  default     = ""
}

variable "enable_ipv6" {
  description = "Controls IPv6 rule population."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Name prefix for security groups."
  type        = string
  default     = "agentops"
}

variable "tags" {
  description = "Tags applied to all security groups created by this module."
  type        = map(string)
  default     = {}
}

locals {
  env_tag         = lookup(var.tags, "Environment", "prod")
  merged_tags     = merge({ "Name" = var.name_prefix, "Environment" = local.env_tag, "ManagedBy" = "agentops-serviceautomation" }, var.tags)
  ipv6_blocks     = (var.enable_ipv6 && var.ipv6_cidr_block != "") ? [var.ipv6_cidr_block] : []
  any_ipv6_egress = var.enable_ipv6 ? ["::/0"] : []
}

########################
# Worker node security group
########################
resource "aws_security_group" "node" {
  name        = "${var.name_prefix}-nodes-sg"
  description = "Worker node security group (allows intra-VPC traffic)."
  vpc_id      = var.vpc_id
  tags        = local.merged_tags

  # Allow full intra-VPC communication for node agents / kubelet / container networking.
  ingress {
    description      = "Allow all traffic within VPC CIDR"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = [var.vpc_cidr]
    ipv6_cidr_blocks = local.ipv6_blocks
  }

  egress {
    description      = "Allow all outbound (AWS APIs, VPC endpoints, internet egress)."
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = local.any_ipv6_egress
  }
}

########################
# VPC interface endpoints SG (attach to interface endpoints ENIs)
########################
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-endpoints-sg"
  description = "SG attached to VPC interface endpoints (ECR, STS, SSM...). Allows HTTPS from worker nodes."
  vpc_id      = var.vpc_id
  tags        = merge(local.merged_tags, { "role" = "vpc-endpoints" })

  # Allow worker nodes to reach endpoint ENIs on 443
  ingress {
    description     = "Allow HTTPS (443) from worker nodes"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  # Optional: allow Kubelet port if operators choose to access nodes via endpoints (kept permissive from VPC CIDR)
  ingress {
    description      = "Optional: allow kubelet port (10250) from VPC CIDR"
    from_port        = 10250
    to_port          = 10250
    protocol         = "tcp"
    cidr_blocks      = [var.vpc_cidr]
    ipv6_cidr_blocks = local.ipv6_blocks
  }

  egress {
    description      = "Allow all outbound from endpoint ENIs"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = local.any_ipv6_egress
  }
}

########################
# Outputs
########################
output "node_security_group_id" {
  description = "Security Group ID for worker nodes."
  value       = aws_security_group.node.id
}

output "vpc_endpoints_security_group_id" {
  description = "Security Group ID to attach to VPC Interface Endpoints (ECR API/DKR, STS, SSM, etc)."
  value       = aws_security_group.vpc_endpoints.id
}