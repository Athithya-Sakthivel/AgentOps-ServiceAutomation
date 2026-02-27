#!/usr/bin/env bash
set -euo pipefail

SOURCE_IMAGES="${SOURCE_IMAGES:-ghcr.io/cloudnative-pg/postgresql:16.10-minimal-trixie,valkey/valkey:9.0.2-alpine}"
DOCKER_USERNAME="${DOCKER_USERNAME:=athithya5354}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:?Set DOCKER_PASSWORD}"
TARGET_PREFIX="${TARGET_PREFIX:-$DOCKER_USERNAME}"
PUSH="${PUSH:-true}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

log(){ printf "\033[0;34m[INFO]\033[0m %s\n" "$*"; }
err(){ printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; }

retry() {
  local n=0
  until "$@"; do
    n=$((n+1))
    [ "$n" -ge 4 ] && return 1
    sleep $((2**n))
  done
}

command -v docker >/dev/null || { err "docker required"; exit 1; }

printf '%s\n' "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin

IFS=',' read -ra IMAGE_ARRAY <<< "$SOURCE_IMAGES"

for SRC in "${IMAGE_ARRAY[@]}"; do
  SRC="$(echo "$SRC" | xargs)"

  IMAGE_NAME="$(echo "$SRC" | awk -F/ '{print $NF}' | awk -F: '{print $1}')"
  IMAGE_TAG="$(echo "$SRC" | awk -F: '{print $NF}')"

  TARGET="docker.io/${TARGET_PREFIX}/${IMAGE_NAME}:${IMAGE_TAG}"

  log "Processing $SRC -> $TARGET"

  if [ "$PUSH" != "true" ]; then
    log "PUSH=false, skipping push"
    continue
  fi

  if docker manifest inspect "$TARGET" >/dev/null 2>&1; then
    log "Remote image exists. Skipping $TARGET"
    continue
  fi

  if [ -n "$PLATFORMS" ]; then
    log "Mirroring multi-arch image for platforms: $PLATFORMS"
    retry docker buildx imagetools create \
      --platform "$PLATFORMS" \
      -t "$TARGET" \
      "$SRC"
  else
    log "PLATFORMS empty → single-arch mirror"
    retry docker pull "$SRC"
    docker tag "$SRC" "$TARGET"
    retry docker push "$TARGET"
  fi

  log "Completed $TARGET"
done

log "All images mirrored successfully"