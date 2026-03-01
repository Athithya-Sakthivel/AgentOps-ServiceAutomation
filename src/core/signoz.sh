#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="signoz"
readonly HELM_RELEASE="signoz"
readonly HELM_REPO="signoz"
readonly HELM_REPO_URL="https://charts.signoz.io"
readonly HELM_CHART="signoz/signoz"
readonly HELM_VERSION="0.113.0"
readonly K8S_CLUSTER="${K8S_CLUSTER:-kind}"

readonly AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
readonly AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
readonly SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

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

dump_diagnostics() {
  log "=== SIGNOZ DIAGNOSTICS ==="
  kubectl -n "${NAMESPACE}" get pods -o wide 2>/dev/null || echo "No pods found"
  kubectl -n "${NAMESPACE}" get svc 2>/dev/null || echo "No services found"
  kubectl -n "${NAMESPACE}" logs -l app.kubernetes.io/name=signoz --tail=30 2>/dev/null || echo "No logs"
  kubectl get events --sort-by=.lastTimestamp -n "${NAMESPACE}" 2>/dev/null | tail -15 || true
  log "=== DIAGNOSTICS END ==="
}

generate_values() {
  case "${K8S_CLUSTER}" in
    kind)
      cat <<EOF
global:
  storageClass: local-path
  clusterName: "kind-local"
  cloud: "other"
telemetryStoreMigrator:
  enableReplication: false
  timeout: "20m"
clickhouse:
  enabled: true
  zookeeper:
    enabled: true
    replicaCount: 1
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
  persistence:
    enabled: true
    storageClass: local-path
    size: 10Gi
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
  layout:
    shardsCount: 1
    replicasCount: 1
otelCollector:
  enabled: true
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
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
        send_batch_size: 1000
        timeout: 10s
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
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
queryService:
  replicaCount: 1
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
EOF
      ;;
    eks)
      cat <<EOF
global:
  storageClass: gp3
  clusterName: "prod-eks-us-west-2"
  cloud: "aws"
telemetryStoreMigrator:
  enableReplication: true
  timeout: "20m"
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
clickhouse:
  enabled: true
  zookeeper:
    enabled: true
    replicaCount: 3
    resources:
      requests:
        cpu: 500m
        memory: 1Gi
      limits:
        cpu: "1"
        memory: 2Gi
    nodeSelector:
      node.kubernetes.io/role: observability
    tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "observability"
        effect: "NoSchedule"
  persistence:
    enabled: true
    storageClass: gp3
    size: 100Gi
    accessModes:
      - ReadWriteOnce
  resources:
    requests:
      cpu: "2"
      memory: 8Gi
    limits:
      cpu: "4"
      memory: 16Gi
  layout:
    shardsCount: 2
    replicasCount: 2
  nodeSelector:
    node.kubernetes.io/role: observability
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "observability"
      effect: "NoSchedule"
  coldStorage:
    enabled: true
    type: s3
    endpoint: "https://s3.us-west-2.amazonaws.com"
    accessKey: "\${AWS_ACCESS_KEY_ID}"
    secretAccess: "\${AWS_SECRET_ACCESS_KEY}"
    bucket: "signoz-cold-storage-prod"
otelCollector:
  enabled: true
  replicaCount: 3
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 5
    targetCPUUtilizationPercentage: 70
  resources:
    requests:
      cpu: "500m"
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 4Gi
  nodeSelector:
    node.kubernetes.io/role: observability
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "observability"
      effect: "NoSchedule"
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
            max_recv_msg_size_mib: 32
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
                - target_label: cluster
                  replacement: prod-eks-us-west-2
            - job_name: 'ray-cluster'
              kubernetes_sd_configs:
                - role: pod
                  namespaces:
                    names:
                      - ray-system
              relabel_configs:
                - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
                  action: keep
                  regex: ray
                - source_labels: [__meta_kubernetes_pod_ip]
                  target_label: __address__
                  replacement: '\$1:8080'
                - target_label: cluster
                  replacement: prod-eks-us-west-2
            - job_name: 'postgres'
              static_configs:
                - targets: ['app-postgres-r.databases.svc.cluster.local:9187']
              relabel_configs:
                - target_label: cluster
                  replacement: prod-eks-us-west-2
    processors:
      batch:
        send_batch_size: 10000
        timeout: 5s
      memory_limiter:
        limit_mib: 3000
        spike_limit_mib: 500
        check_interval: 5s
      k8sattributes:
        extract:
          metadata:
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.deployment.name
            - k8s.namespace.name
            - k8s.node.name
            - k8s.cluster.name
    exporters:
      clickhousetraces:
        datasource: "tcp://\${env:CLICKHOUSE_USER}:\${env:CLICKHOUSE_PASSWORD}@\${env:CLICKHOUSE_HOST}:\${env:CLICKHOUSE_PORT}/signoz_traces"
        timeout: 30s
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s
      signozclickhousemetrics:
        dsn: "tcp://\${env:CLICKHOUSE_USER}:\${env:CLICKHOUSE_PASSWORD}@\${env:CLICKHOUSE_HOST}:\${env:CLICKHOUSE_PORT}/signoz_metrics"
        timeout: 30s
      clickhouselogsexporter:
        dsn: "tcp://\${env:CLICKHOUSE_USER}:\${env:CLICKHOUSE_PASSWORD}@\${env:CLICKHOUSE_HOST}:\${env:CLICKHOUSE_PORT}/signoz_logs"
        timeout: 15s
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [clickhousetraces]
        metrics:
          receivers: [otlp, prometheus]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [signozclickhousemetrics]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [clickhouselogsexporter]
frontend:
  replicaCount: 2
  resources:
    requests:
      cpu: "250m"
      memory: 256Mi
    limits:
      cpu: "500m"
      memory: 512Mi
  service:
    type: ClusterIP
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
queryService:
  replicaCount: 3
  resources:
    requests:
      cpu: "500m"
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 4Gi
  nodeSelector:
    node.kubernetes.io/role: observability
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "observability"
      effect: "NoSchedule"
alertmanager:
  enabled: true
  config:
    route:
      receiver: 'slack-notifications'
    receivers:
      - name: 'slack-notifications'
        slack_configs:
          - api_url: "\${SLACK_WEBHOOK_URL}"
            channel: '#alerts'
            send_resolved: true
EOF
      ;;
  esac
}

install_signoz() {
  require_bin helm kubectl
  validate_environment
  ensure_dns_ready

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
    --values - \
    --atomic \
    --timeout "${timeout}" \
    --wait \
    < <(generate_values) >/dev/null 2>&1; then
    log "Helm install failed"
    dump_diagnostics
    fatal "Installation failed"
  fi

  log "Waiting for migrator completion"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete job -l app.kubernetes.io/name=signoz --timeout=300s 2>/dev/null || {
    log "Migrator job not found or failed - checking pod status"
  }

  log "Waiting for query-service readiness (label: app.kubernetes.io/component=signoz)"
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/component=signoz \
    --timeout=300s; then
    dump_diagnostics
    fatal "query-service not ready"
  fi

  log "Waiting for otel-collector readiness"
  if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/component=otel-collector \
    --timeout=180s; then
    dump_diagnostics
    fatal "otel-collector not ready"
  fi

  log "Verifying ClickHouse connectivity"
  local ch_pod
  ch_pod=$(kubectl -n "${NAMESPACE}" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "${ch_pod}" ]] || fatal "ClickHouse pod not found"
  kubectl -n "${NAMESPACE}" exec "${ch_pod}" -c clickhouse -- clickhouse-client --query="SELECT 1" >/dev/null
  log "All components healthy"
}

cleanup_signoz() {
  require_bin helm kubectl
  log "Uninstalling Helm release"
  helm uninstall "${HELM_RELEASE}" -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true

  log "Deleting namespace"
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s 2>/dev/null || true

  log "Waiting for namespace termination"
  for i in {1..40}; do
    kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || { log "Namespace deleted"; return 0; }
    sleep 3
  done
  fatal "Namespace deletion timed out"
}

rollout() {
  log "=== STARTING SIGNOZ ROLLOUT (K8S_CLUSTER=${K8S_CLUSTER}) ==="
  install_signoz
  cat <<EOF
[SUCCESS] SigNoz deployed
NAMESPACE=${NAMESPACE}  RELEASE=${HELM_RELEASE}
Access UI: kubectl -n ${NAMESPACE} port-forward svc/signoz-frontend 3301:3301
EOF
}

case "${1:-}" in
  --rollout) rollout ;;
  --cleanup) cleanup_signoz ;;
  --diagnose) dump_diagnostics ;;
  *) fatal "Usage: \$0 [--rollout|--cleanup|--diagnose]";;
esac