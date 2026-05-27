#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/test_helper.bash"
  source "$BATS_TEST_DIRNAME/../scripts/registration.sh"
}

# ── _get_registration_token ─────────────────────────────────────────────────

@test "get_registration_token: extracts token from valid response" {
  CURL_CMD=mock_curl
  run _get_registration_token
  [ "$status" -eq 0 ]
  [ "$output" = "AABCDEF123456" ]
}

@test "get_registration_token: fails on HTTP 401" {
  CURL_CMD=mock_curl_401
  run _get_registration_token
  [ "$status" -ne 0 ]
}

@test "get_registration_token: fails when token is null" {
  CURL_CMD=mock_curl_empty_token
  run _get_registration_token
  [ "$status" -ne 0 ]
}

@test "get_registration_token: fails when GITHUB_PAT is unset" {
  unset GITHUB_PAT
  run _get_registration_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_PAT"* ]]
}

# ── _get_remove_token ───────────────────────────────────────────────────────

@test "get_remove_token: extracts token from valid response" {
  CURL_CMD=mock_curl
  run _get_remove_token
  [ "$status" -eq 0 ]
  [ "$output" = "REMOVETOK789" ]
}

@test "get_remove_token: fails on HTTP 401" {
  CURL_CMD=mock_curl_401
  run _get_remove_token
  [ "$status" -ne 0 ]
}

@test "get_remove_token: fails when GITHUB_PAT is unset" {
  unset GITHUB_PAT
  run _get_remove_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_PAT"* ]]
}

# ── _deregister_runner ──────────────────────────────────────────────────────

@test "deregister: finds runner by name and deletes (HTTP 204)" {
  CURL_CMD=mock_curl
  run _deregister_runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"Runner deregistered"* ]]
}

@test "deregister: no runner found — exits 0 (no-op)" {
  CURL_CMD=mock_curl_no_runners
  run _deregister_runner
  [ "$status" -eq 0 ]
}

@test "deregister: DELETE returns 403 — logs scope error" {
  CURL_CMD=mock_curl_deregister_403
  run _deregister_runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"403"* ]]
}

@test "deregister: missing GITHUB_PAT — exits 0 (curl fails gracefully via || true)" {
  unset GITHUB_PAT
  run _deregister_runner
  [ "$status" -eq 0 ]
}
