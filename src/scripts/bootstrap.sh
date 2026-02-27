sudo apt install unzip gh make tree vim jq -y

# Add keyrings and repository (official OpenTofu docs).
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://get.opentofu.org/opentofu.gpg | sudo tee /etc/apt/keyrings/opentofu.gpg >/dev/null
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | sudo gpg --no-tty --batch --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg >/dev/null
sudo chmod a+r /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg

echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" | \
  sudo tee /etc/apt/sources.list.d/opentofu.list >/dev/null
sudo chmod a+r /etc/apt/sources.list.d/opentofu.list

# Update package lists
sudo apt-get update

# Determine the repository candidate (exact package version string)
CANDIDATE=$(apt-cache policy tofu | awk '/Candidate:/ {print $2}')
if [ -z "$CANDIDATE" ] || [ "$CANDIDATE" = "(none)" ]; then
  echo "Error: no candidate version found for package 'tofu' (check network / repo)." >&2
  exit 1
fi

# Install that exact version and hold (pin) it so it won't auto-upgrade
sudo apt-get install -y "tofu=${CANDIDATE}"
sudo apt-mark hold tofu

# Verify
echo "Installed and pinned:"
tofu version || (echo "tofu binary not found in PATH" >&2; exit 1)
echo "Pinned apt status:"
apt-cache policy tofu

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/

curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.25.0/kind-linux-amd64 && \
chmod +x ./kind && sudo mv ./kind /usr/local/bin/


curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip


sudo apt install python3-pip python3-venv -y

python3 -m venv .venv && source .venv/bin/activate && pip install "SQLAlchemy==2.0.47" "asyncpg==0.31.0" "valkey-glide==2.2.7"


curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash