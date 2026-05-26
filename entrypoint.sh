#!/bin/bash
set -euo pipefail

# ── Privilege drop ────────────────────────────────────────────────────────────
if [ "$(id -u)" = "0" ]; then
  /preflight-check.sh || exit $?

  # Clock sync must run as root with SYS_TIME capability (set in docker-compose.yml).
  # Start chronyd as a daemon so chronyc can be used for periodic re-sync.
  # WSL2 desyncs after host sleep — fix before gosu so TLS ops don't fail.
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Syncing clock..."
  chronyd 2>/dev/null || \
    ntpdate -u pool.ntp.org 2>/dev/null || \
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] WARNING: Could not sync clock — TLS errors may follow"
  chronyc makestep 1.0 3 >/dev/null 2>&1 || true
  chronyc tracking 2>/dev/null | grep "System time" | \
    awk '{print "[CLOCK] startup offset: " $4 " " $5}' || true

  # Start cron as root before dropping privileges — needs /var/run/crond.pid
  cron

  # DNS fallback — WSL2 DNS breaks silently after network changes or VPN cycles.
  grep -q '8.8.8.8' /etc/resolv.conf || echo 'nameserver 8.8.8.8' >> /etc/resolv.conf

  # gosu uses initgroups() which only reads /etc/group — Docker's group_add is
  # applied at the container process level but gosu drops it when switching user.
  # Register the socket GID in /etc/group so Runner.Listener inherits it.
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  getent group "$SOCK_GID" >/dev/null 2>&1 || groupadd -g "$SOCK_GID" docker-sock
  usermod -aG "$SOCK_GID" garci

  mkdir -p /home/garci/actions-runner/_work
  if [ "${EXTERNAL_MONGODB:-}" != "true" ]; then
    mkdir -p /data/db
    chown garci:garci /data/db
  fi
  chown -R garci:garci /home/garci
  exec gosu garci "$0" "$@"
fi

# ── From here: running as garci ───────────────────────────────────────────────
# Exported for sourced scripts (registration.sh, background-loops.sh)
if [ -z "${REPO_OWNER:-}" ] || [ -z "${REPO_NAME:-}" ]; then
  echo "FATAL: REPO_OWNER and REPO_NAME must be set" >&2; exit 1
fi
export REPO_OWNER
export REPO_NAME
export REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
export RUNNER_NAME="${RUNNER_NAME:-ci-docker}"
export SESSION_CONFLICT_WAIT="${SESSION_CONFLICT_WAIT:-30}"
export GITHUB_API="https://api.github.com"
export CURL_CMD="${CURL_CMD:-curl}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ── Registration functions (testable via CURL_CMD override) ──────────────────
source /scripts/registration.sh

# ── 1. Docker Hub auth (optional — prevents anonymous pull rate limits) ───────
if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  log "Authenticating with Docker Hub..."
  echo "${DOCKERHUB_TOKEN}" | docker login --username "${DOCKERHUB_USERNAME}" --password-stdin
  log "Docker Hub auth: OK"
else
  log "No Docker Hub credentials — anonymous pulls limited to 100/6hr"
fi

# ── 2. MongoDB ────────────────────────────────────────────────────────────────
MONGODB_URI="${MONGODB_URI:-mongodb://localhost:27017}"

if [ "${EXTERNAL_MONGODB:-}" = "true" ]; then
  log "Using external MongoDB at ${MONGODB_URI}"
  for i in $(seq 1 30); do
    mongosh "$MONGODB_URI" --eval "db.adminCommand('ping')" --quiet 2>/dev/null && break
    log "Waiting for external MongoDB... ($i/30)"
    sleep 2
    [ "$i" = "30" ] && { log "ERROR: External MongoDB not ready after 60s"; exit 1; }
  done
else
  mongod \
    --dbpath /data/db \
    --bind_ip 127.0.0.1 \
    --fork \
    --logpath /tmp/mongod.log \
    --quiet
  log "MongoDB started — waiting for readiness..."
  for i in $(seq 1 30); do
    mongosh --eval "db.adminCommand('ping')" --quiet 2>/dev/null && break
    sleep 1
    [ "$i" = "30" ] && { log "ERROR: MongoDB not ready after 30s"; exit 1; }
  done
fi
log "MongoDB ready"

cd /home/garci/actions-runner

# ── 3. Background loops (clock sync + PAT re-validation) ─────────────────────
CLOCK_SYNC_PID=""
TOKEN_WATCH_PID=""

source /scripts/background-loops.sh

_clock_sync_loop &
CLOCK_SYNC_PID=$!

_token_watch_loop &
TOKEN_WATCH_PID=$!

# ── 4. Graceful shutdown ─────────────────────────────────────────────────────
STOP=0

_cleanup() {
  log "Caught signal — stopping runner loop..."
  STOP=1
  [ -n "${TOKEN_WATCH_PID:-}" ] && kill "$TOKEN_WATCH_PID" 2>/dev/null
  [ -n "${CLOCK_SYNC_PID:-}" ] && kill "$CLOCK_SYNC_PID" 2>/dev/null
  kill "$RUNNER_PID" 2>/dev/null || true
  kill "$WATCHDOG_PID" 2>/dev/null || true
  kill "$TAIL_PID" 2>/dev/null || true
  _deregister_runner
  rm -f .runner .credentials
  log "Runner stopped."
}
trap _cleanup TERM INT

# ── 5. Ephemeral runner loop ─────────────────────────────────────────────────
# Each iteration: get a fresh token → register as ephemeral → run one job → repeat.
# Ephemeral runners auto-deregister after each job, so no stale cleanup needed.
RUNNER_LOG=/tmp/runner-output.log
WATCHDOG_FIRES=0
WATCHDOG_WINDOW_START=$(date +%s)
WATCHDOG_MAX_FIRES="${WATCHDOG_MAX_FIRES:-5}"

_check_watchdog_circuit() {
  local now
  now=$(date +%s)
  local window_age=$(( now - WATCHDOG_WINDOW_START ))

  if [ "$window_age" -ge 3600 ]; then
    WATCHDOG_FIRES=0
    WATCHDOG_WINDOW_START=$now
  fi

  WATCHDOG_FIRES=$(( WATCHDOG_FIRES + 1 ))

  if [ "$WATCHDOG_FIRES" -gt "$WATCHDOG_MAX_FIRES" ]; then
    return 1
  fi
  return 0
}

register() {
  _deregister_runner

  local REG_TOKEN
  REG_TOKEN=$(_get_registration_token) || return 1

  _register_runner "$REG_TOKEN"
}

while [ "$STOP" -eq 0 ]; do
  log "Registering ephemeral runner..."
  if ! register; then
    log "Registration failed — retrying in 10s..."
    sleep 10
    continue
  fi
  log "Runner registered. Waiting for a job..."

  : > "$RUNNER_LOG"
  ./run.sh >> "$RUNNER_LOG" 2>&1 &
  RUNNER_PID=$!
  tail -F "$RUNNER_LOG" &
  TAIL_PID=$!

  # Watchdog: WSL2 silently drops long-poll connections. The runner enters a
  # "Retrying until reconnected" loop that never recovers on its own.
  # Detect it early and kill the process so the loop re-registers fresh.
  (
    sleep 120
    while kill -0 "$RUNNER_PID" 2>/dev/null; do
      sleep 30
      if tail -3 "$RUNNER_LOG" 2>/dev/null | grep -q "Retrying until reconnected"; then
        log "Watchdog: runner stuck in retry loop — waiting 30s before forcing exit"
        sleep 30
        if tail -5 "$RUNNER_LOG" 2>/dev/null | grep -q "Listening for Jobs"; then
          log "Watchdog: runner recovered — standing down"
          continue
        fi
        log "Watchdog: still stuck — killing runner to re-register"
        touch /tmp/watchdog-killed
        kill "$RUNNER_PID" 2>/dev/null || true
        break
      fi
    done
  ) &
  WATCHDOG_PID=$!

  wait "${RUNNER_PID}" 2>/dev/null
  EXIT_CODE=$?
  kill "$TAIL_PID" 2>/dev/null || true
  kill "$WATCHDOG_PID" 2>/dev/null || true

  if [ -f /tmp/watchdog-killed ]; then
    rm -f /tmp/watchdog-killed
    if ! _check_watchdog_circuit; then
      log "[WATCHDOG] circuit open — ${WATCHDOG_FIRES} restarts in 60min"
      log "[WATCHDOG] backing off for 10 minutes before next attempt"
      touch /tmp/watchdog-circuit-open
      sleep 600
      rm -f /tmp/watchdog-circuit-open
      WATCHDOG_FIRES=0
      WATCHDOG_WINDOW_START=$(date +%s)
      log "[WATCHDOG] circuit reset — resuming normal operation"
    fi
  fi

  if grep -q "A session for this runner already exists" "$RUNNER_LOG" 2>/dev/null; then
    log "Runner exited with session conflict — waiting ${SESSION_CONFLICT_WAIT}s for GitHub to clear stale session..."
    sleep "$SESSION_CONFLICT_WAIT"
  else
    log "Runner exited with code ${EXIT_CODE} — re-registering..."
    sleep 2
  fi
done
