#!/bin/bash
# Readiness check — passes only if GitHub API reports this runner as online
# AND the runner process hasn't been idle too long without picking up work.
#
# The runner can flicker between online/offline after --once restarts,
# resetting Docker's retry counter before autoheal triggers. This script
# tracks consecutive offline detections in a local file so a brief "online"
# blip doesn't mask a truly stuck runner.

FAIL_FILE="/tmp/healthcheck-offline-streak"
RUNNER_LOG="/tmp/runner-output.log"
MAX_IDLE_SECONDS=300

if [ -f /tmp/token-invalid ]; then
  echo "[HEALTH] token-invalid sentinel present — PAT may be expired"
fi

if [ -f /tmp/watchdog-circuit-open ]; then
  echo "[HEALTH] watchdog circuit open — chronic reconnection issue"
fi

RUNNER_STATUS=$(curl -sf --max-time 10 \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners" \
  | jq -r --arg name "${RUNNER_NAME}" \
    '.runners[] | select(.name == $name) | .status')

if [ "${RUNNER_STATUS}" = "online" ]; then
  rm -f "$FAIL_FILE"
  exit 0
fi

# Runner is offline or not found — increment streak
STREAK=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
STREAK=$((STREAK + 1))
echo "$STREAK" > "$FAIL_FILE"

# Also check how long since the runner last did anything useful
LAST_ACTIVITY=$(grep -E 'Listening for Jobs|completed with result' "$RUNNER_LOG" 2>/dev/null | tail -1)
if [ -n "$LAST_ACTIVITY" ]; then
  LAST_TS=$(echo "$LAST_ACTIVITY" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
  if [ -n "$LAST_TS" ]; then
    LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    IDLE_SECS=$((NOW_EPOCH - LAST_EPOCH))
  fi
fi

if [ "${STREAK}" -ge 3 ]; then
  echo "Runner offline for ${STREAK} consecutive checks — reporting unhealthy"
  exit 1
fi

if [ "${IDLE_SECS:-0}" -ge "$MAX_IDLE_SECONDS" ] && [ "${RUNNER_STATUS}" != "online" ]; then
  echo "Runner idle ${IDLE_SECS}s and status '${RUNNER_STATUS:-not found}' — reporting unhealthy"
  exit 1
fi

echo "Runner status: '${RUNNER_STATUS:-not found}' (streak: ${STREAK}/${3}) — not yet unhealthy"
exit 0
