#!/bin/bash
set -euo pipefail

# CLI summary of runner health: container uptime, resource usage, CI job history.
# Queries Docker for live container state and GitHub API for workflow run metrics.
#
# Usage: bash scripts/metrics-report.sh [--days N]
#
# Requires: docker, gh (authenticated), jq, awk

export PATH="$HOME/.local/bin:$PATH"

DAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    *) echo "Usage: $0 [--days N]" >&2; exit 1 ;;
  esac
done

REPO="${REPO_OWNER:-blueguy23}/${REPO_NAME:-bill-tracker}"
CONTAINERS=("ci-runner-1" "ci-runner-2" "ci-mongo")
SINCE=$(date -u -d "${DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ')

bold() { printf '\033[1m%s\033[0m' "$1"; }
dim() { printf '\033[2m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
red() { printf '\033[31m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }

# ── Container Health ────────────────────────────────────────────────────────

echo ""
bold "Container Health"
echo ""
printf "  %-16s %-10s %-8s %-22s %s\n" "NAME" "STATUS" "RESTARTS" "UPTIME" "MEMORY"
printf "  %-16s %-10s %-8s %-22s %s\n" "────" "──────" "────────" "──────" "──────"

for ctr in "${CONTAINERS[@]}"; do
  INFO=$(docker inspect "$ctr" --format '{{.State.Status}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.HostConfig.Memory}}' 2>/dev/null) || {
    printf "  %-16s %s\n" "$ctr" "$(red "not found")"
    continue
  }

  IFS='|' read -r STATUS RESTARTS STARTED_AT _ <<< "$INFO"

  if [ "$STATUS" = "running" ]; then
    STATUS_FMT=$(green "$STATUS")
    STARTED_EPOCH=$(date -d "$STARTED_AT" +%s)
    NOW_EPOCH=$(date +%s)
    UPTIME_SECS=$((NOW_EPOCH - STARTED_EPOCH))
    UPTIME_DAYS=$((UPTIME_SECS / 86400))
    UPTIME_HRS=$(( (UPTIME_SECS % 86400) / 3600 ))
    UPTIME_MINS=$(( (UPTIME_SECS % 3600) / 60 ))
    UPTIME="${UPTIME_DAYS}d ${UPTIME_HRS}h ${UPTIME_MINS}m"
  else
    STATUS_FMT=$(red "$STATUS")
    UPTIME="—"
  fi

  MEM_USAGE=$(docker stats --no-stream --format '{{.MemUsage}}' "$ctr" 2>/dev/null || echo "—")

  if [ "$RESTARTS" -gt 0 ]; then
    RESTARTS_FMT=$(yellow "$RESTARTS")
  else
    RESTARTS_FMT="$RESTARTS"
  fi

  printf "  %-16s %-10b %-8b %-22s %s\n" "$ctr" "$STATUS_FMT" "$RESTARTS_FMT" "$UPTIME" "$MEM_USAGE"
done

# ── Resource Usage ──────────────────────────────────────────────────────────

echo ""
bold "Resource Usage (live)"
echo ""
printf "  %-16s %-10s %-22s %s\n" "NAME" "CPU" "MEMORY" "PIDS"
printf "  %-16s %-10s %-22s %s\n" "────" "───" "──────" "────"

docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}' "${CONTAINERS[@]}" 2>/dev/null | while IFS='|' read -r NAME CPU MEM PIDS; do
  printf "  %-16s %-10s %-22s %s\n" "$NAME" "$CPU" "$MEM" "$PIDS"
done

# ── Workflow Runs ───────────────────────────────────────────────────────────

echo ""
bold "CI Runs (last ${DAYS} days)"
echo ""

RUNS_JSON=$(gh api "repos/${REPO}/actions/runs?created=>=${SINCE}&per_page=100" 2>/dev/null) || {
  echo "  $(red "Failed to query GitHub API — check gh auth status")"
  echo ""
  exit 1
}

TOTAL=$(echo "$RUNS_JSON" | jq '.total_count')
SUCCESS=$(echo "$RUNS_JSON" | jq '[.workflow_runs[] | select(.conclusion == "success")] | length')
FAILURE=$(echo "$RUNS_JSON" | jq '[.workflow_runs[] | select(.conclusion == "failure")] | length')
CANCELLED=$(echo "$RUNS_JSON" | jq '[.workflow_runs[] | select(.conclusion == "cancelled")] | length')

if [ "$TOTAL" -eq 0 ]; then
  echo "  No runs in the last ${DAYS} days."
else
  SUCCESS_RATE=$(awk "BEGIN { printf \"%.0f\", ($SUCCESS / $TOTAL) * 100 }")
  printf "  Total: %s   Success: %s   Failed: %s   Cancelled: %s\n" \
    "$TOTAL" "$(green "$SUCCESS")" \
    "$([ "$FAILURE" -gt 0 ] && red "$FAILURE" || echo "$FAILURE")" \
    "$CANCELLED"
  printf "  Success rate: %s\n" \
    "$([ "$SUCCESS_RATE" -ge 90 ] && green "${SUCCESS_RATE}%" || yellow "${SUCCESS_RATE}%")"
fi

# ── Job Duration ────────────────────────────────────────────────────────────

echo ""
bold "Job Duration (completed runs)"
echo ""

DURATIONS=$(echo "$RUNS_JSON" | jq -r '
  [.workflow_runs[]
   | select(.conclusion == "success")
   | {
       created: .created_at,
       started: .run_started_at,
       updated: .updated_at
     }
  ]
  | map({
      queue_wait: (((.started | fromdateiso8601) - (.created | fromdateiso8601))),
      duration: (((.updated | fromdateiso8601) - (.started | fromdateiso8601)))
    })
  | {
      count: length,
      avg_duration: (if length > 0 then ([.[].duration] | add / length) else 0 end),
      max_duration: (if length > 0 then [.[].duration] | max else 0 end),
      min_duration: (if length > 0 then [.[].duration] | min else 0 end),
      avg_queue: (if length > 0 then ([.[].queue_wait] | add / length) else 0 end),
      max_queue: (if length > 0 then [.[].queue_wait] | max else 0 end)
    }
  | "\(.count)|\(.avg_duration)|\(.min_duration)|\(.max_duration)|\(.avg_queue)|\(.max_queue)"
')

if [ -n "$DURATIONS" ] && [ "$DURATIONS" != "0|0|0|0|0|0" ]; then
  IFS='|' read -r COUNT AVG_DUR MIN_DUR MAX_DUR AVG_QUEUE MAX_QUEUE <<< "$DURATIONS"

  fmt_duration() {
    local secs="${1%.*}"
    [ -z "$secs" ] && secs=0
    printf "%dm %ds" $((secs / 60)) $((secs % 60))
  }

  printf "  Avg duration:   %s\n" "$(fmt_duration "$AVG_DUR")"
  printf "  Min duration:   %s\n" "$(fmt_duration "$MIN_DUR")"
  printf "  Max duration:   %s\n" "$(fmt_duration "$MAX_DUR")"
  printf "  Avg queue wait: %s\n" "$(fmt_duration "$AVG_QUEUE")"
  printf "  Max queue wait: %s\n" "$(fmt_duration "$MAX_QUEUE")"

  if [ "${AVG_QUEUE%.*}" -gt 60 ] 2>/dev/null; then
    echo ""
    echo "  $(yellow "⚠ Average queue wait > 60s — runners may be overloaded or offline")"
  fi
else
  echo "  No successful runs to analyze."
fi

# ── Runner Assignment ───────────────────────────────────────────────────────

echo ""
bold "Runner Assignment (last ${DAYS} days)"
echo ""

RUN_IDS=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[:20] | .[].id')

RUNNER_COUNTS=""

for RUN_ID in $RUN_IDS; do
  JOBS=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/jobs" -q '.jobs[] | .runner_name // "unassigned"' 2>/dev/null) || continue
  for RUNNER in $JOBS; do
    RUNNER_COUNTS="${RUNNER_COUNTS}${RUNNER}\n"
  done
done

if [ -n "$RUNNER_COUNTS" ]; then
  printf '%b' "$RUNNER_COUNTS" | sort | uniq -c | sort -rn | while read -r COUNT NAME; do
    printf "  %-20s %s jobs\n" "$NAME" "$COUNT"
  done
else
  echo "  No job data available."
fi

# ── Clock Drift (if runners are accessible) ─────────────────────────────────

echo ""
bold "Clock Drift"
echo ""

for ctr in ci-runner-1 ci-runner-2; do
  TRACKING=$(docker exec "$ctr" chronyc -h 127.0.0.1 tracking 2>&1) || {
    if echo "$TRACKING" | grep -q "Cannot talk to daemon"; then
      printf "  %-16s %s\n" "$ctr" "$(dim "chronyd not running")"
    else
      printf "  %-16s %s\n" "$ctr" "$(dim "not accessible")"
    fi
    continue
  }
  OFFSET=$(echo "$TRACKING" | grep "System time" | awk '{print $4 " " $5}')
  [ -z "$OFFSET" ] && { printf "  %-16s %s\n" "$ctr" "$(dim "no offset data")"; continue; }
  OFFSET_VAL=$(echo "$OFFSET" | awk '{print $1}')
  OFFSET_ABS=$(echo "$OFFSET_VAL" | tr -d '-')
  if awk "BEGIN {exit !($OFFSET_ABS > 1.0)}"; then
    printf "  %-16s %s\n" "$ctr" "$(red "$OFFSET")"
  elif awk "BEGIN {exit !($OFFSET_ABS > 0.1)}"; then
    printf "  %-16s %s\n" "$ctr" "$(yellow "$OFFSET")"
  else
    printf "  %-16s %s\n" "$ctr" "$(green "$OFFSET")"
  fi
done

echo ""
