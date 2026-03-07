# AgentOps-ServiceAutomation — Terraform / OpenTofu Infrastructure (Exact implementation)

## Purpose

This repository contains the complete, production-ready Infrastructure-as-Code that was implemented for the **AgentOps-ServiceAutomation** project. It provisions a private, dual-stack Amazon EKS cluster, container registries, VPC networking (NAT-free), VPC endpoints, least-privilege IAM primitives (split pre/post EKS), and remote OpenTofu/Terraform state.

Key tools used: OpenTofu([terraform OSS](https://opentofu.org/)) and Amazon Web Services. Ingress is terminated in-cluster and routed from the edge via Cloudflare.

---

## What is implemented (concise)

* Single AWS account, single VPC.
* Dual-stack VPC with IPv6 assigned and egress-only internet gateway for IPv6.
* Exactly two private subnets (one per AZ), no public subnets, no NAT gateways.
* VPC endpoints:

  * S3 (Gateway)
  * ECR (API and DKR) — Interface
  * STS — Interface
  * Bedrock runtime — Interface (conditional)
* ECR repositories with lifecycle policies for application images:

  * `agentops-frontend`, `agentops-inference`, `agentops-auth`, `agentops-cloudnativepg`, `agentops-postgresql`, `agentops-cloudflared`.
* IAM split into two modules:

  * `iam_pre_eks`: cluster role, node role, cluster autoscaler policy, CI ECR push policy, reference to EBS CSI managed policy ARN.
  * `iam_post_eks`: IRSA roles (EBS CSI, Cluster Autoscaler) created after EKS OIDC provider exists.
* EKS cluster (private API endpoint) with two managed node groups:

  * `system` (stateful workloads: Signoz, ClickHouse, Postgres)
  * `inference` (stateless inference & auth)
* Remote state: S3 bucket `agentops-tf-state-<ACCOUNT_ID>` and DynamoDB lock table `agentops-tf-lock-<ACCOUNT_ID>`.
* `run.sh` — idempotent backend bootstrap (creates bucket/table and runs `tofu init -backend-config=...`).

---

## File map (what each file implements)

```
src/terraform/
  versions.tf                # pinned OpenTofu & provider versions (required providers includes aws,tls)
  providers.tf               # aws provider block with default tags
  variables.tf               # all module inputs and invariants (enable_ipv6=true, no_nat=true)
  main.tf                    # root module composition (vpc, security, ecr, iam_pre_eks, endpoints, eks, iam_post_eks)
  outputs.tf                 # aggregated, stable outputs for CI/operators
  run.sh                     # state bootstrap script (S3 + DynamoDB + tofu init)
  staging.tfvars, prod.tfvars # environment non-secret overrides
  modules/
    vpc/                     # VPC, subnets, route tables, egress-only IGW
    security/                # node SG and VPC endpoints SG
    ecr/                     # ECR repositories + lifecycle policies
    iam_pre_eks/             # IAM roles/policies created before EKS
    endpoints/               # VPC endpoints (S3 gateway, ECR, STS, Bedrock)
    eks/                     # EKS cluster, OIDC provider, managed node groups
    iam_post_eks/            # IRSA roles created after EKS (trusts OIDC)
```

---

## Architecture summary (facts)

* VPC CIDR: configured via `var.vpc_cidr` (defaults in `variables.tf`); two `/20` private subnets are used by default.
* IPv6: `enable_ipv6 = true` is an enforced invariant; the VPC requests an AWS-provided IPv6 /56 and subnets carve /64s.
* No NAT: all outbound AWS API access occurs via VPC endpoints; node egress to public IPv4 is blocked by routing.
* EKS: private API, `endpoint_public_access = false`, `endpoint_private_access = true`.
* Node groups: EKS managed node groups use `node_role_arn` provided by `iam_pre_eks`.
* IRSA: policies are created in `iam_pre_eks`; IRSA roles that trust the cluster OIDC provider are created in `iam_post_eks` after EKS exists.

---
## Outputs (stable items exported at root)

* `vpc_id`
* `private_subnet_ids`
* `private_subnet_ipv4_cidrs`
* `private_subnet_ipv6_cidrs`
* `ipv6_cidr_block`
* `availability_zones`
* `node_security_group_id`
* `vpc_endpoints_security_group_id`
* `ecr_repository_urls` (map)
* `ecr_repository_arns` (map)
* `iam_cluster_role_arn`
* `iam_node_role_arn`
* `ebs_csi_irsa_role_arn`
* `cluster_autoscaler_irsa_role_arn`
* `eks_cluster_name`
* `eks_cluster_endpoint`
* `eks_cluster_ca_data`
* `eks_oidc_provider_arn`

Use `tofu output <name>` to retrieve values from the applied state.

---

## Security controls and guarantees (implemented)

* State bucket: versioning enabled; server-side encryption (AES256); public access block enforced.
* DynamoDB lock: table exists and is used for remote locking to prevent concurrent state writes.
* Network isolation: no public subnets; control plane private; only required VPC endpoints are provisioned.
* IAM least privilege:

  * Control plane uses `iam_pre_eks.cluster_role_arn`.
  * EC2 node role uses AWS managed policies: `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`.
  * EBS CSI uses AWS managed policy `arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy` (referenced).
  * Cluster Autoscaler and CI policies created and attached via IRSA roles after cluster OIDC is available.
* Pod-level access control: Kubernetes `NetworkPolicy` and service account scoping are expected to enforce pod-to-pod restrictions (databases run inside Kubernetes).

---

## Deterministic invariants (enforced in code)

* `enable_ipv6 = true`
* `no_nat = true`
* Exactly two private subnets (validation in `variables.tf`)
* Two AZs selected (slice of available AZs)
* `src/terraform/run.sh` bootstrapping is idempotent

---

## Verification checklist (commands)

* Backend and init: `bash src/terraform/run.sh --create --env staging`
* Validate config: `tofu validate`
* Plan: `tofu plan -var-file=src/terraform/staging.tfvars`
* Inspect outputs: `tofu output vpc_id`, `tofu output ecr_repository_urls`, `tofu output eks_cluster_endpoint`
* Confirm endpoints: `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$(tofu output -raw vpc_id)`

---

## Change-control notes

* All environment-specific, non-secret values live in `staging.tfvars` and `prod.tfvars`.
* Secrets and credentials must be provided via an external secrets store or CI secret injection; they are not stored in `*.tfvars`.
* Module outputs are the public contract; internal module variables and resources may change as long as root outputs remain stable.

---

## Contact points in code (where to look)

* VPC and subnets: `src/terraform/modules/vpc/main.tf`
* Security groups: `src/terraform/modules/security/main.tf`
* VPC endpoints: `src/terraform/modules/endpoints/main.tf`
* IAM pre/post EKS: `src/terraform/modules/iam_pre_eks/main.tf`, `src/terraform/modules/iam_post_eks/main.tf`
* ECR repos: `src/terraform/modules/ecr/main.tf`
* EKS cluster & node groups: `src/terraform/modules/eks/main.tf`
* State bootstrap: `src/terraform/run.sh`

---

This README documents the implemented infrastructure and operational workflow as present in the repository.
