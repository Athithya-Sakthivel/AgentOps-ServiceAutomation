#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# build-and-deploy.sh
#
# Expects environment variables (set by GH Actions):
#   DOCKER_REGISTRY      (e.g. ghcr.io or myregistry.example.com)
#   DOCKER_USERNAME
#   DOCKER_PASSWORD
#   KUBE_CONFIG_DATA     (base64 kubeconfig)
#   IMAGE_FULL           (full image with tag: registry/repo:tag)
#   IMAGE_TAG            (tag only)
#   SEARCH_IMAGE         (image string to replace in manifests, default placeholder)
#   RAYSERVICE_MANIFEST  (path to manifests/rayservice.yaml)
#   RAYSERVICE_NAME      (name of the RayService CR)
#   NAMESPACE            (k8s namespace)
# ---------------------------

# sanity checks
: "${DOCKER_REGISTRY:?DOCKER_REGISTRY must be set}"
: "${DOCKER_USERNAME:?DOCKER_USERNAME must be set}"
: "${DOCKER_PASSWORD:?DOCKER_PASSWORD must be set}"
: "${KUBE_CONFIG_DATA:?KUBE_CONFIG_DATA must be set}"
: "${IMAGE_FULL:?IMAGE_FULL must be set}"
: "${IMAGE_TAG:?IMAGE_TAG must be set}"
: "${SEARCH_IMAGE:=myregistry.example.com/team/my-ray-serve:2.54.0}"
: "${RAYSERVICE_MANIFEST:=manifests/rayservice.yaml}"
: "${RAYSERVICE_NAME:=my-serve-app}"
: "${NAMESPACE:=default}"

echo "==== Build & push image ===="
echo "IMAGE_FULL=$IMAGE_FULL"

# ensure docker buildx builder exists
docker buildx inspect default >/dev/null 2>&1 || docker buildx create --use

# build & push image (single-platform; add --platform if needed)
docker buildx build --push --tag "${IMAGE_FULL}" .

echo "Pushed ${IMAGE_FULL}"

echo "==== Configure kubectl ===="
# write kubeconfig from base64 secret
KUBECONFIG_PATH="${HOME}/.kube/config"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
echo "${KUBE_CONFIG_DATA}" | base64 --decode > "${KUBECONFIG_PATH}"
chmod 600 "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"
kubectl version --short

echo "==== Patch manifest with new image ===="
if [ ! -f "${RAYSERVICE_MANIFEST}" ]; then
  echo "ERROR: manifest ${RAYSERVICE_MANIFEST} not found"
  exit 2
fi

# Back up original and create a temp file
cp "${RAYSERVICE_MANIFEST}" "${RAYSERVICE_MANIFEST}.bak"

# Replace placeholder image occurrences with built image.
# The manifest is expected to contain the placeholder SEARCH_IMAGE; adjust SEARCH_IMAGE if necessary.
sed "s|${SEARCH_IMAGE}|${IMAGE_FULL}|g" "${RAYSERVICE_MANIFEST}.bak" > "${RAYSERVICE_MANIFEST}.patched"

echo "Patched manifest saved to ${RAYSERVICE_MANIFEST}.patched (not applied yet)."

echo "==== Apply manifest ===="
kubectl apply -f "${RAYSERVICE_MANIFEST}.patched" -n "${NAMESPACE}"

echo "==== Wait for RayService resource to exist ===="
# Wait up to 180s for the CR to appear
RETRIES=60
i=0
while [ $i -lt $RETRIES ]; do
  if kubectl get rayservice "${RAYSERVICE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Found RayService/${RAYSERVICE_NAME}"
    break
  fi
  i=$((i+1))
  sleep 3
done
if [ $i -ge $RETRIES ]; then
  echo "Timed out waiting for RayService CR to be created"
  kubectl get rayservice -n "${NAMESPACE}" || true
  exit 3
fi

echo "==== Wait for pods using the image to be Ready ===="
# We'll wait for pods that reference IMAGE_FULL to reach Ready condition.
# Install jq if needed (on GH runners jq is usually present; include fallback)
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  sudo apt-get update -y
  sudo apt-get install -y jq
fi

TIMEOUT=900  # seconds
INTERVAL=6
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  # list pods in namespace with any container image that contains the registry/repo (IMAGE without tag)
  PODS_JSON=$(kubectl get pods -n "${NAMESPACE}" -o json)
  # find pods where any container image equals IMAGE_FULL (or starts with registry/repo)
  PODS_MATCH=$(echo "${PODS_JSON}" | jq -r --arg img "${IMAGE_FULL}" '
    .items[] |
    select(
      (.status.containerStatuses != null and (.status.containerStatuses[]?.image == $img))
      or
      (.spec.containers[]? | .image == $img)
    ) | .metadata.name' || true)

  if [ -z "${PODS_MATCH}" ]; then
    echo "No pods yet using image ${IMAGE_FULL}. waiting..."
  else
    ALL_READY=true
    for pod in ${PODS_MATCH}; do
      ready_cond=$(kubectl get pod "$pod" -n "${NAMESPACE}" -o json | jq -r '.status.conditions[]? | select(.type=="Ready") | .status' || echo "Unknown")
      echo "Pod $pod Ready condition: ${ready_cond}"
      if [ "${ready_cond}" != "True" ]; then
        ALL_READY=false
      fi
    done

    if [ "${ALL_READY}" = true ]; then
      echo "All pods using ${IMAGE_FULL} are Ready."
      break
    else
      echo "Some pods are not Ready yet."
    fi
  fi

  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "Timed out waiting for pods to become Ready after ${TIMEOUT}s."
  echo "Pods status:"
  kubectl get pods -n "${NAMESPACE}" -o wide
  exit 4
fi

echo "==== Post-deploy checks (RayService status) ===="
# Try to show a summary of RayService status (best-effort; structure may vary by KubeRay version)
kubectl get rayservice "${RAYSERVICE_NAME}" -n "${NAMESPACE}" -o yaml | sed -n '1,200p'

echo "Deployment complete. You may now monitor Prometheus/Grafana and the Ray dashboard."