#!/usr/bin/env bash
# Install Nomad in client mode on the worker. The client points at the
# server tailnet hostnames (e.g. vcn-server-1) for both Nomad and Vault.
# Local Consul is on this host (consul_client.sh ran first).
set -euo pipefail

: "${NODE_NAME:?}"
: "${SERVER_TS_HOSTS:?}"

export DEBIAN_FRONTEND=noninteractive

if ! command -v nomad >/dev/null 2>&1; then
  echo "[nomad-client] installing nomad"
  apt-get install -yq nomad
fi

NOMAD_TOKEN_FILE=/vagrant/.vault-keys/nomad-token
echo "[nomad-client] waiting for $NOMAD_TOKEN_FILE"
for _ in $(seq 1 120); do
  [ -s "$NOMAD_TOKEN_FILE" ] && break
  sleep 1
done
if [ ! -s "$NOMAD_TOKEN_FILE" ]; then
  echo "[nomad-client] FATAL: $NOMAD_TOKEN_FILE not found" >&2
  exit 1
fi
NOMAD_VAULT_TOKEN=$(cat "$NOMAD_TOKEN_FILE")

TS_IP=$(cat /etc/vcn-lab/tailscale_ip)
SERVER_TS_HOSTS_LIST=$(echo "$SERVER_TS_HOSTS" \
  | awk -F',' '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1 ? ", " : ""), $i}')
# Use the first server hostname as the Vault target. Vault's HA forward
# means hitting any node works; we pick one for simplicity.
VAULT_TS_HOST=$(echo "$SERVER_TS_HOSTS" | cut -d, -f1)

install -d -o nomad -g nomad -m 0750 /opt/nomad/data
install -d -o nomad -g nomad -m 0750 /etc/nomad.d

umask 077
sed \
  -e "s|__NODE_NAME__|${NODE_NAME}|g" \
  -e "s|__TAILSCALE_IP__|${TS_IP}|g" \
  -e "s|__SERVER_TS_HOSTS_LIST__|${SERVER_TS_HOSTS_LIST}|g" \
  -e "s|__VAULT_TS_HOST__|${VAULT_TS_HOST}|g" \
  -e "s|__NOMAD_VAULT_TOKEN__|${NOMAD_VAULT_TOKEN}|g" \
  /vagrant/config/nomad-client.hcl.tpl > /etc/nomad.d/nomad.hcl
chown nomad:nomad /etc/nomad.d/nomad.hcl
chmod 0600 /etc/nomad.d/nomad.hcl
umask 022

cat > /etc/profile.d/nomad.sh <<EOF
export NOMAD_ADDR=http://127.0.0.1:4646
EOF
chmod 0644 /etc/profile.d/nomad.sh

systemctl enable nomad.service
systemctl restart nomad.service

echo "[nomad-client] waiting for client to register with servers (over tailnet)"
for _ in $(seq 1 90); do
  STATUS=$(curl -fsS http://127.0.0.1:4646/v1/agent/self 2>/dev/null \
    | jq -r '.stats.client.last_heartbeat // empty')
  if [ -n "$STATUS" ]; then break; fi
  sleep 2
done

echo "[nomad-client] done"
