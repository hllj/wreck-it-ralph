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

# ---------- event stream + hooks (the integration surface for other plugins and tools) ----------
# fire <event> [key=value ...]
#   1. appends {"at", "event", key: value...} to .harness/events.jsonl (git-ignored, append-only);
#   2. runs every `cmd:` handler configured for that event in config.json `hooks`, with the event
#      JSON on stdin and HARNESS_EVENT / HARNESS_<KEY> in the environment. Output goes to
#      .harness/sessions/hooks.log. Handlers never stop the loop; a failure is reported on stderr.
#   Handlers run only when the caller defines hooks_allowed() and it succeeds (trusted config).
fire() {
  local ev="$1" kv j k; shift
  local -a envs=("HARNESS_EVENT=$ev")
  j="$(jq -cn --arg ev "$ev" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{at: $at, event: $ev}')"
  for kv in "$@"; do
    k="${kv%%=*}"
    j="$(jq -c --arg k "$k" --arg v "${kv#*=}" '.[$k] = $v' <<<"$j")"
    envs+=("HARNESS_$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')=${kv#*=}")
  done
  mkdir -p "$HARNESS_DIR/sessions"
  printf '%s\n' "$j" >> "$HARNESS_DIR/events.jsonl"
  declare -F hooks_allowed >/dev/null 2>&1 || return 0
  local cmds
  cmds="$(jq -r --arg ev "$ev" '((.hooks // {})[$ev] // []) | (if type == "string" then [.] else . end)
           | .[] | select(type == "string" and startswith("cmd:")) | sub("^cmd:\\s*"; "")' "$HARNESS_DIR/config.json" 2>/dev/null || true)"
  [[ -z "$cmds" ]] && return 0
  hooks_allowed || { echo "harness: hooks for '$ev' skipped (config not trusted)" >&2; return 0; }
  local c log="$HARNESS_DIR/sessions/hooks.log"
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    printf '[%s] %s $ %s\n' "$(date +%H:%M:%S)" "$ev" "$c" >> "$log"
    if ! env "${envs[@]}" bash -c "$c" <<<"$j" >> "$log" 2>&1; then
      echo "harness: WARNING hook for '$ev' failed: $c (see $log)" >&2
    fi
  done <<<"$cmds"
  return 0
}

# True while a loop is between `step.sh begin` (DECISION=continue) and `step.sh end`.
session_in_progress() {
  local state="$HARNESS_DIR/.step_state.json"
  [[ -f "$state" ]] || return 1
  [[ "$(jq -r '.in_session // false' "$state" 2>/dev/null)" == "true" ]] && lock_live
}
