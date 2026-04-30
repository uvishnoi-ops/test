#!/usr/bin/env bash
# End-to-end verification, run on worker1 after all four nodes are up.
# Each check is independent and prints PASS/FAIL with a one-line reason.
# Exits non-zero if any check fails so `vagrant up` surfaces the problem.
#
# All checks reach the control plane via tailnet hostnames, which is the
# whole point of putting the worker on a separate libvirt network.
set -uo pipefail

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
DIM=$'\033[2m'
RST=$'\033[0m'

FAIL_COUNT=0

pass() { printf "%s  PASS%s  %s\n" "$GREEN" "$RST" "$1"; }
fail() { printf "%s  FAIL%s  %s%s\n" "$RED" "$RST" "$1" "${2:+ ${DIM}— $2${RST}}"; FAIL_COUNT=$((FAIL_COUNT+1)); }

VAULT_HOST=$(echo "${SERVER_TS_HOSTS:-vcn-server-1,vcn-server-2,vcn-server-3}" | cut -d, -f1)
NOMAD_ADDR="http://${VAULT_HOST}:4646"
CONSUL_ADDR="http://${VAULT_HOST}:8500"
VAULT_ADDR="http://${VAULT_HOST}:8200"

INIT_FILE=/vagrant/.vault-keys/init.json
ROOT_TOKEN=""
if [ -s "$INIT_FILE" ]; then
  ROOT_TOKEN=$(jq -r .root_token "$INIT_FILE")
fi

echo
echo "=== Worker -> control-plane reachability (over tailnet) ==="

# 1. DNS / connectivity to all three servers.
for host in $(echo "${SERVER_TS_HOSTS}" | tr ',' ' '); do
  if curl -fsS --max-time 5 "http://${host}:8200/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" >/dev/null; then
    pass "vault on ${host} reachable"
  else
    fail "vault on ${host} reachable" "curl failed"
  fi
done

echo
echo "=== Vault raft cluster ==="

# 2. Raft has 3 voting peers.
if [ -n "$ROOT_TOKEN" ]; then
  PEERS_JSON=$(curl -fsS --max-time 5 \
    -H "X-Vault-Token: $ROOT_TOKEN" \
    "${VAULT_ADDR}/v1/sys/storage/raft/configuration" 2>/dev/null || echo '{}')
  VOTERS=$(echo "$PEERS_JSON" | jq '[.data.config.servers[]? | select(.voter == true)] | length' 2>/dev/null || echo 0)
  if [ "${VOTERS:-0}" -ge 3 ]; then
    pass "vault raft has ${VOTERS} voters"
  else
    fail "vault raft has 3 voters" "got ${VOTERS:-0}"
  fi
else
  fail "vault raft has 3 voters" "init.json missing on shared folder"
fi

echo
echo "=== Consul cluster ==="

# 3. Consul: 3 servers + worker as client, leader elected.
LEADER=$(curl -fsS --max-time 5 "${CONSUL_ADDR}/v1/status/leader" 2>/dev/null | tr -d '"')
if [ -n "$LEADER" ] && [ "$LEADER" != "null" ]; then
  pass "consul leader elected: ${LEADER}"
else
  fail "consul leader elected" "empty response"
fi

PEERS=$(curl -fsS --max-time 5 "${CONSUL_ADDR}/v1/status/peers" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
if [ "${PEERS:-0}" -ge 3 ]; then
  pass "consul has ${PEERS} server peers"
else
  fail "consul has 3 server peers" "got ${PEERS:-0}"
fi

# Worker should appear as a non-server member. Use the local agent so we
# look at the gossip pool from the worker's perspective.
WORKER_IN_POOL=$(curl -fsS --max-time 5 "http://127.0.0.1:8500/v1/agent/members" 2>/dev/null \
  | jq --arg n "$(hostname)" 'map(select(.Name == $n)) | length' 2>/dev/null || echo 0)
if [ "${WORKER_IN_POOL:-0}" -ge 1 ]; then
  pass "worker is in consul gossip pool"
else
  fail "worker is in consul gossip pool" "self not in /v1/agent/members"
fi

echo
echo "=== Nomad cluster ==="

# 4. Nomad: 3 servers, worker registered as ready.
NOMAD_LEADER=$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/status/leader" 2>/dev/null | tr -d '"')
if [ -n "$NOMAD_LEADER" ] && [ "$NOMAD_LEADER" != "null" ]; then
  pass "nomad leader elected: ${NOMAD_LEADER}"
else
  fail "nomad leader elected" "empty response"
fi

NOMAD_PEERS=$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/status/peers" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
if [ "${NOMAD_PEERS:-0}" -ge 3 ]; then
  pass "nomad has ${NOMAD_PEERS} server peers"
else
  fail "nomad has 3 server peers" "got ${NOMAD_PEERS:-0}"
fi

# Worker registration as a client. Wait up to 60s for it to flip to ready.
READY=""
for _ in $(seq 1 30); do
  READY=$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/nodes" 2>/dev/null \
    | jq -r --arg n "$(hostname)" '.[] | select(.Name == $n) | .Status' 2>/dev/null || true)
  [ "$READY" = "ready" ] && break
  sleep 2
done
if [ "$READY" = "ready" ]; then
  pass "worker registered as nomad client (status=ready)"
else
  fail "worker registered as nomad client (status=ready)" "status=${READY:-<missing>}"
fi

echo
echo "=== Test job: hello ==="

# 5. Submit the test job.
if [ "${NOMAD_PEERS:-0}" -ge 3 ] && [ "$READY" = "ready" ]; then
  if NOMAD_ADDR="$NOMAD_ADDR" nomad job run /vagrant/jobs/hello.nomad.hcl 2>&1 | tail -n 5; then
    pass "nomad job run hello submitted"
  else
    fail "nomad job run hello submitted"
  fi

  # Wait for an allocation to reach running.
  ALLOC_STATUS=""
  for _ in $(seq 1 60); do
    ALLOC_STATUS=$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/job/hello/allocations" 2>/dev/null \
      | jq -r '.[0].ClientStatus // empty')
    [ "$ALLOC_STATUS" = "running" ] && break
    [ "$ALLOC_STATUS" = "failed" ] && break
    sleep 2
  done
  if [ "$ALLOC_STATUS" = "running" ]; then
    pass "hello allocation is running"
  else
    fail "hello allocation is running" "ClientStatus=${ALLOC_STATUS:-<none>}"
  fi

  # 6. Vault template rendered into the task. The check passes if the
  # http endpoint returns text containing MESSAGE=.
  ALLOC_ID=$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/job/hello/allocations" 2>/dev/null \
    | jq -r '.[0].ID // empty')
  if [ -n "$ALLOC_ID" ]; then
    HTTP_PORT=$(curl -fsS --max-time 5 "${NOMAD_ADDR}/v1/allocation/${ALLOC_ID}" 2>/dev/null \
      | jq -r '.AllocatedResources.Shared.Networks[0].DynamicPorts[] | select(.Label=="http") | .Value' 2>/dev/null || echo "")
    if [ -n "$HTTP_PORT" ]; then
      # Hit the task locally on the worker — it's the only thing on this
      # libvirt network anyway.
      RESPONSE=$(curl -fsS --max-time 5 "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null || true)
      if echo "$RESPONSE" | grep -q "^MESSAGE="; then
        pass "vault template rendered into task ($(echo "$RESPONSE" | head -1))"
      else
        fail "vault template rendered into task" "response: ${RESPONSE:0:80}"
      fi
    else
      fail "vault template rendered into task" "no http port found"
    fi
  fi

  # 7. Consul service registered + check passing.
  HEALTH=""
  for _ in $(seq 1 30); do
    HEALTH=$(curl -fsS --max-time 5 "${CONSUL_ADDR}/v1/health/service/hello?passing=true" 2>/dev/null \
      | jq 'length' 2>/dev/null || echo 0)
    [ "${HEALTH:-0}" -ge 1 ] && break
    sleep 2
  done
  if [ "${HEALTH:-0}" -ge 1 ]; then
    pass "consul has hello service with passing check"
  else
    fail "consul has hello service with passing check" "0 passing instances"
  fi
else
  fail "test job submission" "skipped — cluster not ready"
fi

echo
echo "=== Summary ==="
if [ "$FAIL_COUNT" -eq 0 ]; then
  printf "%sAll checks passed.%s\n" "$GREEN" "$RST"
  exit 0
else
  printf "%s${FAIL_COUNT} check(s) failed.%s\n" "$RED" "$RST"
  exit 1
fi
