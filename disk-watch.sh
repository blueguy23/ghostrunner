#!/bin/sh
# Runs as a sidecar container alongside the runner.
# Prunes Docker build artifacts when disk drops below threshold.
# docker volume prune is intentionally omitted — it would wipe runner-work
# and playwright-cache between jobs.

THRESHOLD_GB="${PRUNE_THRESHOLD_GB:-10}"
THRESHOLD_KB=$((THRESHOLD_GB * 1024 * 1024))
CHECK_INTERVAL=300  # Check every 5 minutes

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] disk-watcher: $*"; }

while true; do
  AVAILABLE_KB=$(df / | awk 'NR==2 {print $4}')
  AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))

  log "Disk available: ${AVAILABLE_GB}GB (threshold: ${THRESHOLD_GB}GB)"

  if [ "${AVAILABLE_KB}" -lt "${THRESHOLD_KB}" ]; then
    log "ALERT: Below threshold — pruning Docker system..."

    docker system prune -f --filter "until=6h"

    AFTER_KB=$(df / | awk 'NR==2 {print $4}')
    FREED_MB=$(( (AFTER_KB - AVAILABLE_KB) / 1024 ))
    log "Pruning complete. Freed ~${FREED_MB}MB"

    if [ "${AFTER_KB}" -lt "$((THRESHOLD_KB / 2))" ]; then
      log "CRITICAL: Disk still low after pruning. Manual intervention needed."
    fi
  fi

  sleep "${CHECK_INTERVAL}"
done
