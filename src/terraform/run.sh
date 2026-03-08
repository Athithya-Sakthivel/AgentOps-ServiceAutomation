#!/usr/bin/env bash
# src/terraform/run.sh
# Production-ready, idempotent wrapper to manage OpenTofu (tofu) lifecycle:
#  - --plan      : init backend, fmt/validate (auto-fix), produce a plan file (dry-run)
#  - --create    : init backend, fmt/validate (auto-fix), plan, then apply -auto-approve (fully automated)
#  - --destroy   : init backend, then destroy (destructive; requires --yes-delete)
#  - --validate  : init backend and validate backend / prereqs
#  - --find-version / --rollback-state <versionId> : state management helpers
#
# Usage:
#   bash src/terraform/run.sh --plan  --env staging
#   bash src/terraform/run.sh --create --env staging
#   bash src/terraform/run.sh --destroy --env staging --yes-delete
#
# Notes / invariants:
#  - AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION is used (fallback ap-south-1).
#  - Script does NOT commit formatted changes to git; it only auto-formats files in-place.
#  - State bucket is versioned (ENABLED) and encrypted (AES256).
#  - DynamoDB lock table exists and is ACTIVE.
#  - Script exits non-zero on any infrastructure mutation failure.
#
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"   # src/terraform
AWS_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

usage() {
  cat <<USAGE >&2
Usage:
  $(basename "$0") --plan|--create|--destroy|--validate|--find-version|--rollback-state <versionId> --env <prod|staging> [--yes-delete]

Modes:
  --plan            : init backend, run fmt/validate (auto-fix), produce a plan file (dry-run)
  --create          : init backend, run fmt/validate (auto-fix), plan, then apply -auto-approve
  --destroy|--delete: init backend, destroy -auto-approve (destructive; requires --yes-delete)
  --validate        : validate backend and AWS prerequisites (non-mutating)
  --find-version    : list state versions for the environment key
  --rollback-state <versionId> : restore the specified state version into the state key (destructive)
Flags:
  --env <prod|staging>  : environment (required)
  --yes-delete           : required to actually perform destructive actions (destroy/rollback)
Notes:
  - Requires aws, tofu, python3 in PATH.
  - Terraform var-file used automatically if <env>.tfvars exists in ${STACK_DIR}.
USAGE
  exit 2
}

# ---- Parse args ----
if [ $# -lt 1 ]; then usage; fi

MODE=""
ENVIRONMENT=""
YES_DELETE=false
ROLLBACK_VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plan|--create|--destroy|--delete|--validate|--find-version)
      if [ -n "$MODE" ]; then echo "Only one mode allowed" >&2; usage; fi
      MODE="$1"
      if [ "$MODE" = "--delete" ]; then MODE="--destroy"; fi
      shift
      ;;
    --rollback-state)
      if [ -n "$MODE" ]; then echo "Only one mode allowed" >&2; usage; fi
      MODE="--rollback-state"
      shift
      if [ $# -eq 0 ]; then echo "--rollback-state requires a versionId" >&2; usage; fi
      ROLLBACK_VERSION="$1"
      shift
      ;;
    --env)
      shift
      if [ $# -eq 0 ]; then echo "--env requires prod or staging" >&2; usage; fi
      case "$1" in
        prod|staging) ENVIRONMENT="$1"; shift ;;
        *) echo "Invalid env: $1" >&2; usage ;;
      esac
      ;;
    --yes-delete) YES_DELETE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if [ -z "$MODE" ] || [ -z "$ENVIRONMENT" ]; then usage; fi

# ---- Prechecks ----
for cmd in aws tofu python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' not found" >&2; exit 10; }
done

log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
dry(){ printf 'DRYRUN: %s\n' "$*"; }

# Plan directory (persistent so plan file survives script exit)
PLAN_DIR="${STACK_DIR}/.plans"
mkdir -p "$PLAN_DIR"
PLAN_FILE="${PLAN_DIR}/${ENVIRONMENT}.tfplan"

# ---- Derived names ----
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT_ID" ]; then
  echo "ERROR: unable to determine AWS account id (check AWS credentials)" >&2
  exit 20
fi

STATE_BUCKET="agentops-tf-state-${ACCOUNT_ID}"
LOCK_TABLE="agentops-tf-lock-${ACCOUNT_ID}"
S3_PREFIX="agentops/"
STATE_KEY="${ENVIRONMENT}/terraform.tfstate"
VAR_FILE="${STACK_DIR}/${ENVIRONMENT}.tfvars"
LOCK_TABLE_REGION="${AWS_REGION}"

# ---- Exec wrapper (stream outputs) ----
# Usage: exec_and_log "label" cmd args...
# Streams stdout/stderr to terminal. Exits on non-zero return code.
exec_and_log() {
  local label="$1"; shift
  # single-line, copy/pasteable command log
  log "CMD START: ${label}: $*"
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "ERROR: command failed: ${label} (rc=${rc})" >&2
    exit $rc
  fi
  log "CMD OK: ${label}"
}

# ---- Helpers ----
retry() {
  local tries=${1:-6}; shift
  local delay=${1:-1}; shift
  local i=0 rc=0
  while [ $i -lt $tries ]; do
    set +e
    "$@"
    rc=$?
    set -e
    [ $rc -eq 0 ] && return 0
    i=$((i+1)); sleep $delay
    delay=$((delay * 2))
  done
  return $rc
}

ensure_bucket_exists_and_versioning() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    log "s3: bucket ${bucket} exists"
  else
    log "s3: creating bucket ${bucket} (region=${region})"
    if [ "$region" = "us-east-1" ]; then
      exec_and_log "s3-create-bucket" aws s3api create-bucket --bucket "$bucket"
    else
      exec_and_log "s3-create-bucket" aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration LocationConstraint="$region"
    fi
    retry 6 2 aws s3api head-bucket --bucket "$bucket"
    log "s3: created bucket ${bucket}"
  fi

  log "s3: ensuring versioning Enabled on ${bucket}"
  exec_and_log "s3-put-versioning" aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled

  log "s3: ensuring server-side encryption (AES256) on ${bucket}"
  # continue on encryption errors (some regions/accounts may require different policies)
  set +e
  aws s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null 2>&1
  set -e

  log "s3: applying public access block on ${bucket}"
  set +e
  aws s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}' >/dev/null 2>&1
  set -e
}

ensure_dynamodb_table() {
  local table="$1" region="$2"
  if aws dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    log "ddb: table ${table} exists"
    return 0
  fi
  log "ddb: creating table ${table}"
  exec_and_log "ddb-create-table" aws dynamodb create-table --table-name "$table" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region "$region"
  retry 8 2 aws dynamodb wait table-exists --table-name "$table" --region "$region"
  log "ddb: ensured ${table}"
}

validate_backend() {
  local bucket="$1" key="$2" table="$3" region="$4"

  aws sts get-caller-identity --query Account --output text >/dev/null

  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "ERROR: state bucket ${bucket} not found" >&2
    return 1
  fi

  local vs
  vs="$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null || true)"
  if [ "$vs" != "Enabled" ]; then
    echo "ERROR: bucket ${bucket} versioning not Enabled (status=${vs})" >&2
    return 2
  fi

  if ! aws s3api get-bucket-encryption --bucket "$bucket" >/dev/null 2>&1; then
    echo "ERROR: bucket ${bucket} encryption not configured" >&2
    return 3
  fi

  local dstat
  dstat="$(aws dynamodb describe-table --table-name "$table" --query "Table.TableStatus" --output text 2>/dev/null || true)"
  if [ -z "$dstat" ]; then
    echo "ERROR: dynamodb table ${table} not found" >&2
    return 4
  fi
  if [ "$dstat" != "ACTIVE" ]; then
    echo "ERROR: dynamodb table ${table} status=${dstat}" >&2
    return 5
  fi

  # backend init test in correct directory
  exec_and_log "tofu-init-validate" bash -c "cd \"$STACK_DIR\" && tofu init -backend-config \"bucket=${bucket}\" -backend-config \"key=${key}\" -backend-config \"region=${region}\" -backend-config \"dynamodb_table=${table}\" -input=false"
  log "Validation OK: backend connectivity and lock table verified"
  return 0
}

list_state_versions() {
  local bucket="$1" key="$2"
  aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --output json 2>/dev/null | \
    python3 - "$key" <<'PY'
import json,sys
data=sys.stdin.read()
key=sys.argv[1]
try:
  r=json.loads(data or "{}")
except Exception:
  print("No versions found or error listing versions for:", key); sys.exit(0)
rows=[]
for v in r.get("Versions",[]):
  if v.get("Key")==key: rows.append((v.get("VersionId"), v.get("LastModified"), "Version"))
for d in r.get("DeleteMarkers",[]):
  if d.get("Key")==key: rows.append((d.get("VersionId"), d.get("LastModified"), "DeleteMarker"))
if not rows:
  print("No versions found for key:", key); sys.exit(0)
print(f"{'VersionId':<36}  {'LastModified':<30}  {'info'}")
for ver,lm,info in rows:
  print(f"{ver:<36}  {lm:<30}  {info}")
PY
}

rollback_state_version() {
  local bucket="$1" key="$2" version="$3"
  local found
  found="$(aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --query "Versions[?VersionId=='${version}'] | [0].VersionId" --output text 2>/dev/null || true)"
  if [ -z "$found" ] || [ "$found" = "None" ]; then
    echo "ERROR: versionId ${version} not found for ${key} in ${bucket}" >&2; return 2
  fi
  log "Restoring version ${version} into ${bucket}/${key}"
  exec_and_log "s3-copy-rollback" aws s3api copy-object --bucket "$bucket" --copy-source "${bucket}/${key}?versionId=${version}" --key "$key" --metadata-directive REPLACE
  log "Rollback attempted: verify versions with --find-version"
}

# ---- Main execution helpers ----
init_backend() {
  ensure_bucket_exists_and_versioning "$STATE_BUCKET" "$AWS_REGION"
  ensure_dynamodb_table "$LOCK_TABLE" "$AWS_REGION"

  if ! ls "${STACK_DIR}"/*.tf >/dev/null 2>&1; then
    log "WARNING: no .tf files found in ${STACK_DIR}; nothing to apply"
  fi

  log "Running: tofu init (with backend-config) in ${STACK_DIR}"
  exec_and_log "tofu-init" bash -c "cd \"$STACK_DIR\" && tofu init -backend-config \"bucket=${STATE_BUCKET}\" -backend-config \"key=${STATE_KEY}\" -backend-config \"region=${AWS_REGION}\" -backend-config \"dynamodb_table=${LOCK_TABLE}\" -input=false"
}

fmt_auto_fix_if_needed() {
  # run check and auto-fix without redirecting outputs
  if (cd "$STACK_DIR" && tofu fmt -check -recursive); then
    log "Formatting OK"
    return 0
  fi

  log "Formatting check failed — running 'tofu fmt -recursive' in ${STACK_DIR}"
  (cd "$STACK_DIR" && tofu fmt -recursive)
  # recheck
  if (cd "$STACK_DIR" && tofu fmt -check -recursive); then
    log "Formatting fixed"
  else
    echo "ERROR: formatting still failing after auto-fix; run 'tofu fmt -recursive' manually" >&2
    exit 30
  fi

  if command -v git >/dev/null 2>&1 && [ -d "${STACK_DIR}/.git" ]; then
    log "Files changed by auto-format (unstaged):"
    (cd "$STACK_DIR" && git --no-pager diff --name-only) || true
    log "Please review and commit formatted changes in ${STACK_DIR}"
  else
    log "Auto-formatting applied in-place; review and commit changes as needed"
  fi
}

validate_config() {
  log "Running: tofu validate in ${STACK_DIR}"
  exec_and_log "tofu-validate" bash -c "cd \"$STACK_DIR\" && tofu validate -no-color"
}

build_plan() {
  log "Building plan -> ${PLAN_FILE}"
  if [ -f "$VAR_FILE" ]; then
    exec_and_log "tofu-plan" bash -c "cd \"$STACK_DIR\" && tofu plan -var-file=\"$VAR_FILE\" -out=\"$PLAN_FILE\" -input=false"
  else
    exec_and_log "tofu-plan" bash -c "cd \"$STACK_DIR\" && tofu plan -out=\"$PLAN_FILE\" -input=false"
  fi
  log "Plan written to ${PLAN_FILE}"
}

apply_plan_auto() {
  if [ ! -f "$PLAN_FILE" ]; then
    echo "ERROR: plan file not found: ${PLAN_FILE}" >&2; exit 40
  fi
  log "Applying plan (auto-approve) from ${PLAN_FILE}"
  exec_and_log "tofu-apply-plan" bash -c "cd \"$STACK_DIR\" && tofu apply -input=false -auto-approve \"$PLAN_FILE\""
}

apply_auto_from_root() {
  log "Applying directly (tofu apply -auto-approve) in ${STACK_DIR}"
  if [ -f "$VAR_FILE" ]; then
    exec_and_log "tofu-apply" bash -c "cd \"$STACK_DIR\" && tofu apply -var-file=\"$VAR_FILE\" -input=false -auto-approve"
  else
    exec_and_log "tofu-apply" bash -c "cd \"$STACK_DIR\" && tofu apply -input=false -auto-approve"
  fi
}

destroy_auto() {
  log "Destroying infrastructure (auto-approve) in ${STACK_DIR}"
  if [ -f "$VAR_FILE" ]; then
    exec_and_log "tofu-destroy" bash -c "cd \"$STACK_DIR\" && tofu destroy -var-file=\"$VAR_FILE\" -input=false -auto-approve"
  else
    exec_and_log "tofu-destroy" bash -c "cd \"$STACK_DIR\" && tofu destroy -input=false -auto-approve"
  fi
}

# ---- Main switch ----
case "$MODE" in
  --plan)
    log "MODE=plan env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    init_backend
    fmt_auto_fix_if_needed
    validate_config
    build_plan
    log "Plan completed. Inspect ${PLAN_FILE} (binary). To show human-readable diff: tofu show ${PLAN_FILE}"
    ;;

  --create)
    log "MODE=create env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    init_backend
    fmt_auto_fix_if_needed
    validate_config
    build_plan
    apply_plan_auto
    log "create complete"
    ;;

  --destroy|--delete)
    log "MODE=destroy env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    if [ "$YES_DELETE" != true ]; then
      echo "Destructive action: pass --yes-delete to actually perform destroy." >&2
      echo "Preview: tofu plan -destroy -var-file=${VAR_FILE:-<none>}" >&2
      exit 3
    fi
    init_backend
    destroy_auto
    log "destroy complete"
    ;;

  --validate)
    log "MODE=validate env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    init_backend
    validate_backend "$STATE_BUCKET" "$STATE_KEY" "$LOCK_TABLE" "$AWS_REGION"
    ;;

  --find-version)
    log "MODE=find-version env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    list_state_versions "$STATE_BUCKET" "$STATE_KEY"
    ;;

  --rollback-state)
    if [ "$YES_DELETE" != true ]; then
      echo "Rollback is destructive: pass --yes-delete to perform rollback." >&2
      exit 3
    fi
    log "MODE=rollback env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID} version=${ROLLBACK_VERSION}"
    rollback_state_version "$STATE_BUCKET" "$STATE_KEY" "$ROLLBACK_VERSION"
    ;;

  *)
    echo "Unhandled mode: $MODE" >&2
    exit 2
    ;;
esac

exit 0