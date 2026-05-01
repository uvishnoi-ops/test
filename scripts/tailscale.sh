#!/usr/bin/env bash
# Install Tailscale and bring the node up on the tailnet with a stable
# hostname. Idempotent: re-running does nothing if the daemon is already
# logged in with the right hostname.
set -euo pipefail

: "${TS_AUTHKEY:?TS_AUTHKEY must be set (passed in from Vagrantfile)}"
: "${TS_HOSTNAME:?TS_HOSTNAME must be set (passed in from Vagrantfile)}"
: "${NODE_NAME:?NODE_NAME must be set (passed in from Vagrantfile)}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh

if ! command -v tailscale >/dev/null 2>&1; then
  echo "[tailscale] installing"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

# Wait for tailscaled to be ready.
for _ in $(seq 1 30); do
  if tailscale status --json >/dev/null 2>&1; then break; fi
  sleep 1
done

CURRENT_BACKEND=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')
CURRENT_HOST=$(tailscale status --json 2>/dev/null | jq -r '.Self.HostName // ""')

if [ "$CURRENT_BACKEND" = "Running" ] && [ "$CURRENT_HOST" = "$TS_HOSTNAME" ]; then
  echo "[tailscale] already up as $CURRENT_HOST"
else
  echo "[tailscale] bringing up as $TS_HOSTNAME"
  tailscale up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" \
    --accept-dns=true \
    --ssh=false \
    --reset
fi

# Wait for a tailnet IPv4 to be assigned (needed by Consul/Nomad
# advertise_addr on the worker).
for _ in $(seq 1 30); do
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if [ -n "${TS_IP:-}" ]; then break; fi
  sleep 1
done

if [ -z "${TS_IP:-}" ]; then
  echo "[tailscale] FATAL: no tailnet IPv4 assigned" >&2
  exit 1
fi

echo "[tailscale] up: hostname=$TS_HOSTNAME ip=$TS_IP"

# Persist the tailnet IP for later provisioners on this node.
mkdir -p /etc/vcn-lab
echo "$TS_IP" > /etc/vcn-lab/tailscale_ip
echo "$TS_HOSTNAME" > /etc/vcn-lab/tailscale_hostname

mark_done "$NODE_NAME" tailscale
