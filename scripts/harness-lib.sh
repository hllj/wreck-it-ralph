#!/bin/bash
# harness-lib.sh - small helpers shared by harness-step.sh and backlog.sh (sourced, not executed).
# Expects HARNESS_DIR to be set by the caller.

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

# The loop lock (.harness/.lock) is live when its owner pid is alive, or, for interactive runs
# (pid 0), when its heartbeat is younger than lock_timeout_minutes.
lock_live() {
  local lock="$HARNESS_DIR/.lock" cfg="$HARNESS_DIR/config.json" pid ts timeout
  [[ -f "$lock" ]] || return 1
  pid="$(jq -r '.pid // 0' "$lock" 2>/dev/null || echo 0)"; ts="$(jq -r '.ts // 0' "$lock" 2>/dev/null || echo 0)"
  timeout="$(jq -r '.lock_timeout_minutes // 120' "$cfg" 2>/dev/null || echo 120)"
  [[ "$pid" =~ ^[0-9]+$ && "$ts" =~ ^[0-9]+$ && "$timeout" =~ ^[0-9]+$ ]] || return 1
  if [[ "$pid" -gt 0 ]]; then kill -0 "$pid" 2>/dev/null; else (( $(date +%s) - ts < timeout * 60 )); fi
}

# True while a loop is between `step.sh begin` (DECISION=continue) and `step.sh end`.
session_in_progress() {
  local state="$HARNESS_DIR/.step_state.json"
  [[ -f "$state" ]] || return 1
  [[ "$(jq -r '.in_session // false' "$state" 2>/dev/null)" == "true" ]] && lock_live
}
