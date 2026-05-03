#!/usr/bin/env bash
# Runs on worker1 after all three Nomad servers have finished provisioning
# (bootstrap_expect=3 means Nomad has a leader only once all three are up).
#
# Configures Vault's JWT auth method so Nomad Workload Identity tokens can
# be exchanged for Vault tokens by task-local Nomad clients:
#   1. Wait for nomad-server phase barrier on all three servers
#   2. Wait for Nomad leader election
#   3. Enable JWT auth at vault/auth/jwt/  (idempotent)
#   4. Point it at Nomad's JWKS endpoint (rotated keys published there)
#   5. Create the nomad-cluster JWT role bound to the nomad-job policy
#
# The JWT role MUST be named "nomad-cluster" — Nomad 1.7 uses
# create_from_role as the role name when calling auth/jwt/login.
#
# Vault is reached over the tailnet (VAULT_TS_HOST).
# Nomad JWKS is fetched from NOMAD_TS_HOST (any Nomad server; same keys).
set -euo pipefail

: "${NOMAD_BARRIER_NODES:?}"
: "${VAULT_TS_HOST:?}"
: "${NOMAD_TS_HOST:?}"

# shellcheck source=phase_barrier.sh
source /vagrant/scripts/phase_barrier.sh

# Phase barrier: wait for all three nomad servers.
IFS=',' read -ra _barrier <<< "$NOMAD_BARRIER_NODES"
wait_done nomad "${_barrier[@]}"

INIT_FILE=/vagrant/.vault-keys/init.json
if [ ! -s "$INIT_FILE" ]; then
  echo "[vault-nomad-wi] FATAL: $INIT_FILE not found" >&2
  exit 1
fi

VAULT_BASE="http://${VAULT_TS_HOST}:8200"
ROOT_TOKEN=$(jq -r .root_token "$INIT_FILE")
NOMAD_JWKS_URL="http://${NOMAD_TS_HOST}:4646/.well-known/jwks.json"

# ---------------------------------------------------------------------------
# Helper: Vault API call (curl-based; vault CLI is not installed on worker1).
# Usage: vault_req METHOD path [json-body]
# ---------------------------------------------------------------------------
vault_req() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -fsS \
      -X "$method" \
      -H "X-Vault-Token: ${ROOT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "${VAULT_BASE}/v1/${path}"
  else
    curl -fsS \
      -X "$method" \
      -H "X-Vault-Token: ${ROOT_TOKEN}" \
      "${VAULT_BASE}/v1/${path}"
  fi
}

# ---------------------------------------------------------------------------
# 1. Wait for Nomad leader (needed so the JWKS endpoint is serving).
# ---------------------------------------------------------------------------
echo "[vault-nomad-wi] waiting for Nomad leader"
LEADER=""
for _ in $(seq 1 60); do
  LEADER=$(curl -fsS --max-time 3 \
    "http://${NOMAD_TS_HOST}:4646/v1/status/leader" 2>/dev/null \
    | tr -d '"' || true)
  if [ -n "$LEADER" ] && [ "$LEADER" != "null" ]; then break; fi
  sleep 3
done
if [ -z "$LEADER" ] || [ "$LEADER" = "null" ]; then
  echo "[vault-nomad-wi] FATAL: Nomad has no leader after waiting" >&2
  exit 1
fi
echo "[vault-nomad-wi] Nomad leader: $LEADER"

# ---------------------------------------------------------------------------
# 2. Enable JWT auth at jwt/ (idempotent — ignore 400 "already in use").
# ---------------------------------------------------------------------------
if vault_req GET sys/auth 2>/dev/null | jq -e '."jwt/"' >/dev/null 2>&1; then
  echo "[vault-nomad-wi] JWT auth already enabled at jwt/"
else
  echo "[vault-nomad-wi] enabling JWT auth at jwt/"
  vault_req POST sys/auth/jwt '{"type":"jwt"}' >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. Configure the JWT backend to trust Nomad's JWKS.
#    default_role matches create_from_role so logins without an explicit
#    role parameter still land on the right role.
# ---------------------------------------------------------------------------
echo "[vault-nomad-wi] configuring JWT backend (JWKS: $NOMAD_JWKS_URL)"
CONFIG_BODY=$(jq -n \
  --arg jwks_url  "$NOMAD_JWKS_URL" \
  --arg def_role  "nomad-cluster" \
  '{
    jwks_url:             $jwks_url,
    jwt_supported_algs:   ["RS256","EdDSA"],
    default_role:         $def_role
  }')
vault_req POST auth/jwt/config "$CONFIG_BODY" >/dev/null

# ---------------------------------------------------------------------------
# 4. Create the nomad-cluster JWT role.
#    Name MUST match create_from_role in nomad-server/client.hcl.tpl —
#    Nomad 1.7 passes create_from_role as the role when calling
#    auth/<jwt_auth_backend_path>/login for Workload Identity.
#    bound_audiences must match the `aud` in default_identity on the server.
#
#    user_claim = "sub": the vault_default identity JWT only carries standard
#    OIDC claims (sub, aud, iat, exp, nbf, jti). Nomad-specific claims such as
#    nomad_job_id and nomad_namespace are NOT present unless an explicit
#    `identity` block with custom extra_claims is configured in the job spec.
#    Using "sub" (format: region:namespace:job:group:task) is safe and unique.
#
#    token_period (seconds) keeps tokens alive while Nomad renews them.
# ---------------------------------------------------------------------------
echo "[vault-nomad-wi] writing nomad-cluster JWT role"
ROLE_BODY=$(cat <<'EOF'
{
  "role_type":        "jwt",
  "bound_audiences":  ["vault.io"],
  "user_claim":       "sub",
  "token_type":       "service",
  "token_policies":   ["nomad-job"],
  "token_period":     "3600",
  "token_explicit_max_ttl": 0
}
EOF
)
vault_req POST auth/jwt/role/nomad-cluster "$ROLE_BODY" >/dev/null

echo "[vault-nomad-wi] JWT auth configured; tasks using vault_default WI can now authenticate"
