#!/bin/bash
# harness-run.sh - HEADLESS fresh-context runner for the wreck-it-ralph harness.
#
# Use this for unattended runs (overnight, CI, away from the keyboard). Each agent is a
# separate `claude -p` process with a brand-new context and needs a valid `claude` login.
# For interactive use prefer /wreck-it-ralph-loop:harness-run (Claude Code subagents).
#
# All gates (limits, stuck detection, spec lock, clean tree, summary) live in
# harness-step.sh and are shared with the interactive mode.
#
# Usage: .harness/run.sh [--max-sessions N] [--once]
# Stop:  touch .harness/STOP  (or /wreck-it-ralph-loop:harness-cancel)

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
CFG="$HARNESS_DIR/config.json"
STEP="$PLUGIN_ROOT/scripts/harness-step.sh"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "❌ $*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
[[ -f "$CFG" ]] || die "$CFG missing - run /wreck-it-ralph-loop:harness-init first"
[[ -f "$HARNESS_DIR/feature_list.json" ]] || die "feature_list.json missing - initializer has not run"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

cfg() { jq -r "$1" "$CFG"; }

MAX_SESSIONS=""
CLAUDE_BIN="${CLAUDE_BIN:-$(cfg '.claude_bin // "claude"')}"
MODEL="$(cfg '.model // ""')"
PERM="$(cfg '.permission_mode // "bypassPermissions"')"
MCP="$(cfg '.mcp_config // ""')"
ALLOWED="$(cfg '.allowed_tools // ""')"
ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-sessions) MAX_SESSIONS="${2:?number required}"; [[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || die "--max-sessions must be a non-negative integer"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Single runner per project.
PIDFILE="$HARNESS_DIR/runner.pid"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  die "runner already running (pid $(cat "$PIDFILE"))"
fi
echo $$ > "$PIDFILE"
REASON="aborted"

kv() { sed -n "s/^$1=//p" <<<"$2" | head -n1; } # key, text

on_exit() {
  local code=$?
  trap - EXIT
  rm -f "$PIDFILE"
  "$STEP" summary "$REASON" "$code" || true
  exit "$code"
}
trap on_exit EXIT
stop_run() { REASON="$1"; exit "$2"; } # reason, exit code

strip_frontmatter() { awk '/^---$/{i++; next} i>=2' "$1"; }

resolve_agent() {
  local p
  for p in "$HARNESS_DIR/agents/$1.md" "$PLUGIN_ROOT/agents/$1.md" "$PLUGIN_ROOT/templates/agents/$1.md"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

run_agent() { # name task logfile
  local name="$1" task="$2" logfile="$3" def sys
  def="$(resolve_agent "$name")" || { log "agent '$name' not found"; return 127; }
  sys="$(strip_frontmatter "$def")"
  local args=(-p --append-system-prompt "$sys" --permission-mode "$PERM")
  [[ -n "$MODEL" ]]   && args+=(--model "$MODEL")
  [[ -n "$ALLOWED" ]] && args+=(--allowedTools "$ALLOWED")
  [[ -n "$MCP" && -f "$MCP" ]] && args+=(--mcp-config "$MCP")
  # Task goes via stdin: variadic flags (--mcp-config) would swallow a positional prompt.
  printf '%s' "$task" | "$CLAUDE_BIN" "${args[@]}" > "$logfile" 2>&1
}

NEWRUN=(--new-run --owner-pid "$$")
[[ -n "$MAX_SESSIONS" ]] && NEWRUN+=(--max-sessions "$MAX_SESSIONS")
FIRST=1

log "🎬 harness runner started"
[[ "$PERM" == "bypassPermissions" ]] && log "⚠️  permission_mode is bypassPermissions: agents run with NO permission prompts. Use a sandbox/VM or a throwaway checkout."
while true; do
  if [[ $FIRST -eq 1 ]]; then OUT="$("$STEP" begin "${NEWRUN[@]}")"; FIRST=0; else OUT="$("$STEP" begin)"; fi
  decision="$(kv DECISION "$OUT")"
  if [[ "$decision" != "continue" ]]; then
    log "🛑 $(kv REASON "$OUT")"
    stop_run "$(kv REASON "$OUT")" "$(kv CODE "$OUT")"
  fi
  n="$(kv SESSION "$OUT")"; target="$(kv TARGET "$OUT")"
  log "── session $n | $(kv STATS "$OUT") | target: $target"

  session_failed=0
  while IFS=$'\t' read -r agent blocking every when; do
    task="$("$STEP" task "$agent")"
    if [[ "$task" == SKIP:* ]]; then log "   skip $agent (${task#SKIP: })"; continue; fi
    logfile="$HARNESS_DIR/sessions/$(printf '%03d' "$n")-$agent.log"
    log "   ▶ $agent (fresh context) → $logfile"
    if run_agent "$agent" "$task" "$logfile"; then
      log "   ✓ $agent finished"
    else
      log "   ✗ $agent exited with an error (see log)"
      if [[ "$blocking" == "true" ]]; then session_failed=1; break; fi
    fi
  done < <("$STEP" plan)

  END="$("$STEP" end)"
  log "── session $n done | $(kv STATS "$END") | commits: $(kv COMMITS "$END") | no-progress streak: $(kv STUCK "$END")"
  [[ $session_failed -eq 1 ]] && log "   (a blocking agent failed this session)"
  if [[ "$(kv NEXT "$END")" == "stop" ]]; then
    log "🛑 $(kv REASON "$END"). Review $HARNESS_DIR/progress.md and feature notes."
    stop_run "$(kv REASON "$END")" "$(kv CODE "$END")"
  fi
  [[ $ONCE -eq 1 ]] && stop_run "single session (--once)" 0
done
