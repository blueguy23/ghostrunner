#!/usr/bin/env bats

# Tests the watchdog circuit breaker — pure bash arithmetic extracted from entrypoint.sh.
# The circuit breaker trips after WATCHDOG_MAX_FIRES within a 1-hour window,
# preventing infinite restart loops when the root cause isn't recoverable.

setup() {
  WATCHDOG_FIRES=0
  WATCHDOG_WINDOW_START=$(date +%s)
  WATCHDOG_MAX_FIRES=5

  # Extracted verbatim from entrypoint.sh
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
}

# ── Basic counting ──────────────────────────────────────────────────────────

@test "circuit breaker: first fire passes" {
  _check_watchdog_circuit
  [ $? -eq 0 ]
  [ "$WATCHDOG_FIRES" -eq 1 ]
}

@test "circuit breaker: fires up to max all pass" {
  for i in $(seq 1 "$WATCHDOG_MAX_FIRES"); do
    _check_watchdog_circuit
    [ $? -eq 0 ]
  done
  [ "$WATCHDOG_FIRES" -eq "$WATCHDOG_MAX_FIRES" ]
}

@test "circuit breaker: trips on max+1" {
  for i in $(seq 1 "$WATCHDOG_MAX_FIRES"); do
    _check_watchdog_circuit
  done
  run _check_watchdog_circuit
  [ "$status" -ne 0 ]
}

@test "circuit breaker: still tripped on max+2" {
  for i in $(seq 1 $((WATCHDOG_MAX_FIRES + 1))); do
    _check_watchdog_circuit || true
  done
  run _check_watchdog_circuit
  [ "$status" -ne 0 ]
}

# ── Window reset ────────────────────────────────────────────────────────────

@test "circuit breaker: resets after 1-hour window expires" {
  for i in $(seq 1 "$WATCHDOG_MAX_FIRES"); do
    _check_watchdog_circuit
  done
  # Simulate window expiry by backdating the start
  WATCHDOG_WINDOW_START=$(( $(date +%s) - 3601 ))

  _check_watchdog_circuit
  [ $? -eq 0 ]
  [ "$WATCHDOG_FIRES" -eq 1 ]
}

@test "circuit breaker: does not reset before window expires" {
  for i in $(seq 1 "$WATCHDOG_MAX_FIRES"); do
    _check_watchdog_circuit
  done
  # 59 minutes — not yet expired
  WATCHDOG_WINDOW_START=$(( $(date +%s) - 3540 ))

  run _check_watchdog_circuit
  [ "$status" -ne 0 ]
}

# ── Custom max ──────────────────────────────────────────────────────────────

@test "circuit breaker: respects custom WATCHDOG_MAX_FIRES=2" {
  WATCHDOG_MAX_FIRES=2
  _check_watchdog_circuit
  _check_watchdog_circuit
  run _check_watchdog_circuit
  [ "$status" -ne 0 ]
}

@test "circuit breaker: WATCHDOG_MAX_FIRES=1 trips on second fire" {
  WATCHDOG_MAX_FIRES=1
  _check_watchdog_circuit
  run _check_watchdog_circuit
  [ "$status" -ne 0 ]
}
