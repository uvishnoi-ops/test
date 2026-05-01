#!/usr/bin/env bash
# Runs on follower nodes (server2, server3). Reads the unseal keys that
# the leader wrote to /vagrant/.vault-keys/init.json and unseals this
# node. Raft auto-join is already configured via retry_join in vault.hcl,
# so once unsealed the node will sync raft state from the leader.
set -euo pipefail

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh

export VAULT_ADDR=http://127.0.0.1:8200
INIT_FILE=/vagrant/.vault-keys/init.json

echo "[vault-unseal] waiting for $INIT_FILE to appear (leader must run init first)"
for _ in $(seq 1 120); do
  [ -s "$INIT_FILE" ] && break
  sleep 1
done
if [ ! -s "$INIT_FILE" ]; then
  echo "[vault-unseal] FATAL: $INIT_FILE not found" >&2
  exit 1
fi

# Wait for the local listener; with retry_join the node will keep trying
# to find the leader until it's unsealed.
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" >/dev/null && break
  sleep 1
done

if vault status -format=json | jq -e '.sealed == false' >/dev/null; then
  echo "[vault-unseal] already unsealed"
  exit 0
fi

mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
for key in "${KEYS[@]}"; do
  if vault status -format=json | jq -e '.sealed == false' >/dev/null; then
    break
  fi
  vault operator unseal "$key" >/dev/null
done

# After unseal, raft sync should kick in. Confirm we are part of the cluster.
# Use `if` rather than a command substitution so vault's non-zero exit code
# (2 = sealed) does not trigger set -e through the pipeline.
echo "[vault-unseal] waiting for raft join"
for _ in $(seq 1 60); do
  if vault status -format=json 2>/dev/null | jq -e '.ha_enabled == true' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

vault status || true
echo "[vault-unseal] done"

mark_done "$NODE_NAME" vault
