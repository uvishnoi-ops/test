#!/usr/bin/env bash
# Runs only on the raft leader (server1). Initializes Vault if not already
# initialized, writes unseal keys + root token to a Vagrant-shared folder
# (so followers can read them), and unseals the leader.
#
# WARNING: keys are written in cleartext to /vagrant/.vault-keys. Lab only.
set -euo pipefail

export VAULT_ADDR=http://127.0.0.1:8200
KEY_DIR=/vagrant/.vault-keys
INIT_FILE="${KEY_DIR}/init.json"

mkdir -p "$KEY_DIR"
chmod 0700 "$KEY_DIR"

if vault status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null; then
  echo "[vault-init] already initialized; skipping init"
else
  echo "[vault-init] running operator init (3 shares, threshold 2)"
  vault operator init \
    -key-shares=3 \
    -key-threshold=2 \
    -format=json > "$INIT_FILE"
  chmod 0600 "$INIT_FILE"
  sync
fi

if [ ! -s "$INIT_FILE" ]; then
  echo "[vault-init] FATAL: $INIT_FILE missing/empty after init" >&2
  exit 1
fi

# Unseal until the node reports sealed=false.
mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
for key in "${KEYS[@]}"; do
  if vault status -format=json | jq -e '.sealed == false' >/dev/null; then
    break
  fi
  vault operator unseal "$key" >/dev/null
done

# Wait for the node to become active leader (single-node raft cluster
# at this point; followers join later).
echo "[vault-init] waiting for active leader"
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8200/v1/sys/health >/dev/null; then
    break
  fi
  sleep 1
done

ROOT_TOKEN=$(jq -r .root_token "$INIT_FILE")
VAULT_TOKEN=$ROOT_TOKEN vault status
echo "[vault-init] leader is up; root token saved to $INIT_FILE"
