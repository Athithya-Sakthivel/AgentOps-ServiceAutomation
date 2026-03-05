// modules/vpc.tf
// Executable OpenTofu/Terraform module compatible with OpenTofu v1.11.5 and hashicorp/aws provider 6.x (>=6.34.0).
// Produces a dual-stack, NAT-free VPC with exactly two private subnets (one per AZ), an egress-only IGW for IPv6,
// route tables and associations. Do not add NAT gateways in this module (project invariant).

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

# Use two AZs deterministically
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  subnet_count = length(var.private_subnet_cidrs)  # should be 2
}

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = var.assign_ipv6_cidr_block
  tags = merge({"Name" = "${var.tags["Name"] != null ? var.tags["Name"] : "agentops-vpc"}}, var.tags)
}

# Wait for AWS to allocate the IPv6 block (if enabled) — subnet IPv6 cidrs derive from this.
# Create private subnets: one per AZ using provided IPv4 CIDRs and derived IPv6 /64s from the VPC /56.
resource "aws_subnet" "private" {
  count = local.subnet_count

  vpc_id                             = aws_vpc.this.id
  cidr_block                         = var.private_subnet_cidrs[count.index]
  availability_zone                  = local.azs[count.index]
  map_public_ip_on_launch            = false
  assign_ipv6_address_on_creation    = true
  ipv6_cidr_block                    = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, count.index) # derives /64s from /56

  tags = merge(
    {
      Name        = "agentops-private-${local.azs[count.index]}"
      Environment = var.tags["Environment"] != null ? var.tags["Environment"] : "prod"
    },
    var.tags
  )
}

# Route table for private subnets (IPv6 route to egress-only IGW)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags = merge({"Name" = "agentops-private-rt"}, var.tags)
}

# Egress-only IGW for IPv6 (enables outbound IPv6 only)
resource "aws_egress_only_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge({"Name" = "agentops-egress-only-igw"}, var.tags)
}

# IPv6 default route to egress-only IGW
resource "aws_route" "ipv6_egress" {
  route_table_id               = aws_route_table.private.id
  ipv6_cidr_block              = "::/0"
  egress_only_internet_gateway_id = aws_egress_only_internet_gateway.this.id

  depends_on = [aws_egress_only_internet_gateway.this]
}

# Associate the private route table with each private subnet
resource "aws_route_table_association" "private_assoc" {
  count = local.subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Outputs
output "vpc_id" {
  description = "The ID of the VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (order corresponds to selected AZs)."
  value       = [for s in aws_subnet.private : s.id]
}

output "private_subnet_ipv4_cidrs" {
  description = "List of private subnet IPv4 CIDRs."
  value       = [for s in aws_subnet.private : s.cidr_block]
}

output "private_subnet_ipv6_cidrs" {
  description = "List of private subnet IPv6 CIDRs (/64 derived from VPC /56)."
  value       = [for s in aws_subnet.private : s.ipv6_cidr_block]
}

output "ipv6_cidr_block" {
  description = "The IPv6 CIDR block assigned to the VPC (AWS-provided /56)."
  value       = aws_vpc.this.ipv6_cidr_block
}

output "egress_only_igw_id" {
  description = "Egress-only Internet Gateway ID for IPv6 outbound."
  value       = aws_egress_only_internet_gateway.this.id
}

output "availability_zones" {
  description = "The two Availability Zones selected for this VPC/subnets."
  value       = local.azs
}