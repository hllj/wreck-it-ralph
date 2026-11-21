#!/bin/bash
# harness-run.sh - HEADLESS fresh-context runner for the wreck-it-ralph harness.
#
# Use this for unattended runs (overnight, CI, away from the keyboard). Each agent is a
# separate `claude -p` process with a brand-new context and needs a valid `claude` login.
# For interactive use prefer /wreck-it-ralph:run (Claude Code subagents).
#
# All gates (limits, stuck detection, spec lock, clean tree, summary) live in
# harness-step.sh and are shared with the interactive mode.
#
# Usage: .harness/run.sh [--max-sessions N] [--once] [--rollout L1|L2|L3]
#        .harness/run.sh --plan "<request>"   run the planner (always in plan mode, read-only) and file its proposal
# Stop:  touch .harness/STOP  (or /wreck-it-ralph:cancel)

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
CFG="$HARNESS_DIR/config.json"
STEP="$PLUGIN_ROOT/scripts/harness-step.sh"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "❌ $*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
[[ -f "$CFG" ]] || die "$CFG missing - run /wreck-it-ralph:init first"
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
ROLLOUT=""
PLAN_REQUEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-sessions) MAX_SESSIONS="${2:?number required}"; [[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || die "--max-sessions must be a non-negative integer"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --plan) PLAN_REQUEST="${2:?request text required}"; shift 2 ;;
    --rollout) ROLLOUT="${2:?L1|L2|L3 required}"; [[ "$ROLLOUT" =~ ^L[123]$ ]] || die "--rollout must be L1, L2 or L3"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

strip_frontmatter() { awk '/^---$/{i++; next} i>=2' "$1"; }

resolve_agent() {
  local p
  for p in "$HARNESS_DIR/agents/$1.md" "$PLUGIN_ROOT/agents/$1.md" "$PLUGIN_ROOT/templates/agents/$1.md"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# ---------- --plan: the planner, headless. Plan mode (read-only): it returns a proposal payload and this
# script files it; the planner itself never gets a tool that can write. Humans approve with /backlog.
if [[ -n "$PLAN_REQUEST" ]]; then
  pinfo="$("$STEP" agent-info planner)"
  pmodel="$(sed -n 's/^MODEL=//p' <<<"$pinfo" | head -n1)"
  pdef="$(resolve_agent planner)" || die "planner agent not found"
  PLAN_NOTE="You cannot ask questions in this run (unattended): decide, and list every assumption in the summary. Never answer with QUESTIONS."
  pctx="$("$PLUGIN_ROOT/scripts/feature-list.sh" stats 2>/dev/null || true)
$("$PLUGIN_ROOT/scripts/feature-list.sh" list 2>/dev/null | head -60 || true)"
  pargs=(-p --permission-mode plan --output-format json --allowedTools "Read,Grep,Glob")
  pargs+=(--append-system-prompt "$(strip_frontmatter "$pdef")")
  [[ -n "$pmodel" ]] && pargs+=(--model "$pmodel")
  pjson="$(mktemp)"; ppayload="$(mktemp)"
  printf 'Current backlog (read-only context):\n%s\n\n%s\n\nRequest:\n%s\n' "$pctx" "$PLAN_NOTE" "$PLAN_REQUEST" \
    | "$CLAUDE_BIN" "${pargs[@]}" > "$pjson" || die "planner run failed"
  jq -r '.result // ""' "$pjson" | awk '/^```json[[:space:]]*$/{f=1;next} /^```[[:space:]]*$/{if(f){exit}} f' > "$ppayload"
  if ! jq -e 'type == "object"' "$ppayload" >/dev/null 2>&1 && jq -r '.result // ""' "$pjson" | grep -q '^QUESTIONS:'; then
    jq -r '.result // ""' "$pjson" | sed -n '/^QUESTIONS:/,$p'
    rm -f "$pjson" "$ppayload"
    echo "The planner needs answers. Add them to the request and run --plan again." >&2
    exit 3
  fi
  jq -e 'type == "object"' "$ppayload" >/dev/null 2>&1 || { jq -r '.result // ""' "$pjson" | tail -n 20; die "the planner returned no valid JSON payload"; }
  HARNESS_DIR="$HARNESS_DIR" "$PLUGIN_ROOT/scripts/backlog.sh" propose --by planner --reason "$(printf '%s' "$PLAN_REQUEST" | head -n1 | cut -c1-120)" --file "$ppayload"
  rm -f "$pjson" "$ppayload"
  echo "Review with: /wreck-it-ralph:backlog (nothing changes until a human approves)"
  exit 0
fi

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


# Probe the CLI once: a per-call spend cap needs --max-budget-usd.
SUPPORTS_BUDGET=0
"$CLAUDE_BIN" --help </dev/null 2>/dev/null | grep -q -- '--max-budget-usd' && SUPPORTS_BUDGET=1

record_usage() { # name jsonfile [model] [escalated] -> ledger line (tolerant: unknown/old output just records nothing)
  local name="$1" json="$2" fmodel="${3:-}" fesc="${4:-}" fields
  fields="$(jq -r 'select(type == "object") | [(.total_cost_usd // .cost_usd // ""), (.usage.input_tokens // ""),
      ((.usage.output_tokens // 0) + (.usage.cache_creation_input_tokens // 0) | tostring), (.duration_ms // ""), (.num_turns // "")] | @tsv' "$json" 2>/dev/null | head -n1)" || return 0
  [[ -z "$fields" ]] && return 0
  local cost itok otok ms turns; IFS=$'\t' read -r cost itok otok ms turns <<<"$fields"
  local a=(ledger add "$name" --mode headless)
  [[ -n "$fmodel" ]] && a+=(--model "$fmodel"); [[ "$fesc" == true ]] && a+=(--escalated)
  [[ -n "$cost" ]] && a+=(--cost "$cost"); [[ -n "$itok" ]] && a+=(--input-tokens "$itok")
  [[ -n "$otok" ]] && a+=(--output-tokens "$otok"); [[ -n "$ms" ]] && a+=(--ms "$ms"); [[ -n "$turns" ]] && a+=(--turns "$turns")
  "$STEP" "${a[@]}" >/dev/null 2>&1 || true
}

# Run one pipeline step. Returns 0 ok, 1+ failed, 75 skipped (optional extension not available).
run_agent() { # name task logfile
  local name="$1" task="$2" logfile="$3" sys="" json="${3%.log}.json" rc=0 info type optional
  info="$("$STEP" spawn-info "$name" 2>"$logfile")" || { log "   step '$name': $(cat "$logfile")"; return 127; }
  type="$(sed -n 's/^TYPE=//p' <<<"$info" | head -n1)"; optional="$(sed -n 's/^OPTIONAL=//p' <<<"$info" | head -n1)"
  local model; model="$(sed -n '1,/^---PROMPT---$/s/^MODEL=//p' <<<"$info" | head -n1)"; model="${model:-$MODEL}"
  local perm; perm="$(sed -n '1,/^---PROMPT---$/s/^PERMISSION_MODE=//p' <<<"$info" | head -n1)"; perm="${perm:-$PERM}"
  case "$type" in
    gate) "$STEP" run-step "$name" > "$logfile" 2>&1; return $? ;;
    missing) echo "optional step '$name': agent not found" > "$logfile"; return 75 ;;
    wreck-it-ralph:*)
      local def; def="$(resolve_agent "${type#wreck-it-ralph:}")" || return 127
      sys="$(strip_frontmatter "$def")" ;;
    general-purpose) sys="$(sed '1,/^---PROMPT---$/d' <<<"$info")" ;;
    *) # another plugin's agent: let a headless session delegate to it (the plugin must be installed for this user)
      task="Use the Agent tool with subagent_type \"$type\" and give it the task below verbatim. Wait for it and report its result. If that agent type is not available, say exactly 'EXTENSION UNAVAILABLE: $type' and stop.

$task" ;;
  esac
  local args=(-p --permission-mode "$perm" --output-format json)
  [[ -n "$sys" ]] && args+=(--append-system-prompt "$sys")
  [[ -n "$model" ]]   && args+=(--model "$model")
  [[ -n "$ALLOWED" ]] && args+=(--allowedTools "$ALLOWED")
  [[ -n "$MCP" && -f "$MCP" ]] && args+=(--mcp-config "$MCP")
  if [[ $SUPPORTS_BUDGET -eq 1 ]]; then
    local left; left="${BUDGET_LEFT:-$(sed -n 's/^REMAINING_USD=//p' <<<"$("$STEP" budget)")}"
    [[ -n "$left" ]] && args+=(--max-budget-usd "$left")
  fi
  # Task goes via stdin: variadic flags (--mcp-config) would swallow a positional prompt.
  printf '%s' "$task" | "$CLAUDE_BIN" "${args[@]}" > "$json" 2> "$logfile" || rc=$?
  # Human-readable log: the agent's final text, then stderr. Raw JSON (cost, usage) stays next to it.
  if jq -e 'type == "object" and has("result")' "$json" >/dev/null 2>&1; then
    { jq -r '.result // ""' "$json"; echo; cat "$logfile"; } > "$logfile.tmp" && mv "$logfile.tmp" "$logfile"
    [[ -n "${NO_RECORD:-}" ]] || record_usage "$name" "$json" "$model" "$(sed -n '1,/^---PROMPT---$/s/^ESCALATED=//p' <<<"$info" | head -n1)"
  else
    { cat "$json"; cat "$logfile"; } > "$logfile.tmp" && mv "$logfile.tmp" "$logfile"
  fi
  if [[ "$optional" == true ]] && grep -q "EXTENSION UNAVAILABLE" "$logfile"; then return 75; fi
  if [[ "$optional" == true && $rc -ne 0 ]]; then return 75; fi
  return $rc
}

# Fan the coder step out over git worktrees when parallel.max_workers > 1 and the batch has >1 feature.
# Returns 0 when it ran the coders (the normal coder step is then skipped), 1 to fall back.
run_parallel_coders() { # session
  local n="$1" fo workers line id path abs pids=() ids=() i left share
  fo="$("$STEP" fanout plan)"; workers="$(kv WORKERS "$fo")"
  [[ "${workers:-1}" -gt 1 ]] || return 1
  left="$(sed -n 's/^REMAINING_USD=//p' <<<"$("$STEP" budget)")"
  share=""; [[ -n "$left" ]] && share="$(jq -n --argjson l "$left" --argjson w "$workers" '$l / $w | . * 100 | floor / 100')"
  log "   ⇉ $workers coders in parallel (git worktrees)"
  while IFS= read -r line; do
    id="${line%% *}"; path="${line#* }"; abs="$(pwd)/$HARNESS_DIR/sessions/$(printf '%03d' "$n")-coder-$id.log"
    task="$("$STEP" fanout task "$id")"
    log "   ▶ coder[$id] → $abs"
    ( cd "$path" && NO_RECORD=1 BUDGET_LEFT="$share" run_agent coder "$task" "$abs" ) &
    pids+=("$!"); ids+=("$id")
  done < <(sed -n 's/^WORKER=//p' <<<"$fo")
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then log "   ✓ coder[${ids[$i]}] finished"; else log "   ✗ coder[${ids[$i]}] exited with an error (see log)"; fi
    record_usage coder "$HARNESS_DIR/sessions/$(printf '%03d' "$n")-coder-${ids[$i]}.json"
  done
  local m; m="$("$STEP" fanout merge)"
  log "   ⇇ merged: $(kv MERGED "$m")$([[ -n "$(kv CONFLICTS "$m")" ]] && echo " | conflicts (retried later): $(kv CONFLICTS "$m")")"
  return 0
}

NEWRUN=(--new-run --owner-pid "$$")
[[ -n "$MAX_SESSIONS" ]] && NEWRUN+=(--max-sessions "$MAX_SESSIONS")
[[ -n "$ROLLOUT" ]] && NEWRUN+=(--rollout "$ROLLOUT")
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
  [[ -n "$(kv NOTE "$OUT")" ]] && log "   note: $(kv NOTE "$OUT")"
  [[ -n "$(kv BRANCH "$OUT")" ]] && log "   rollout $(kv ROLLOUT "$OUT"): working on branch $(kv BRANCH "$OUT") (base $(kv BASE "$OUT") is not touched)"

  session_failed=0
  while IFS=$'\t' read -r agent blocking every when; do
    if [[ "$agent" == coder ]] && run_parallel_coders "$n"; then continue; fi
    task="$("$STEP" task "$agent")"
    if [[ "$task" == SKIP:* ]]; then log "   skip $agent (${task#SKIP: })"; continue; fi
    logfile="$HARNESS_DIR/sessions/$(printf '%03d' "$n")-$agent.log"
    log "   ▶ $agent (fresh context) → $logfile"
    rc=0; run_agent "$agent" "$task" "$logfile" || rc=$?
    if [[ $rc -eq 0 ]]; then
      log "   ✓ $agent finished"
    elif [[ $rc -eq 75 ]]; then
      log "   - $agent skipped (optional extension not available)"
      "$STEP" note "$agent" skipped "optional extension not available" >/dev/null 2>&1 || true
    else
      log "   ✗ $agent exited with an error (see log)"
      if [[ "$blocking" == "true" ]]; then session_failed=1; break; fi
    fi
  done < <("$STEP" plan)

  END="$("$STEP" end)"
  SPEND="$("$STEP" ledger total)"
  log "── session $n done | $(kv STATS "$END") | commits: $(kv COMMITS "$END") | diff: $(kv DIFF_LINES "$END") lines | no-progress streak: $(kv STUCK "$END") | spent: \$$(kv COST "$SPEND")"
  [[ $session_failed -eq 1 ]] && log "   (a blocking agent failed this session)"
  [[ -n "$(kv VERIFY_FAILED "$END")" ]] && log "   verify commands failed: $(kv VERIFY_FAILED "$END")"
  [[ -n "$(kv NEEDS_HUMAN "$END")" ]] && log "   escalated to a human: $(kv NEEDS_HUMAN "$END") (answer with /wreck-it-ralph:backlog answer <ID> \"...\")"
  [[ -n "$(kv WARN "$END")" ]] && log "   ⚠️  $(kv WARN "$END")"
  if [[ "$(kv NEXT "$END")" == "stop" ]]; then
    log "🛑 $(kv REASON "$END"). Review $HARNESS_DIR/progress.md and feature notes."
    stop_run "$(kv REASON "$END")" "$(kv CODE "$END")"
  fi
  [[ $ONCE -eq 1 ]] && stop_run "single session (--once)" 0
done
