#!/usr/bin/env bash
# Install Consul in client mode on the worker. retry_join uses the
# Tailscale MagicDNS hostnames of the servers, so this only works after
# tailscale.sh has brought the worker onto the tailnet.
set -euo pipefail

: "${NODE_NAME:?}"
: "${NODE_TS_HOSTNAME:?}"
: "${SERVER_TS_HOSTS:?}"
: "${VAULT_BARRIER_NODES:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh
IFS=',' read -ra _vbn <<< "$VAULT_BARRIER_NODES"
wait_done vault "${_vbn[@]}"

export DEBIAN_FRONTEND=noninteractive

if ! command -v consul >/dev/null 2>&1; then
  echo "[consul-client] installing consul"
  apt-get install -yq consul
fi

TS_IP=$(cat /etc/vcn-lab/tailscale_ip)
if [ -z "$TS_IP" ]; then
  echo "[consul-client] FATAL: tailscale ip not found" >&2
  exit 1
fi

SERVER_TS_HOSTS_LIST=$(echo "$SERVER_TS_HOSTS" \
  | awk -F',' '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1 ? ", " : ""), $i}')

install -d -o consul -g consul -m 0750 /opt/consul
install -d -o consul -g consul -m 0750 /etc/consul.d

sed \
  -e "s|__NODE_NAME__|${NODE_NAME}|g" \
  -e "s|__TAILSCALE_IP__|${TS_IP}|g" \
  -e "s|__SERVER_TS_HOSTS_LIST__|${SERVER_TS_HOSTS_LIST}|g" \
  /vagrant/config/consul-client.hcl.tpl > /etc/consul.d/consul.hcl
chown consul:consul /etc/consul.d/consul.hcl
chmod 0640 /etc/consul.d/consul.hcl

cat > /etc/profile.d/consul.sh <<EOF
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
EOF
chmod 0644 /etc/profile.d/consul.sh

systemctl enable consul.service
systemctl restart consul.service

echo "[consul-client] waiting for join (servers must already be up)"
for _ in $(seq 1 90); do
  PEERS=$(curl -fsS http://127.0.0.1:8500/v1/status/peers 2>/dev/null || echo "[]")
  COUNT=$(echo "$PEERS" | jq 'length' 2>/dev/null || echo 0)
  if [ "${COUNT:-0}" -ge 3 ]; then break; fi
  sleep 2
done

curl -fsS http://127.0.0.1:8500/v1/status/peers || true
echo "[consul-client] done"

mark_done "$NODE_NAME" consul
