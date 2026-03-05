// src/terraform/modules/vpc/main.tf
// NAT-free, dual-stack VPC module compatible with OpenTofu v1.11.5 and hashicorp/aws v6.x.
// - Exactly two private dual-stack subnets (one per AZ).
// - Egress-only IGW for IPv6.
// - No NAT gateways.

variable "vpc_cidr" {
  type        = string
  description = "Primary IPv4 CIDR for the VPC (recommend /19 or /20)."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "List of exactly two IPv4 CIDRs for private subnets (one per AZ)."
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly 2 CIDRs (one per AZ)."
  }
}

variable "assign_ipv6_cidr_block" {
  type        = bool
  description = "Request AWS-provided IPv6 CIDR for the VPC (true for dual-stack)."
  default     = true
}

variable "enable_ipv6" {
  type        = bool
  description = "Project invariant: IPv6 must be enabled (dual-stack)."
  default     = true
  validation {
    condition     = var.enable_ipv6 == true
    error_message = "enable_ipv6 must be true for this NAT-free dual-stack architecture."
  }
}

variable "tags" {
  type        = map(string)
  description = "Map of tags to apply to VPC and subnets."
  default     = {}
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  subnet_count = length(var.private_subnet_cidrs)
  name_tag     = lookup(var.tags, "Name", "agentops-vpc")
  env_tag      = lookup(var.tags, "Environment", "prod")
}

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = var.assign_ipv6_cidr_block

  tags = merge(
    { "Name" = local.name_tag, "Environment" = local.env_tag },
    var.tags
  )
}

# Create private subnets: explicit IPv4 cidr (from input) and deterministic IPv6 cidr carved from VPC IPv6 block.
resource "aws_subnet" "private" {
  count = local.subnet_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  # carve a /64 from the VPC-provided IPv6 /56 using cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, count.index)
  # aws_vpc.this.ipv6_cidr_block is provided by AWS when assign_generated_ipv6_cidr_block = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, count.index)
  assign_ipv6_address_on_creation = true

  tags = merge(
    {
      Name        = "agentops-private-${local.azs[count.index]}"
      Environment = local.env_tag
    },
    var.tags
  )
}

# Private route table (attach IPv6 default route to egress-only IGW)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge({ "Name" = "agentops-private-rt", "Environment" = local.env_tag }, var.tags)
}

resource "aws_egress_only_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge({ "Name" = "agentops-egress-only-igw", "Environment" = local.env_tag }, var.tags)
}

# IPv6 default route via egress-only IGW
resource "aws_route" "ipv6_egress" {
  route_table_id              = aws_route_table.private.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this.id

  depends_on = [aws_egress_only_internet_gateway.this]
}

# Associate route table with each private subnet
resource "aws_route_table_association" "private_assoc" {
  count = local.subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Outputs
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ, order matches aws_availability_zones slice(0,2))"
  value       = [for s in aws_subnet.private : s.id]
}

output "private_subnet_ipv4_cidrs" {
  description = "IPv4 CIDRs of private subnets"
  value       = [for s in aws_subnet.private : s.cidr_block]
}

output "private_subnet_ipv6_cidrs" {
  description = "IPv6 CIDRs assigned to private subnets (carved from VPC IPv6 block)"
  value       = [for s in aws_subnet.private : s.ipv6_cidr_block]
}

output "ipv6_cidr_block" {
  description = "VPC IPv6 CIDR block (if assigned by AWS). May be computed after apply."
  value       = aws_vpc.this.ipv6_cidr_block
}

output "egress_only_igw_id" {
  description = "Egress-only IGW ID"
  value       = aws_egress_only_internet_gateway.this.id
}

output "availability_zones" {
  description = "Two AZs selected"
  value       = local.azs
}