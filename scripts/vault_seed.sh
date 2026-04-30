#!/usr/bin/env bash
# Runs on the raft leader (server1) AFTER vault_init_unseal.sh. At this
# point Vault is a single-node raft cluster (server2/3 join later when
# they boot, and storage is replicated). Anything we write here lands in
# the cluster state and shows up on followers automatically.
#
# Outputs:
#   - kv/test/hello                       (KV v2 secret read by the test job)
#   - sys/policies/acl/nomad-server       (policy used by the periodic
#                                          token Nomad servers will use)
#   - sys/policies/acl/nomad-job          (policy that tasks request via
#                                          their `vault { policies = [...] }`
#                                          stanza)
#   - auth/token/roles/nomad-cluster      (token role tasks are issued
#                                          tokens from)
#   - /vagrant/.vault-keys/nomad-token    (the periodic token that Nomad
#                                          servers/clients use)
set -euo pipefail

export VAULT_ADDR=http://127.0.0.1:8200
KEY_DIR=/vagrant/.vault-keys
INIT_FILE="${KEY_DIR}/init.json"
NOMAD_TOKEN_FILE="${KEY_DIR}/nomad-token"

if [ ! -s "$INIT_FILE" ]; then
  echo "[vault-seed] FATAL: $INIT_FILE missing — leader init did not run" >&2
  exit 1
fi
export VAULT_TOKEN
VAULT_TOKEN=$(jq -r .root_token "$INIT_FILE")

# Wait for active leader before doing any writes.
echo "[vault-seed] waiting for active leader"
for _ in $(seq 1 60); do
  if vault status -format=json | jq -e '.sealed == false and .initialized == true' >/dev/null; then
    break
  fi
  sleep 1
done

# Enable KV v2 at kv/ if not already enabled.
if ! vault secrets list -format=json | jq -e '."kv/"' >/dev/null; then
  echo "[vault-seed] enabling kv-v2 at kv/"
  vault secrets enable -path=kv -version=2 kv
fi

echo "[vault-seed] writing kv/test/hello"
vault kv put kv/test/hello \
  message="hello from vault, rendered into a nomad task" \
  rendered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null

# Policies. nomad-server is what the periodic token has; nomad-job is
# what tasks request via their job spec.
echo "[vault-seed] writing nomad-server policy"
vault policy write nomad-server - <<'EOF'
# Nomad-Vault integration: the server uses this policy to create
# per-task tokens scoped to nomad-job (or any policy in the role's
# allowed_policies list).
path "auth/token/create/nomad-cluster" {
  capabilities = ["update"]
}
path "auth/token/roles/nomad-cluster" {
  capabilities = ["read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/lookup" {
  capabilities = ["update"]
}
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}
path "sys/capabilities-self" {
  capabilities = ["update"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
EOF

echo "[vault-seed] writing nomad-job policy"
vault policy write nomad-job - <<'EOF'
# What tasks (the hello job in particular) are allowed to read.
path "kv/data/test/*" {
  capabilities = ["read"]
}
EOF

echo "[vault-seed] writing nomad-cluster token role"
vault write auth/token/roles/nomad-cluster \
  allowed_policies="nomad-job" \
  disallowed_policies="nomad-server" \
  token_explicit_max_ttl=0 \
  orphan=true \
  token_period="259200" \
  renewable=true >/dev/null

# Mint a periodic token bound to nomad-server. Periodic tokens never
# expire as long as Nomad keeps renewing them; with period=72h the
# renewal window is comfortable.
echo "[vault-seed] minting periodic nomad-server token"
NOMAD_TOKEN_JSON=$(vault token create \
  -policy=nomad-server \
  -period=72h \
  -orphan=true \
  -format=json)
NOMAD_TOKEN=$(echo "$NOMAD_TOKEN_JSON" | jq -r .auth.client_token)

if [ -z "$NOMAD_TOKEN" ] || [ "$NOMAD_TOKEN" = "null" ]; then
  echo "[vault-seed] FATAL: failed to mint Nomad token" >&2
  echo "$NOMAD_TOKEN_JSON" >&2
  exit 1
fi

echo "$NOMAD_TOKEN" > "$NOMAD_TOKEN_FILE"
chmod 0600 "$NOMAD_TOKEN_FILE"

echo "[vault-seed] done. nomad token written to $NOMAD_TOKEN_FILE"
