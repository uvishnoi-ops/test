#!/usr/bin/env bash
# Install Vault (HashiCorp apt repo), render /etc/vault.d/vault.hcl from
# the template using node-specific values, and start vault.service. The
# server starts up sealed; init/unseal happens in vault_init_unseal.sh
# (leader) or vault_unseal.sh (followers).
set -euo pipefail

: "${NODE_NAME:?}"
: "${NODE_LAN_IP:?}"
: "${RAFT_LEADER_IP:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh
wait_done tailscale "$NODE_NAME"

export DEBIAN_FRONTEND=noninteractive

if ! command -v vault >/dev/null 2>&1; then
  echo "[vault-install] installing vault"
  apt-get install -yq vault
fi

install -d -o vault -g vault -m 0750 /opt/vault/data
install -d -o vault -g vault -m 0750 /etc/vault.d

# Render config from template.
sed \
  -e "s|__NODE_NAME__|${NODE_NAME}|g" \
  -e "s|__NODE_LAN_IP__|${NODE_LAN_IP}|g" \
  -e "s|__RAFT_LEADER_IP__|${RAFT_LEADER_IP}|g" \
  /vagrant/config/vault.hcl.tpl > /etc/vault.d/vault.hcl
chown vault:vault /etc/vault.d/vault.hcl
chmod 0640 /etc/vault.d/vault.hcl

# Drop dev/demo defaults from the package and rely on our config only.
if [ -f /etc/vault.d/vault.env ]; then
  cat > /etc/vault.d/vault.env <<EOF
VAULT_ADDR=http://${NODE_LAN_IP}:8200
EOF
  chown vault:vault /etc/vault.d/vault.env
fi

# Cluster-wide CLI defaults for any operator who ssh's in.
cat > /etc/profile.d/vault.sh <<EOF
export VAULT_ADDR=http://127.0.0.1:8200
EOF
chmod 0644 /etc/profile.d/vault.sh

systemctl enable --now vault.service

# Wait for the API to come up. With raft + retry_join, the API answers
# even before init/unseal — we just want the listener bound.
echo "[vault-install] waiting for vault listener on 127.0.0.1:8200"
for _ in $(seq 1 60); do
  # /sys/health returns 501 when uninitialized, 503 when sealed, 200 when
  # active. Any of those means the listener is up. uninitcode/sealedcode
  # remap those into 200 for the curl exit.
  if curl -fsS "http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" >/dev/null; then
    break
  fi
  sleep 1
done

VAULT_ADDR=http://127.0.0.1:8200 vault status || true
echo "[vault-install] done"
