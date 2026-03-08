# AgentOps-ServiceAutomation — Terraform / OpenTofu Infrastructure

## Purpose

This repository contains the Infrastructure-as-Code used to provision the cloud infrastructure for the **AgentOps-ServiceAutomation** project.

The infrastructure is defined using **OpenTofu (Terraform-compatible)** and deployed to **Amazon Web Services (AWS)**. It provisions networking, container registries, IAM roles, and a production-ready **Amazon EKS Kubernetes cluster**.

Ingress traffic is routed from the edge through **Cloudflare**, with services running inside the Kubernetes cluster.

---

# What the infrastructure provisions

The repository provisions the following AWS resources:

* Single AWS account environment
* Dedicated **VPC networking layer**
* Private subnets distributed across **two Availability Zones**
* Internet access through a **single NAT Gateway**
* **Amazon EKS cluster** with managed worker node groups
* **Amazon ECR repositories** for container images
* **IAM roles and policies** for Kubernetes workloads
* **Remote Terraform/OpenTofu state storage**
* Supporting security groups and routing infrastructure

The infrastructure is designed to be reproducible and environment-isolated.

---

# Core components

## VPC networking

The infrastructure creates a dedicated Virtual Private Cloud with:

* Configurable VPC CIDR block
* Two private subnets (one per availability zone)
* One public subnet used for the NAT Gateway
* Internet Gateway for outbound traffic
* Single NAT Gateway used by private workloads
* Route tables connecting private workloads to the NAT gateway

Kubernetes worker nodes run inside the private subnets.

---

## Amazon EKS cluster

The system provisions an **Amazon Elastic Kubernetes Service (EKS)** cluster with:

* Private worker nodes
* Managed node groups
* IAM roles for cluster and node operation
* OIDC provider for Kubernetes service account IAM roles (IRSA)

Two node groups are deployed:

**System node group**

Runs cluster-level services and stateful workloads such as:

* Observability stack
* Databases
* Storage controllers

**Inference node group**

Runs stateless workloads such as:

* inference services
* API components
* authentication services

---

## Amazon ECR repositories

Container images are stored in dedicated ECR repositories.

Repositories created by the infrastructure include:

* `agentops-frontend`
* `agentops-inference`
* `agentops-auth`
* `agentops-cloudnativepg`
* `agentops-postgresql`
* `agentops-cloudflared`

Each repository includes lifecycle policies for automatic cleanup of unused images.

---

## IAM design

IAM configuration is split into two stages to respect resource dependencies.

### Pre-EKS IAM

Created before the Kubernetes cluster:

* EKS cluster IAM role
* Worker node IAM role
* Cluster Autoscaler policy
* CI image push policy for ECR
* Reference to the EBS CSI managed policy

### Post-EKS IAM

Created after the cluster exists:

* IAM roles for Kubernetes service accounts
* IRSA trust relationships using the cluster OIDC provider

These roles enable Kubernetes workloads to access AWS services securely.

---

## Remote Terraform / OpenTofu state

Infrastructure state is stored remotely to support collaboration and safe deployments.

Resources created automatically:

**S3 bucket**

```
agentops-tf-state-<ACCOUNT_ID>
```

Features:

* Versioning enabled
* Server-side encryption
* Public access blocked

**DynamoDB table**

```
agentops-tf-lock-<ACCOUNT_ID>
```

Used for Terraform/OpenTofu state locking to prevent concurrent modifications.

---

# Repository structure

```
src/terraform/
  versions.tf
  providers.tf
  variables.tf
  main.tf
  outputs.tf
  run.sh
  staging.tfvars
  prod.tfvars

  modules/
    vpc/
    security/
    ecr/
    iam_pre_eks/
    eks/
    iam_post_eks/
```

---

# Module overview

## VPC module

Creates:

* VPC
* Subnets
* Internet Gateway
* NAT Gateway
* Route tables
* Subnet associations

---

## Security module

Creates:

* Kubernetes node security group
* Security group rules required by the EKS control plane

---

## ECR module

Creates:

* Application container repositories
* Image lifecycle policies

---

## IAM modules

### `iam_pre_eks`

Creates roles required before cluster creation.

### `iam_post_eks`

Creates IAM roles that depend on the EKS OIDC provider.

---

## EKS module

Creates:

* EKS cluster
* OIDC provider
* managed node groups
* cluster security groups

---

# Outputs

After deployment, the root module exposes key infrastructure values.

Examples:

* `vpc_id`
* `private_subnet_ids`
* `availability_zones`
* `node_security_group_id`
* `ecr_repository_urls`
* `ecr_repository_arns`
* `iam_cluster_role_arn`
* `iam_node_role_arn`
* `eks_cluster_name`
* `eks_cluster_endpoint`
* `eks_cluster_ca_data`
* `eks_oidc_provider_arn`

Retrieve outputs using:

```
tofu output <name>
```

Example:

```
tofu output vpc_id
```

---

# Deployment workflow

## Bootstrap infrastructure state

```
bash src/terraform/run.sh --create --env staging
```

This script:

1. Creates the S3 backend bucket if it does not exist
2. Creates the DynamoDB state lock table
3. Runs `tofu init` with backend configuration

---

## Validate configuration

```
tofu validate
```

---

## Plan infrastructure

```
tofu plan -var-file=src/terraform/staging.tfvars
```

---

## Apply infrastructure

```
tofu apply -var-file=src/terraform/staging.tfvars
```

---

# Configuration management

Environment configuration is stored in:

```
staging.tfvars
prod.tfvars
```

These files contain **non-secret environment parameters**.

Secrets must be injected through:

* CI/CD environment variables
* external secret management systems

Sensitive values must not be committed to the repository.

---

# Change management

Infrastructure changes should follow these guidelines:

* All modifications must be made through Terraform/OpenTofu
* Environment variables must remain isolated per environment
* Module outputs serve as the public interface between components
* Internal module implementations may change as long as root outputs remain stable

---

# Operational reference

Key implementation locations:

* VPC networking
  `src/terraform/modules/vpc/main.tf`

* Security groups
  `src/terraform/modules/security/main.tf`

* ECR repositories
  `src/terraform/modules/ecr/main.tf`

* IAM roles
  `src/terraform/modules/iam_pre_eks/main.tf`
  `src/terraform/modules/iam_post_eks/main.tf`

* Kubernetes cluster
  `src/terraform/modules/eks/main.tf`

* State bootstrap script
  `src/terraform/run.sh`

---

This document describes the infrastructure implemented in the repository and the operational workflow used to deploy and maintain it.
