terraform {
  required_version = ">= 1.11.5, < 2.0.0"           # OpenTofu/Terraform binary constraint
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.34.0, < 7.0.0"               # pin to aws provider 6.x series
    }
  }
}