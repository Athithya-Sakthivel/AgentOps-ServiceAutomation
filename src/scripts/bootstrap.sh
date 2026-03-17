#!/usr/bin/env bash

echo "[INFO] apt update && apt upgrade"
apt update && apt upgrade -y

echo "[INFO] installing base packages"
apt install -y unzip gh make tree vim jq

echo "[INFO] ensure basic tools"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg apt-transport-https || true

echo "[INFO] preparing apt keyrings"
install -m 0755 -d /etc/apt/keyrings

echo "[INFO] adding opentofu GPG keys"
curl -fsSL https://get.opentofu.org/opentofu.gpg | tee /etc/apt/keyrings/opentofu.gpg >/dev/null
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | gpg --dearmor -o /tmp/opentofu-repo.gpg >/dev/null
mv /tmp/opentofu-repo.gpg /etc/apt/keyrings/opentofu-repo.gpg
chmod a+r /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg

echo "[INFO] adding opentofu APT repository"
echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" | tee /etc/apt/sources.list.d/opentofu.list >/dev/null
chmod a+r /etc/apt/sources.list.d/opentofu.list

echo "[INFO] refreshing apt"
apt-get update -qq

echo "[INFO] querying apt for tofu candidate version"
CANDIDATE="$(apt-cache policy tofu 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"

if [ -z "${CANDIDATE:-}" ] || [ "${CANDIDATE:-}" = "(none)" ]; then
  echo "[WARN] apt Candidate empty, trying apt-cache madison"
  CANDIDATE="$(apt-cache madison tofu 2>/dev/null | awk '{print $3}' | sed -n '1p' || true)"
fi

if [ -z "${CANDIDATE:-}" ] || [ "${CANDIDATE:-}" = "(none)" ]; then
  echo "[WARN] apt-cache madison returned nothing, falling back to package index scrape"
  CANDIDATE="$(curl -fsSL https://packages.opentofu.org/opentofu/tofu/packages/any/any/ \
    | grep -oE 'tofu_[0-9]+\.[0-9]+\.[0-9](_[0-9]+)?_amd64\.deb' \
    | sed -E 's/tofu_([0-9]+\.[0-9]+\.[0-9]).*/\1/' \
    | sort -V | tail -n1 || true)"
fi

if [ -z "${CANDIDATE:-}" ] || [ "${CANDIDATE:-}" = "(none)" ]; then
  echo "[ERROR] No installable tofu version found in APT repo. Abort." >&2
  echo "[TIP] Run: apt-cache policy tofu ; apt-cache madison tofu ; curl -fsSL https://packages.opentofu.org/opentofu/tofu/packages/any/any/ | sed -n '1,200p'"
  exit 1
fi

echo "[INFO] selected tofu version: ${CANDIDATE}"

echo "[INFO] installing tofu ${CANDIDATE}"
apt-get install -y --allow-downgrades "tofu=${CANDIDATE}" || {
  echo "[ERROR] apt install failed for tofu=${CANDIDATE}" >&2
  apt-cache policy tofu || true
  exit 1
}

apt-mark hold tofu

echo "[INFO] installing kubectl"
curl -LO https://dl.k8s.io/release/v1.30.1/bin/linux/amd64/kubectl
chmod +x kubectl
mv kubectl /usr/local/bin/

echo "[INFO] installing kind"
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-amd64
chmod +x ./kind
mv ./kind /usr/local/bin/

echo "[INFO] installing AWS CLI"
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

echo "[INFO] updating PATH in ~/.bashrc"
echo 'export PATH=$HOME/.local/bin:$HOME/go/bin:$PATH' >> ~/.bashrc
source ~/.bashrc || true

echo "[INFO] installing k6"
curl -s https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6.gpg
echo "deb [signed-by=/usr/share/keyrings/k6.gpg] https://dl.k6.io/deb stable main" > /etc/apt/sources.list.d/k6.list
apt update && apt install -y k6

echo "[INFO] installing helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | DESIRED_VERSION=v3.15.4 bash

echo "[INFO] installing gitleaks"
wget -qO- https://github.com/gitleaks/gitleaks/releases/download/v8.30.0/gitleaks_8.30.0_linux_x64.tar.gz | tar xz
mv gitleaks /usr/local/bin/gitleaks

echo "[INFO] installing golangci-lint v2.11.3"

if command -v go >/dev/null 2>&1; then
  echo "[INFO] go found; installing golangci-lint v2.11.3 via go install"
  go install github.com/golangci/golangci-lint/cmd/golangci-lint@v2.11.3 || true
fi
apt update
apt install -y postgresql-client

clear
echo "gitleaks version $(gitleaks version 2>/dev/null || true)"
echo "helm version: $(helm version 2>/dev/null || true)"
aws --version 2>/dev/null || true
echo "go version: $(go version 2>/dev/null || true)"
golangci-lint version 2>/dev/null || true
kubectl version --client || true
tofu version || true
k6 version || true