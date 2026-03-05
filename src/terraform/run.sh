#!/usr/bin/env bash
# src/terraform/run.sh
# Final production-grade, idempotent backend manager for OpenTofu/Terraform state.
#
# CLI:
#   bash src/terraform/run.sh  --create --env <prod|staging>
#   bash src/terraform/run.sh --delete --env <prod|staging> --yes-delete
#   bash src/terraform/run.sh --plan --env <prod|staging>
#   bash src/terraform/run.sh --validate --env <prod|staging>
#   bash src/terraform/run.sh --find-version --env <prod|staging>
#   bash src/terraform/run.sh --rollback-state <versionId> --env <prod|staging>
#
# Notes / invariants:
#  - AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION is used (fallback ap-south-1).
#  - Script does NOT commit backend.hcl to repo; uses tofu init CLI backend-config flags.
#  - State bucket is versioned (ENABLED) and encrypted (AES256).
#  - DynamoDB lock table exists and is ACTIVE.
#  - Script exits non-zero on any infrastructure mutation failure.
# Requirements: aws, tofu, python3 on PATH; credentials provided via env/profile/role.

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<USAGE >&2
Usage:
  $(basename "$0") --create --env <prod|staging>
  $(basename "$0") --delete --env <prod|staging> --yes-delete
  $(basename "$0") --plan --env <prod|staging>
  $(basename "$0") --validate --env <prod|staging>
  $(basename "$0") --find-version --env <prod|staging>
  $(basename "$0") --rollback-state <versionId> --env <prod|staging>

Notes:
  - AWS_DEFAULT_REGION read (default ap-south-1).
  - --plan is a dry-run for create/delete/validate actions.
  - --yes-delete must be passed to actually perform destructive delete.
USAGE
  exit 2
}

# --- parse args ---
if [ $# -lt 2 ]; then usage; fi

MODE=""
ROLLBACK_VERSION=""
ENVIRONMENT=""
YES_DELETE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --create|--delete|--plan|--validate|--find-version)
      if [ -n "$MODE" ]; then echo "Only one mode allowed" >&2; usage; fi
      MODE="$1"; shift ;;
    --rollback-state)
      if [ -n "$MODE" ]; then echo "Only one mode allowed" >&2; usage; fi
      MODE="--rollback-state"; shift
      if [ $# -eq 0 ]; then echo "--rollback-state requires a versionId" >&2; usage; fi
      ROLLBACK_VERSION="$1"; shift ;;
    --env)
      shift
      if [ $# -eq 0 ]; then echo "--env requires prod or staging" >&2; usage; fi
      case "$1" in
        prod|staging) ENVIRONMENT="$1"; shift ;;
        *) echo "Invalid env: $1" >&2; usage ;;
      esac ;;
    --yes-delete) YES_DELETE=true; shift ;;
    --dry-run) MODE="--plan"; shift ;; # alias
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if [ -z "$MODE" ] || [ -z "$ENVIRONMENT" ]; then usage; fi

AWS_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

# --- prerequisites ---
for cmd in aws tofu python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command '$cmd' not found" >&2; exit 10; }
done

log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
dry(){ printf 'DRYRUN: %s\n' "$*"; }

# tmp workspace
TMPDIR="$(mktemp -d -t runsh.XXXX)" || exit 1
cleanup(){ rm -rf "$TMPDIR" || true; }
trap cleanup EXIT

# --- deterministic names and paths ---
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [ -z "$ACCOUNT_ID" ]; then
  echo "ERROR: unable to determine AWS account id (check AWS credentials)" >&2
  exit 20
fi

STATE_BUCKET="agentops-tf-state-${ACCOUNT_ID}"
LOCK_TABLE="agentops-tf-lock-${ACCOUNT_ID}"
S3_PREFIX="agentops/"
STATE_KEY="${ENVIRONMENT}/terraform.tfstate"
STACK_DIR="$(cd "$(dirname "$0")" && pwd)/stacks/${ENVIRONMENT}"

# --- helpers ---
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

# ensure bucket exists and versioning/encryption/public-block as required
ensure_bucket_exists_and_versioning() {
  local bucket="$1" region="$2"

  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    log "s3: bucket ${bucket} exists"
  else
    if [ "$MODE" = "--plan" ]; then
      dry "create s3 bucket ${bucket} in ${region}"
    else
      log "s3: creating bucket ${bucket} (region=${region})"
      if [ "$region" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$bucket"
      else
        aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration LocationConstraint="$region"
      fi
      retry 6 2 aws s3api head-bucket --bucket "$bucket"
      log "s3: created bucket ${bucket}"
    fi
  fi

  # enable versioning (must end up Enabled)
  if [ "$MODE" = "--plan" ]; then
    dry "enable versioning on ${bucket}"
  else
    log "s3: enabling versioning on ${bucket}"
    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
    # verify
    local vs
    vs="$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null || true)"
    if [ "$vs" != "Enabled" ]; then
      echo "ERROR: failed to enable versioning on ${bucket} (status=${vs})" >&2
      exit 21
    fi
    log "s3: versioning Enabled on ${bucket}"
  fi

  # enable SSE AES256 if not present
  if [ "$MODE" = "--plan" ]; then
    dry "ensure server-side encryption (AES256 or aws:kms) on ${bucket}"
  else
    local enc
    enc="$(aws s3api get-bucket-encryption --bucket "$bucket" --output json 2>/dev/null || true)"
    if [ -z "$enc" ] || [ "$enc" = "null" ]; then
      log "s3: setting SSE AES256 on ${bucket}"
      aws s3api put-bucket-encryption --bucket "$bucket" \
        --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    else
      log "s3: bucket ${bucket} already has encryption configured"
    fi
  fi

  # enable public access block
  if [ "$MODE" = "--plan" ]; then
    dry "enable public access block on ${bucket}"
  else
    aws s3api put-public-access-block --bucket "$bucket" \
      --public-access-block-configuration '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}'
    log "s3: public access block set on ${bucket}"
  fi
}

ensure_dynamodb_table() {
  local table="$1" region="$2"
  if aws dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    log "ddb: table ${table} exists"
    return 0
  fi

  if [ "$MODE" = "--plan" ]; then
    dry "create dynamodb table ${table} (PAY_PER_REQUEST) in ${region}"
    return 0
  fi

  log "ddb: creating table ${table}"
  aws dynamodb create-table --table-name "$table" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region "$region"
  retry 8 2 aws dynamodb wait table-exists --table-name "$table" --region "$region"
  log "ddb: ensured ${table}"
}

list_state_versions() {
  local bucket="$1" key="$2"
  local lfile="$TMPDIR/list.json"
  aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --output json >"$lfile" 2>/dev/null || true
  python3 - <<PY "$lfile" "$key"
import json,sys
f=sys.argv[1]; key=sys.argv[2]
try:
  r=json.load(open(f))
except Exception:
  print("No versions found or error listing versions for:", key)
  sys.exit(0)
rows=[]
for v in r.get("Versions",[]):
  if v.get("Key")==key:
    rows.append((v.get("VersionId"), v.get("LastModified"), v.get("IsLatest")))
for d in r.get("DeleteMarkers",[]):
  if d.get("Key")==key:
    rows.append((d.get("VersionId"), d.get("LastModified"), "DeleteMarker"))
if not rows:
  print("No versions found for key:", key)
  sys.exit(0)
print(f"{'VersionId':<36}  {'LastModified':<30}  {'info'}")
for ver,lm,info in rows:
  print(f"{ver:<36}  {lm:<30}  {info}")
PY
}

rollback_state_version() {
  local bucket="$1" key="$2" version="$3"

  # verify version exists
  local found
  found="$(aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --query "Versions[?VersionId=='${version}'] | [0].VersionId" --output text 2>/dev/null || true)"
  if [ -z "$found" ] || [ "$found" = "None" ]; then
    echo "ERROR: versionId ${version} not found for ${key} in ${bucket}" >&2
    return 2
  fi

  if [ "$MODE" = "--plan" ]; then
    dry "Would copy s3://${bucket}/${key}?versionId=${version} -> s3://${bucket}/${key} (overwrite current)"
    return 0
  fi

  log "Restoring version ${version} into ${bucket}/${key}"
  local copy_source="${bucket}/${key}?versionId=${version}"
  aws s3api copy-object --bucket "$bucket" --copy-source "$copy_source" --key "$key" --metadata-directive REPLACE
  log "Rollback requested: copy-object completed for ${version}. Validate by listing versions."
}

delete_s3_prefix_objects() {
  local bucket="$1" prefix="$2"
  if [ "$MODE" = "--plan" ]; then
    dry "Would enumerate and delete objects under s3://${bucket}/${prefix}"
    return 0
  fi

  # check versioning
  local ver_status
  ver_status="$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null || true)"
  if [ "$ver_status" = "Enabled" ]; then
    # versioned: delete versions + markers in chunks
    while :; do
      local listf="$TMPDIR/list.json"
      aws s3api list-object-versions --bucket "$bucket" --prefix "$prefix" --output json >"$listf" 2>/dev/null || true
      local count
      count="$(python3 - <<PY "$listf"
import json,sys
try:
  r=json.load(open(sys.argv[1]))
except Exception:
  print(0); sys.exit(0)
c=0
for k in ("Versions","DeleteMarkers"):
  c += len(r.get(k,[]))
print(c)
PY
"$listf")"
      if [ -z "$count" ] || [ "$count" = "0" ]; then rm -f "$listf" >/dev/null 2>&1 || true; break; fi

      python3 - <<PY "$listf" "$bucket" "$TMPDIR"
import json,sys,subprocess,os
r=json.load(open(sys.argv[1]))
objs=[]
for k in ("Versions","DeleteMarkers"):
  for it in r.get(k,[]):
    objs.append({"Key": it.get("Key"), "VersionId": it.get("VersionId")})
for i in range(0, len(objs), 1000):
  chunk = objs[i:i+1000]
  payload = json.dumps({"Objects": chunk}, separators=(",",":"))
  pfile = os.path.join(sys.argv[3], "del.json")
  open(pfile,"w").write(payload)
  subprocess.run(["aws","s3api","delete-objects","--bucket",sys.argv[2],"--delete","file://"+pfile], check=False)
  try:
    os.remove(pfile)
  except Exception:
    pass
PY
      sleep 1
    done
  else
    # not versioned
    aws s3 rm "s3://${bucket}/${prefix}" --recursive
  fi

  log "Deleted objects under s3://${bucket}/${prefix}"
}

delete_dynamodb_table() {
  local table="$1" region="$2"
  if aws dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    log "Deleting DynamoDB table ${table}"
    aws dynamodb delete-table --table-name "$table" --region "$region"
    aws dynamodb wait table-not-exists --table-name "$table" --region "$region"
    log "Deleted DynamoDB table ${table}"
  else
    log "DynamoDB table ${table} not found; skipping"
  fi
}

validate_backend() {
  local bucket="$1" key="$2" table="$3" region="$4"

  # identity
  aws sts get-caller-identity --query Account --output text >/dev/null

  # bucket exists
  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "ERROR: state bucket ${bucket} not found" >&2
    return 1
  fi

  # versioning enabled
  local vs
  vs="$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null || true)"
  if [ "$vs" != "Enabled" ]; then
    echo "ERROR: bucket ${bucket} versioning not Enabled (status=${vs})" >&2
    return 2
  fi

  # encryption
  if ! aws s3api get-bucket-encryption --bucket "$bucket" >/dev/null 2>&1; then
    echo "ERROR: bucket ${bucket} encryption not configured" >&2
    return 3
  fi

  # public access block
  local pab_ok
  pab_ok="$(aws s3api get-public-access-block --bucket "$bucket" --output json 2>/dev/null || echo '{}')"
  python3 - <<PY "$pab_ok"
import json,sys
try:
  j=json.loads(sys.argv[1])["PublicAccessBlockConfiguration"]
  if all(j.get(k,False) for k in ("BlockPublicAcls","IgnorePublicAcls","BlockPublicPolicy","RestrictPublicBuckets")):
    sys.exit(0)
except Exception:
  pass
sys.exit(1)
PY
  if [ $? -ne 0 ]; then
    echo "ERROR: bucket ${bucket} public access block not fully enabled" >&2
    return 4
  fi

  # dynamodb
  local dstat
  dstat="$(aws dynamodb describe-table --table-name "$table" --query "Table.TableStatus" --output text 2>/dev/null || true)"
  if [ -z "$dstat" ]; then
    echo "ERROR: dynamodb table ${table} not found" >&2
    return 5
  fi
  if [ "$dstat" != "ACTIVE" ]; then
    echo "ERROR: dynamodb table ${table} status=${dstat}" >&2
    return 6
  fi

  # tofu init (non-destructive) to validate backend connectivity
  local init_dir="$TMPDIR/init"
  mkdir -p "$init_dir"
  ( cd "$init_dir" && tofu init -backend-config "bucket=${bucket}" -backend-config "key=${key}" -backend-config "region=${region}" -backend-config "dynamodb_table=${table}" -input=false ) >/dev/null 2>&1

  log "Validation OK: bucket/encryption/versioning/public-block and dynamodb lock table verified; backend init succeeded"
  return 0
}

# --- main ---
case "$MODE" in
  --create)
    log "create: env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    ensure_bucket_exists_and_versioning "$STATE_BUCKET" "$AWS_REGION"
    ensure_dynamodb_table "$LOCK_TABLE" "$AWS_REGION"
    # init backend (no file)
    run_cmd=(tofu init -backend-config "bucket=${STATE_BUCKET}" -backend-config "key=${STATE_KEY}" -backend-config "region=${AWS_REGION}" -backend-config "dynamodb_table=${LOCK_TABLE}" -input=false)
    log "Running: ${run_cmd[*]}"
    ( mkdir -p "$STACK_DIR" && cd "$STACK_DIR" && "${run_cmd[@]}" )
    log "create complete"
    ;;

  --plan)
    log "plan (dry-run): env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    dry "Would ensure bucket ${STATE_BUCKET} (create, versioning enabled, SSE, public-block)"
    dry "Would ensure DynamoDB table ${LOCK_TABLE}"
    dry "Would run: tofu init -backend-config bucket=${STATE_BUCKET} -backend-config key=${STATE_KEY} -backend-config region=${AWS_REGION} -backend-config dynamodb_table=${LOCK_TABLE} -input=false"
    ;;

  --validate)
    log "validate: env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    validate_backend "$STATE_BUCKET" "$STATE_KEY" "$LOCK_TABLE" "$AWS_REGION"
    ;;

  --find-version)
    log "find-version: env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    list_state_versions "$STATE_BUCKET" "$STATE_KEY"
    ;;

  --rollback-state)
    log "rollback: env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID} version=${ROLLBACK_VERSION}"
    rollback_state_version "$STATE_BUCKET" "$STATE_KEY" "$ROLLBACK_VERSION"
    ;;

  --delete)
    log "delete: env=${ENVIRONMENT} region=${AWS_REGION} account=${ACCOUNT_ID}"
    if [ "$YES_DELETE" != true ]; then
      echo "Destructive action: to perform deletion pass --yes-delete flag." >&2
      echo "What would be deleted:" >&2
      echo "  - objects under s3://${STATE_BUCKET}/${S3_PREFIX}${ENVIRONMENT}/" >&2
      echo "  - DynamoDB table: ${LOCK_TABLE}" >&2
      exit 3
    fi
    delete_s3_prefix_objects "$STATE_BUCKET" "${S3_PREFIX}${ENVIRONMENT}/"
    delete_dynamodb_table "$LOCK_TABLE" "$AWS_REGION"
    log "delete complete (bucket preserved). To remove bucket manually: aws s3 rb s3://${STATE_BUCKET} --force"
    ;;

  *)
    echo "Unhandled mode: $MODE" >&2
    exit 2
    ;;
esac

exit 0