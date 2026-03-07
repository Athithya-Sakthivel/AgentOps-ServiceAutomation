// src/terraform/modules/vpc/main.tf
// NAT-free, dual-stack VPC module compatible with OpenTofu v1.11.5 and hashicorp/aws v6.x.

variable "vpc_cidr" {
  type        = string
  description = "Primary IPv4 CIDR for the VPC."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Two IPv4 CIDRs for private subnets."
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly 2 CIDRs."
  }
}

variable "assign_ipv6_cidr_block" {
  type    = bool
  default = true
}

variable "enable_ipv6" {
  type    = bool
  default = true
  validation {
    condition     = var.enable_ipv6 == true
    error_message = "enable_ipv6 must be true."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  subnet_count = length(var.private_subnet_cidrs)
  env_tag      = lookup(var.tags, "Environment", "prod")
}

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = var.assign_ipv6_cidr_block

  tags = merge({ Name = "agentops-vpc", Environment = local.env_tag }, var.tags)
}

resource "aws_subnet" "private" {
  count = local.subnet_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, count.index)
  assign_ipv6_address_on_creation = true

  tags = merge({ Name = "agentops-private-${local.azs[count.index]}", Environment = local.env_tag }, var.tags)
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge({ Name = "agentops-private-rt", Environment = local.env_tag }, var.tags)
}

resource "aws_egress_only_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge({ Name = "agentops-egress-only-igw", Environment = local.env_tag }, var.tags)
}

resource "aws_route" "ipv6_egress" {
  route_table_id              = aws_route_table.private.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.this.id
}

resource "aws_route_table_association" "private_assoc" {
  count = local.subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "private_subnet_ipv4_cidrs" {
  value = [for s in aws_subnet.private : s.cidr_block]
}

output "private_subnet_ipv6_cidrs" {
  value = [for s in aws_subnet.private : s.ipv6_cidr_block]
}

output "ipv6_cidr_block" {
  value = aws_vpc.this.ipv6_cidr_block
}

output "egress_only_igw_id" {
  value = aws_egress_only_internet_gateway.this.id
}

output "availability_zones" {
  value = local.azs
}

output "main_route_table_id" {
  value = aws_vpc.this.main_route_table_id
}

# Convenience: return the private route table IDs as a list (single element today)
output "private_route_table_ids" {
  value = [aws_route_table.private.id]
}