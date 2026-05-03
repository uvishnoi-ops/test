#!/usr/bin/env bash
# Install Nomad in server mode and integrate with local Vault using the
# periodic token written by vault_seed.sh on server1. server2 and server3
# read the same token from the shared folder (it works cluster-wide once
# raft replication catches up).
set -euo pipefail

: "${NODE_NAME:?}"
: "${SERVER_TS_HOSTS:?}"
: "${CONSUL_BARRIER_NODES:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh
IFS=',' read -ra _cbn <<< "$CONSUL_BARRIER_NODES"
wait_done consul "${_cbn[@]}"

NODE_TS_IP=$(cat /etc/vcn-lab/tailscale_ip)

export DEBIAN_FRONTEND=noninteractive

if ! command -v nomad >/dev/null 2>&1; then
  echo "[nomad-server] installing nomad"
  apt-get install -yq nomad
fi

NOMAD_TOKEN_FILE=/vagrant/.vault-keys/nomad-token

# Wait for the Vault-issued nomad token. server1 produces this in
# vault_seed.sh which runs before nomad_server.sh on server1; server2/3
# need to wait for that file to appear via rsync (they are provisioned
# after server1 is finished).
echo "[nomad-server] waiting for $NOMAD_TOKEN_FILE"
for _ in $(seq 1 120); do
  [ -s "$NOMAD_TOKEN_FILE" ] && break
  sleep 1
done
if [ ! -s "$NOMAD_TOKEN_FILE" ]; then
  echo "[nomad-server] FATAL: $NOMAD_TOKEN_FILE not found" >&2
  exit 1
fi
NOMAD_VAULT_TOKEN=$(cat "$NOMAD_TOKEN_FILE")

SERVER_TS_HOSTS_LIST=$(echo "$SERVER_TS_HOSTS" \
  | awk -F',' '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1 ? ", " : ""), $i}')

install -d -o nomad -g nomad -m 0750 /opt/nomad/data
install -d -o nomad -g nomad -m 0750 /etc/nomad.d

# Write config with token. Mode 0600 since it embeds a Vault token.
umask 077
sed \
  -e "s|__NODE_NAME__|${NODE_NAME}|g" \
  -e "s|__NODE_TS_IP__|${NODE_TS_IP}|g" \
  -e "s|__SERVER_TS_HOSTS_LIST__|${SERVER_TS_HOSTS_LIST}|g" \
  -e "s|__NOMAD_VAULT_TOKEN__|${NOMAD_VAULT_TOKEN}|g" \
  /vagrant/config/nomad-server.hcl.tpl > /etc/nomad.d/nomad.hcl
chown nomad:nomad /etc/nomad.d/nomad.hcl
chmod 0600 /etc/nomad.d/nomad.hcl
umask 022

cat > /etc/profile.d/nomad.sh <<EOF
export NOMAD_ADDR=http://127.0.0.1:4646
EOF
chmod 0644 /etc/profile.d/nomad.sh

systemctl enable nomad.service
systemctl restart nomad.service

echo "[nomad-server] waiting for local agent"
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:4646/v1/agent/self >/dev/null; then break; fi
  sleep 1
done

# Don't block on bootstrap — like consul, the first two servers wait for
# the third. run_tests.sh on the worker confirms the cluster is healthy.
curl -fsS http://127.0.0.1:4646/v1/status/leader || true
echo "[nomad-server] done"

mark_done "$NODE_NAME" nomad
