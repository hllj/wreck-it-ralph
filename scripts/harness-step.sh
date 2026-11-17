#!/bin/bash
# harness-step.sh - deterministic gates for one harness session.
#
# Shared by BOTH loop modes so the rules live in code, not in an LLM's memory:
#   - /harness-run  (Claude Code orchestrator spawning coder/tester subagents)
#   - .harness/run.sh (headless runner spawning `claude -p` processes)
#
# Usage: .harness/step.sh <command> [args]
#   begin [--new-run] [--max-sessions N] [--owner-pid PID]
#         Decide whether to start another session. Prints KEY=VALUE lines:
#         DECISION=continue|done|stop  SESSION=n  TARGET=<feature id>  STATS=...  REASON=...  CODE=<exit code>
#   plan                         list pipeline steps: agent<TAB>blocking<TAB>every<TAB>when
#   task <agent>                 print the task message for the agent, or "SKIP: <why>"
#   spawn-info <agent>           TYPE=<subagent type>; for non-plugin agents the prompt follows "---PROMPT---"
#   end                          after the pipeline: spec-lock check, clean tree, stuck detection.
#                                Prints PASSING, STATS, COMMITS, STUCK, NEXT=continue|stop, REASON, CODE
#   summary <reason> <code>      print + save the run summary (.harness/last-run.md)
#   note <agent> ok|failed|skipped [text]   append one line to this session's notes (text may come from stdin)
#   trust status|show|accept     review/record the risky repo-supplied config (see README "Trust")
#   unlock                       remove a stale loop lock (use only when no loop is running)
#
# begin --new-run stop codes: 4 dirty tree, 5 config not trusted, 6 git identity missing, 7 another loop running

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
CFG="$HARNESS_DIR/config.json"
FL="$PLUGIN_ROOT/scripts/feature-list.sh"
STATE="$HARNESS_DIR/.step_state.json"
SESSION_FILE="$HARNESS_DIR/session_count"
# shellcheck source=harness-ignores.sh
source "$PLUGIN_ROOT/scripts/harness-ignores.sh"

die() { echo "harness-step: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
[[ -f "$CFG" ]] || die "$CFG missing - run /wreck-it-ralph-loop:harness-init first"
[[ "${1:-}" == "trust" || -f "$HARNESS_DIR/feature_list.json" ]] || die "feature_list.json missing - initializer has not run"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

cfg() { jq -r "$1" "$CFG"; }
emit() { printf '%s=%s\n' "$1" "$2"; }
st_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE" 2>/dev/null || true; }
st_set() { local tmp="$STATE.tmp.$$"; jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$STATE" > "$tmp" && mv "$tmp" "$STATE"; }
st_set_s() { st_set "$1" "$(jq -Rn --arg s "$2" '$s')"; }
passing() { "$FL" stats | sed 's#/.*##'; }
claimed_ids() { "$FL" claimed | tr '\n' ' ' | sed 's/ *$//'; }
st_get_json() { jq -c --arg k "$1" '.[$k] // []' "$STATE" 2>/dev/null || echo '[]'; }
git_identity_ok() { [[ -n "$(git config user.email 2>/dev/null)" && -n "$(git config user.name 2>/dev/null)" ]] || [[ -n "${GIT_AUTHOR_EMAIL:-}" && -n "${GIT_AUTHOR_NAME:-}" ]]; }
COMMIT_FAILED=0
safe_commit() { # message; never swallows a failure
  git add -A
  git diff --cached --quiet && return 0
  if ! git commit -qm "$1" >/dev/null 2>&1; then
    echo "harness: WARNING git commit failed (is git user.name/user.email set? a hook failing?)" >&2
    COMMIT_FAILED=1; return 1
  fi
}
has_tester() { jq -e 'any(.pipeline[]?; .agent == "tester")' "$CFG" >/dev/null; }


# ---------- trust: repo-supplied config can execute code, so it must be reviewed once per machine ----------
TRUST_FILE="$HARNESS_DIR/.trusted"
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
mcp_path() { cfg '.mcp_config // ""'; }
trust_material() { # everything that can run commands or steer agents with elevated rights
  jq -S '{permission_mode, allowed_tools, final_verify_command, claude_bin, model, mcp_config}' "$CFG"
  local m; m="$(mcp_path)"; if [[ -n "$m" && -f "$m" ]]; then echo "## mcp: $m"; cat "$m"; fi
  local f; for f in $(ls "$HARNESS_DIR"/agents/*.md 2>/dev/null | sort); do echo "## agent: $f"; cat "$f"; done
}
trust_hash() { trust_material | sha; }
is_trusted() { [[ -f "$TRUST_FILE" && "$(cat "$TRUST_FILE")" == "$(trust_hash)" ]]; }

cmd_trust() {
  case "${1:-status}" in
    status) if is_trusted; then echo "trusted"; else echo "NOT trusted: run /wreck-it-ralph-loop:harness-trust to review" >&2; return 1; fi ;;
    show)
      echo "These settings come from files in this repository and can run commands on your machine:"
      echo
      echo "permission_mode:      $(cfg '.permission_mode // "default"')"
      echo "allowed_tools:        $(cfg '.allowed_tools // ""')"
      echo "claude_bin:           $(cfg '.claude_bin // "claude"')"
      echo "model:                $(cfg '.model // ""')"
      echo "final_verify_command: $(cfg '.final_verify_command // ""')"
      local m; m="$(mcp_path)"
      if [[ -n "$m" && -f "$m" ]]; then echo; echo "MCP servers ($m):"; jq -r '.mcpServers | to_entries[] | "  \(.key): \(.value.command) \((.value.args // []) | join(" "))"' "$m" 2>/dev/null || cat "$m"; fi
      local f any=0; for f in "$HARNESS_DIR"/agents/*.md; do [[ -f "$f" ]] || continue; any=1; done
      if [[ $any -eq 1 ]]; then echo; echo "Custom agent prompts (.harness/agents/):"; ls "$HARNESS_DIR"/agents/*.md | sed 's/^/  /'; fi
      echo; if is_trusted; then echo "Status: trusted"; else echo "Status: NOT trusted yet"; fi ;;
    accept) trust_hash > "$TRUST_FILE"; echo "trust recorded" ;;
    *) die "usage: trust status|show|accept" ;;
  esac
}


# ---------- single loop per project (heartbeat lock; headless runners also register their pid) ----------
LOCK="$HARNESS_DIR/.lock"
lock_live() {
  [[ -f "$LOCK" ]] || return 1
  local pid ts timeout
  pid="$(jq -r '.pid // 0' "$LOCK" 2>/dev/null || echo 0)"; ts="$(jq -r '.ts // 0' "$LOCK" 2>/dev/null || echo 0)"
  timeout="$(cfg '.lock_timeout_minutes // 120')"
  if [[ "$pid" -gt 0 ]]; then kill -0 "$pid" 2>/dev/null; else (( $(date +%s) - ts < timeout * 60 )); fi
}
lock_write() { jq -n --argjson pid "$1" --argjson ts "$(date +%s)" '{pid:$pid, ts:$ts}' > "$LOCK"; }
lock_touch() { [[ -f "$LOCK" ]] && lock_write "$(jq -r '.pid // 0' "$LOCK" 2>/dev/null || echo 0)" || true; }

# stop decision helper (prints DECISION lines)
stop_decision() { emit DECISION stop; emit REASON "$1"; emit CODE "$2"; }

ensure_clean_state() { # session
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "harness: agents left uncommitted changes; committing so the next session starts clean" >&2
    local big f
    big="$(git status --porcelain --untracked-files=all | sed 's/^...//' | while IFS= read -r f; do
      [[ -f "$f" && "$(wc -c < "$f")" -gt 5242880 ]] && echo "$f"; done | head -n 3 || true)"
    [[ -n "$big" ]] && echo "harness: WARNING large files (>5MB) are being committed; consider .gitignore: $(echo "$big" | tr '\n' ' ')" >&2
    safe_commit "harness: session $1 auto-commit (uncommitted changes left by agent)" || true
  fi
}

check_spec_lock() {
  if ! "$FL" verify-lock 2>/dev/null; then
    echo "harness: an agent edited the feature spec; restoring it from the lock snapshot" >&2
    "$FL" restore >&2
    safe_commit "harness: restored feature_list.json spec (agents may only change statuses)" || true
  fi
}

final_verification() { # 0 if ok or not configured
  local cmd; cmd="$(cfg '.final_verify_command // ""')"
  [[ -z "$cmd" ]] && return 0
  mkdir -p "$HARNESS_DIR/sessions"
  bash -c "$cmd" > "$HARNESS_DIR/sessions/final-verify.log" 2>&1
}

cmd_begin() {
  local newrun=0 maxs="" owner=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new-run) newrun=1; shift ;;
      --max-sessions) maxs="${2:?number required}"; shift 2 ;;
      --owner-pid) owner="${2:?pid required}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$owner" =~ ^[0-9]+$ ]] || die "--owner-pid must be a number"
  [[ -z "$maxs" || "$maxs" =~ ^[0-9]+$ ]] || die "--max-sessions must be a non-negative integer, got: $maxs"
  mkdir -p "$HARNESS_DIR/sessions"
  if [[ $newrun -eq 1 || ! -f "$STATE" ]]; then
    if ! is_trusted; then
      stop_decision "harness config is not trusted yet (it can run commands): review it with /wreck-it-ralph-loop:harness-trust, then start again" 5; return 0
    fi
    if ! git_identity_ok; then
      stop_decision "git identity is not configured, so harness commits would fail: git config user.name \"Your Name\" && git config user.email you@example.com" 6; return 0
    fi
    if [[ "$(cfg '.allow_dirty // false')" != "true" ]] && git rev-parse --verify -q HEAD >/dev/null 2>&1; then
      local dirty; dirty="$(git status --porcelain --untracked-files=all -- . ':!.harness' ':!.gitignore' 2>/dev/null | head -n 5 || true)"
      if [[ -n "$dirty" ]]; then
        stop_decision "uncommitted changes in the working tree would be swept into harness commits; commit/stash them (or set allow_dirty in config.json): $(echo "$dirty" | tr '\n' ';' | cut -c1-200)" 4; return 0
      fi
    fi
    if lock_live; then
      stop_decision "another harness loop is already running here (lock: $LOCK). If none is running, clear it with: .harness/step.sh unlock" 7; return 0
    fi
    lock_write "$owner"
    rm -f "$HARNESS_DIR/STOP"
    jq -n --argjson run "$(date +%s)" --arg head "$(git rev-parse HEAD 2>/dev/null || echo "")" \
          --argjson max "${maxs:-$(cfg '.max_sessions // 100')}" \
      --argjson s0 "$(cat "$SESSION_FILE" 2>/dev/null || echo 0)" \
      '{run:$run, start_head:$head, ran:0, stuck:0, extra_task:"", max:$max, session:0, session_start:$s0}' > "$STATE"
    ensure_all_ignores "$HARNESS_DIR" >&2 || true
  fi

  lock_touch
  local ran max stuck limit
  ran="$(st_get ran)"; max="$(st_get max)"; stuck="$(st_get stuck)"; limit="$(cfg '.stuck_limit // 3')"

  if [[ -f "$HARNESS_DIR/STOP" ]]; then
    emit DECISION stop; emit REASON "stopped by STOP flag"; emit CODE 0; return 0
  fi
  if [[ "$ran" -ge "$max" ]]; then
    emit DECISION stop; emit REASON "max sessions reached"; emit CODE 2; return 0
  fi
  if [[ "$stuck" -ge "$limit" ]]; then
    emit DECISION stop; emit REASON "stuck: no progress for $limit sessions"; emit CODE 3; return 0
  fi
  if "$FL" done; then
    if final_verification; then
      emit DECISION done; emit REASON "complete: all features pass"; emit CODE 0; return 0
    fi
    st_set_s extra_task "All features are marked passing but the final verification command failed (output in $HARNESS_DIR/sessions/final-verify.log). Command: $(cfg '.final_verify_command'). Fix the root cause."
  fi

  local n; n=$(( $(cat "$SESSION_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$SESSION_FILE"
  st_set session "$n"; st_set ran $((ran + 1))
  st_set pass_before "$(passing)"
  st_set pass_ids_before "$("$FL" list | awk -F'\t' '$2=="PASS"{print $1}' | jq -R -s -c 'split("\n")|map(select(length>0))')"
  st_set verified_ids '[]'
  st_set_s head_before "$(git rev-parse HEAD 2>/dev/null || echo none)"
  local target; target="$("$FL" next | cut -f1 || true)"
  st_set_s target "$target"
  emit DECISION continue; emit SESSION "$n"; emit TARGET "${target:-none}"; emit STATS "$("$FL" stats)"
}

cmd_plan() { jq -r '.pipeline[] | [.agent, (.blocking // true), (.every // 1), (.when // "always")] | @tsv' "$CFG"; }

cmd_task() {
  local agent="${1:?agent name required}" entry n every when target extra
  entry="$(jq -c --arg a "$agent" 'first(.pipeline[]? | select(.agent == $a)) // {}' "$CFG")"
  every="$(jq -r '.every // 1' <<<"$entry")"; when="$(jq -r '.when // "always"' <<<"$entry")"
  n="$(st_get session)"; target="$(st_get target)"; extra="$(st_get extra_task)"
  if (( n % every != 0 )); then echo "SKIP: runs every $every sessions"; return 0; fi
  if [[ "$when" == "claimed" && -z "$(claimed_ids)" ]]; then echo "SKIP: nothing claimed"; return 0; fi
  if [[ "$when" == "failing" && -z "$("$FL" next)" ]]; then echo "SKIP: nothing failing"; return 0; fi
  if [[ "$agent" == "tester" ]]; then st_set verified_ids "$("$FL" claimed | jq -R -s -c 'split("\n")|map(select(length>0))')"; fi
  local task="Harness session $n. Progress: $("$FL" stats). Target feature: ${target:-none}. Features awaiting verification: $(claimed_ids)."
  [[ -n "$extra" ]] && task="$task $extra"
  echo "$task"
}

resolve_agent() {
  local p
  for p in "$HARNESS_DIR/agents/$1.md" "$PLUGIN_ROOT/agents/$1.md" "$PLUGIN_ROOT/templates/agents/$1.md"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

cmd_spawn_info() {
  local name="${1:?agent name required}" def
  def="$(resolve_agent "$name")" || die "agent '$name' not found (looked in $HARNESS_DIR/agents, plugin agents/, templates/agents/)"
  if [[ "$def" == "$PLUGIN_ROOT/agents/$name.md" ]]; then
    echo "TYPE=wreck-it-ralph-loop:$name"
  else
    echo "TYPE=general-purpose"
    echo "---PROMPT---"
    awk '/^---$/{i++; next} i>=2' "$def"
  fi
}

cmd_end() {
  local n limit stuck before after
  n="$(st_get session)"; limit="$(cfg '.stuck_limit // 3')"; stuck="$(st_get stuck)"
  if ! has_tester; then # no verifier in the pipeline: coder claims are accepted as passes
    local id; for id in $(claimed_ids); do "$FL" pass "$id" >/dev/null; echo "harness: (no tester in pipeline) accepted claim $id" >&2; done
  fi
  local unauth=""
  if has_tester; then # only features claimed when the tester started may become passing
    local id
    for id in $(jq -r -n --argjson before "$(st_get_json pass_ids_before)" --argjson ok "$(st_get_json verified_ids)" \
          --slurpfile fl "$HARNESS_DIR/feature_list.json" '[$fl[0].features[] | select(.passes == true) | .id] - $before - $ok | .[]'); do
      "$FL" fail "$id" "marked passing without tester verification (must be claimed, then passed by the tester); reset" >/dev/null
      echo "harness: WARNING $id was marked passing without tester verification; reset to failing" >&2
      unauth="$unauth $id"
    done
  fi
  check_spec_lock
  ensure_clean_state "$n"
  lock_touch
  before="$(st_get pass_before)"; after="$(passing)"
  if [[ "$after" -le "$before" ]]; then stuck=$((stuck + 1)); else stuck=0; fi
  st_set stuck "$stuck"; st_set_s extra_task ""
  emit PASSING "$after"; emit STATS "$("$FL" stats)"
  emit COMMITS "$(git rev-list --count "$(st_get head_before)"..HEAD 2>/dev/null || echo '?')"
  emit STUCK "$stuck/$limit"
  [[ -n "$unauth" ]] && emit UNVERIFIED_RESET "${unauth# }"
  [[ $COMMIT_FAILED -eq 1 ]] && emit WARN "a git commit failed; check git user.name/user.email"
  if [[ "$stuck" -ge "$limit" ]]; then
    emit NEXT stop; emit REASON "stuck: no progress for $limit sessions"; emit CODE 3
  else
    emit NEXT continue
  fi
}

cmd_note() { # agent status [text | stdin]
  local agent="${1:?agent}" status="${2:?ok|failed|skipped}" text n file
  shift 2
  case "$status" in ok|failed|skipped) ;; *) die "status must be ok, failed or skipped" ;; esac
  text="$*"; if [[ -z "$text" && ! -t 0 ]]; then text="$(cat)"; fi
  text="$(printf '%s' "$text" | tr '\n\r' '  ' | cut -c1-300)"
  n="$(st_get session)"; mkdir -p "$HARNESS_DIR/sessions"
  file="$HARNESS_DIR/sessions/$(printf '%03d' "${n:-0}")-notes.md"
  printf -- '- [%s] %s %s: %s\n' "$(date +%H:%M:%S)" "$agent" "$status" "$text" >> "$file"
  echo "noted"
}

cmd_unlock() { rm -f "$LOCK"; echo "lock removed"; }

cmd_summary() {
  local reason="${1:-finished}" code="${2:-0}" out="$HARNESS_DIR/last-run.md" start_head
  start_head="$(st_get start_head)"
  {
    echo "# Harness run summary"
    echo
    echo "- **Stop reason:** $reason (exit code $code)"
    echo "- **Features:** $("$FL" stats)"
    echo "- **Sessions this run:** $(st_get ran)"
    echo
    echo "## Features"
    echo
    echo "| id | status | description | notes |"
    echo "|---|---|---|---|"
    jq -r '.features[] | "| \(.id) | \(if .passes then "PASS" elif .claimed then "CLAIMED" else "FAIL" end) | \(.description | .[0:70]) | \(.notes // "" | .[0:80]) |"' "$HARNESS_DIR/feature_list.json"
    if [[ -n "$start_head" ]]; then
      echo
      echo "## Commits this run"
      echo
      git log --oneline "$start_head"..HEAD 2>/dev/null | sed 's/^/- /'
    fi
    local s0 nf b num any=0; s0="$(st_get session_start)"; s0="${s0:-0}"
    for nf in "$HARNESS_DIR"/sessions/*-notes.md; do
      [[ -f "$nf" ]] || continue; b="$(basename "$nf")"; num="${b%%-*}"
      [[ "$num" =~ ^[0-9]+$ ]] && (( 10#$num > s0 )) || continue
      if [[ $any -eq 0 ]]; then echo; echo "## Agent notes"; echo; any=1; fi
      echo "Session $((10#$num)):"; cat "$nf"
    done
  } > "$out"
  rm -f "$LOCK"
  echo
  sed 's/^#\+ //' "$out"
  echo
  echo "(saved to $out)"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  begin)       cmd_begin "$@" ;;
  plan)        cmd_plan ;;
  task)        cmd_task "$@" ;;
  spawn-info)  cmd_spawn_info "$@" ;;
  end)         cmd_end ;;
  summary)     cmd_summary "$@" ;;
  trust)       cmd_trust "$@" ;;
  note)        cmd_note "$@" ;;
  unlock)      cmd_unlock ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
