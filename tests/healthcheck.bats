#!/usr/bin/env bats

# Tests deep-healthcheck.sh scenarios by overriding curl and filesystem state.
# The real healthcheck queries the GitHub API — we mock curl and control
# the sentinel files + runner log to test each decision branch.

setup() {
  export GITHUB_PAT="ghp_fake_token"
  export REPO_OWNER="test-owner"
  export REPO_NAME="test-repo"
  export RUNNER_NAME="test-runner"

  HEALTHCHECK="$BATS_TEST_DIRNAME/../deep-healthcheck.sh"

  # Temp dir for sentinel files and runner log
  export BATS_TMPDIR="${BATS_TMPDIR:-/tmp}"
  TEST_TMP="$(mktemp -d "$BATS_TMPDIR/healthcheck-test.XXXXXX")"

  # Redirect sentinel/log paths by patching the script into a temp copy
  export TEST_HEALTHCHECK="$TEST_TMP/deep-healthcheck.sh"
  sed \
    -e "2i export PATH=\"$HOME/.local/bin:\$PATH\"" \
    -e "s|/tmp/healthcheck-offline-streak|$TEST_TMP/healthcheck-offline-streak|g" \
    -e "s|/tmp/runner-output.log|$TEST_TMP/runner-output.log|g" \
    -e "s|/tmp/token-invalid|$TEST_TMP/token-invalid|g" \
    -e "s|/tmp/watchdog-circuit-open|$TEST_TMP/watchdog-circuit-open|g" \
    "$HEALTHCHECK" > "$TEST_HEALTHCHECK"
  chmod +x "$TEST_HEALTHCHECK"

  # Default: no sentinels, empty log
  : > "$TEST_TMP/runner-output.log"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ── Helper to inject a mock curl ────────────────────────────────────────────

inject_curl() {
  local mock_script="$TEST_TMP/curl"
  cat > "$mock_script" <<SCRIPT
#!/bin/bash
$1
SCRIPT
  chmod +x "$mock_script"
  export PATH="$TEST_TMP:$PATH"
}

# ── Online runner ───────────────────────────────────────────────────────────

@test "healthcheck: runner online — exits 0" {
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"online\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
}

@test "healthcheck: runner online — clears offline streak file" {
  echo "2" > "$TEST_TMP/healthcheck-offline-streak"
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"online\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMP/healthcheck-offline-streak" ]
}

# ── Offline runner — streak tracking ────────────────────────────────────────

@test "healthcheck: runner offline once — not yet unhealthy" {
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"offline\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"streak: 1/"* ]]
}

@test "healthcheck: runner offline twice — not yet unhealthy" {
  echo "1" > "$TEST_TMP/healthcheck-offline-streak"
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"offline\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"streak: 2/"* ]]
}

@test "healthcheck: runner offline 3 times — reports unhealthy" {
  echo "2" > "$TEST_TMP/healthcheck-offline-streak"
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"offline\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"offline for 3 consecutive checks"* ]]
}

# ── Runner not found ────────────────────────────────────────────────────────

@test "healthcheck: runner not in API response — increments streak" {
  inject_curl 'echo "{\"runners\":[]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
}

# ── Sentinel files ──────────────────────────────────────────────────────────

@test "healthcheck: token-invalid sentinel — warns in output" {
  touch "$TEST_TMP/token-invalid"
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"online\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"token-invalid"* ]]
}

@test "healthcheck: watchdog-circuit-open sentinel — warns in output" {
  touch "$TEST_TMP/watchdog-circuit-open"
  inject_curl 'echo "{\"runners\":[{\"id\":42,\"name\":\"test-runner\",\"status\":\"online\"}]}"'
  run "$TEST_HEALTHCHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"watchdog circuit open"* ]]
}

# ── Network failure ─────────────────────────────────────────────────────────

@test "healthcheck: curl fails (network error) — increments streak" {
  inject_curl 'exit 22'
  run "$TEST_HEALTHCHECK"
  # Should not crash — status is empty so streak increments
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"streak"* ]]
}
