// src/terraform/main.tf
// Root composition: S3 backend placeholder + vpc module instantiation.
// Backend configured by run.sh via CLI -backend-config arguments.

terraform {
  backend "s3" {}
}

module "vpc" {
  source = "./modules/vpc"

  vpc_cidr               = var.vpc_cidr
  private_subnet_cidrs   = var.private_subnet_cidrs
  assign_ipv6_cidr_block = var.assign_ipv6_cidr_block
  enable_ipv6            = var.enable_ipv6
  tags                   = var.tags
}