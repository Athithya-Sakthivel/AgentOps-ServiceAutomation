// src/terraform/variables.tf
// OpenTofu / Terraform v1.11.5 compatible variable declarations.
// Keep values non-secret here; place environment-specific values in *.tfvars.

variable "region" {
  description = "AWS region where resources will be created. Default matches operator workstation expectation."
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Logical environment name. Used for tags, S3 backend key prefix, resource naming."
  type        = string
  default     = "prod"
}

variable "cluster_name" {
  description = "EKS cluster name. Keep globally unique per-account if multiple clusters exist."
  type        = string
  default     = "agentops-eks-prod"
}

variable "enable_ipv6" {
  description = "Always true for this project; VPC will be dual-stack and IPv6 routing (egress-only IGW) will be configured."
  type        = bool
  default     = true
  validation {
    condition     = var.enable_ipv6 == true
    error_message = "enable_ipv6 is a required invariant for this project and must be true."
  }
}

variable "no_nat" {
  description = "Design invariant: NAT gateways are disabled. Keep true to enforce the NAT-free architecture."
  type        = bool
  default     = true
  validation {
    condition     = var.no_nat == true
    error_message = "no_nat is a required invariant for this project and must be true."
  }
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR for the VPC. Recommend /19 to /20 to avoid ENI/pod IP exhaustion in a 2-AZ cluster."
  type        = string
  default     = "10.0.0.0/19"
}

variable "private_subnet_cidrs" {
  description = "List of exactly two IPv4 CIDRs for private (dual-stack) subnets, one per AZ. Must be length 2."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly 2 CIDRs (one per AZ)."
  }
}

variable "assign_ipv6_cidr_block" {
  description = "When true, the VPC will request an Amazon-provided IPv6 CIDR block. Required for NAT-free dual-stack design."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Create required VPC endpoints (ecr.api, ecr.dkr, sts, s3 gateway). Keep true for NAT-free operation."
  type        = bool
  default     = true
}

variable "bedrock_enabled" {
  description = "Set true if workloads will call Amazon Bedrock directly from inside the VPC. Adds Bedrock interface endpoint when true."
  type        = bool
  default     = true
}

variable "system_nodegroup" {
  description = "System nodegroup sizing for stateful workloads (Signoz, ClickHouse, Postgres). Use conservative defaults that prioritize stability."
  type = object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
  })
  default = {
    instance_type = "m6i.large" // conservative general-purpose, no GPU
    min_size      = 2
    desired_size  = 2
    max_size      = 3
  }
}

variable "inference_nodegroup" {
  description = "Inference nodegroup sizing for stateless inference/auth services. No GPUs; Bedrock handles heavy model compute."
  type = object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
  })
  default = {
    instance_type = "c6i.xlarge" // compute-optimized baseline; tune to observed CPU load
    min_size      = 2            // keep warm capacity to reduce cold-start latency
    desired_size  = 2
    max_size      = 6
  }
}

variable "system_node_taints" {
  description = "Taints applied to system nodes to ensure stateful system pods schedule only on system nodegroup."
  type        = list(string)
  default     = ["node-role=system:NoSchedule"]
}

variable "inference_node_labels" {
  description = "Labels applied to inference nodes for deterministic scheduling of inference workloads."
  type        = map(string)
  default     = { "node-role" = "inference" }
}

variable "ebs_volume_type" {
  description = "EBS volume type for stateful workloads (Postgres, ClickHouse). Default to gp3 for predictable performance and lower cost."
  type        = string
  default     = "gp3"
}

variable "ecr_repositories" {
  description = "Map of ECR repository logical names to repo names. Non-secret."
  type        = map(string)
  default = {
    frontend = "agentops-frontend"
    backend  = "agentops-backend"
  }
}

variable "cluster_autoscaler" {
  description = "Cluster Autoscaler tuning params. These values are conservative starting points for a 2-AZ cluster."
  type = object({
    enabled                    = bool
    scan_interval_seconds      = number
    max_node_provision_time    = number // in seconds
    expander                   = string
    balance_similar_nodegroups = bool
  })
  default = {
    enabled                    = true
    scan_interval_seconds      = 10
    max_node_provision_time    = 600 // 10 minutes
    expander                   = "least-waste"
    balance_similar_nodegroups = true
  }
}

variable "tags" {
  description = "Additional tags applied to all resources via provider default_tags and resource-level tags."
  type        = map(string)
  default     = {}
}

variable "audit_log_bucket" {
  description = "Optional S3 bucket name for storing operational logs/exports. Leave blank to not create."
  type        = string
  default     = ""
}