// src/terraform/variables.tf
// Root-level variables for the AgentOps infra (non-secret).

variable "region" {
  description = "AWS region where resources will be created."
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Logical environment name. Used for tags and resource naming."
  type        = string
  default     = "prod"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "agentops-eks-prod"
}

variable "vpc_cidr" {
  description = "Primary IPv4 CIDR for the VPC (recommend /19 or /20)."
  type        = string
  default     = "10.0.0.0/19"
}

variable "private_subnet_cidrs" {
  description = "Exactly two IPv4 CIDRs for private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly 2 CIDRs."
  }
}

variable "system_nodegroup" {
  description = "System nodegroup sizing for stateful workloads."
  type = object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
  })
  default = {
    instance_type = "m6i.large"
    min_size      = 2
    desired_size  = 2
    max_size      = 3
  }
}

variable "inference_nodegroup" {
  description = "Inference nodegroup sizing for stateless workloads."
  type = object({
    instance_type = string
    min_size      = number
    desired_size  = number
    max_size      = number
  })
  default = {
    instance_type = "c6i.xlarge"
    min_size      = 2
    desired_size  = 2
    max_size      = 6
  }
}

variable "system_node_taints" {
  description = <<EOF
Structured taints for the system nodegroup.
Each item is an object with:
  - key    = string
  - value  = string
  - effect = string (one of "NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE")
Example:
[
  { key = "node-role", value = "system", effect = "NO_SCHEDULE" }
]
EOF

  type = list(object({
    key    = string
    value  = string
    effect = string
  }))

  default = [
    { key = "node-role", value = "system", effect = "NO_SCHEDULE" }
  ]

  validation {
    condition     = alltrue([for t in var.system_node_taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)])
    error_message = "Each system_node_taints[].effect must be one of: NO_SCHEDULE, NO_EXECUTE, PREFER_NO_SCHEDULE"
  }
}

variable "inference_node_labels" {
  description = "Labels for inference nodes."
  type        = map(string)
  default     = { "node-role" = "inference" }
}

variable "ebs_volume_type" {
  description = "EBS volume type for stateful workloads."
  type        = string
  default     = "gp3"
}

variable "ecr_repositories" {
  description = "Map of ECR logical name -> repo name (non-secret)."
  type        = map(string)
  default = {
    frontend      = "agentops-frontend"
    inference     = "agentops-inference"
    auth          = "agentops-auth"
    cloudnativepg = "agentops-cloudnativepg"
    postgresql    = "agentops-postgresql"
    cloudflared   = "agentops-cloudflared"
  }
}

variable "cluster_autoscaler" {
  description = "Cluster Autoscaler tuning parameters."
  type = object({
    enabled                    = bool
    scan_interval_seconds      = number
    max_node_provision_time    = number
    expander                   = string
    balance_similar_nodegroups = bool
  })
  default = {
    enabled                    = true
    scan_interval_seconds      = 10
    max_node_provision_time    = 600
    expander                   = "least-waste"
    balance_similar_nodegroups = true
  }
}

variable "tags" {
  description = "Additional tags for all resources."
  type        = map(string)
  default     = {}
}

variable "audit_log_bucket" {
  description = "Optional S3 bucket for operational logs (leave empty to skip)."
  type        = string
  default     = ""
}