#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-agentops-spa}"
IMAGE_TAG="${IMAGE_TAG:-staging-multiarch-v3}"
BUILD_CONTEXT="${BUILD_CONTEXT:-src/services/frontend}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-${BUILD_CONTEXT}/Dockerfile}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
REGISTRY_TYPE="${REGISTRY_TYPE:-dockerhub}" # or ecr
AWS_REGION="${AWS_REGION:-ap-south-1}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy@sha256:3d1f862cb6c4fe13c1506f96f816096030d8d5ccdb2380a3069f7bf07daa86aa}"
INPUT_SEVERITY="${TRIVY_SEVERITY:-CRITICAL}"

BUILDER_NAME=""
LOCAL_BUILDER_NAME=""

log(){ printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
err(){ printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup(){
  if [ -n "${BUILDER_NAME}" ]; then
    docker buildx rm "${BUILDER_NAME}" 2>/dev/null || true
  fi
  if [ -n "${LOCAL_BUILDER_NAME}" ]; then
    docker buildx rm "${LOCAL_BUILDER_NAME}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log "Starting SPA image build: ${IMAGE_NAME}:${IMAGE_TAG} (${REGISTRY_TYPE})"
log "Input Severity Config: '${INPUT_SEVERITY}'"
log "Requested Platforms: ${PLATFORMS}"

[ -f "${DOCKERFILE_PATH}" ] || err "Dockerfile not found: ${DOCKERFILE_PATH}"
[ -d "${BUILD_CONTEXT}" ] || err "Build context not found: ${BUILD_CONTEXT}"

if [ "${REGISTRY_TYPE}" = "ecr" ]; then
  [ -n "${ECR_REPO:-}" ] || err "ECR_REPO required for ECR"
  IMAGE_REF="${ECR_REPO}:${IMAGE_TAG}"
  log "Authenticating to ECR (${AWS_REGION})"
  aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "$(echo "${ECR_REPO}" | cut -d'/' -f1)" >/dev/null 2>&1
else
  [ -n "${DOCKER_USERNAME:-}" ] || err "DOCKER_USERNAME required for Docker Hub"
  IMAGE_REF="${DOCKER_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"
  log "Authenticating to Docker Hub"
  printf '%s\n' "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin >/dev/null 2>&1
fi

CACHE_FROM="type=gha,scope=${IMAGE_NAME}"
CACHE_TO="type=gha,scope=${IMAGE_NAME},mode=max"

CURRENT_ARCH=$(docker info --format '{{.Architecture}}')
SCAN_PLATFORM="linux/${CURRENT_ARCH}"

log "Building local image for scan (platform: ${SCAN_PLATFORM})"
docker buildx build \
  --platform "${SCAN_PLATFORM}" \
  --tag "${IMAGE_REF}" \
  --file "${DOCKERFILE_PATH}" \
  --cache-from "${CACHE_FROM}" \
  --load \
  "${BUILD_CONTEXT}"

log "Scanning local image with Trivy (threshold: ${INPUT_SEVERITY})"
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  "${TRIVY_IMAGE}" \
  image --exit-code 1 --severity "${INPUT_SEVERITY}" --no-progress "${IMAGE_REF}" || {
  err "Trivy scan failed (threshold: ${INPUT_SEVERITY}). Fix vulnerabilities before proceeding."
}

if [ "${PUSH}" = "true" ]; then
  log "Pushing multi-arch image: ${IMAGE_REF} (platforms: ${PLATFORMS})"
  BUILDER_NAME="spa-builder-$$"
  docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use >/dev/null
  
  docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform "${PLATFORMS}" \
    --tag "${IMAGE_REF}" \
    --file "${DOCKERFILE_PATH}" \
    --cache-from "${CACHE_FROM}" \
    --cache-to "${CACHE_TO}" \
    --provenance=true \
    --sbom=true \
    --push \
    "${BUILD_CONTEXT}"
  log "Push complete: ${IMAGE_REF}"
else
  log "PUSH=false, skipping push"
fi

log "Build, scan, and push completed successfully"