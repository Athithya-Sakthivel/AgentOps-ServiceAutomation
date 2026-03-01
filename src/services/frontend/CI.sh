#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-agentops-spa}"
IMAGE_TAG="${IMAGE_TAG:-staging-multiarch-v1}"
BUILD_CONTEXT="${BUILD_CONTEXT:-src/services/frontend}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-${BUILD_CONTEXT}/Dockerfile}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
REGISTRY_TYPE="${REGISTRY_TYPE:-dockerhub}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
TRIVY_IMAGE="${TRIVY_IMAGE:-athithya5354/trivy:0.68.2}"
TRIVY_SEVERITY="${TRIVY_SEVERITY:-CRITICAL}"

log(){ printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
err(){ printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

log "Starting SPA image build: ${IMAGE_NAME}:${IMAGE_TAG} (${REGISTRY_TYPE})"

[ -f "${DOCKERFILE_PATH}" ] || err "Dockerfile not found: ${DOCKERFILE_PATH}"
[ -d "${BUILD_CONTEXT}" ] || err "Build context not found: ${BUILD_CONTEXT}"

BUILDER_NAME="spa-builder"
if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  docker buildx create --name "${BUILDER_NAME}" --use --driver docker-container >/dev/null
fi
docker buildx inspect --bootstrap >/dev/null

if [ "${REGISTRY_TYPE}" = "ecr" ]; then
  [ -n "${ECR_REPO:-}" ] || err "ECR_REPO required for ECR"
  IMAGE_REF="${ECR_REPO}:${IMAGE_TAG}"
  log "Authenticating to ECR"
  aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "$(echo "${ECR_REPO}" | cut -d'/' -f1)"
else
  [ -n "${DOCKER_USERNAME:-}" ] || err "DOCKER_USERNAME required for Docker Hub"
  IMAGE_REF="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
  log "Authenticating to Docker Hub"
  printf '%s\n' "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin
fi

log "Building and pushing multi-arch image: ${IMAGE_REF}"
docker buildx build \
  --builder "${BUILDER_NAME}" \
  --platform "${PLATFORMS}" \
  --tag "${IMAGE_REF}" \
  --file "${DOCKERFILE_PATH}" \
  --push \
  "${BUILD_CONTEXT}"
log "Push complete: ${IMAGE_REF}"

log "Scanning pushed image with Trivy (image: ${TRIVY_IMAGE})"
EFFECTIVE_SEVERITY="${TRIVY_SEVERITY}"
if [ "${GITHUB_EVENT_NAME:-push}" = "workflow_dispatch" ]; then
  EFFECTIVE_SEVERITY="HIGH"
  log "Workflow dispatch detected: adjusting severity threshold to HIGH"
fi

docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  "${TRIVY_IMAGE}" \
  image --exit-code 1 --severity "${EFFECTIVE_SEVERITY}" --no-progress "${IMAGE_REF}" || {
  err "Trivy scan failed (threshold: ${EFFECTIVE_SEVERITY}). Fix vulnerabilities before proceeding."
}

log "Build, scan, and push completed successfully"