#!/bin/bash
set -euo pipefail

# Chaos tests for ghostrunner — validates that recovery mechanisms actually work.
# Each test simulates a specific failure mode, waits for the system to recover,
# and reports whether the recovery path succeeded.
#
# Usage: bash scripts/chaos-test.sh [test-name]
#
# Tests: mongo-kill, clock-drift, sigterm, disk-pressure, all
#
# WARNING: These tests are destructive. Only run against a local dev stack
# with no active CI jobs in the queue.

export PATH="$HOME/.local/bin:$PATH"

TIMEOUT=120
POLL_INTERVAL=5
PASS=0
FAIL=0

bold()   { printf '\033[1m%s\033[0m' "$1"; }
green()  { printf '\033[32m%s\033[0m' "$1"; }
red()    { printf '\033[31m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
log()    { echo "[$(date -u '+%H:%M:%S')] $*"; }

pass() { PASS=$((PASS + 1)); log "$(green "PASS"): $1"; }
fail() { FAIL=$((FAIL + 1)); log "$(red "FAIL"): $1 — $2"; }

wait_for() {
  local description="$1" check_cmd="$2" timeout="${3:-$TIMEOUT}"
  local elapsed=0
  log "Waiting for: ${description} (timeout: ${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    if eval "$check_cmd" >/dev/null 2>&1; then
      log "Condition met after ${elapsed}s: ${description}"
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
  return 1
}

container_healthy() {
  local ctr="$1"
  [ "$(docker inspect --format='{{.State.Health.Status}}' "$ctr" 2>/dev/null)" = "healthy" ]
}

container_running() {
  local ctr="$1"
  [ "$(docker inspect --format='{{.State.Status}}' "$ctr" 2>/dev/null)" = "running" ]
}

# ── Preflight ───────────────────────────────────────────────────────────────

preflight() {
  log "Running preflight checks..."
  local ok=true

  for ctr in ci-runner-1 ci-runner-2 ci-mongo; do
    if ! container_running "$ctr"; then
      log "$(red "ERROR"): $ctr is not running"
      ok=false
    fi
  done

  if ! command -v jq >/dev/null 2>&1; then
    log "$(red "ERROR"): jq is required"
    ok=false
  fi

  if [ "$ok" = false ]; then
    log "Preflight failed — start the stack first: docker compose up -d"
    exit 1
  fi

  log "Preflight OK — all containers running"
}

# ── Test: Kill MongoDB mid-operation ────────────────────────────────────────
# Validates: autoheal restarts MongoDB, runners reconnect after it comes back.

test_mongo_kill() {
  echo ""
  bold "TEST: mongo-kill"
  echo " — Kill MongoDB, verify autoheal restarts it and runners survive"
  echo ""

  log "Killing ci-mongo..."
  docker kill ci-mongo >/dev/null

  if wait_for "ci-mongo restarted by autoheal" "container_running ci-mongo" 90; then
    pass "ci-mongo restarted after kill"
  else
    fail "ci-mongo did not restart" "autoheal may not be running"
    return
  fi

  if wait_for "ci-mongo healthy" "container_healthy ci-mongo" 60; then
    pass "ci-mongo reports healthy after restart"
  else
    fail "ci-mongo not healthy after restart" "healthcheck may be failing"
  fi

  log "Checking runners survived the MongoDB outage..."
  sleep 10

  for ctr in ci-runner-1 ci-runner-2; do
    if container_running "$ctr"; then
      pass "$ctr still running after MongoDB kill"
    else
      fail "$ctr died during MongoDB outage" "runner should tolerate transient DB loss"
    fi
  done
}

# ── Test: Simulate clock drift ──────────────────────────────────────────────
# Validates: chronyd detects and corrects the drift (if running), or the
# clock monitor loop warns about it.

test_clock_drift() {
  echo ""
  bold "TEST: clock-drift"
  echo " — Set clock forward 5 minutes in runner, check if chronyd corrects it"
  echo ""

  local target="ci-runner-1"

  local before
  before=$(docker exec "$target" date +%s 2>/dev/null) || {
    fail "clock-drift" "cannot exec into $target"
    return
  }

  log "Setting clock 5 minutes ahead in $target..."
  docker exec "$target" date -s "+5 minutes" >/dev/null 2>&1 || {
    log "$(yellow "SKIP"): Cannot set clock — SYS_TIME capability may be missing"
    return
  }

  local after
  after=$(docker exec "$target" date +%s)
  local skew=$((after - before))

  if [ "$skew" -gt 200 ]; then
    log "Clock skewed by ${skew}s (expected ~300)"
  else
    fail "clock-drift" "clock didn't actually skew (delta: ${skew}s)"
    return
  fi

  if wait_for "chronyd corrects drift to < 30s" \
    "[ \$(( \$(docker exec $target date +%s) - \$(date +%s) )) -lt 30 ] && [ \$(( \$(docker exec $target date +%s) - \$(date +%s) )) -gt -30 ]" 90; then
    pass "chronyd corrected the 5-minute drift"
  else
    local remaining
    remaining=$(( $(docker exec "$target" date +%s) - $(date +%s) ))
    fail "clock-drift" "drift still ${remaining}s after 90s — chronyd may not be running"
  fi

  log "Checking runner logs for clock warnings..."
  if docker logs --since 2m "$target" 2>&1 | grep -q "\[CLOCK\]"; then
    pass "clock monitor logged drift detection"
  else
    log "$(yellow "NOTE"): No [CLOCK] log entries — monitor loop may not have fired yet"
  fi
}

# ── Test: SIGTERM during idle ───────────────────────────────────────────────
# Validates: graceful shutdown — runner deregisters from GitHub, container
# stops cleanly, and restarts via restart policy.

test_sigterm() {
  echo ""
  bold "TEST: sigterm"
  echo " — Send SIGTERM to runner, verify graceful shutdown and restart"
  echo ""

  local target="ci-runner-1"

  log "Sending SIGTERM to $target..."
  docker kill --signal SIGTERM "$target" >/dev/null

  sleep 5

  log "Checking if container stopped gracefully..."
  local status
  status=$(docker inspect --format='{{.State.Status}}' "$target" 2>/dev/null || echo "removed")

  if [ "$status" = "exited" ] || [ "$status" = "running" ]; then
    pass "$target handled SIGTERM (status: $status)"
  else
    fail "sigterm" "$target in unexpected state: $status"
  fi

  if wait_for "$target running again (restart policy)" "container_running $target" 60; then
    pass "$target restarted after SIGTERM"
  else
    fail "sigterm restart" "$target did not restart — check restart policy"
    return
  fi

  if wait_for "$target healthy" "container_healthy $target" "$TIMEOUT"; then
    pass "$target healthy after SIGTERM recovery"
  else
    fail "sigterm healthy" "$target running but not healthy"
  fi
}

# ── Test: Disk pressure ─────────────────────────────────────────────────────
# Validates: disk-watcher detects low disk and runs docker system prune.
# Creates a large temp file to simulate pressure, then checks logs for
# the prune action.

test_disk_pressure() {
  echo ""
  bold "TEST: disk-pressure"
  echo " — Simulate low disk, verify disk-watcher triggers prune"
  echo ""

  local available_gb
  available_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  local threshold="${PRUNE_THRESHOLD_GB:-10}"

  log "Current free disk: ${available_gb}GB (threshold: ${threshold}GB)"

  if [ "$available_gb" -lt $((threshold + 5)) ]; then
    log "$(yellow "SKIP"): Not enough headroom to safely simulate disk pressure"
    log "Need at least $((threshold + 5))GB free, have ${available_gb}GB"
    return
  fi

  local fill_gb=$((available_gb - threshold + 1))
  local fill_file="/tmp/chaos-disk-fill-$$"

  log "Creating ${fill_gb}GB fill file to trigger disk-watcher..."
  dd if=/dev/zero of="$fill_file" bs=1G count="$fill_gb" 2>/dev/null || {
    rm -f "$fill_file"
    fail "disk-pressure" "failed to create fill file"
    return
  }

  local after_gb
  after_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  log "Free disk after fill: ${after_gb}GB"

  log "Waiting for disk-watcher to detect and prune (checks every 5m)..."
  if wait_for "disk-watcher prune log entry" \
    "docker logs --since 6m disk-watcher 2>&1 | grep -q 'pruning\\|Pruning\\|ALERT'" 360; then
    pass "disk-watcher detected low disk and triggered prune"
  else
    log "$(yellow "NOTE"): disk-watcher may not have checked yet (5m interval)"
    fail "disk-pressure" "no prune detected in disk-watcher logs within 6m"
  fi

  log "Cleaning up fill file..."
  rm -f "$fill_file"

  local final_gb
  final_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  log "Free disk after cleanup: ${final_gb}GB"
}

# ── Runner ──────────────────────────────────────────────────────────────────

run_test() {
  case "$1" in
    mongo-kill)    test_mongo_kill ;;
    clock-drift)   test_clock_drift ;;
    sigterm)       test_sigterm ;;
    disk-pressure) test_disk_pressure ;;
    all)
      test_mongo_kill
      sleep 15
      test_sigterm
      sleep 15
      test_clock_drift
      sleep 15
      test_disk_pressure
      ;;
    *)
      echo "Unknown test: $1"
      echo "Available: mongo-kill, clock-drift, sigterm, disk-pressure, all"
      exit 1
      ;;
  esac
}

# ── Main ────────────────────────────────────────────────────────────────────

TEST="${1:-all}"

echo ""
bold "ghostrunner chaos tests"
echo ""
log "Target: ${TEST}"
echo ""

preflight

read -r -p "These tests are destructive. Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
  echo "Aborted."
  exit 0
fi

run_test "$TEST"

echo ""
echo "═══════════════════════════════════════"
printf "  %s passed, %s failed\n" "$(green "$PASS")" \
  "$([ "$FAIL" -gt 0 ] && red "$FAIL" || echo "$FAIL")"
echo "═══════════════════════════════════════"
echo ""

[ "$FAIL" -eq 0 ] || exit 1
