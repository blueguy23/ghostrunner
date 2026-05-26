#!/bin/bash
# Intended to be sourced from entrypoint.sh — not executed directly
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && echo "ERROR: source this script, don't execute it" && exit 1

# ── Clock re-sync loop (compensates for WSL2 drift mid-job) ───────────────────
_clock_sync_loop() {
  while true; do
    sleep 60
    if ! chronyc makestep 1.0 3 >/dev/null 2>&1; then
      echo "[CLOCK] WARNING: chronyc makestep failed — drift may be accumulating"
    else
      OFFSET=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}')
      if [ -n "$OFFSET" ]; then
        OFFSET_ABS=$(echo "$OFFSET" | tr -d '-')
        if awk "BEGIN {exit !($OFFSET_ABS > 2.0)}"; then
          echo "[CLOCK] WARNING: large drift detected — ${OFFSET}s offset after sync"
        else
          echo "[CLOCK] sync OK — offset ${OFFSET}s"
        fi
      fi
    fi
  done
}

# ── PAT re-validation loop (detects token expiry while runner is live) ────────
_token_watch_loop() {
  while true; do
    sleep 21600  # 6 hours
    HTTP_STATUS=$(${CURL_CMD:-curl} -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $GITHUB_PAT" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/user)
    if [ "$HTTP_STATUS" = "200" ]; then
      echo "[TOKEN] re-validation OK — PAT still valid"
      rm -f /tmp/token-invalid
    elif [ "$HTTP_STATUS" = "000" ]; then
      echo "[TOKEN] WARNING: GitHub API unreachable (HTTP 000) — skipping sentinel"
    else
      echo "[TOKEN] WARNING: PAT re-validation failed — HTTP ${HTTP_STATUS}"
      echo "[TOKEN] Runner will continue but registration renewal may fail"
      touch /tmp/token-invalid
    fi
  done
}
