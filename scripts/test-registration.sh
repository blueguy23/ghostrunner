#!/bin/bash
set -euo pipefail

# ── Test harness for registration functions ──────────────────────────────────
# Runs locally without Docker or network calls.
# Usage: bash scripts/test-registration.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $1"; echo "    → $2"; }

# ── Source the registration functions from entrypoint.sh ─────────────────────
# We source only the function definitions by extracting them. The entrypoint
# has side effects (mongod, docker login) so we can't source the whole file.
# Instead, set up the env and eval just the function block.

export GITHUB_API="https://api.github.com"
export REPO_OWNER="test-owner"
export REPO_NAME="test-repo"
export RUNNER_NAME="test-runner"
export GITHUB_PAT="ghp_fake_token_for_testing"
export SESSION_CONFLICT_WAIT="30"

# Suppress log timestamps in test output
log() { echo "[TEST] $*"; }

# ── Mock curl implementations ────────────────────────────────────────────────

mock_curl_registration_success() {
  local args="$*"
  if echo "$args" | grep -q "registration-token"; then
    echo '{"token":"AABCDEF123456","expires_at":"2026-05-16T20:00:00Z"}'
  elif echo "$args" | grep -q "remove-token"; then
    echo '{"token":"REMOVETOK789","expires_at":"2026-05-16T20:00:00Z"}'
  elif echo "$args" | grep -q "DELETE"; then
    echo -n "204"
  elif echo "$args" | grep -q "/actions/runners"; then
    echo '{"runners":[{"id":42,"name":"test-runner","status":"online"}]}'
  fi
}

mock_curl_401() {
  # Simulate HTTP 401 — curl -f exits non-zero on 4xx
  return 22
}

mock_curl_404() {
  return 22
}

mock_curl_empty_token() {
  echo '{"token":null}'
}

mock_curl_no_runners() {
  local args="$*"
  if echo "$args" | grep -q "/actions/runners\""; then
    echo '{"runners":[]}'
  fi
}

mock_curl_deregister_403() {
  local args="$*"
  if echo "$args" | grep -q "DELETE"; then
    echo -n "403"
  elif echo "$args" | grep -q "/actions/runners"; then
    echo '{"runners":[{"id":99,"name":"test-runner","status":"online"}]}'
  fi
}

# ── Provide jq if not installed (test environments may lack it) ──────────────
if ! command -v jq >/dev/null 2>&1; then
  jq() {
    local filter="" input
    # Parse flags: -r, --arg name value
    while [ $# -gt 0 ]; do
      case "$1" in
        -r) shift ;;
        --arg) shift; shift; shift ;;  # skip --arg <name> <value>
        *) filter="$1"; shift ;;
      esac
    done
    input=$(cat)
    case "$filter" in
      '.token')
        local val
        val=$(echo "$input" | grep -oP '"token"\s*:\s*"\K[^"]+') || { echo "null"; return; }
        echo "$val"
        ;;
      '.runners[]'*'.id')
        echo "$input" | grep -oP '"id"\s*:\s*\K[0-9]+' | head -1
        ;;
      *)
        echo "null"
        ;;
    esac
  }
fi

# ── Source the functions under test ───────────────────────────────────────────

source "$SCRIPT_DIR/registration.sh"

# ── Tests ────────────────────────────────────────────────────────────────────

echo "Testing _get_registration_token()"
echo "─────────────────────────────────"

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_registration_success
TOKEN=$(_get_registration_token 2>/dev/null)
if [ "$TOKEN" = "AABCDEF123456" ]; then
  pass "succeeds with valid PAT → extracts token"
else
  fail "succeeds with valid PAT → extracts token" "got: '$TOKEN'"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_401
if OUTPUT=$(_get_registration_token 2>/dev/null); then
  fail "fails with 401 → exits non-zero" "expected failure, got success"
else
  pass "fails with 401 → exits non-zero"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_404
if OUTPUT=$(_get_registration_token 2>/dev/null); then
  fail "fails with 404 → exits non-zero" "expected failure, got success"
else
  pass "fails with 404 → exits non-zero"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_empty_token
if OUTPUT=$(_get_registration_token 2>/dev/null); then
  fail "fails with null token → exits non-zero" "expected failure, got success"
else
  pass "fails with null token → exits non-zero"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_registration_success
SAVED_PAT="$GITHUB_PAT"
unset GITHUB_PAT
if OUTPUT=$(_get_registration_token 2>/dev/null); then
  fail "fails with missing GITHUB_PAT → exits non-zero" "expected failure, got success"
else
  pass "fails with missing GITHUB_PAT → exits non-zero"
fi
export GITHUB_PAT="$SAVED_PAT"

echo ""
echo "Testing _get_remove_token()"
echo "───────────────────────────"

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_registration_success
TOKEN=$(_get_remove_token 2>/dev/null)
if [ "$TOKEN" = "REMOVETOK789" ]; then
  pass "succeeds with valid PAT → extracts remove token"
else
  fail "succeeds with valid PAT → extracts remove token" "got: '$TOKEN'"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_401
if OUTPUT=$(_get_remove_token 2>/dev/null); then
  fail "fails with 401 → exits non-zero" "expected failure, got success"
else
  pass "fails with 401 → exits non-zero"
fi

echo ""
echo "Testing _deregister_runner()"
echo "────────────────────────────"

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_registration_success
OUTPUT=$(_deregister_runner 2>/dev/null)
if echo "$OUTPUT" | grep -q "Runner deregistered"; then
  pass "succeeds → finds runner by name and deletes (HTTP 204)"
else
  fail "succeeds → finds runner by name and deletes (HTTP 204)" "output: '$OUTPUT'"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_no_runners
OUTPUT=$(_deregister_runner 2>/dev/null)
if [ $? -eq 0 ]; then
  pass "no runner found → exits 0 (no-op)"
else
  fail "no runner found → exits 0 (no-op)" "expected success"
fi

TESTS_RUN=$((TESTS_RUN + 1))
CURL_CMD=mock_curl_deregister_403
OUTPUT=$(_deregister_runner 2>/dev/null)
if echo "$OUTPUT" | grep -q "403"; then
  pass "DELETE returns 403 → logs scope error"
else
  fail "DELETE returns 403 → logs scope error" "output: '$OUTPUT'"
fi

TESTS_RUN=$((TESTS_RUN + 1))
SAVED_PAT="$GITHUB_PAT"
unset GITHUB_PAT
export CURL_CMD=mock_curl_registration_success
_deregister_runner 2>/dev/null
RESULT=$?
export GITHUB_PAT="$SAVED_PAT"
if [ $RESULT -eq 0 ]; then
  pass "missing GITHUB_PAT → exits 0 (curl fails gracefully via || true)"
else
  fail "missing GITHUB_PAT → exits 0 (curl fails gracefully)" "exit code: $RESULT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════"
echo "${TESTS_PASSED}/${TESTS_RUN} tests passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo "${TESTS_FAILED} FAILED"
  exit 1
fi
echo "All tests passed."
exit 0
