#!/usr/bin/env bash
# Phase barrier helpers. Source this from provisioner scripts.
#
# mark_done NODE PHASE  — record that NODE has finished PHASE
# wait_done PHASE NODE… — block until each NODE has finished PHASE (5-min timeout each)

BARRIER_DIR=/vagrant/.done

mark_done() {
  local node=$1 phase=$2
  mkdir -p "$BARRIER_DIR"
  touch "${BARRIER_DIR}/${node}-${phase}"
  echo "[barrier] ${node}: ${phase} done"
}

wait_done() {
  local phase=$1; shift
  for node in "$@"; do
    local marker="${BARRIER_DIR}/${node}-${phase}"
    if [ -f "$marker" ]; then
      echo "[barrier] ${node}-${phase} already done"
      continue
    fi
    echo "[barrier] waiting for ${node}-${phase} ..."
    for _ in $(seq 1 150); do
      [ -f "$marker" ] && break
      sleep 2
    done
    if [ ! -f "$marker" ]; then
      echo "[barrier] FATAL: timed out waiting for ${node}-${phase}" >&2
      exit 1
    fi
    echo "[barrier] ${node}-${phase} ready"
  done
}
