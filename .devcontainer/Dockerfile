# PREREQUISITES: Docker running, enabled on boot, and must be accessible without sudo(sudo usermod -aG docker $USER && newgrp docker)

FROM golang:1.26.1-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# install utilities and Docker CLI (kept from original file)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl gnupg lsb-release openssh-client socat apt-transport-https gnupg2 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
       https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli qemu-user-static \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
