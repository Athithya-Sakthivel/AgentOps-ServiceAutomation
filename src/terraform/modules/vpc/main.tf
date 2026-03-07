// src/terraform/modules/vpc/main.tf
// Stable VPC module with a single NAT gateway (AWS provider 6.x).
// - Creates VPC, one public subnet (derived), two private subnets (caller-provided).
// - Private subnets route IPv4 0.0.0.0/0 to the single NAT gateway.
// - No IPv6 configuration or resources present.

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_cidrs" {
  type = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly 2 CIDRs."
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
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)
  env_tag     = lookup(var.tags, "Environment", "prod")
  common_tags = merge({ Name = "agentops-vpc", Environment = local.env_tag }, var.tags)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = local.common_tags
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 250)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "agentops-public-${local.azs[0]}" })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, { Name = "agentops-private-${local.azs[count.index]}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "agentops-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "agentops-public-rt" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "agentops-private-rt" })
}

resource "aws_eip" "nat_allocation" {
  domain = "vpc"

  tags = merge(local.common_tags, { Name = "agentops-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat_allocation.id
  subnet_id     = aws_subnet.public.id

  tags = merge(local.common_tags, { Name = "agentops-natgw" })
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id

  depends_on = [aws_nat_gateway.this]
}

resource "aws_route_table_association" "private_assoc" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "private_route_table_ids" {
  value = [aws_route_table.private.id]
}

output "main_route_table_id" {
  value = aws_vpc.this.main_route_table_id
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}