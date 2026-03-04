# AWS Infrastructure Architecture (AgentOps-ServiceAutomation)

This repository implements a single-account, AWS-focused infrastructure using [Opentofu](https://opentofu.org/) to provision a private Amazon Elastic Kubernetes Service cluster with two purpose-built node pools (system, inference), container registries via Amazon Elastic Container Registry, and remote state stored in Amazon S3 with state locking through Amazon DynamoDB.

OpenTofu is used instead of Terraform to ensure long-term licensing stability, full open governance, and elimination of vendor lock-in risk while remaining configuration-compatible with the Terraform ecosystem. This preserves deterministic IaC workflows without exposure to future license changes.

The architecture is intentionally minimal:

* No public subnets
* No NAT gateways
* IPv6 enabled as a constant
* Conservative VPC interface and gateway endpoints to support a NAT-free design

AWS Load Balancers are deliberately avoided. Ingress is handled externally (via Cloudflare Tunnel) and terminated inside the cluster, eliminating dependency on AWS ALB/NLB resources. This reduces recurring load balancer costs, avoids AWS-specific ingress coupling, and preserves cloud-agnostic portability at the networking layer. The cluster therefore does not rely on AWS-managed public ingress components.

The design prioritizes:

* Determinism (pinned versions, remote state, locking)
* Operational simplicity (single account, flat structure, minimal moving parts)
* Cost-efficiency at scale (no NAT Gateway, no ALB baseline cost)
* Least-privilege security (private EKS, scoped IAM roles, minimal endpoints)

The result is a tightly scoped, production-grade baseline optimized for controlled growth without premature abstraction or unnecessary managed dependencies.

Key operational characteristics:

* Private cluster only (Cloudflare Tunnel-based ingress)
* Two AZs, two private (dual-stack) subnets (one per AZ)
* No NAT gateways — VPC endpoints for required AWS services
* Two node pools: `system` (stateful, stable), `inference` (stateless, autoscaled)
* Terraform state per account: `agentops-tf-state-<ACCOUNT_ID>` + `agentops-tf-lock-<ACCOUNT_ID>`

---

## Files & responsibilities

`src/terraform/` (top level)
* `run.sh` — deterministic, idempotent bootstrap script that creates S3 state bucket + DynamoDB lock table and writes `backend.hcl`. Script enforces audit logs and safety checks.
* `versions.tf` — pins OpenTofu and provider constraints; ensures reproducible toolchain.
* `providers.tf` — provider blocks (AWS region, default tags).
* `main.tf` — orchestration and top-level composition of modules; includes an empty backend stanza placeholder intended to be configured by generated `backend.hcl`.
* `variables.tf` — all deterministic inputs and environment constants (e.g., `enable_ipv6 = true`).
* `outputs.tf` — stable outputs consumed by CI and operators (vpc_id, subnet ids, cluster endpoint, ECR URLs).
* `modules/` — modularized resources (see below).

  * `modules/vpc.tf` — VPC, private subnets, route tables, IGW for IPv6, egress-only IGW, and CIDR sizing constants.
  * `modules/security.tf` — security groups, minimal IAM instance policies attached via node roles, and baseline network ACL guidance.
  * `modules/endpoints.tf` — VPC endpoints: interface endpoints for `ecr.api`, `ecr.dkr`, `sts`, `bedrock`; gateway endpoint for `s3`; optional SSM endpoint.
  * `modules/eks.tf` — EKS cluster, OIDC provider, node groups (system + inference), addons (CNI, EBS CSI, kube-addons).
  * `modules/iam.tf` — IAM roles and policies: cluster role, node role, EBS CSI IRSA role, cluster autoscaler IRSA role, inference IRSA role (Bedrock invocation), CI ECR push role.
  * `modules/ecr.tf` — ECR repositories and lifecycle policies.
* `staging.tfvars`, `prod.tfvars` — environment variable sets with non-secret parameters.
* `README.md` — (this file) concise professional documentation. 

---

## Architecture (textual)

1. **VPC**

   * Single VPC with a sufficiently large CIDR block (recommendation: `/19` or `/20`) to avoid ENI/pod IP exhaustion.
   * Two private, dual-stack subnets (one per AZ). No public subnets. IPv6 enabled; egress handled via egress-only internet gateway for IPv6.
   * No NAT gateways.

2. **Networking endpoints**

   * Gateway endpoint: `s3` (free).
   * Interface endpoints (one per AZ): `ecr.api`, `ecr.dkr`, `sts`. Add `bedrock-runtime` interface endpoint only if workloads call Bedrock directly.
   * Optional: `ssm` endpoint for management/debug.

3. **EKS**

   * One EKS cluster (private endpoint).
   * Two managed node groups:

     * `system` — for stateful/system apps (Signoz, ClickHouse, PostgreSQL). Stable size, taints to ensure placement, no autoscaling-to-zero.
     * `inference` — for FastAPI and auth service. Autoscaling permitted (HPA → Cluster Autoscaler). No GPUs; Bedrock handles heavy model compute.
   * Addons: VPC CNI, EBS CSI, core DNS, kube-proxy, EBS CSI driver enabled by default.

4. **Storage & Registry**

   * ECR: `frontend`, `backend` repositories with lifecycle policies for cleanup.
   * Persistent storage: EBS volumes (gp3) provisioned by CSI for Postgres and ClickHouse.

5. **State management**

   * Remote state bucket per account: `agentops-tf-state-<ACCOUNT_ID>`.
   * DynamoDB table for locks: `agentops-tf-lock-<ACCOUNT_ID>`.
   * `run.sh` bootstraps these resources idempotently and writes `backend.hcl` per environment.

6. **Ingress**

   * Cloudflare Tunnel (cloudflared) deployed inside cluster (DaemonSet or small HA ReplicaSet). No public LB or public nodes required.

---

## Control flow — lifecycle & operations

1. **Bootstrap (single step, idempotent)**

   * Run `run.sh --create` from operator workstation or CI runner. It:

     * Detects account ID via `aws sts get-caller-identity`.
     * Ensures S3 bucket `agentops-tf-state-<ACCOUNT_ID>` exists with versioning + SSE + public access block.
     * Ensures DynamoDB table `agentops-tf-lock-<ACCOUNT_ID>` exists.
     * Generates `src/terraform/stacks/<ENV>/backend.hcl` with the correct `bucket`, `key`, `dynamodb_table`, `region`, `encrypt=true`.
     * Runs `tofu init -backend-config=...` in stacks dir (non-interactive).
   * Idempotence: script checks existence before creating; retries for eventual consistency.

2. **Plan & apply**

   * Standard workflow:

     * `tofu plan -var-file=prod.tfvars` (CI or operator)
     * `tofu apply -var-file=prod.tfvars` (manual approval via CI gate)
   * Terraform modules are deterministic; `variables.tf` contains stable inputs.

3. **CI integration**

   * CI uses `ci-ecr-push-role` (OIDC) to authenticate and push images to ECR.
   * After successful image push, deployment step triggers a `kubectl/helm` rollout (outside Terraform) or a GitOps agent (managed separately).

4. **Scaling**

   * Pod scaling: HPA (CPU or custom metrics).
   * Node scaling: Cluster Autoscaler configured with conservative flags (e.g., `--max-node-provision-time=10m`, `--expander=least-waste`).
   * Ensure prefix delegation / CNI settings are tuned to avoid IP exhaustion.

5. **Delete**

   * `run.sh --delete` removes state objects under the environment prefix and deletes DynamoDB lock table; S3 bucket preserved to avoid accidental full bucket deletion.

---

## Invariants and design rationales

These are hard guarantees and assumptions enforced by the configuration and operational process:

1. **No NAT, IPv6 always enabled**

   * Rationale: reduce cost, simplify routing, lower blast radius.
   * Guarantee: all necessary AWS services reachable via VPC endpoints; public internet access from nodes is prevented by design.

2. **Two AZs for failure tolerance**

   * Rationale: survive a single AZ failure while limiting cross-AZ resource and operational complexity.
   * Guarantee: cluster remains operable with at least one AZ degraded.

3. **Two private subnets only**

   * Rationale: minimize network surface and avoid unnecessary public footprint; Cloudflare Tunnel provides ingress.
   * Guarantee: no public subnets exist, preventing accidental exposure.

4. **Least-privilege IAM**

   * Rationale: minimize credentials blast radius.
   * Guarantee: each role has narrowly scoped policies (cluster role, node role, EBS CSI IRSA, cluster autoscaler IRSA, inference IRSA for Bedrock calls, CI ECR push role).

5. **Idempotent state bootstrap**

   * Rationale: safe multi-operator or CI invocation.
   * Guarantee: `run.sh` will not recreate resources that already exist and will log all operations.

6. **Separation of concerns**

   * Terraform manages cloud infrastructure only; Kubernetes manifests and runtime workloads are deployed outside Terraform (GitOps or CI). This reduces state churn and secret handling in Terraform state.

7. **Predictability**

   * Rationale: prefer managed node groups + Cluster Autoscaler over Karpenter to reduce operational complexity.
   * Guarantee: node provisioning is deterministic by instance types in node group configs.

---

## Security & compliance controls

* S3 state bucket: versioning, SSE (AES256 or KMS if required), public access block.
* DynamoDB lock table: server-side locking to prevent concurrent Terraform writes.
* OIDC for IRSA: single cluster OIDC provider; IRSA roles limited to service account scope.
* IAM least privilege: narrow ECR push policy for CI; Bedrock invocation rights scoped to required model ARNs.
* Network isolation: no public subnets, private EKS endpoint if desired, Cloudflare Tunnel for managed ingress.
* Auditability: Terraform plans and `run.sh` logs retained in CI artifacts for HR/audit review.

---
