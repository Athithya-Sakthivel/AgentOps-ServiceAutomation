// src/terraform/modules/endpoints/main.tf
// VPC endpoints module — deterministic variant (OpenTofu v1.11.5 + aws provider v6.x).
// - All resource creation is gated only by var.enable_vpc_endpoints (plan-time known).
// - Caller responsibility: when enable_vpc_endpoints = true provide non-empty subnet_ids,
//   security_group_id and route_table_ids (S3 gateway) so apply succeeds.

variable "vpc_id" {
  description = "VPC ID where endpoints will be created."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs to place interface endpoint ENIs in (one per AZ). Caller must provide these when enable_vpc_endpoints = true."
  type        = list(string)
  default     = []
}

variable "route_table_ids" {
  description = "Route table IDs to attach Gateway endpoints (S3). Caller must provide these when enable_vpc_endpoints = true."
  type        = list(string)
  default     = []
}

variable "security_group_id" {
  description = "Security Group ID to attach to Interface Endpoints (must allow inbound 443 from worker node SG). Caller must provide this when enable_vpc_endpoints = true."
  type        = string
  default     = ""
}

variable "enable_vpc_endpoints" {
  description = "Feature flag: create VPC endpoints when true."
  type        = bool
  default     = true
}

variable "bedrock_enabled" {
  description = "Create Bedrock interface endpoint if true (region dependent)."
  type        = bool
  default     = false
}

variable "region" {
  description = "AWS region used to construct service names."
  type        = string
  default     = "ap-south-1"
}

variable "tags" {
  description = "Tags applied to endpoints."
  type        = map(string)
  default     = {}
}

locals {
  svc = {
    ecr_api         = "com.amazonaws.${var.region}.ecr.api"
    ecr_dkr         = "com.amazonaws.${var.region}.ecr.dkr"
    sts             = "com.amazonaws.${var.region}.sts"
    ssm             = "com.amazonaws.${var.region}.ssm"
    ssmmessages     = "com.amazonaws.${var.region}.ssmmessages"
    ec2messages     = "com.amazonaws.${var.region}.ec2messages"
    ec2             = "com.amazonaws.${var.region}.ec2"
    bedrock_runtime = "com.amazonaws.${var.region}.bedrock-runtime"
    s3              = "com.amazonaws.${var.region}.s3"
  }

  common_tags = merge({ ManagedBy = "agentops-serviceautomation" }, var.tags)

  // single-element list to pass into security_group_ids when non-empty
  sg_for_endpoints = var.security_group_id != "" ? [var.security_group_id] : []
}

# NOTE:
# - All resource counts depend only on var.enable_vpc_endpoints (plan-time known).
# - Caller must supply subnet_ids/security_group_id/route_table_ids when enable_vpc_endpoints = true.

# --- S3 Gateway endpoint (Gateway type) ---
resource "aws_vpc_endpoint" "s3_gateway" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = local.svc.s3
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  tags = local.common_tags
}

# --- ECR API (Interface) ---
resource "aws_vpc_endpoint" "ecr_api" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.ecr_api
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  // conservative: use ipv4 to avoid region/service dualstack mismatch errors
  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- ECR DKR (Interface) ---
resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.ecr_dkr
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- STS (Interface) ---
resource "aws_vpc_endpoint" "sts" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.sts
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- EC2 (Interface) ---
resource "aws_vpc_endpoint" "ec2" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.ec2
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- SSM (Interface) ---
resource "aws_vpc_endpoint" "ssm" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.ssm
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- SSM Messages (Interface) ---
resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.ssmmessages
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- EC2 Messages (Interface) ---
resource "aws_vpc_endpoint" "ec2messages" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.ec2messages
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- Bedrock runtime (Interface) — optional ---
resource "aws_vpc_endpoint" "bedrock_runtime" {
  count = var.enable_vpc_endpoints && var.bedrock_enabled ? 1 : 0

  vpc_id             = var.vpc_id
  service_name       = local.svc.bedrock_runtime
  vpc_endpoint_type  = "Interface"
  subnet_ids         = var.subnet_ids
  security_group_ids = local.sg_for_endpoints

  // conservative: Bedrock is explicitly ipv4 to avoid region-specific dualstack gaps
  ip_address_type     = "ipv4"
  private_dns_enabled = true

  tags = local.common_tags
}

# --- Outputs ---
output "endpoint_ids" {
  description = "Map of created endpoint logical name -> endpoint id (empty string when not created)."
  value = {
    s3_gateway      = length(aws_vpc_endpoint.s3_gateway) > 0 ? aws_vpc_endpoint.s3_gateway[0].id : ""
    ecr_api         = length(aws_vpc_endpoint.ecr_api) > 0 ? aws_vpc_endpoint.ecr_api[0].id : ""
    ecr_dkr         = length(aws_vpc_endpoint.ecr_dkr) > 0 ? aws_vpc_endpoint.ecr_dkr[0].id : ""
    sts             = length(aws_vpc_endpoint.sts) > 0 ? aws_vpc_endpoint.sts[0].id : ""
    ec2             = length(aws_vpc_endpoint.ec2) > 0 ? aws_vpc_endpoint.ec2[0].id : ""
    ssm             = length(aws_vpc_endpoint.ssm) > 0 ? aws_vpc_endpoint.ssm[0].id : ""
    ssmmessages     = length(aws_vpc_endpoint.ssmmessages) > 0 ? aws_vpc_endpoint.ssmmessages[0].id : ""
    ec2messages     = length(aws_vpc_endpoint.ec2messages) > 0 ? aws_vpc_endpoint.ec2messages[0].id : ""
    bedrock_runtime = length(aws_vpc_endpoint.bedrock_runtime) > 0 ? aws_vpc_endpoint.bedrock_runtime[0].id : ""
  }
}

output "s3_gateway_route_table_ids" {
  description = "Route table IDs used for the S3 gateway endpoint (same as input)."
  value       = var.route_table_ids
}