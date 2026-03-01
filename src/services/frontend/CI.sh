#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-agentops-spa}"
IMAGE_TAG="${IMAGE_TAG:-staging-multiarch-v1}"
BUILD_CONTEXT="${BUILD_CONTEXT:-src/frontend}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-${BUILD_CONTEXT}/Dockerfile}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
REGISTRY_TYPE="${REGISTRY_TYPE:-dockerhub}"
AWS_REGION="${AWS_REGION:-ap-south-1}"

log(){ printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
err(){ printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

log "Starting SPA image build: ${IMAGE_NAME}:${IMAGE_TAG} (${REGISTRY_TYPE})"

if [ ! -f "${DOCKERFILE_PATH}" ]; then err "Dockerfile not found: ${DOCKERFILE_PATH}"; fi
if [ ! -d "${BUILD_CONTEXT}" ]; then err "Build context not found: ${BUILD_CONTEXT}"; fi

BUILDER_NAME="spa-builder"
if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDER_NAME}" --use --driver docker-container >/dev/null
fi
docker buildx inspect --bootstrap >/dev/null

if [ "${REGISTRY_TYPE}" = "ecr" ]; then
  if [ -z "${ECR_REPO:-}" ]; then err "ECR_REPO required for ECR"; fi
  IMAGE_REF="${ECR_REPO}:${IMAGE_TAG}"
  log "Authenticating to ECR"
  aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "$(echo "${ECR_REPO}" | cut -d'/' -f1)"
else
  if [ -z "${DOCKER_USERNAME:-}" ]; then err "DOCKER_USERNAME required for Docker Hub"; fi
  IMAGE_REF="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
  log "Authenticating to Docker Hub"
  printf '%s\n' "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
fi

log "Downloading security scanners"

# Trivy v0.69.1 (verified asset name)
TRIVY_VERSION="0.69.1"
TRIVY_URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
curl -fL -o /tmp/trivy.tar.gz "${TRIVY_URL}" || err "Failed to download Trivy from ${TRIVY_URL}"
tar -xzf /tmp/trivy.tar.gz -C /tmp trivy
rm -f /tmp/trivy.tar.gz
chmod +x /tmp/trivy

# OpenGrep v1.16.2 (verified asset name)
OPENGREP_VERSION="1.16.2"
OPENGREP_URL="https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/opengrep_manylinux_x86"
OPENGREP_SHA256="6f74e2624cd9b54e2cbca500dc9905c132b610cba487d2493a948d9d08b8fcb9"
curl -fL -o /tmp/opengrep "${OPENGREP_URL}" || err "Failed to download OpenGrep from ${OPENGREP_URL}"
echo "${OPENGREP_SHA256}  /tmp/opengrep" | sha256sum -c - >/dev/null || err "OpenGrep checksum failed"
chmod +x /tmp/opengrep

log "Scanning source for secrets with OpenGrep"
/tmp/opengrep scan "${BUILD_CONTEXT}" --exit-code 1 || {
  err "OpenGrep detected security issues in source. Review findings above."
}

log "Building multi-arch image: ${IMAGE_REF}"
docker buildx build \
  --builder "${BUILDER_NAME}" \
  --platform "${PLATFORMS}" \
  --tag "${IMAGE_REF}" \
  --file "${DOCKERFILE_PATH}" \
  --output "type=docker" \
  "${BUILD_CONTEXT}"

log "Scanning image with Trivy"
SEVERITY_THRESHOLD="CRITICAL"
if [ "${GITHUB_EVENT_NAME:-push}" = "workflow_dispatch" ]; then
  SEVERITY_THRESHOLD="HIGH"
fi
/tmp/trivy image --exit-code 1 --severity "${SEVERITY_THRESHOLD}" "${IMAGE_REF}" || {
  err "Trivy scan failed (threshold: ${SEVERITY_THRESHOLD}). Fix vulnerabilities before proceeding."
}

if [ "${PUSH}" = "true" ]; then
  log "Pushing image to registry"
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${PLATFORMS}" \
    --tag "${IMAGE_REF}" \
    --file "${DOCKERFILE_PATH}" \
    --push \
    "${BUILD_CONTEXT}"
  log "Push complete: ${IMAGE_REF}"
else
  log "PUSH=false, skipping registry push"
fi

log "Build, scan, and push completed successfully"