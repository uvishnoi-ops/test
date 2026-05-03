#!/usr/bin/env bash
# Install Consul, render server-mode config, and start consul.service.
# All three servers run this; bootstrap_expect=3 means consul will wait
# for all three to be reachable on the LAN before electing a leader.
set -euo pipefail

: "${NODE_NAME:?}"
: "${SERVER_TS_HOSTS:?}"
: "${VAULT_BARRIER_NODES:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh
IFS=',' read -ra _vbn <<< "$VAULT_BARRIER_NODES"
wait_done vault "${_vbn[@]}"

NODE_TS_IP=$(cat /etc/vcn-lab/tailscale_ip)

export DEBIAN_FRONTEND=noninteractive

if ! command -v consul >/dev/null 2>&1; then
  echo "[consul-server] installing consul"
  apt-get install -yq consul
fi

# Convert "vcn-server-1,vcn-server-2,vcn-server-3" to "\"...\", \"...\", \"...\""
SERVER_TS_HOSTS_LIST=$(echo "$SERVER_TS_HOSTS" \
  | awk -F',' '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1 ? ", " : ""), $i}')

install -d -o consul -g consul -m 0750 /opt/consul
install -d -o consul -g consul -m 0750 /etc/consul.d

sed \
  -e "s|__NODE_NAME__|${NODE_NAME}|g" \
  -e "s|__NODE_TS_IP__|${NODE_TS_IP}|g" \
  -e "s|__SERVER_TS_HOSTS_LIST__|${SERVER_TS_HOSTS_LIST}|g" \
  /vagrant/config/consul-server.hcl.tpl > /etc/consul.d/consul.hcl
chown consul:consul /etc/consul.d/consul.hcl
chmod 0640 /etc/consul.d/consul.hcl

# CLI default for any operator who ssh's in.
cat > /etc/profile.d/consul.sh <<EOF
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
EOF
chmod 0644 /etc/profile.d/consul.sh

systemctl enable consul.service
systemctl restart consul.service

echo "[consul-server] waiting for local API"
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8500/v1/status/leader >/dev/null; then break; fi
  sleep 1
done

# We don't block on leader election here — bootstrap_expect=3 means the
# first two servers will sit waiting until the third joins. That's fine;
# the test runner on worker1 verifies leader election later.
curl -fsS http://127.0.0.1:8500/v1/status/leader || true
echo "[consul-server] done"

mark_done "$NODE_NAME" consul
