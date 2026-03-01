#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="${SIGNOZ_NAMESPACE:-signoz}"
readonly HELM_RELEASE="${SIGNOZ_HELM_RELEASE:-signoz}"
readonly HELM_REPO="signoz"
readonly HELM_REPO_URL="https://charts.signoz.io"
readonly HELM_CHART="signoz/signoz"
readonly HELM_VERSION="${SIGNOZ_HELM_VERSION:-0.113.0}"
readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"
readonly MANIFESTS_DIR="${MANIFESTS_DIR:-src/manifests/signoz}"

readonly JWT_SECRET="${SIGNOZ_JWT_SECRET:-}"
readonly AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
readonly AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
readonly SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
readonly CLICKHOUSE_USER="${CLICKHOUSE_USER:-signoz}"
readonly CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-signozpass}"
readonly CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-9000}"

log() { printf '[%s] [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$K8S_CLUSTER" "$*" >&2; }
fatal() { printf '[FATAL] [%s] %s\n' "$K8S_CLUSTER" "$*" >&2; exit 1; }
require_bin() { command -v "$1" >/dev/null 2>&1 || fatal "$1 not found in PATH"; }

validate_environment() {
  log "Validating environment for K8S_CLUSTER=${K8S_CLUSTER}"
  case "${K8S_CLUSTER}" in
    eks)
      [[ -n "${AWS_ACCESS_KEY_ID}" ]] || fatal "AWS_ACCESS_KEY_ID required for EKS"
      [[ -n "${AWS_SECRET_ACCESS_KEY}" ]] || fatal "AWS_SECRET_ACCESS_KEY required for EKS"
      [[ -n "${SLACK_WEBHOOK_URL}" ]] || fatal "SLACK_WEBHOOK_URL required for EKS alerts"
      ;;
    kind)
      if ! kubectl get storageclass local-path >/dev/null 2>&1; then
        log "StorageClass 'local-path' missing. Installing provisioner..."
        kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml >/dev/null 2>&1
        kubectl -n local-path-storage wait --for=condition=ready pod -l app=local-path-provisioner --timeout=120s
        log "local-path-provisioner ready"
      fi
      ;;
    *) fatal "Unsupported K8S_CLUSTER='${K8S_CLUSTER}'. Must be 'kind' or 'eks'";;
  esac
}

ensure_dns_ready() {
  log "Verifying CoreDNS readiness"
  local retries=30
  until kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -q "^Running$"; do
    ((retries--)) || fatal "CoreDNS not ready after 60s"
    sleep 2
  done
  log "CoreDNS operational"
}

ensure_manifests_dir() {
  log "Ensuring manifests directory exists: ${MANIFESTS_DIR}"
  mkdir -p "${MANIFESTS_DIR}"
}

create_secrets() {
  log "Creating Kubernetes secrets"
  
  local jwt_secret_value="${JWT_SECRET}"
  local jwt_generated="false"
  if [[ -z "${jwt_secret_value}" ]]; then
    jwt_secret_value=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    jwt_generated="true"
    log "WARNING: Generated random JWT_SECRET (set SIGNOZ_JWT_SECRET for reproducibility)"
  fi
  
  local clickhouse_host="signoz-clickhouse.${NAMESPACE}.svc.cluster.local"
  
  kubectl create secret generic signoz-secrets \
    --namespace "${NAMESPACE}" \
    --from-literal=jwt-secret="${jwt_secret_value}" \
    --from-literal=clickhouse-user="${CLICKHOUSE_USER}" \
    --from-literal=clickhouse-password="${CLICKHOUSE_PASSWORD}" \
    --from-literal=clickhouse-host="${clickhouse_host}" \
    --from-literal=clickhouse-port="${CLICKHOUSE_PORT}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  
  if [[ "${K8S_CLUSTER}" == "eks" ]]; then
    kubectl create secret generic signoz-aws-secrets \
      --namespace "${NAMESPACE}" \
      --from-literal=aws-access-key-id="${AWS_ACCESS_KEY_ID}" \
      --from-literal=aws-secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
      --from-literal=slack-webhook-url="${SLACK_WEBHOOK_URL}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    log "AWS secrets created"
  fi
  
  log "Secrets created successfully"
}

render_secret_template() {
  log "Rendering secret template to ${MANIFESTS_DIR}/secrets.template.yaml"
  
  cat > "${MANIFESTS_DIR}/secrets.template.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: signoz-secrets
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: signoz
    app.kubernetes.io/managed-by: signoz-rollout
type: Opaque
stringData:
  jwt-secret: "\${SIGNOZ_JWT_SECRET}"
  clickhouse-user: "\${CLICKHOUSE_USER:-signoz}"
  clickhouse-password: "\${CLICKHOUSE_PASSWORD:-signozpass}"
  clickhouse-host: "signoz-clickhouse.${NAMESPACE}.svc.cluster.local"
  clickhouse-port: "\${CLICKHOUSE_PORT:-9000}"
---
apiVersion: v1
kind: Secret
metadata:
  name: signoz-aws-secrets
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: signoz
    app.kubernetes.io/managed-by: signoz-rollout
type: Opaque
stringData:
  aws-access-key-id: "\${AWS_ACCESS_KEY_ID}"
  aws-secret-access-key: "\${AWS_SECRET_ACCESS_KEY}"
  slack-webhook-url: "\${SLACK_WEBHOOK_URL}"
EOF
  
  log "Secret template rendered (DO NOT COMMIT - contains placeholder values)"
}

render_helm_values() {
  log "Rendering Helm values to ${MANIFESTS_DIR}/values.yaml"
  
  local local_dev_mode="false"
  local storage_class="gp3"
  local cluster_name="prod-eks"
  local clickhouse_replicas=2
  local zookeeper_replicas=3
  local otel_replicas=3
  local query_replicas=3
  local frontend_replicas=2
  
  if [[ "${K8S_CLUSTER}" == "kind" ]]; then
    local_dev_mode="true"
    storage_class="local-path"
    cluster_name="kind-local"
    clickhouse_replicas=1
    zookeeper_replicas=1
    otel_replicas=1
    query_replicas=1
    frontend_replicas=1
  fi
  
  cat > "${MANIFESTS_DIR}/values.yaml" <<EOF
global:
  storageClass: ${storage_class}
  clusterName: "${cluster_name}"
  cloud: "${K8S_CLUSTER}"
telemetryStoreMigrator:
  enableReplication: $([ "${K8S_CLUSTER}" == "eks" ] && echo "true" || echo "false")
  timeout: "20m"
  env:
    - name: SIGNOZ_LOCAL_DEV_MODE
      value: "${local_dev_mode}"
clickhouse:
  enabled: true
  zookeeper:
    enabled: true
    replicaCount: ${zookeeper_replicas}
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
  persistence:
    enabled: true
    storageClass: ${storage_class}
    size: $([ "${K8S_CLUSTER}" == "eks" ] && echo "100Gi" || echo "10Gi")
  resources:
    requests:
      cpu: $([ "${K8S_CLUSTER}" == "eks" ] && echo "2" || echo "500m")
      memory: $([ "${K8S_CLUSTER}" == "eks" ] && echo "8Gi" || echo "1Gi")
  layout:
    shardsCount: $([ "${K8S_CLUSTER}" == "eks" ] && echo "2" || echo "1")
    replicasCount: ${clickhouse_replicas}
otelCollector:
  enabled: true
  replicaCount: ${otel_replicas}
  env:
    - name: SIGNOZ_LOCAL_DEV_MODE
      value: "${local_dev_mode}"
    - name: CLICKHOUSE_USER
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-user
    - name: CLICKHOUSE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-password
    - name: CLICKHOUSE_HOST
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-host
    - name: CLICKHOUSE_PORT
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-port
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
          http:
            endpoint: "0.0.0.0:4318"
      prometheus:
        config:
          scrape_configs:
            - job_name: 'ray-serve'
              kubernetes_sd_configs:
                - role: pod
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component]
                  action: keep
                  regex: ray-serve-app
                - source_labels: [__meta_kubernetes_pod_ip]
                  target_label: __address__
                  replacement: '\$1:8001'
                - source_labels: [__meta_kubernetes_namespace]
                  target_label: k8s_namespace
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: k8s_pod_name
            - job_name: 'ray-cluster'
              static_configs:
                - targets: ['ray-head.ray-system.svc.cluster.local:8080']
            - job_name: 'postgres'
              static_configs:
                - targets: ['app-postgres-r.databases.svc.cluster.local:9187']
    processors:
      batch:
        send_batch_size: $([ "${K8S_CLUSTER}" == "eks" ] && echo "10000" || echo "1000")
        timeout: $([ "${K8S_CLUSTER}" == "eks" ] && echo "5s" || echo "10s")
      k8sattributes:
        extract:
          metadata:
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.namespace.name
            - k8s.node.name
    exporters:
      clickhousetraces:
        datasource: "tcp://\${env:CLICKHOUSE_USER}:\${env:CLICKHOUSE_PASSWORD}@\${env:CLICKHOUSE_HOST}:\${env:CLICKHOUSE_PORT}/signoz_traces"
      signozclickhousemetrics:
        dsn: "tcp://\${env:CLICKHOUSE_USER}:\${env:CLICKHOUSE_PASSWORD}@\${env:CLICKHOUSE_HOST}:\${env:CLICKHOUSE_PORT}/signoz_metrics"
      clickhouselogsexporter:
        dsn: "tcp://\${env:CLICKHOUSE_USER}:\${env:CLICKHOUSE_PASSWORD}@\${env:CLICKHOUSE_HOST}:\${env:CLICKHOUSE_PORT}/signoz_logs"
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [k8sattributes, batch]
          exporters: [clickhousetraces]
        metrics:
          receivers: [otlp, prometheus]
          processors: [k8sattributes, batch]
          exporters: [signozclickhousemetrics]
        logs:
          receivers: [otlp]
          processors: [k8sattributes, batch]
          exporters: [clickhouselogsexporter]
frontend:
  replicaCount: ${frontend_replicas}
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
queryService:
  replicaCount: ${query_replicas}
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
  env:
    - name: SIGNOZ_LOCAL_DEV_MODE
      value: "${local_dev_mode}"
    - name: SIGNOZ_TOKENIZER_JWT_SECRET
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: jwt-secret
    - name: CLICKHOUSE_USER
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-user
    - name: CLICKHOUSE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-password
    - name: CLICKHOUSE_HOST
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-host
    - name: CLICKHOUSE_PORT
      valueFrom:
        secretKeyRef:
          name: signoz-secrets
          key: clickhouse-port
EOF
  
  log "Helm values rendered to ${MANIFESTS_DIR}/values.yaml"
}

wait_for_service_endpoints() {
  local svc_name="$1"
  local max_wait="${2:-120}"
  local elapsed=0
  log "Waiting for Service ${svc_name} endpoints"
  while ! kubectl -n "${NAMESPACE}" get endpoints "${svc_name}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q "."; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${max_wait} ]]; then
      fatal "Service ${svc_name} has no endpoints after ${max_wait}s"
    fi
  done
  log "Service ${svc_name} has endpoints"
}

wait_for_clickhouse_migration() {
  log "Waiting for ClickHouse migration completion"
  local ch_pod
  local max_wait=600
  local elapsed=0
  while true; do
    ch_pod=$(kubectl -n "${NAMESPACE}" get pods -l "clickhouse.altinity.com/chi=signoz-clickhouse" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
    if [[ -n "${ch_pod}" ]]; then
      if kubectl -n "${NAMESPACE}" exec "${ch_pod}" -c clickhouse -- clickhouse-client --query="SELECT 1 FROM system.clusters WHERE cluster='cluster'" >/dev/null 2>&1; then
        if kubectl -n "${NAMESPACE}" exec "${ch_pod}" -c clickhouse -- clickhouse-client --query="SELECT migration_id FROM signoz_metrics.distributed_schema_migrations_v2 WHERE status='finished' ORDER BY migration_id DESC LIMIT 1" >/dev/null 2>&1; then
          log "ClickHouse migration completed"
          return 0
        fi
      fi
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    if [[ ${elapsed} -ge ${max_wait} ]]; then
      fatal "ClickHouse migration timeout after ${max_wait}s"
    fi
    log "Waiting for ClickHouse migration... (${elapsed}s)"
  done
}

print_connection_info() {
  log "=== SIGNOZ CONNECTION INFORMATION ==="
  log ""
  log "UI Access:"
  log "  kubectl -n ${NAMESPACE} port-forward svc/signoz 3301:8080"
  log "  URL: http://localhost:3301"
  log ""
  log "OTLP Endpoints (for instrumentation):"
  log "  GRPC: signoz-otel-collector.${NAMESPACE}.svc.cluster.local:4317"
  log "  HTTP: signoz-otel-collector.${NAMESPACE}.svc.cluster.local:4318"
  log ""
  log "ClickHouse Connection (for direct queries):"
  log "  Host: signoz-clickhouse.${NAMESPACE}.svc.cluster.local"
  log "  Port: ${CLICKHOUSE_PORT}"
  log "  User: ${CLICKHOUSE_USER}"
  log "  Password: Retrieve via: kubectl -n ${NAMESPACE} get secret signoz-secrets -o jsonpath='{.data.clickhouse-password}' | base64 -d"
  log ""
  log "Retrieve Secrets:"
  log "  kubectl -n ${NAMESPACE} get secret signoz-secrets -o jsonpath='{.data}' | jq 'with_entries(.value |= @base64d)'"
  log ""
  log "Helm Warning (safe to ignore):"
  log "  coalesce.go: skipped value for zookeeper.initContainers - known chart bug, no impact [[1]][[4]][[6]]"
  log ""
  log "=== END CONNECTION INFORMATION ==="
}

install_signoz() {
  require_bin helm kubectl
  validate_environment
  ensure_dns_ready
  ensure_manifests_dir

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  log "Namespace ${NAMESPACE} ensured"

  create_secrets
  render_secret_template
  render_helm_values

  log "Adding Helm repository"
  helm repo add "${HELM_REPO}" "${HELM_REPO_URL}" --force-update >/dev/null 2>&1
  helm repo update >/dev/null 2>&1

  local timeout="900s"
  [[ "${K8S_CLUSTER}" == "kind" ]] && timeout="1200s"
  log "Installing SigNoz (timeout=${timeout})"

  if ! helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${HELM_VERSION}" \
    --values "${MANIFESTS_DIR}/values.yaml" \
    --atomic \
    --timeout "${timeout}" \
    --wait 2>&1 | tee /tmp/helm_output.log; then
    log "Helm install failed"
    kubectl -n "${NAMESPACE}" get pods -o wide 2>/dev/null || echo "No pods found"
    kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/name=signoz --tail=50 2>/dev/null || echo "No logs"
    fatal "Installation failed"
  fi
  
  if grep -q "coalesce.go.*warning.*zookeeper.initContainers" /tmp/helm_output.log 2>/dev/null; then
    log "Helm warning detected (non-critical): zookeeper.initContainers format mismatch"
  fi

  log "Waiting for ClickHouse migration completion"
  wait_for_clickhouse_migration

  log "Waiting for query-service readiness"
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/component=signoz \
    --timeout=300s; then
    kubectl -n "${NAMESPACE}" get pods -o wide 2>/dev/null
    kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/name=signoz --tail=50 2>/dev/null
    fatal "query-service not ready"
  fi

  log "Waiting for otel-collector readiness"
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/component=otel-collector \
    --timeout=180s; then
    kubectl -n "${NAMESPACE}" get pods -o wide 2>/dev/null
    kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/component=otel-collector --tail=50 2>/dev/null
    fatal "otel-collector not ready"
  fi

  log "Verifying ClickHouse service endpoints"
  wait_for_service_endpoints "signoz-clickhouse" 120

  log "Verifying ClickHouse connectivity"
  local ch_pod
  ch_pod=$(kubectl -n "${NAMESPACE}" get pods -l "clickhouse.altinity.com/chi=signoz-clickhouse" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "${ch_pod}" ]] || fatal "ClickHouse pod not found"
  kubectl -n "${NAMESPACE}" exec "${ch_pod}" -c clickhouse -- clickhouse-client --query="SELECT 1" >/dev/null
  log "All components healthy"
}

rollout() {
  log "=== STARTING SIGNOZ ROLLOUT (K8S_CLUSTER=${K8S_CLUSTER}) ==="
  install_signoz
  print_connection_info
  cat <<EOF
[SUCCESS] SigNoz deployed
NAMESPACE=${NAMESPACE}  RELEASE=${HELM_RELEASE}
MANIFESTS=${MANIFESTS_DIR}/values.yaml
EOF
}

rollout