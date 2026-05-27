#!/bin/bash
# Shared setup for all bats tests — mock environment + helper functions

export PATH="$HOME/.local/bin:$PATH"

export GITHUB_API="https://api.github.com"
export REPO_OWNER="test-owner"
export REPO_NAME="test-repo"
export RUNNER_NAME="test-runner"
export GITHUB_PAT="ghp_fake_token_for_testing"
export SESSION_CONFLICT_WAIT="30"
export CURL_CMD="mock_curl"

log() { echo "[TEST] $*"; }
export -f log

# ── Mock curl implementations ──────────────────────────────────────────────

mock_curl() {
  _mock_curl_default "$@"
}

_mock_curl_default() {
  local args="$*"
  if echo "$args" | grep -q "registration-token"; then
    echo '{"token":"AABCDEF123456","expires_at":"2026-05-16T20:00:00Z"}'
  elif echo "$args" | grep -q "remove-token"; then
    echo '{"token":"REMOVETOK789","expires_at":"2026-05-16T20:00:00Z"}'
  elif echo "$args" | grep -q "DELETE"; then
    # -w '%{http_code}' format — return just the status code
    echo -n "204"
  elif echo "$args" | grep -q "/actions/runners"; then
    echo '{"runners":[{"id":42,"name":"test-runner","status":"online"}]}'
  elif echo "$args" | grep -q "/user"; then
    echo '{"login":"test-user"}'
  fi
}

mock_curl_401() {
  return 22
}

mock_curl_empty_token() {
  echo '{"token":null}'
}

mock_curl_no_runners() {
  local args="$*"
  if echo "$args" | grep -q "/actions/runners"; then
    echo '{"runners":[]}'
  fi
}

mock_curl_deregister_403() {
  local args="$*"
  if echo "$args" | grep -q "DELETE" || echo "$args" | grep -q "%{http_code}.*DELETE" || echo "$args" | grep -q -- "-X DELETE"; then
    echo -n "403"
  elif echo "$args" | grep -q "/actions/runners"; then
    echo '{"runners":[{"id":99,"name":"test-runner","status":"online"}]}'
  fi
}

mock_curl_healthcheck_online() {
  echo '{"runners":[{"id":42,"name":"test-runner","status":"online"}]}'
}

mock_curl_healthcheck_offline() {
  echo '{"runners":[{"id":42,"name":"test-runner","status":"offline"}]}'
}

mock_curl_healthcheck_not_found() {
  echo '{"runners":[]}'
}

mock_curl_healthcheck_network_error() {
  return 22
}

mock_curl_token_valid() {
  local args="$*"
  if echo "$args" | grep -q "%{http_code}"; then
    echo -n "200"
  else
    echo '{"login":"test-user"}'
  fi
}

mock_curl_token_expired() {
  local args="$*"
  if echo "$args" | grep -q "%{http_code}"; then
    echo -n "401"
  fi
}

mock_curl_token_unreachable() {
  local args="$*"
  if echo "$args" | grep -q "%{http_code}"; then
    echo -n "000"
  fi
}

export -f mock_curl _mock_curl_default mock_curl_401 mock_curl_empty_token
export -f mock_curl_no_runners mock_curl_deregister_403
export -f mock_curl_healthcheck_online mock_curl_healthcheck_offline
export -f mock_curl_healthcheck_not_found mock_curl_healthcheck_network_error
export -f mock_curl_token_valid mock_curl_token_expired mock_curl_token_unreachable
