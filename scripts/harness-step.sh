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
#   ledger add <agent> [--cost USD] [--tokens N] [--input-tokens N] [--output-tokens N] [--ms N] [--turns N] [--mode M]
#                                record what an agent run cost (headless: parsed from claude's JSON output;
#                                interactive: the orchestrator passes the usage the Agent tool reported)
#   ledger total                 COST=, TOKENS=, MINUTES=, RUNS= for the current run
#   budget                       REMAINING_USD= (empty when no cost cap) for the current run
#   verify                       run gate-owned verify commands for claimed features (also run
#                                automatically before the tester and at `end`); failures -> `fail`
#   trust status|show|accept|accept-verify   review/record the risky repo-supplied config (README "Trust")
#   unlock                       remove a stale loop lock (use only when no loop is running)
#
# begin --new-run stop codes: 4 dirty tree, 5 config not trusted, 6 git identity missing, 7 another loop running
# begin/end stop codes:       2 max sessions, 3 stuck, 8 waiting for a human answer, 9 blocked by dependencies,
#                             10 budget exhausted (cost/tokens/wall time), 11 session diff over budget.max_diff_lines

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
# shellcheck source=harness-lib.sh
source "$PLUGIN_ROOT/scripts/harness-lib.sh"

die() { echo "harness-step: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
[[ -f "$CFG" ]] || die "$CFG missing - run /wreck-it-ralph:init first"
[[ "${1:-}" == "trust" || -f "$HARNESS_DIR/feature_list.json" ]] || die "feature_list.json missing - initializer has not run"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
if [[ -f "$HARNESS_DIR/.step_state.json" ]] && ! jq -e 'type == "object"' "$HARNESS_DIR/.step_state.json" >/dev/null 2>&1; then
  die "$HARNESS_DIR/.step_state.json is corrupted; start a new run with: .harness/step.sh begin --new-run"
fi

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
mcp_path() { cfg '.mcp_config // ""'; }
trust_material() { # everything that can run commands or steer agents with elevated rights
  jq -S '{permission_mode, allowed_tools, final_verify_command, verify_static, claude_bin, model, mcp_config}' "$CFG"
  local m; m="$(mcp_path)"; if [[ -n "$m" && -f "$m" ]]; then echo "## mcp: $m"; cat "$m"; fi
  local f; for f in $(ls "$HARNESS_DIR"/agents/*.md 2>/dev/null | sort); do echo "## agent: $f"; cat "$f"; done
}
trust_hash() { trust_material | sha; }
# Per-feature verify commands are trusted separately (line 2 of .trusted): the initializer and approved
# proposals add them, and both are reviewed by the user, so they can be accepted without re-trusting config.
verify_hash() { local v; v="$("$FL" verify-cmds 2>/dev/null || true)"; if [[ -z "$v" ]]; then echo none; else printf '%s' "$v" | sha; fi; }
config_trusted() { [[ -f "$TRUST_FILE" && "$(sed -n 1p "$TRUST_FILE")" == "$(trust_hash)" ]]; }
is_trusted() { config_trusted && [[ "$(sed -n 2p "$TRUST_FILE" | sed 's/^$/none/')" == "$(verify_hash)" ]]; }

cmd_trust() {
  case "${1:-status}" in
    status) if is_trusted; then echo "trusted"; else echo "NOT trusted: run /wreck-it-ralph:trust to review" >&2; return 1; fi ;;
    accept-verify) # extend trust to the current feature verify commands; only if the config itself is trusted
      config_trusted || die "config is not trusted; review it with /wreck-it-ralph:trust"
      { trust_hash; verify_hash; } > "$TRUST_FILE"; echo "verify commands trusted" ;;
    show)
      echo "These settings come from files in this repository and can run commands on your machine:"
      echo
      echo "permission_mode:      $(cfg '.permission_mode // "default"')"
      echo "allowed_tools:        $(cfg '.allowed_tools // ""')"
      echo "claude_bin:           $(cfg '.claude_bin // "claude"')"
      echo "model:                $(cfg '.model // ""')"
      echo "final_verify_command: $(cfg '.final_verify_command // ""')"
      echo "verify_static:        $(cfg '.verify_static // ""')"
      local v; v="$("$FL" verify-cmds 2>/dev/null || true)"
      if [[ -n "$v" ]]; then echo; echo "Feature verify commands (feature_list.json):"; printf '%s\n' "$v" | sort -u | sed 's/^/  $ /'; fi
      local m; m="$(mcp_path)"
      if [[ -n "$m" && -f "$m" ]]; then echo; echo "MCP servers ($m):"; jq -r '.mcpServers | to_entries[] | "  \(.key): \(.value.command) \((.value.args // []) | join(" "))"' "$m" 2>/dev/null || cat "$m"; fi
      local f any=0; for f in "$HARNESS_DIR"/agents/*.md; do [[ -f "$f" ]] || continue; any=1; done
      if [[ $any -eq 1 ]]; then echo; echo "Custom agent prompts (.harness/agents/):"; ls "$HARNESS_DIR"/agents/*.md | sed 's/^/  /'; fi
      echo; if is_trusted; then echo "Status: trusted"; else echo "Status: NOT trusted yet"; fi ;;
    accept) { trust_hash; verify_hash; } > "$TRUST_FILE"; echo "trust recorded" ;;
    *) die "usage: trust status|show|accept|accept-verify" ;;
  esac
}


# ---------- single loop per project (heartbeat lock; headless runners also register their pid) ----------
LOCK="$HARNESS_DIR/.lock"   # lock_live() comes from harness-lib.sh
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

SNAP_LOCK="$HARNESS_DIR/.lock_snapshot.json"
SNAP_PROPS="$HARNESS_DIR/.proposals_snapshot.json"
LIST_LOCK="$HARNESS_DIR/.feature_list.lock.json"
PROPS="$HARNESS_DIR/proposals.json"

LEDGER="$HARNESS_DIR/ledger.jsonl"
bcfg() { jq -r --arg k "$1" '(.budget // {})[$k] // 0' "$CFG"; }   # budget.<key>, 0 = unlimited
num_ok() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

ledger_totals() { # -> "cost tokens runs" for the current run (state .run)
  local run; run="$(st_get run)"
  if [[ -z "$run" || ! -f "$LEDGER" ]]; then echo "0 0 0"; return 0; fi
  jq -rs --argjson run "$run" '[.[] | select(.run == $run)] as $e
    | "\([$e[].cost_usd // 0] | add // 0) \([$e[] | (.input_tokens // 0) + (.output_tokens // 0) + (.tokens // 0)] | add // 0) \($e | length)"' "$LEDGER" 2>/dev/null || echo "0 0 0"
}
run_minutes() { local run; run="$(st_get run)"; if [[ -n "$run" ]]; then echo $(( ($(date +%s) - run) / 60 )); else echo 0; fi; }

cmd_ledger() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      local agent="${1:?agent required}" cost="" tokens="" itok="" otok="" ms="" turns="" mode="interactive"; shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --cost) cost="${2:-}"; shift 2 ;; --tokens) tokens="${2:-}"; shift 2 ;;
          --input-tokens) itok="${2:-}"; shift 2 ;; --output-tokens) otok="${2:-}"; shift 2 ;;
          --ms) ms="${2:-}"; shift 2 ;; --turns) turns="${2:-}"; shift 2 ;; --mode) mode="${2:-}"; shift 2 ;;
          *) die "unknown ledger option: $1" ;;
        esac
      done
      local v; for v in "$cost" "$tokens" "$itok" "$otok" "$ms" "$turns"; do [[ -z "$v" ]] || num_ok "$v" || die "ledger values must be numbers, got: $v"; done
      local run session; run="$(st_get run)"; session="$(st_get session)"
      jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson run "${run:-0}" --argjson session "${session:-0}" \
        --arg agent "$agent" --arg mode "$mode" --arg cost "$cost" --arg tokens "$tokens" --arg itok "$itok" --arg otok "$otok" --arg ms "$ms" --arg turns "$turns" '
        def n($x): if $x == "" then null else ($x | tonumber) end;
        {at: $at, run: $run, session: $session, agent: $agent, mode: $mode, cost_usd: n($cost), tokens: n($tokens),
         input_tokens: n($itok), output_tokens: n($otok), duration_ms: n($ms), turns: n($turns)} | with_entries(select(.value != null))' >> "$LEDGER"
      echo "recorded"
      ;;
    total)
      local t; read -r -a t <<<"$(ledger_totals)"
      emit COST "${t[0]}"; emit TOKENS "${t[1]}"; emit MINUTES "$(run_minutes)"; emit RUNS "${t[2]}"
      ;;
    *) die "usage: ledger add|total" ;;
  esac
}

cmd_budget() {
  local cap; cap="$(bcfg max_cost_usd)"
  if [[ "$cap" == "0" ]]; then emit REMAINING_USD ""; return 0; fi
  local t; read -r -a t <<<"$(ledger_totals)"
  emit REMAINING_USD "$(jq -n --argjson c "$cap" --argjson s "${t[0]}" '[$c - $s, 0] | max | . * 100 | floor / 100')"
}

budget_exhausted() { # prints a reason when a run budget is used up
  local t cap; read -r -a t <<<"$(ledger_totals)"
  cap="$(bcfg max_cost_usd)"
  if [[ "$cap" != "0" ]] && jq -en --argjson c "$cap" --argjson s "${t[0]}" '$s >= $c' >/dev/null; then echo "cost \$${t[0]} reached budget.max_cost_usd \$$cap"; return 0; fi
  cap="$(bcfg max_tokens)"
  if [[ "$cap" != "0" && "${t[1]%.*}" -ge "$cap" ]]; then echo "${t[1]%.*} tokens reached budget.max_tokens $cap"; return 0; fi
  cap="$(bcfg max_wall_minutes)"
  if [[ "$cap" != "0" && "$(run_minutes)" -ge "$cap" ]]; then echo "$(run_minutes) minutes reached budget.max_wall_minutes $cap"; return 0; fi
  return 1
}

session_diff_lines() { # lines added+removed since the session started, outside .harness/
  local base; base="$(st_get head_before)"
  if [[ -z "$base" || "$base" == none ]]; then echo 0; return 0; fi
  git diff --numstat "$base" HEAD -- . ':!.harness' 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {s += $1 + $2} END {print s + 0}'
}

ids_json() { "$FL" ids --status "$1" | jq -R -s -c 'split("\n")|map(select(length>0))'; }

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
      stop_decision "harness config is not trusted yet (it can run commands): review it with /wreck-it-ralph:trust, then start again" 5; return 0
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
    if [[ -f "$HARNESS_DIR/STOP" ]]; then rm -f "$HARNESS_DIR/STOP"; emit NOTE "cleared a STOP flag left from an earlier cancel (starting a new run overrides it)"; fi
    jq -n --argjson run "$(date +%s)" --arg head "$(git rev-parse HEAD 2>/dev/null || echo "")" \
          --argjson max "${maxs:-$(cfg '.max_sessions // 100')}" \
      --argjson s0 "$(cat "$SESSION_FILE" 2>/dev/null || echo 0)" \
      '{run:$run, start_head:$head, ran:0, stuck:0, extra_task:"", max:$max, session:0, session_start:$s0, in_session:false}' > "$STATE"
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
  local spent; if spent="$(budget_exhausted)"; then
    emit DECISION stop; emit REASON "budget exhausted: $spent"; emit CODE 10; return 0
  fi
  if "$FL" done; then
    if final_verification; then
      emit DECISION done; emit REASON "complete: all features pass"; emit CODE 0; return 0
    fi
    st_set_s extra_task "All features are marked passing but the final verification command failed (output in $HARNESS_DIR/sessions/final-verify.log). Command: $(cfg '.final_verify_command'). Fix the root cause."
  fi

  local target; target="$("$FL" next | cut -f1 || true)"
  if [[ -z "$target" && -z "$(claimed_ids)" ]] && ! "$FL" done; then
    local waiting; waiting="$("$FL" ids --status needs_human | tr '\n' ' ' | sed 's/ *$//')"
    if [[ -n "$waiting" ]]; then
      stop_decision "waiting for a human: $waiting need an answer (see .harness/feature-list.sh questions; answer with /wreck-it-ralph:backlog answer <ID> \"...\")" 8; return 0
    fi
    stop_decision "blocked: no remaining feature has its dependencies passing ($("$FL" list --failing | cut -f1 | tr '\n' ' ' | sed 's/ *$//'))" 9; return 0
  fi

  local n; n=$(( $(cat "$SESSION_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$SESSION_FILE"
  st_set session "$n"; st_set ran $((ran + 1))
  st_set pass_before "$(passing)"
  st_set human_before "$("$FL" count needs_human)"
  st_set pass_ids_before "$(ids_json passing)"
  st_set verified_ids '[]'
  st_set verify_done 0
  st_set_s verify_failed ""
  st_set_s head_before "$(git rev-parse HEAD 2>/dev/null || echo none)"
  st_set_s target "$target"
  # Snapshot the spec lock and proposals: an approval made during the session is undone at `end`.
  if [[ -f "$LIST_LOCK" ]]; then cp "$LIST_LOCK" "$SNAP_LOCK"; else rm -f "$SNAP_LOCK"; fi
  if [[ -f "$PROPS" ]]; then cp "$PROPS" "$SNAP_PROPS"; else rm -f "$SNAP_PROPS"; fi
  st_set in_session true
  emit DECISION continue; emit SESSION "$n"; emit TARGET "${target:-none}"; emit STATS "$("$FL" stats)"
}

cmd_plan() { jq -r '.pipeline[] | [.agent, (.blocking // true), (.every // 1), (.when // "always")] | @tsv' "$CFG"; }

# Gate-owned verification: commands the agents cannot fake. Runs once per session, before the
# tester (or any step with when=claimed), and at `end` when no such step ran.
cmd_verify() {
  local n; n="$(st_get session)"
  [[ "$(st_get verify_done)" == "1" ]] && return 0
  st_set verify_done 1
  local static id cmd failed ran log failed_ids=""
  static="$(cfg '.verify_static // ""')"
  for id in $(claimed_ids); do
    failed=""; ran=0; log="$HARNESS_DIR/sessions/$(printf '%03d' "${n:-0}")-verify-$id.log"
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      ran=1; printf '$ %s\n' "$cmd" >> "$log"
      if ! bash -c "$cmd" >> "$log" 2>&1 < /dev/null; then failed="$cmd"; break; fi
    done < <( { [[ -n "$static" ]] && printf '%s\n' "$static"; "$FL" verify-cmds "$id"; } || true )
    if [[ -n "$failed" ]]; then
      "$FL" fail "$id" "verify command failed: $failed | $(tail -n 5 "$log" | tr '\n' ' ' | cut -c1-240) (log: $log)" >/dev/null
      echo "harness: verify failed for $id: $failed" >&2
      failed_ids="$failed_ids $id"
    elif [[ $ran -eq 1 ]]; then
      echo "harness: verify commands passed for $id" >&2
    fi
  done
  st_set_s verify_failed "${failed_ids# }"
  [[ -n "$failed_ids" ]] && emit VERIFY_FAILED "${failed_ids# }"
  return 0
}

feature_context() { # id -> extra task text for a retry: last failure, human answer
  [[ -z "$1" ]] && return 0
  jq -r --arg id "$1" '.features[] | select(.id == $id)
    | ([ (if (.answer // "") != "" then "Human answer for \(.id): \(.answer)." else empty end),
         (if (.notes // "") != "" then "Previous attempt failed: \(.notes | .[0:400]). Do not repeat the approach that failed." else empty end) ] | join(" "))' \
    "$HARNESS_DIR/feature_list.json"
}

cmd_task() {
  local agent="${1:?agent name required}" entry n every when target extra
  entry="$(jq -c --arg a "$agent" 'first(.pipeline[]? | select(.agent == $a)) // {}' "$CFG")"
  every="$(jq -r '.every // 1' <<<"$entry")"; when="$(jq -r '.when // "always"' <<<"$entry")"
  n="$(st_get session)"; target="$(st_get target)"; extra="$(st_get extra_task)"
  if (( n % every != 0 )); then echo "SKIP: runs every $every sessions"; return 0; fi
  if [[ "$when" == "claimed" || "$agent" == "tester" ]]; then cmd_verify >/dev/null; fi
  if [[ "$when" == "claimed" && -z "$(claimed_ids)" ]]; then echo "SKIP: nothing claimed$( [[ -n "$(st_get verify_failed)" ]] && echo " (verify commands failed: $(st_get verify_failed))")"; return 0; fi
  if [[ "$when" == "failing" && -z "$("$FL" next)" ]]; then echo "SKIP: nothing failing"; return 0; fi
  if [[ "$agent" == "tester" ]]; then st_set verified_ids "$("$FL" claimed | jq -R -s -c 'split("\n")|map(select(length>0))')"; fi
  local task="Harness session $n. Progress: $("$FL" stats). Target feature: ${target:-none}. Features awaiting verification: $(claimed_ids)."
  local ctx; ctx="$(feature_context "$target")"
  [[ -n "$ctx" && "$agent" != "tester" ]] && task="$task $ctx"
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
    echo "TYPE=wreck-it-ralph:$name"
  else
    echo "TYPE=general-purpose"
    echo "---PROMPT---"
    awk '/^---$/{i++; next} i>=2' "$def"
  fi
}

# Undo backlog approvals made while the session ran (only humans approve, and only between sessions).
check_backlog_snapshot() {
  [[ -f "$SNAP_LOCK" ]] || return 0
  if ! cmp -s "$SNAP_LOCK" "$LIST_LOCK" 2>/dev/null; then
    echo "harness: the feature spec lock changed during the session (approvals are human-only, between sessions); undoing it" >&2
    cp "$SNAP_LOCK" "$LIST_LOCK"
    # Keep proposals filed during the session (agents may propose), but put any approval back to pending.
    if [[ -f "$PROPS" ]]; then
      local tmp="$PROPS.tmp.$$" snap='{"proposals":[]}'
      [[ -f "$SNAP_PROPS" ]] && snap="$(cat "$SNAP_PROPS")"
      jq --argjson snap "$snap" '
        ($snap.proposals | map({key: .id, value: .status}) | from_entries) as $was
        | .proposals |= map(if .status == "approved" and ($was[.id] // "pending") != "approved"
                            then .status = "pending" | del(.decided_at) else . end)' "$PROPS" > "$tmp" && mv "$tmp" "$PROPS"
    fi
    "$FL" restore >&2
    REVERTED=1
  fi
}

cmd_end() {
  local n limit stuck before after
  n="$(st_get session)"; limit="$(cfg '.stuck_limit // 3')"; stuck="$(st_get stuck)"
  REVERTED=0
  check_backlog_snapshot
  cmd_verify >/dev/null
  if ! has_tester; then # no tester in the pipeline: verified claims are accepted as passes
    local id; for id in $(claimed_ids); do "$FL" pass "$id" >/dev/null; echo "harness: (no tester in pipeline) accepted claim $id" >&2; done
  fi
  local unauth=""
  if has_tester; then # only features claimed when the tester started may become passing
    local id
    for id in $(jq -r -n --argjson before "$(st_get_json pass_ids_before)" --argjson ok "$(st_get_json verified_ids)" \
          --argjson now "$(ids_json passing)" '$now - $before - $ok | .[]'); do
      "$FL" fail "$id" "marked passing without tester verification (must be claimed, then passed by the tester); reset" >/dev/null
      echo "harness: WARNING $id was marked passing without tester verification; reset to failing" >&2
      unauth="$unauth $id"
    done
  fi
  # Escalate features that keep failing so the loop can move on (skip-and-continue).
  local esc escalated="" fid fails
  esc="$(cfg '.escalate_after_failures // 3')"
  if [[ "$esc" =~ ^[0-9]+$ && "$esc" -gt 0 ]]; then
    for fid in $("$FL" ids --status failing); do
      fails="$("$FL" failures "$fid")"
      if [[ "$fails" -ge "$esc" ]]; then
        "$FL" ask "$fid" "failed $fails attempts in a row; last note: $(jq -r --arg id "$fid" '.features[] | select(.id == $id) | .notes // "" | .[0:200]' "$HARNESS_DIR/feature_list.json"). Clarify the requirement, give a hint, or drop it." >/dev/null
        echo "harness: $fid failed $fails times; escalated to a human (needs_human)" >&2
        escalated="$escalated $fid"
      fi
    done
  fi
  check_spec_lock
  ensure_clean_state "$n"
  lock_touch
  st_set in_session false
  before="$(st_get pass_before)"; after="$(passing)"
  # Progress = more features passing, or a feature handed to a human (the loop can move on).
  if [[ "$after" -gt "$before" || "$("$FL" count needs_human)" -gt "$(st_get human_before)" ]]; then stuck=0; else stuck=$((stuck + 1)); fi
  st_set stuck "$stuck"; st_set_s extra_task ""
  emit PASSING "$after"; emit STATS "$("$FL" stats)"
  emit COMMITS "$(git rev-list --count "$(st_get head_before)"..HEAD 2>/dev/null || echo '?')"
  emit STUCK "$stuck/$limit"
  local maxd lines large=0; maxd="$(bcfg max_diff_lines)"; lines="$(session_diff_lines)"
  emit DIFF_LINES "$lines"
  if [[ "$maxd" != "0" && "$lines" -gt "$maxd" ]]; then
    large=1; emit WARN "session $n changed $lines lines (budget.max_diff_lines $maxd); review the commits"
  fi
  [[ -n "$unauth" ]] && emit UNVERIFIED_RESET "${unauth# }"
  [[ -n "$(st_get verify_failed)" ]] && emit VERIFY_FAILED "$(st_get verify_failed)"
  [[ -n "$escalated" ]] && emit NEEDS_HUMAN "${escalated# }"
  [[ $REVERTED -eq 1 ]] && emit WARN "a backlog approval made during the session was undone; approve between sessions"
  [[ $COMMIT_FAILED -eq 1 ]] && emit WARN "a git commit failed; check git user.name/user.email"
  local spent
  if [[ "$stuck" -ge "$limit" ]]; then
    emit NEXT stop; emit REASON "stuck: no progress for $limit sessions"; emit CODE 3
  elif [[ $large -eq 1 && "$(jq -r '(.budget // {}).on_large_diff // "warn"' "$CFG")" == "stop" ]]; then
    emit NEXT stop; emit REASON "large diff: session $n changed $lines lines (over budget.max_diff_lines $maxd); review it, then run again"; emit CODE 11
  elif spent="$(budget_exhausted)"; then
    emit NEXT stop; emit REASON "budget exhausted: $spent"; emit CODE 10
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
    local t; read -r -a t <<<"$(ledger_totals)"
    echo "- **Spend this run:** \$${t[0]} | ${t[1]} tokens | $(run_minutes) min | ${t[2]} agent runs recorded"
    echo
    echo "## Features"
    echo
    echo "| id | status | description | notes |"
    echo "|---|---|---|---|"
    "$FL" table
    local q; q="$("$FL" questions)"
    if [[ -n "$q" ]]; then echo; echo "## Waiting for a human"; echo; printf '%s\n' "$q" | sed 's/\t/: /; s/^/- /'; fi
    local pend; pend="$(jq -r '.proposals[]? | select(.status == "pending") | "- \(.id): \(.reason)"' "$PROPS" 2>/dev/null || true)"
    if [[ -n "$pend" ]]; then echo; echo "## Backlog proposals awaiting approval"; echo; echo "$pend"; fi
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
  verify)      cmd_verify ;;
  summary)     cmd_summary "$@" ;;
  trust)       cmd_trust "$@" ;;
  note)        cmd_note "$@" ;;
  ledger)      cmd_ledger "$@" ;;
  budget)      cmd_budget ;;
  unlock)      cmd_unlock ;;
  *) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
