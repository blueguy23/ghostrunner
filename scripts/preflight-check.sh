#!/bin/bash
set -euo pipefail

FAILURES=0

log()  { echo "[PREFLIGHT] $*"; }
fail() { log "INVALID: $*"; FAILURES=$((FAILURES + 1)); }
miss() { log "MISSING: $*"; FAILURES=$((FAILURES + 1)); }

# ── 1. Secret Inventory Check ────────────────────────────────────────────────

check_secret_inventory() {
  local had_missing=0

  if [ -z "${GITHUB_PAT:-}" ]; then
    miss "GITHUB_PAT — required for runner registration"
    had_missing=1
  fi

  if [ -z "${REPO_OWNER:-}" ]; then
    miss "REPO_OWNER — required for registration URL and healthcheck"
    had_missing=1
  fi

  if [ -z "${DOCKERHUB_USERNAME:-}" ] || [ -z "${DOCKERHUB_TOKEN:-}" ]; then
    log "WARN: DOCKERHUB_USERNAME/DOCKERHUB_TOKEN not set — anonymous pulls limited to 100/6hr"
  fi

  return $had_missing
}

# ── 2. GitHub PAT Scope Validation ───────────────────────────────────────────

check_github_pat() {
  if [ -z "${GITHUB_PAT:-}" ]; then
    return 1
  fi

  local HTTP_CODE HEADERS
  HEADERS=$(mktemp)
  HTTP_CODE=$(curl -s -o /dev/null -D "$HEADERS" -w '%{http_code}' \
    --max-time 10 \
    -H "Authorization: Bearer ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user" 2>/dev/null) || {
    fail "GITHUB_PAT — network error (cannot reach api.github.com)"
    rm -f "$HEADERS"
    return 1
  }

  if [ "$HTTP_CODE" != "200" ]; then
    fail "GITHUB_PAT — HTTP ${HTTP_CODE} (token expired or revoked)"
    rm -f "$HEADERS"
    return 1
  fi

  local SCOPES
  SCOPES=$(grep -i '^x-oauth-scopes:' "$HEADERS" | cut -d: -f2- | tr -d ' \r')
  rm -f "$HEADERS"

  if ! echo "$SCOPES" | grep -q "repo"; then
    fail "GITHUB_PAT — missing scope \"repo\" (has: ${SCOPES:-none})"
    return 1
  fi

  log "OK: GITHUB_PAT — valid, scopes include \"repo\""
  return 0
}

# ── 3. Docker Hub Token Validation ───────────────────────────────────────────

check_dockerhub_token() {
  if [ -z "${DOCKERHUB_USERNAME:-}" ] || [ -z "${DOCKERHUB_TOKEN:-}" ]; then
    log "SKIP: Docker Hub validation (credentials not configured)"
    return 0
  fi

  echo "${DOCKERHUB_TOKEN}" | docker login \
    --username "${DOCKERHUB_USERNAME}" \
    --password-stdin >/dev/null 2>&1 || {
    fail "DOCKERHUB_TOKEN — login failed"
    return 1
  }

  docker logout >/dev/null 2>&1 || true
  log "OK: DOCKERHUB_TOKEN — login succeeded"
  return 0
}

# ── 4. Dependency Binary Check ───────────────────────────────────────────────

check_binaries() {
  local REQUIRED_BINARIES="curl jq docker gosu chronyc mongod node pnpm"
  local had_missing=0

  for bin in $REQUIRED_BINARIES; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      fail "${bin} — binary not found in PATH"
      had_missing=1
    fi
  done

  if [ "$had_missing" -eq 0 ]; then
    log "OK: all required binaries present"
  fi

  return $had_missing
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "Running pre-flight checks..."

check_secret_inventory || true
check_github_pat || true
check_dockerhub_token || true
check_binaries || true

echo ""
if [ "$FAILURES" -gt 0 ]; then
  log "FAILED — runner will not start (see above)"
  exit 1
fi

log "OK — all secrets valid, all binaries present"
exit 0
