// src/terraform/modules/ecr/main.tf
// ECR repositories for AgentOps-ServiceAutomation
// Compatible with OpenTofu v1.11.5 and hashicorp/aws v6.x (resource/argument names conform to provider v6.x docs).
// Creates explicit repositories (no placeholders) and lifecycle policies to retain a bounded number of images.

variable "tags" {
  description = "Tags applied to all ECR repositories created by this module."
  type        = map(string)
  default     = {}
}

locals {
  merged_tags = merge({ ManagedBy = "agentops-serviceautomation" }, var.tags)
}

############################
# agentops-frontend
############################
resource "aws_ecr_repository" "agentops_frontend" {
  name                 = "agentops-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.merged_tags
}

resource "aws_ecr_lifecycle_policy" "agentops_frontend" {
  repository = aws_ecr_repository.agentops_frontend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# agentops-inference
############################
resource "aws_ecr_repository" "agentops_inference" {
  name                 = "agentops-inference"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.merged_tags
}

resource "aws_ecr_lifecycle_policy" "agentops_inference" {
  repository = aws_ecr_repository.agentops_inference.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# agentops-auth
############################
resource "aws_ecr_repository" "agentops_auth" {
  name                 = "agentops-auth"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.merged_tags
}

resource "aws_ecr_lifecycle_policy" "agentops_auth" {
  repository = aws_ecr_repository.agentops_auth.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# agentops-cloudnativepg
############################
resource "aws_ecr_repository" "agentops_cloudnativepg" {
  name                 = "agentops-cloudnativepg"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.merged_tags
}

resource "aws_ecr_lifecycle_policy" "agentops_cloudnativepg" {
  repository = aws_ecr_repository.agentops_cloudnativepg.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# agentops-postgresql
############################
resource "aws_ecr_repository" "agentops_postgresql" {
  name                 = "agentops-postgresql"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.merged_tags
}

resource "aws_ecr_lifecycle_policy" "agentops_postgresql" {
  repository = aws_ecr_repository.agentops_postgresql.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# agentops-cloudflared
############################
resource "aws_ecr_repository" "agentops_cloudflared" {
  name                 = "agentops-cloudflared"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.merged_tags
}

resource "aws_ecr_lifecycle_policy" "agentops_cloudflared" {
  repository = aws_ecr_repository.agentops_cloudflared.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

############################
# Outputs
############################
output "repository_url_map" {
  description = "Map of repository name -> repository URL (https://<account>.dkr.ecr.<region>.amazonaws.com/<name>)"
  value = {
    "agentops-frontend"      = aws_ecr_repository.agentops_frontend.repository_url
    "agentops-inference"     = aws_ecr_repository.agentops_inference.repository_url
    "agentops-auth"          = aws_ecr_repository.agentops_auth.repository_url
    "agentops-cloudnativepg" = aws_ecr_repository.agentops_cloudnativepg.repository_url
    "agentops-postgresql"    = aws_ecr_repository.agentops_postgresql.repository_url
    "agentops-cloudflared"   = aws_ecr_repository.agentops_cloudflared.repository_url
  }
}

output "repository_arn_map" {
  description = "Map of repository name -> repository ARN"
  value = {
    "agentops-frontend"      = aws_ecr_repository.agentops_frontend.arn
    "agentops-inference"     = aws_ecr_repository.agentops_inference.arn
    "agentops-auth"          = aws_ecr_repository.agentops_auth.arn
    "agentops-cloudnativepg" = aws_ecr_repository.agentops_cloudnativepg.arn
    "agentops-postgresql"    = aws_ecr_repository.agentops_postgresql.arn
    "agentops-cloudflared"   = aws_ecr_repository.agentops_cloudflared.arn
  }
}