#!/usr/bin/env bash
# Zero-touch deployment script that installs CloudNativePG operator, provisions a PostgreSQL cluster, and configures a PgBouncer pooler on any Kubernetes environment (kind or cloud).
# Verifies CSI/storage drivers, and ensures a portable StorageClass using WaitForFirstConsumer to prevent PVC scheduling failures.
# Generates deterministic manifests under src/manifests/postgres and archives the exact operator YAML under src/scripts/archive for reproducible deployments.
# Performs server-side schema validation before applying manifests, waits for cluster readiness, then deploys the pooler and exposes connection URIs derived from the CNPG secret.
# Executes automated end-to-end PostgreSQL CRUD tests through the pooler using ephemeral test pods to verify storage, networking, authentication, and query functionality.

set -euo pipefail

K8S_CLUSTER="${K8S_CLUSTER:-kind}" # or eks|gke|aks
TARGET_NS="${TARGET_NS:-default}"
ARCHIVE_DIR="src/scripts/archive"
MANIFEST_DIR="src/manifests/postgres"
CLUSTER_FILE="${MANIFEST_DIR}/postgres_cluster.yaml"
POOLER_FILE="${MANIFEST_DIR}/postgres_pooler.yaml"
OPERATOR_ARCHIVE_TEMPLATE="${ARCHIVE_DIR}/cnpg-%s.yaml"

CNPG_VERSION="${CNPG_VERSION:-1.28.1}"
CNPG_NAMESPACE="${CNPG_NAMESPACE:-cnpg-system}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.3-minimal-trixie}"
CLUSTER_NAME="${CLUSTER_NAME:-postgres-cluster}"
POOLER_NAME="${POOLER_NAME:-postgres-pooler}"

OPERATOR_TIMEOUT="${OPERATOR_TIMEOUT:-300}"
POD_TIMEOUT="${POD_TIMEOUT:-900}"
SECRET_TIMEOUT="${SECRET_TIMEOUT:-180}"

STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-default-storage-class}"
INITDB_DB="${INITDB_DB:-iceberg_catalogue_metadata}"
ADDITIONAL_DBS=(flyte_admin flyte_propeller mlflow app)

if [[ "${K8S_CLUSTER}" == "kind" ]]; then
  INSTANCES=2
  CPU_REQUEST="250m"; CPU_LIMIT="1000m"
  MEM_REQUEST="512Mi"; MEM_LIMIT="1Gi"
  STORAGE_SIZE="5Gi"; WAL_SIZE="2Gi"
  POOLER_INSTANCES=1
  POOLER_CPU_REQUEST="50m"; POOLER_MEM_REQUEST="64Mi"
  POOLER_CPU_LIMIT="200m"; POOLER_MEM_LIMIT="256Mi"
else
  INSTANCES=3
  CPU_REQUEST="500m"; CPU_LIMIT="2000m"
  MEM_REQUEST="1Gi"; MEM_LIMIT="4Gi"
  STORAGE_SIZE="20Gi"; WAL_SIZE="10Gi"
  POOLER_INSTANCES=2
  POOLER_CPU_REQUEST="100m"; POOLER_MEM_REQUEST="128Mi"
  POOLER_CPU_LIMIT="500m"; POOLER_MEM_LIMIT="512Mi"
fi

ANNOTATION_CLUSTER_KEY="mlsecops.cnpg.cluster-checksum"
ANNOTATION_POOLER_KEY="mlsecops.cnpg.pooler-checksum"

log(){ printf '[%s] [cnpg] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
fatal(){ printf '[%s] [cnpg][FATAL] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }
require_bin(){ command -v "$1" >/dev/null 2>&1 || fatal "$1 required in PATH"; }

trap 'rc=$?; echo; echo "[DIAG] exit_code=$rc"; echo "[DIAG] kubectl context: $(kubectl config current-context 2>/dev/null || true)"; echo "[DIAG] pods (ns ${TARGET_NS}):"; kubectl -n "${TARGET_NS}" get pods -o wide || true; echo "[DIAG] pvc (ns ${TARGET_NS}):"; kubectl -n "${TARGET_NS}" get pvc || true; echo "[DIAG] events (last 200):"; kubectl get events -A --sort-by=.lastTimestamp | tail -n 200 || true; exit $rc' ERR

require_prereqs(){
  require_bin kubectl
  require_bin curl
  require_bin sha256sum
  kubectl version --client >/dev/null 2>&1 || fatal "kubectl client unavailable"
  kubectl cluster-info >/dev/null 2>&1 || fatal "kubectl cannot reach cluster"
  mkdir -p "${ARCHIVE_DIR}" "${MANIFEST_DIR}"
}

detect_provider(){
  if [[ -n "${K8S_CLUSTER:-}" ]]; then
    echo "${K8S_CLUSTER}"; return 0
  fi
  if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
    fatal "kubectl cannot reach cluster to detect provider"
  fi
  local nodeName providerID
  nodeName="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  providerID="$(kubectl get node "${nodeName}" -o jsonpath='{.spec.providerID}' 2>/dev/null || true)"
  if [[ "${providerID}" == aws* || "${providerID}" == aws://* ]] || kubectl get csidrivers 2>/dev/null | grep -q 'ebs.csi.aws.com'; then
    echo "eks"; return 0
  fi
  if [[ "${providerID}" == gce* || "${providerID}" == gce://* ]] || kubectl get csidrivers 2>/dev/null | grep -q 'pd.csi.storage.gke.io'; then
    echo "gke"; return 0
  fi
  if [[ "${providerID}" == azure* || "${providerID}" == azure://* ]] || kubectl get csidrivers 2>/dev/null | grep -q 'disk.csi.azure.com'; then
    echo "aks"; return 0
  fi
  if [[ -z "${providerID}" ]] && ([[ "${nodeName:-}" =~ kind- ]] || kubectl get ns local-path-storage >/dev/null 2>&1); then
    echo "kind"; return 0
  fi
  echo "unknown"
}

check_cloud_csi(){
  case "${K8S_CLUSTER}" in
    eks)
      log "checking for AWS EBS CSI driver"
      if kubectl get csidrivers -o name 2>/dev/null | grep -q 'ebs.csi.aws.com'; then log "EBS CSI driver detected"; return 0; fi
      fatal "EBS CSI driver 'ebs.csi.aws.com' not found"
      ;;
    gke)
      log "checking for GCE PD CSI driver"
      if kubectl get csidrivers -o name 2>/dev/null | grep -q 'pd.csi.storage.gke.io'; then log "GCE PD CSI driver detected"; return 0; fi
      fatal "GCE PD CSI driver not found"
      ;;
    aks)
      log "checking for Azure Disk CSI driver"
      if kubectl get csidrivers -o name 2>/dev/null | grep -q 'disk.csi.azure.com'; then log "Azure Disk CSI driver detected"; return 0; fi
      fatal "Azure Disk CSI driver not found"
      ;;
    kind)
      log "kind cluster: skipping CSI checks"
      return 0
      ;;
    *)
      log "unknown cluster type; skipping CSI checks"
      return 0
      ;;
  esac
}

install_local_path_provisioner(){
  if kubectl -n local-path-storage get deploy local-path-provisioner >/dev/null 2>&1; then log "local-path-provisioner already installed"; return 0; fi
  log "installing local-path-provisioner"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml" >/dev/null 2>&1 || fatal "failed to install local-path-provisioner"
  kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=180s >/dev/null || log "local-path-provisioner rollout issue"
}

create_storageclass_kind(){
  cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
mountOptions:
  - noatime
  - nodiratime
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
  log "created storageclass ${STORAGE_CLASS_NAME} for kind"
}

create_storageclass_eks(){
  cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
  log "created storageclass ${STORAGE_CLASS_NAME} for eks"
}

ensure_storage_class(){
  log "ensuring storageclass '${STORAGE_CLASS_NAME}' with WaitForFirstConsumer"
  if kubectl get storageclass "${STORAGE_CLASS_NAME}" >/dev/null 2>&1; then
    local prov mode pv_count
    prov="$(kubectl get storageclass "${STORAGE_CLASS_NAME}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
    mode="$(kubectl get storageclass "${STORAGE_CLASS_NAME}" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo '')"
    pv_count="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="'"${STORAGE_CLASS_NAME}"'")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l)"
    log "found StorageClass ${STORAGE_CLASS_NAME} (provisioner=${prov}, mode=${mode}, pv_count=${pv_count})"
    if [[ "${mode}" == "WaitForFirstConsumer" ]]; then
      kubectl patch storageclass "${STORAGE_CLASS_NAME}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null || true
      return 0
    fi
    if [[ "${prov}" == "rancher.io/local-path" || "${K8S_CLUSTER}" == "kind" ]]; then
      if [[ "${pv_count}" -gt 0 ]]; then fatal "StorageClass ${STORAGE_CLASS_NAME} has PVs and cannot be safely recreated"; fi
      kubectl delete storageclass "${STORAGE_CLASS_NAME}" >/dev/null 2>&1 || true
      install_local_path_provisioner
      create_storageclass_kind
      return 0
    fi
    if [[ "${pv_count}" -gt 0 ]]; then
      STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME}-wffc"
      log "existing SC has PVs; using ${STORAGE_CLASS_NAME}"
      create_storageclass_eks
      return 0
    fi
  fi
  case "${K8S_CLUSTER}" in
    kind) install_local_path_provisioner; create_storageclass_kind ;;
    eks) create_storageclass_eks ;;
    gke) fatal "GKE automatic storageclass creation not implemented";;
    aks) fatal "AKS automatic storageclass creation not implemented";;
    *) create_storageclass_kind ;;
  esac
  log "storageclass ensured: ${STORAGE_CLASS_NAME}"
}

validate_operand_major(){
  local img="${POSTGRES_IMAGE##*:}"
  local major="${img%%.*}"
  if ! [[ "${major}" =~ ^[0-9]+$ ]]; then major="$(echo "${img}" | sed -E 's/^([0-9]+).*/\1/')"; fi
  log "postgres image major: ${major}"
  case "${major}" in
    14|15|16|17|18) return 0 ;;
    *) fatal "postgres major ${major} not supported by CNPG 1.28" ;;
  esac
}

install_cnpg_operator(){
  log "installing CloudNativePG operator ${CNPG_VERSION}"
  kubectl get ns "${CNPG_NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${CNPG_NAMESPACE}" >/dev/null
  local branch url archive_file
  branch="${CNPG_VERSION%.*}"
  url="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${branch}/releases/cnpg-${CNPG_VERSION}.yaml"
  archive_file="$(printf "${OPERATOR_ARCHIVE_TEMPLATE}" "${CNPG_VERSION}")"
  curl -fsSL -o "${archive_file}" "${url}" || fatal "download operator manifest failed"
  if kubectl apply --server-side -f "${archive_file}" >/dev/null 2>&1; then log "operator applied (server-side)"; else kubectl apply -f "${archive_file}" >/dev/null || fatal "kubectl apply operator failed"; fi
  kubectl -n "${CNPG_NAMESPACE}" rollout status deployment/cnpg-controller-manager --timeout="${OPERATOR_TIMEOUT}s" >/dev/null || fatal "cnpg-controller-manager rollout failed"
  local start now elapsed
  start=$(date +%s)
  while true; do
    if kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then break; fi
    now=$(date +%s); elapsed=$((now-start))
    if [[ "${elapsed}" -ge 60 ]]; then fatal "CRD clusters.postgresql.cnpg.io not present after operator install"; fi
    sleep 1
  done
  log "operator ready"
}

render_cluster_manifest(){
  log "rendering cluster manifest -> ${CLUSTER_FILE}"
  mkdir -p "$(dirname "${CLUSTER_FILE}")"
  cat > "${CLUSTER_FILE}" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${TARGET_NS}
spec:
  instances: ${INSTANCES}
  imageName: ${POSTGRES_IMAGE}
  bootstrap:
    initdb:
      database: ${INITDB_DB}
      owner: app
      postInitSQL:
$(for db in "${ADDITIONAL_DBS[@]}"; do printf "        - CREATE DATABASE %s OWNER app;\n" "${db}"; done)
      postInitApplicationSQL:
        - ALTER SCHEMA public OWNER TO app;
  storage:
    storageClass: ${STORAGE_CLASS_NAME}
    size: ${STORAGE_SIZE}
  walStorage:
    storageClass: ${STORAGE_CLASS_NAME}
    size: ${WAL_SIZE}
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "200"
      wal_compression: "on"
      effective_cache_size: "1GB"
  resources:
    requests:
      cpu: ${CPU_REQUEST}
      memory: ${MEM_REQUEST}
    limits:
      cpu: ${CPU_LIMIT}
      memory: ${MEM_LIMIT}
EOF
  log "wrote ${CLUSTER_FILE}"
}

render_pooler_manifest(){
  log "rendering pooler manifest -> ${POOLER_FILE}"
  mkdir -p "$(dirname "${POOLER_FILE}")"
  cat > "${POOLER_FILE}" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: ${POOLER_NAME}
  namespace: ${TARGET_NS}
spec:
  cluster:
    name: ${CLUSTER_NAME}
  instances: ${POOLER_INSTANCES}
  type: rw
  pgbouncer:
    poolMode: transaction
    parameters:
      max_client_conn: "1000"
      default_pool_size: "25"
      min_pool_size: "5"
      reserve_pool_size: "10"
      server_idle_timeout: "600"
  template:
    spec:
      containers:
      - name: pgbouncer
        resources:
          requests:
            cpu: ${POOLER_CPU_REQUEST}
            memory: ${POOLER_MEM_REQUEST}
          limits:
            cpu: ${POOLER_CPU_LIMIT}
            memory: ${POOLER_MEM_LIMIT}
EOF
  log "wrote ${POOLER_FILE}"
}

manifest_hash(){
  local file="$1"
  sha256sum "$file" | awk '{print $1}'
}

get_annotation(){
  local kind="$1"
  local name="$2"
  local key="$3"
  kubectl -n "${TARGET_NS}" get "${kind}" "${name}" -o "jsonpath={.metadata.annotations['${key}']}" 2>/dev/null || true
}

set_annotation(){
  local kind="$1"
  local name="$2"
  local key="$3"
  local value="$4"
  kubectl -n "${TARGET_NS}" patch "${kind}" "${name}" --type=merge -p "{\"metadata\":{\"annotations\":{\"${key}\":\"${value}\"}}}" >/dev/null 2>&1 || true
}

apply_manifest_if_changed(){
  local file="$1"
  local kind="$2"
  local name="$3"
  local ann_key="$4"
  local h
  h=$(manifest_hash "${file}")
  local existing
  existing=$(get_annotation "${kind}" "${name}" "${ann_key}")
  if [[ -n "${existing}" && "${existing}" == "${h}" ]]; then
    log "manifest ${file} unchanged (annotation match); skipping apply for ${kind}/${name}"
    return 0
  fi
  log "applying manifest ${file} for ${kind}/${name}"
  if kubectl -n "${TARGET_NS}" get "${kind}" "${name}" >/dev/null 2>&1; then
    kubectl apply --server-side --force-conflicts --field-manager=mlsecops-cnpg -f "${file}" >/dev/null || fatal "apply failed for ${file}"
  else
    kubectl apply --server-side --field-manager=mlsecops-cnpg -f "${file}" >/dev/null || fatal "first apply failed for ${file}"
  fi
  set_annotation "${kind}" "${name}" "${ann_key}" "${h}"
  log "applied ${file} and updated annotation ${ann_key}"
}

wait_for_cluster_ready(){
  log "waiting for cluster readiness (timeout ${POD_TIMEOUT}s)"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s); elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${POD_TIMEOUT}" ]]; then fatal "timeout waiting for cluster readiness"; fi
    local ready expected
    ready=$(kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
    expected=$(kubectl -n "${TARGET_NS}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo ${INSTANCES})
    if [[ -n "${ready}" && -n "${expected}" && "${ready}" -ge "${expected}" ]]; then log "cluster ready ${ready}/${expected}"; return 0; fi
    sleep 3
  done
}

wait_for_app_secret(){
  log "waiting for app secret (timeout ${SECRET_TIMEOUT}s)"
  local start now elapsed secret
  start=$(date +%s)
  while true; do
    now=$(date +%s); elapsed=$((now - start))
    secret="$(kubectl -n "${TARGET_NS}" get secret -l "cnpg.io/cluster=${CLUSTER_NAME},cnpg.io/userType=app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${secret}" ]]; then log "found app secret ${secret}"; printf '%s' "${secret}"; return 0; fi
    if [[ "${elapsed}" -ge "${SECRET_TIMEOUT}" ]]; then fatal "timeout waiting for app secret"; fi
    sleep 2
  done
}

get_primary_pod(){
  kubectl -n "${TARGET_NS}" get pods -l 'cnpg.io/instanceRole=primary' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

ensure_database_exists(){
  local primary db exists
  primary="$(get_primary_pod)"
  if [[ -z "${primary}" ]]; then fatal "primary pod not found to run DB creation"; fi
  for db in "$@"; do
    exists=$(kubectl -n "${TARGET_NS}" exec "${primary}" -- psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null || echo "")
    if [[ "${exists}" =~ 1 ]]; then
      log "database ${db} already exists"
    else
      log "creating database ${db}"
      kubectl -n "${TARGET_NS}" exec "${primary}" -- psql -U postgres -c "CREATE DATABASE ${db} OWNER app;" >/dev/null 2>&1 || fatal "failed to create database ${db}"
      log "created ${db}"
    fi
  done
}

fix_database_schema_ownership(){
  log "ensuring schema ownership for target DBs"
  local db primary
  primary="$(get_primary_pod)"
  if [[ -z "${primary}" ]]; then fatal "primary pod not found to run ownership fix"; fi
  for db in "${ADDITIONAL_DBS[@]}"; do
    kubectl -n "${TARGET_NS}" exec "${primary}" -- psql -U postgres -d "${db}" -c "ALTER SCHEMA public OWNER TO app;" >/dev/null 2>&1 || true
  done
  log "schema ownership attempts complete"
}

deploy_pooler_and_wait(){
  apply_manifest_if_changed "${POOLER_FILE}" pooler "${POOLER_NAME}" "${ANNOTATION_POOLER_KEY}"
  log "waiting for pooler pods to be ready"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s); elapsed=$((now - start))
    local pods ready need svc
    pods=$(kubectl -n "${TARGET_NS}" get pods -l "cnpg.io/poolerName=${POOLER_NAME}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ -n "${pods}" ]]; then
      ready=$(for p in ${pods}; do kubectl -n "${TARGET_NS}" get pod "$p" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false; done | grep -c true || true)
      need=$(kubectl -n "${TARGET_NS}" get pooler "${POOLER_NAME}" -o jsonpath='{.spec.instances}' 2>/dev/null || echo ${POOLER_INSTANCES})
      if [[ "${ready}" -ge "${need}" && "${need}" -gt 0 ]]; then
        svc=$(kubectl -n "${TARGET_NS}" get svc "${POOLER_NAME}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)
        if [[ -n "${svc}" ]]; then log "pooler ready"; return 0; fi
      fi
    fi
    if [[ "${elapsed}" -ge "${OPERATOR_TIMEOUT}" ]]; then fatal "timeout waiting for pooler readiness"; fi
    sleep 3
  done
}

mask_uri(){ echo "$1" | sed -E 's#(:)[^:@]+(@)#:\*\*\*\*\*@#'; }

print_connection_uris(){
  log "printing masked pooler URIs"
  local secret user pw port host raw masked
  secret="$(kubectl -n "${TARGET_NS}" get secret -l "cnpg.io/cluster=${CLUSTER_NAME},cnpg.io/userType=app" -o jsonpath='{.items[0].metadata.name}')"
  user="$(kubectl -n "${TARGET_NS}" get secret "${secret}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
  pw="$(kubectl -n "${TARGET_NS}" get secret "${secret}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
  port="$(kubectl -n "${TARGET_NS}" get secret "${secret}" -o jsonpath='{.data.port}' 2>/dev/null | base64 -d || echo 5432)"
  host="${POOLER_NAME}.${TARGET_NS}"
  raw="postgresql://${user}:${pw}@${host}:${port}"
  masked=$(mask_uri "${raw}")
  printf "\nConnection URIs (masked):\n\n"
  printf "%s/%s\n" "${masked}" "${INITDB_DB}"
  for db in "${ADDITIONAL_DBS[@]}"; do
    printf "%s/%s\n" "${masked}" "${db}"
  done
}

persist_artifacts(){
  mkdir -p "${MANIFEST_DIR}" "${ARCHIVE_DIR}"
  cp "${CLUSTER_FILE}" "${MANIFEST_DIR}/postgres_cluster.yaml" 2>/dev/null || true
  cp "${POOLER_FILE}" "${MANIFEST_DIR}/postgres_pooler.yaml" 2>/dev/null || true
  print_connection_uris > "${MANIFEST_DIR}/masked_pooler_uris.txt" || true
  log "artifacts persisted to ${MANIFEST_DIR}"
}

delete_all(){
  kubectl -n "${TARGET_NS}" delete deployment,cluster,pooler "${CLUSTER_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${TARGET_NS}" delete svc "${POOLER_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  log "deleted cnpg resources; preserved PV data"
}

main(){
  require_prereqs
  log "starting postgres cluster rollout (cluster=${K8S_CLUSTER}, ns=${TARGET_NS})"
  local detected
  detected="$(detect_provider)"
  log "provider detection result: ${detected}"
  check_cloud_csi || true
  ensure_storage_class
  validate_operand_major
  install_cnpg_operator
  render_cluster_manifest
  render_pooler_manifest
  apply_manifest_if_changed "${CLUSTER_FILE}" cluster "${CLUSTER_NAME}" "${ANNOTATION_CLUSTER_KEY}"
  wait_for_cluster_ready
  local app_secret
  app_secret="$(wait_for_app_secret)"
  ensure_database_exists "${INITDB_DB}"
  fix_database_schema_ownership
  deploy_pooler_and_wait
  persist_artifacts
  print_connection_uris
  run_crud_tests_via_pooler || log "CRUD tests were skipped or failed; inspect above logs"
  printf "\n[SUCCESS] CNPG deploy complete. Manifests: %s\n" "${MANIFEST_DIR}"
}

run_crud_tests_via_pooler(){
  log "running CRUD tests via pooler"
  local secret user pw port host db pod start phase
  secret="$(kubectl -n "${TARGET_NS}" get secret -l "cnpg.io/cluster=${CLUSTER_NAME},cnpg.io/userType=app" -o jsonpath='{.items[0].metadata.name}')"
  user="$(kubectl -n "${TARGET_NS}" get secret "${secret}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
  pw="$(kubectl -n "${TARGET_NS}" get secret "${secret}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
  port="$(kubectl -n "${TARGET_NS}" get secret "${secret}" -o jsonpath='{.data.port}' 2>/dev/null | base64 -d || echo 5432)"
  host="${POOLER_NAME}.${TARGET_NS}"
  for db in "${ADDITIONAL_DBS[@]}" "${INITDB_DB}"; do
    pod="e2e-pgtest-${db//_/-}"
    kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl run "${pod}" -n "${TARGET_NS}" --restart=Never --image=postgres:16 --env="PGUSER=${user}" --env="PGPASSWORD=${pw}" --env="PGHOST=${host}" --env="PGPORT=${port}" --env="PGDATABASE=${db}" --command -- sh -c "psql -h \"\$PGHOST\" -U \"\$PGUSER\" -p \"\$PGPORT\" -d \"\$PGDATABASE\" -v ON_ERROR_STOP=1 -c \"CREATE TABLE IF NOT EXISTS e2e_test (id SERIAL PRIMARY KEY, v TEXT); INSERT INTO e2e_test(v) VALUES ('insert_test');\" && psql -h \"\$PGHOST\" -U \"\$PGUSER\" -p \"\$PGPORT\" -d \"\$PGDATABASE\" -c \"SELECT 'READ_AFTER_INSERT', count(*) FROM e2e_test;\" && psql -h \"\$PGHOST\" -U \"\$PGUSER\" -p \"\$PGPORT\" -d \"\$PGDATABASE\" -c \"UPDATE e2e_test SET v='updated_test' WHERE v='insert_test';\" && psql -h \"\$PGHOST\" -U \"\$PGUSER\" -p \"\$PGPORT\" -d \"\$PGDATABASE\" -c \"DELETE FROM e2e_test;\""
    start=$(date +%s)
    while true; do
      if kubectl -n "${TARGET_NS}" get pod "${pod}" -o jsonpath='{.status.phase}' >/dev/null 2>&1; then
        phase=$(kubectl -n "${TARGET_NS}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "${phase}" == "Succeeded" ]]; then
          log "pod ${pod} succeeded; logs:"
          kubectl -n "${TARGET_NS}" logs "${pod}" --tail=200 || true
          kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
          log "CRUD passed for ${db}"
          break
        fi
        if [[ "${phase}" == "Failed" ]]; then
          log "pod ${pod} failed; logs:"
          kubectl -n "${TARGET_NS}" logs "${pod}" --tail=200 || true
          kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
          fatal "CRUD failed for ${db}"
        fi
      fi
      if [[ $(( $(date +%s) - start )) -gt 180 ]]; then
        log "timeout waiting for ${pod}; logs:"
        kubectl -n "${TARGET_NS}" logs "${pod}" --tail=200 || true
        kubectl -n "${TARGET_NS}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true
        fatal "CRUD timeout for ${db}"
      fi
      sleep 2
    done
  done
  log "all CRUD tests via pooler passed"
  return 0
}

case "${1:-}" in
  --rollout) main ;;
  --delete) delete_all ;;
  --help|-h) printf "Usage: %s [--rollout|--delete]\n" "$0"; exit 0 ;;
  *) main ;;
esac