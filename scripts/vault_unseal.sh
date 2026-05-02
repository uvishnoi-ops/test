#!/usr/bin/env bash
# Runs on follower nodes (server2, server3).
# Sequence:
#   1. Wait for local Vault API to answer
#   2. Explicitly join the Raft cluster (vault operator raft join)
#   3. Wait for the node to become initialized (cluster state synced from leader)
#   4. Unseal using keys from the shared init file
set -euo pipefail

: "${NODE_NAME:?}"
: "${RAFT_LEADER_IP:?}"
: "${VAULT_UNSEAL_BARRIER_NODES:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh

# Wait for every preceding server to complete its full vault phase before
# attempting raft-join + unseal on this node. On server2 this means
# waiting for server1-vault (written at the end of vault_seed.sh). On
# server3 it means waiting for server1-vault AND server2-vault.
IFS=',' read -ra _barrier <<< "$VAULT_UNSEAL_BARRIER_NODES"
wait_done vault "${_barrier[@]}"

export VAULT_ADDR=http://127.0.0.1:8200
INIT_FILE=/vagrant/.vault-keys/init.json

# 1. Wait for the shared init file (leader must complete vault-init first).
echo "[vault-unseal] waiting for $INIT_FILE"
for _ in $(seq 1 120); do
  [ -s "$INIT_FILE" ] && break
  sleep 1
done
if [ ! -s "$INIT_FILE" ]; then
  echo "[vault-unseal] FATAL: $INIT_FILE not found after waiting" >&2
  exit 1
fi

# 2. Wait for the local Vault listener to be up.
echo "[vault-unseal] waiting for local vault listener"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# 3. Join the Raft cluster if this node is not yet initialized.
#    retry_join in vault.hcl may have already done this; vault operator raft
#    join is idempotent — it returns an error if already joined which we
#    suppress so the script can confirm initialization in the next step.
if ! vault status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "[vault-unseal] joining raft cluster at leader ${RAFT_LEADER_IP}"
  vault operator raft join "http://${RAFT_LEADER_IP}:8200" || true
fi

# Wait for initialized state (cluster state has been synced from the leader).
echo "[vault-unseal] waiting for initialized state"
for _ in $(seq 1 60); do
  if vault status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! vault status -format=json 2>/dev/null | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "[vault-unseal] FATAL: node did not reach initialized state" >&2
  exit 1
fi

# 4. Unseal.
if vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null 2>&1; then
  echo "[vault-unseal] already unsealed"
else
  mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
  for key in "${KEYS[@]}"; do
    if vault status -format=json 2>/dev/null | jq -e '.sealed == false' >/dev/null 2>&1; then
      break
    fi
    echo "[vault-unseal] applying unseal key"
    vault operator unseal "$key" >/dev/null
  done
fi

# Confirm the node is unsealed and has joined the raft cluster.
echo "[vault-unseal] waiting for raft ha_enabled"
for _ in $(seq 1 60); do
  if vault status -format=json 2>/dev/null | jq -e '.ha_enabled == true' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

vault status || true
echo "[vault-unseal] done"

mark_done "$NODE_NAME" vault
