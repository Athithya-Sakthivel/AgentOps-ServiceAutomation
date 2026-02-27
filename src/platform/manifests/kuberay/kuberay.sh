#!/usr/bin/env bash
set -e

# Pin chart version explicitly
CHART_VERSION="1.5.1"

# Add repo (safe if already exists)
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ --force-update
helm repo update

# Install or upgrade (idempotent)
helm upgrade --install kuberay-operator kuberay/kuberay-operator \
  --namespace ray \
  --create-namespace \
  --version ${CHART_VERSION} \
  -f src/platform/manifests/kuberay/kuberay_values.yaml \
  --wait --atomic

kubectl get crds | grep ray
kubectl get pods -A
# helm uninstall kuberay-operator -n ray