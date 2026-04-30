#!/usr/bin/env bash
# Base packages, sysctls, and HashiCorp apt repo. Idempotent.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[common] apt update"
apt-get update -qq

echo "[common] base packages"
apt-get install -yq --no-install-recommends \
  curl \
  ca-certificates \
  gnupg \
  lsb-release \
  jq \
  unzip \
  iproute2 \
  iputils-ping \
  dnsutils \
  net-tools \
  socat

# HashiCorp apt repo (used by vault_install / consul_* / nomad_*).
if [ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]; then
  echo "[common] adding HashiCorp apt repo"
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -qq
fi

# Disable swap (Nomad client requirement on hosts that run jobs).
if [ "$(swapon --show=NAME --noheadings | wc -l)" -gt 0 ]; then
  echo "[common] disabling swap"
  swapoff -a || true
  sed -i.bak '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab || true
fi

# Sysctls helpful for Consul/Nomad (more conntrack, larger socket buffers).
cat > /etc/sysctl.d/99-vcn-lab.conf <<'EOF'
net.netfilter.nf_conntrack_max = 262144
net.core.somaxconn = 4096
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

echo "[common] done"
