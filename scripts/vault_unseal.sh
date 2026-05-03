#!/usr/bin/env bash
# Runs on follower nodes (server2, server3).
# Sequence:
#   1. Phase barrier: wait for all preceding servers to finish vault
#   2. Wait for local Vault API listener
#   3. vault operator raft join (explicit; idempotent if retry_join already ran)
#   4. Wait for initialized == true  (cluster state synced from leader)
#   5. Unseal with keys from shared init file
#   6. Wait for sealed == false to confirm success
set -euo pipefail

: "${NODE_NAME:?}"
: "${RAFT_LEADER_TS_HOSTNAME:?}"
: "${VAULT_UNSEAL_BARRIER_NODES:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh

# Phase barrier: wait for every preceding server's full vault phase.
# server2 waits for server1-vault; server3 waits for server1-vault + server2-vault.
IFS=',' read -ra _barrier <<< "$VAULT_UNSEAL_BARRIER_NODES"
wait_done vault "${_barrier[@]}"

export VAULT_ADDR=http://127.0.0.1:8200
INIT_FILE=/vagrant/.vault-keys/init.json

# ---------------------------------------------------------------------------
# Helper: fetch vault seal-status via curl.
# /v1/sys/seal-status always returns HTTP 200 regardless of initialized/sealed
# state, so curl exits 0 every time. This avoids the set -euo pipefail trap
# where `vault status` exits 2 (sealed) propagating through a pipeline even
# when jq successfully finds the field we want.
# ---------------------------------------------------------------------------
vault_seal_status() {
  curl -fsS http://127.0.0.1:8200/v1/sys/seal-status 2>/dev/null
}

# 1. Wait for the shared init file (leader must finish vault-init first).
echo "[vault-unseal] waiting for $INIT_FILE"
for _ in $(seq 1 120); do
  [ -s "$INIT_FILE" ] && break
  sleep 1
done
if [ ! -s "$INIT_FILE" ]; then
  echo "[vault-unseal] FATAL: $INIT_FILE not found after waiting" >&2
  exit 1
fi

# 2. Wait for the local Vault listener.
echo "[vault-unseal] waiting for local vault listener"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# 3. Explicitly join the Raft cluster.
#    retry_join in vault.hcl may have already done this automatically;
#    vault operator raft join is idempotent (|| true handles already-joined).
if ! vault_seal_status | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "[vault-unseal] joining raft cluster at leader ${RAFT_LEADER_TS_HOSTNAME}"
  vault operator raft join "http://${RAFT_LEADER_TS_HOSTNAME}:8200" || true
fi

# 4. Wait for initialized == true (leader has synced cluster state to this node).
echo "[vault-unseal] waiting for initialized state"
for _ in $(seq 1 60); do
  if vault_seal_status | jq -e '.initialized == true' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! vault_seal_status | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "[vault-unseal] FATAL: node did not reach initialized state after raft join" >&2
  exit 1
fi
echo "[vault-unseal] node is initialized"

# 5. Unseal.
if vault_seal_status | jq -e '.sealed == false' >/dev/null 2>&1; then
  echo "[vault-unseal] already unsealed"
else
  mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
  for key in "${KEYS[@]}"; do
    if vault_seal_status | jq -e '.sealed == false' >/dev/null 2>&1; then
      break
    fi
    echo "[vault-unseal] applying unseal key"
    vault operator unseal "$key" >/dev/null
  done
fi

# 6. Confirm unsealed.
echo "[vault-unseal] waiting for sealed == false"
for _ in $(seq 1 60); do
  if vault_seal_status | jq -e '.sealed == false' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! vault_seal_status | jq -e '.sealed == false' >/dev/null 2>&1; then
  echo "[vault-unseal] FATAL: node is still sealed after applying unseal keys" >&2
  exit 1
fi

vault_seal_status | jq .
echo "[vault-unseal] done"

mark_done "$NODE_NAME" vault
