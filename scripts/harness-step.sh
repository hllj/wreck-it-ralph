#!/bin/bash
# harness-step.sh - deterministic gates for one harness session.
#
# Shared by BOTH loop modes so the rules live in code, not in an LLM's memory:
#   - /harness-run  (Claude Code orchestrator spawning coder/tester subagents)
#   - .harness/run.sh (headless runner spawning `claude -p` processes)
#
# Usage: .harness/step.sh <command> [args]
#   begin [--new-run] [--max-sessions N] [--owner-pid PID] [--rollout L1|L2|L3]
#         Decide whether to start another session. Prints KEY=VALUE lines:
#         DECISION=continue|done|stop  SESSION=n  TARGET=<feature id>  STATS=...  REASON=...  CODE=<exit code>
#   plan                         list pipeline steps: name<TAB>blocking<TAB>every<TAB>when
#   task <name>                  print the task message for the step, or "SKIP: <why>"
#   spawn-info <name>            TYPE=<subagent type> | general-purpose | gate, OPTIONAL=true|false;
#                                for general-purpose the prompt follows "---PROMPT---"
#   run-step <name>              run a `cmd:` pipeline step in the gate (exit code = result)
#   fanout plan|task <ID>|merge|cleanup   parallel coders in git worktrees (headless; parallel.max_workers > 1):
#                                plan picks the batch and creates worktrees (WORKERS=n, WORKER=<id> <path>),
#                                merge folds each worker branch back and applies its claim/question/proposals
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
#                             10 budget exhausted (cost/tokens/wall time), 11 session diff over budget.max_diff_lines,
#                             12 rollout branch problem (detached HEAD, no commits, or not on the run branch)
#
# Rollout (config `rollout`, or --rollout on a new run):
#   L3  unattended: commit on the current branch (default)
#   L2  assisted:   work on a new branch harness/run-<time>; at the end optionally push it and open a PR
#                   (rollout_push / rollout_pr); your branch is never committed to
#   L1  shadow:     work on harness/shadow-<time>, then switch back to your branch and leave only a report

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
# Pipeline steps: {"agent": "coder"} (classic) or {"name": "review", "use": "agent:plugin:agent" | "agent:name" |
# "skill:name" | "command:/plugin:cmd args" | "cmd:shell", "optional": true}. A step's name is its handle.
STEPNAME='def stepname: .name // .agent // ((.use // "step") | sub("^[a-z]+:\\s*/?"; "") | gsub("[^A-Za-z0-9_-]+"; "-") | .[0:40]);'
step_entry() { jq -c --arg a "$1" "$STEPNAME"' [.pipeline[]? | select(stepname == $a)] | .[0] // {}' "$CFG"; }
is_extension() { case "$1" in agent:*:*|skill:*|command:*) return 0 ;; esac; return 1; } # another plugin's agent / a skill
has_tester() { jq -e 'any(.pipeline[]?; .agent == "tester" or .use == "agent:tester")' "$CFG" >/dev/null; }
hooks_allowed() { is_trusted; }


# ---------- trust: repo-supplied config can execute code, so it must be reviewed once per machine ----------
TRUST_FILE="$HARNESS_DIR/.trusted"
mcp_path() { cfg '.mcp_config // ""'; }
trust_material() { # everything that can run commands or steer agents with elevated rights
  jq -S '{permission_mode, allowed_tools, final_verify_command, verify_static, claude_bin, model, mcp_config,
          uses: [.pipeline[]? | .use // empty], models: [.pipeline[]? | .model // empty], hooks: (.hooks // {}),
          rollout_push, rollout_pr, parallel} + (if .replay then {replay} else {} end) + (if .coverage then {coverage: {tool: .coverage.tool, cmd: .coverage.cmd}} else {} end)' "$CFG"
  local m; m="$(mcp_path)"; if [[ -n "$m" && -f "$m" ]]; then echo "## mcp: $m"; cat "$m"; fi
  local f; for f in $(ls "$HARNESS_DIR"/agents/*.md 2>/dev/null | sort); do echo "## agent: $f"; cat "$f"; done
}
trust_hash() { trust_material | sha; }
# Per-feature verify commands are trusted separately (line 2 of .trusted): the initializer and approved
# proposals add them, and both are reviewed by the user, so they can be accepted without re-trusting config.
# Part 2 also covers .harness/stop.sh, which the initializer writes and the gate runs at the end of a run.
verify_hash() {
  local v; v="$("$FL" verify-cmds 2>/dev/null || true)"
  [[ -f "$HARNESS_DIR/stop.sh" ]] && v="$v"$'\n## stop.sh\n'"$(cat "$HARNESS_DIR/stop.sh")"
  if [[ -z "$v" ]]; then echo none; else printf '%s' "$v" | sha; fi
}
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
      if [[ -n "$(cfg '.coverage.cmd // ""')" ]]; then echo "coverage.cmd:         $(cfg '.coverage.cmd') (runs the test suite under coverage)"; fi
      if [[ -n "$(cfg '.replay.command // ""')" ]]; then echo "replay.command:       $(cfg '.replay.command') (runs with example arguments; replay.base_url: $(cfg '.replay.base_url // ""'))"; fi
      local u; u="$(jq -r '.pipeline[]? | select(.use) | "  \(.name // "-"): \(.use)\(if .optional then " (optional)" else "" end)"' "$CFG")"
      if [[ -n "$u" ]]; then echo; echo "Pipeline extensions (other plugins' agents/skills, shell steps):"; echo "$u"; fi
      local h; h="$(jq -r '(.hooks // {}) | to_entries[] | .key as $k | (.value | if type == "string" then [.] else . end)[] | "  \($k): \(.)"' "$CFG")"
      if [[ -n "$h" ]]; then echo; echo "Hooks (run on harness events):"; echo "$h"; fi
      local v; v="$("$FL" verify-cmds 2>/dev/null || true)"
      if [[ -n "$v" ]]; then echo; echo "Feature verify commands (feature_list.json):"; printf '%s\n' "$v" | sort -u | sed 's/^/  $ /'; fi
      if [[ -f "$HARNESS_DIR/stop.sh" ]]; then echo; echo "Cleanup script run by the gate at the end of each run ($HARNESS_DIR/stop.sh):"; sed 's/^/  | /' "$HARNESS_DIR/stop.sh"; fi
      local pm; pm="$(jq -r '.pipeline[]? | select(.model) | "  \(.name // .agent): \(.model)"' "$CFG")"
      if [[ -n "$pm" ]]; then echo; echo "Per-step models:"; echo "$pm"; fi
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

# Keep progress.md small enough to read every session: move older entries to progress/archive-NNN.md
# (split at an entry heading), keep the newest ~150 lines. learnings.md holds the distilled lessons.
rotate_progress() {
  local f="$HARNESS_DIR/progress.md" max size total cut n arch
  max="$(cfg '.progress_max_kb // 64')"
  [[ -f "$f" && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || return 0
  size="$(wc -c < "$f" | tr -d ' ')"
  (( size > max * 1024 )) || return 0
  total="$(wc -l < "$f" | tr -d ' ')"; cut=$(( total - 150 )); (( cut > 1 )) || return 0
  cut="$(awk -v c="$cut" 'NR >= c && /^## / {print NR; exit}' "$f")"; cut="${cut:-$(( total - 150 ))}"
  mkdir -p "$HARNESS_DIR/progress"
  n=$(( $(find "$HARNESS_DIR/progress" -name 'archive-*.md' | wc -l) + 1 )); arch="$HARNESS_DIR/progress/archive-$(printf '%03d' "$n").md"
  head -n $(( cut - 1 )) "$f" > "$arch"
  { echo "# Progress log"; echo
    echo "(append-only; older entries were moved to progress/archive-*.md; distilled lessons are in learnings.md)"; echo
    tail -n +"$cut" "$f"; } > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
  echo "harness: progress.md over ${max}KB; moved older entries to $arch" >&2
}

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
    | "\([$e[].cost_usd // 0] | add // 0 | . * 10000 | round / 10000) \([$e[] | (.input_tokens // 0) + (.output_tokens // 0) + (.tokens // 0)] | add // 0) \($e | length)"' "$LEDGER" 2>/dev/null || echo "0 0 0"
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
  local newrun=0 maxs="" owner=0 rollout_opt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new-run) newrun=1; shift ;;
      --rollout) rollout_opt="${2:?L1|L2|L3 required}"; shift 2 ;;
      --max-sessions) maxs="${2:?number required}"; shift 2 ;;
      --owner-pid) owner="${2:?pid required}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$owner" =~ ^[0-9]+$ ]] || die "--owner-pid must be a number"
  [[ -z "$maxs" || "$maxs" =~ ^[0-9]+$ ]] || die "--max-sessions must be a non-negative integer, got: $maxs"
  [[ -z "$rollout_opt" || "$rollout_opt" =~ ^L[123]$ ]] || die "--rollout must be L1, L2 or L3, got: $rollout_opt"
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
    local rollout base="" rbranch=""
    rollout="${rollout_opt:-$(cfg '.rollout // "L3"')}"
    [[ "$rollout" =~ ^L[123]$ ]] || { rm -f "$LOCK"; die "config rollout must be L1, L2 or L3, got: $rollout"; }
    if [[ "$rollout" != L3 ]]; then
      base="$(git branch --show-current 2>/dev/null || true)"
      if [[ -z "$base" ]] || ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        rm -f "$LOCK"; stop_decision "rollout $rollout needs a checked-out branch with at least one commit (detached HEAD or empty repository)" 12; return 0
      fi
      if [[ "$base" == harness/* && -n "$(git config "branch.$base.harnessBase" 2>/dev/null)" ]]; then
        rbranch="$base"; base="$(git config "branch.$rbranch.harnessBase")"   # resume an earlier run branch
      else
        rbranch="harness/$([[ "$rollout" == L1 ]] && echo shadow || echo run)-$(date +%Y%m%d-%H%M%S)"
        git checkout -q -b "$rbranch" || { rm -f "$LOCK"; stop_decision "could not create branch $rbranch" 12; return 0; }
        git config "branch.$rbranch.harnessBase" "$base"; git config "branch.$rbranch.harnessRollout" "$rollout"
      fi
      emit ROLLOUT "$rollout"; emit BRANCH "$rbranch"; emit BASE "$base"
    fi
    jq -n --argjson run "$(date +%s)" --arg head "$(git rev-parse HEAD 2>/dev/null || echo "")" \
          --argjson max "${maxs:-$(cfg '.max_sessions // 100')}" \
      --argjson s0 "$(cat "$SESSION_FILE" 2>/dev/null || echo 0)" \
      --arg rollout "$rollout" --arg rb "$rbranch" --arg base "$base" \
      '{run:$run, start_head:$head, ran:0, stuck:0, extra_task:"", max:$max, session:0, session_start:$s0, in_session:false,
        rollout:$rollout, run_branch:$rb, base_branch:$base}' > "$STATE"
    ensure_all_ignores "$HARNESS_DIR" >&2 || true
    [[ -d "$WT_DIR" ]] && cmd_fanout cleanup
    fire run_started "stats=$("$FL" stats)" >&2
  fi

  lock_touch
  local ran max stuck limit
  ran="$(st_get ran)"; max="$(st_get max)"; stuck="$(st_get stuck)"; limit="$(cfg '.stuck_limit // 3')"

  if [[ -f "$HARNESS_DIR/STOP" ]]; then
    emit DECISION stop; emit REASON "stopped by STOP flag"; emit CODE 0; return 0
  fi
  local rb; rb="$(st_get run_branch)"
  if [[ -n "$rb" && "$(git branch --show-current 2>/dev/null)" != "$rb" ]]; then
    stop_decision "not on this run's branch $rb (now on '$(git branch --show-current 2>/dev/null)'); switch back with: git checkout $rb" 12; return 0
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

  if [[ -z "$target" && -n "$(claimed_ids)" ]]; then
    local run_iso; run_iso="$(date -u -r "$(st_get run)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(st_get run)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
    if [[ -n "$run_iso" && "$(claimed_ids)" == "$("$FL" blocked-ids --since "$run_iso" | tr '\n' ' ' | sed 's/ *$//')" ]]; then
      stop_decision "blocked: the tester could not verify $(claimed_ids) (app or environment problem, not a logic failure; see progress.md and .harness/evidence/). Fix it (.harness/init.sh must start the app), then run again" 9; return 0
    fi
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
  st_set_s session_started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fire session_started "session=$n" "target=${target:-none}" "stats=$("$FL" stats)" >&2
  emit DECISION continue; emit SESSION "$n"; emit TARGET "${target:-none}"; emit STATS "$("$FL" stats)"
}

cmd_plan() { jq -r "$STEPNAME"' .pipeline[] | [stepname, (if has("blocking") then .blocking else (has("use") | not) end), (.every // 1), (.when // "always")] | @tsv' "$CFG"; }

# Gate-owned verification: commands the agents cannot fake. Runs once per session, before the
# tester (or any step with when=claimed), and at `end` when no such step ran.
cmd_verify() {
  local n; n="$(st_get session)"
  [[ "$(st_get verify_done)" == "1" ]] && return 0
  st_set verify_done 1
  local static id cmd failed ran log failed_ids=""
  static="$(cfg '.verify_static // ""')"
  for id in $(claimed_ids); do
    fire feature_claimed "feature=$id" "session=${n:-0}" >&2
    failed=""; ran=0; log="$HARNESS_DIR/sessions/$(printf '%03d' "${n:-0}")-verify-$id.log"
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      ran=1; printf '$ %s\n' "$cmd" >> "$log"
      if ! bash -c "$cmd" >> "$log" 2>&1 < /dev/null; then failed="$cmd"; break; fi
    done < <( { [[ -n "$static" ]] && printf '%s\n' "$static"; "$FL" verify-cmds "$id"; } || true )
    if [[ -n "$failed" ]]; then
      "$FL" fail "$id" "verify command failed: $failed | $(tail -n 5 "$log" | tr '\n' ' ' | cut -c1-240) (log: $log)" >/dev/null
      echo "harness: verify failed for $id: $failed" >&2
      fire verify_failed "feature=$id" "command=$failed" "session=${n:-0}" >&2
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
  local agent="${1:?step name required}" entry n every when target extra
  entry="$(step_entry "$agent")"
  every="$(jq -r '.every // 1' <<<"$entry")"; when="$(jq -r '.when // "always"' <<<"$entry")"
  n="$(st_get session)"; target="$(st_get target)"; extra="$(st_get extra_task)"
  if (( n % every != 0 )); then echo "SKIP: runs every $every sessions"; return 0; fi
  if [[ "$when" == "claimed" || "$agent" == "tester" ]]; then cmd_verify >/dev/null; fi
  if [[ "$when" == "claimed" && -z "$(claimed_ids)" ]]; then echo "SKIP: nothing claimed$( [[ -n "$(st_get verify_failed)" ]] && echo " (verify commands failed: $(st_get verify_failed))")"; return 0; fi
  if [[ "$when" == "failing" && -z "$("$FL" next)" ]]; then echo "SKIP: nothing failing"; return 0; fi
  if [[ "$when" == "passed" && -z "$(newly_passing)" ]]; then echo "SKIP: nothing passed this session"; return 0; fi
  if [[ "$when" == tag:* ]]; then
    local tag="${when#tag:}"
    if ! jq -e --arg id "$target" --arg t "$tag" '.features[] | select(.id == $id) | (.tags // []) | index($t)' "$HARNESS_DIR/feature_list.json" >/dev/null 2>&1; then
      echo "SKIP: target ${target:-none} is not tagged $tag"; return 0
    fi
  fi
  if [[ "$agent" == "tester" ]]; then st_set_s tester_started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
  if [[ "$agent" == "tester" ]]; then st_set verified_ids "$("$FL" claimed | jq -R -s -c 'split("\n")|map(select(length>0))')"; fi
  local task="Harness session $n. Progress: $("$FL" stats). Target feature: ${target:-none}. Features awaiting verification: $(claimed_ids)."
  local ctx; ctx="$(feature_context "$target")"
  [[ -n "$ctx" && "$agent" != "tester" ]] && task="$task $ctx"
  [[ -n "$extra" ]] && task="$task $extra"
  if is_extension "$(jq -r '.use // ""' <<<"$entry")"; then
    local np; np="$(newly_passing | tr '\n' ' ' | sed 's/ *$//')"
    task="$task Commits this session: $(st_get head_before)..HEAD. Features passed this session: ${np:-none}.
You are an extension step '$agent' in a long-running agent harness (state in .harness/, see .harness/progress.md). Do your job on the work of this session.
Rules: never edit .harness/feature_list.json and never run feature-list.sh pass/claim. If you find that a feature passed this session is actually broken, run: .harness/feature-list.sh fail <ID> \"<precise reason>\". To suggest follow-up work, file a proposal: .harness/backlog.sh propose --by $agent --reason \"...\" --file <payload.json> (payload: {\"add\":[{\"description\":...,\"steps\":[...]}]}). Append a short '$agent' entry with your findings to .harness/progress.md, commit any change you make, and leave git status clean. Finish with a 2-3 line summary."
  fi
  echo "$task"
}

newly_passing() { jq -r -n --argjson before "$(st_get_json pass_ids_before)" --argjson now "$(ids_json passing)" '$now - $before | .[]'; }

resolve_agent() {
  local p
  for p in "$HARNESS_DIR/agents/$1.md" "$PLUGIN_ROOT/agents/$1.md" "$PLUGIN_ROOT/templates/agents/$1.md"; do
    [[ -f "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

cmd_spawn_info() {
  local name="${1:?step name required}" def entry use optional ref
  entry="$(step_entry "$name")"
  use="$(jq -r '.use // ""' <<<"$entry")"; optional="$(jq -r '.optional // false' <<<"$entry")"
  [[ -z "$use" ]] && use="agent:$name"
  local model; model="$(jq -r '.model // ""' <<<"$entry")"
  [[ -n "$model" ]] && echo "MODEL=$model"
  case "$use" in
    agent:*:*) # another plugin's agent, e.g. agent:pr-review-toolkit:code-reviewer
      echo "TYPE=${use#agent:}"; echo "OPTIONAL=$optional" ;;
    agent:*)
      ref="${use#agent:}"
      def="$(resolve_agent "$ref")" || {
        [[ "$optional" == true ]] && { echo "TYPE=missing"; echo "OPTIONAL=true"; return 0; }
        die "agent '$ref' not found (looked in $HARNESS_DIR/agents, plugin agents/, templates/agents/)"; }
      if [[ "$def" == "$PLUGIN_ROOT/agents/$ref.md" ]]; then
        echo "TYPE=wreck-it-ralph:$ref"; echo "OPTIONAL=$optional"
      else
        echo "TYPE=general-purpose"; echo "OPTIONAL=$optional"; echo "---PROMPT---"
        awk '/^---$/{i++; next} i>=2' "$def"
      fi ;;
    skill:*|command:*) # a skill or slash command, run by a fresh general-purpose subagent
      ref="${use#*:}"; ref="${ref# }"
      echo "TYPE=general-purpose"; echo "OPTIONAL=$optional"; echo "---PROMPT---"
      echo "Use the Skill tool to invoke \`${ref}\` (a skill or slash command provided by another plugin or the user's setup), and follow its instructions, applied to the harness work described below. If that skill or command is not available in this session, say exactly 'EXTENSION UNAVAILABLE: ${ref}' and stop without doing anything else." ;;
    cmd:*) echo "TYPE=gate"; echo "OPTIONAL=$optional" ;;
    *) die "step '$name': unknown use '$use' (expected agent:, skill:, command: or cmd:)" ;;
  esac
}

cmd_run_step() { # run a cmd: step in the gate (trusted config only)
  local name="${1:?step name required}" entry use n log rc=0
  entry="$(step_entry "$name")"; use="$(jq -r '.use // ""' <<<"$entry")"
  [[ "$use" == cmd:* ]] || die "step '$name' is not a cmd: step"
  is_trusted || die "config is not trusted; review it with /wreck-it-ralph:trust"
  n="$(st_get session)"; log="$HARNESS_DIR/sessions/$(printf '%03d' "${n:-0}")-$name.log"
  bash -c "${use#cmd:}" > "$log" 2>&1 < /dev/null || rc=$?
  if [[ $rc -eq 0 ]]; then cmd_note "$name" ok "cmd passed" >/dev/null; echo "OK"
  else cmd_note "$name" failed "cmd exited $rc: $(tail -n 3 "$log" | tr '\n' ' ' | cut -c1-200)" >/dev/null; echo "FAILED exit $rc (log: $log)"; fi
  fire step_finished "step=$name" "result=$([[ $rc -eq 0 ]] && echo ok || echo failed)" "session=${n:-0}"
  return $rc
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
  if [[ "$(fanout_workers | jq length)" -gt 0 ]]; then cmd_fanout merge >/dev/null; fi   # a runner that skipped it
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
  if has_tester; then # no evidence, no PASS: a verified feature with examples needs complete replay results from this tester run
    local eid
    for eid in $(newly_passing); do
      [[ "$(jq -r --arg id "$eid" '.features[] | select(.id == $id) | ((.examples // []) | length) > 0' "$HARNESS_DIR/feature_list.json")" == true ]] || continue
      if ! "$PLUGIN_ROOT/scripts/harness-report.sh" check "$eid" --since "$(st_get tester_started_at)" >/dev/null 2>"$HARNESS_DIR/sessions/.evidence.err"; then
        "$FL" fail "$eid" "marked passing without complete replay evidence ($(tr '\n' ' ' < "$HARNESS_DIR/sessions/.evidence.err" | cut -c1-200)); run .harness/replay.sh $eid and report with .harness/report.sh" >/dev/null
        echo "harness: WARNING $eid passed without replay evidence; reset to failing" >&2
        unauth="$unauth $eid"
      fi
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
  local since fid2; since="$(st_get session_started_at)"
  for fid2 in $(newly_passing); do
    fire feature_passed "feature=$fid2" "session=$n" >&2
    # branches kept from merge conflicts are no longer needed once the feature passes
    git for-each-ref --format='%(refname:short)' "refs/heads/harness/wt-*-$fid2" | while IFS= read -r b; do git branch -q -D "$b" >/dev/null 2>&1 || true; done
  done
  for fid2 in $(jq -r --arg since "${since:-0}" '.features[] | select((.status // "") != "passing" and any((.attempts // [])[]; .event == "fail" and (.at // "") >= $since)) | .id' "$HARNESS_DIR/feature_list.json"); do
    fire feature_failed "feature=$fid2" "session=$n" "note=$(jq -r --arg id "$fid2" '.features[] | select(.id == $id) | .notes // "" | .[0:300]' "$HARNESS_DIR/feature_list.json")" >&2
  done
  for fid2 in $(jq -r --arg since "${since:-0}" '.features[] | select(.status == "needs_human" and ((.attempts // [])[-1] | (.at // "") >= $since)) | .id' "$HARNESS_DIR/feature_list.json"); do
    fire needs_human "feature=$fid2" "session=$n" "question=$(jq -r --arg id "$fid2" '.features[] | select(.id == $id) | .question // "" | .[0:300]' "$HARNESS_DIR/feature_list.json")" >&2
  done
  check_spec_lock
  rotate_progress
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
  fire session_ended "session=$n" "stats=$("$FL" stats)" "stuck=$stuck/$limit" >&2
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

rollout_finish() { # rollout run_branch base -> markdown lines (L2: optional push + PR)
  local rollout="$1" rb="$2" base="$3" n stat
  n="$(git rev-list --count "$base..$rb" 2>/dev/null || echo '?')"
  stat="$(git diff --shortstat "$base...$rb" 2>/dev/null | sed 's/^ *//')"
  if [[ "$rollout" == L1 ]]; then
    echo "- Shadow run on branch \`$rb\`: $n commits (${stat:-no changes}). Your branch \`$base\` was not touched; the loop switches back to it now."
    echo "- Inspect: \`git log $base..$rb\` and \`git diff $base...$rb\`. Delete it with \`git branch -D $rb\`."
    echo "- When shadow runs keep being right, move to \`\"rollout\": \"L2\"\` (branch + PR) or L3."
    return 0
  fi
  echo "- Work is on branch \`$rb\`: $n commits (${stat:-no changes}). Base: \`$base\` (not touched)."
  if [[ "$(cfg '.rollout_push // false')" == true || "$(cfg '.rollout_pr // false')" == true ]]; then
    if git push -q -u origin "$rb" >/dev/null 2>&1; then echo "- Pushed \`$rb\` to origin."
    else echo "- WARNING: could not push \`$rb\` to origin."; fi
  fi
  if [[ "$(cfg '.rollout_pr // false')" == true ]]; then
    if command -v gh >/dev/null 2>&1; then
      local url
      if url="$(gh pr create --base "$base" --head "$rb" --title "harness: $("$FL" stats)" --body "Opened by the wreck-it-ralph harness (rollout L2). See .harness/last-run.md and .harness/progress.md on the branch." 2>&1)"; then
        echo "- Pull request: $url"; fire pr_opened "branch=$rb" "base=$base" "url=$url" >&2
      else echo "- WARNING: gh pr create failed: $(echo "$url" | tail -n 1)"; fi
    else echo "- rollout_pr is set but the GitHub CLI (gh) is not installed."; fi
  fi
  echo "- Review: \`git diff $base...$rb\`. Merge: \`git checkout $base && git merge $rb\`."
}

# ---------- parallel fan-out (headless) ----------
WT_DIR="$HARNESS_DIR/worktrees"
fanout_workers() { jq -c '.fanout // []' "$STATE" 2>/dev/null || echo '[]'; }

cmd_fanout() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    plan)
      local max n target ids id path branch list='[]'
      max="$(jq -r '(.parallel // {}).max_workers // 1' "$CFG")"; n="$(st_get session)"; target="$(st_get target)"
      [[ "$max" =~ ^[0-9]+$ && "$max" -gt 1 && -n "$target" ]] || { emit WORKERS 1; return 0; }
      ids="$("$FL" batch "$max")"
      if [[ "$(wc -l <<<"$ids" | tr -d ' ')" -lt 2 ]]; then emit WORKERS 1; return 0; fi
      # progress.md: concatenate both sides instead of conflicting
      local attrs; attrs="$(git rev-parse --git-path info/attributes)"; mkdir -p "$(dirname "$attrs")"
      grep -qxF ".harness/progress.md merge=union" "$attrs" 2>/dev/null || echo ".harness/progress.md merge=union" >> "$attrs"
      mkdir -p "$WT_DIR"
      for id in $ids; do
        path="$WT_DIR/$id"; branch="harness/wt-$n-$id"
        git worktree add -q -b "$branch" "$path" HEAD >/dev/null 2>&1 || { echo "harness: could not create worktree for $id; it stays for a later session" >&2; continue; }
        (cd "$path" && HARNESS_DIR=.harness "$PLUGIN_ROOT/scripts/harness-setup.sh" --refresh >/dev/null 2>&1) || true
        list="$(jq -c --arg id "$id" --arg p "$path" --arg b "$branch" '. + [{id: $id, path: $p, branch: $b}]' <<<"$list")"
        emit WORKER "$id $path"
      done
      st_set fanout "$list"
      emit WORKERS "$(jq length <<<"$list")"
      fire fanout_started "session=$n" "features=$(jq -r 'map(.id) | join(" ")' <<<"$list")" >&2
      ;;
    task)
      local id="${1:?feature id required}" n k total ctx
      n="$(st_get session)"; total="$(fanout_workers | jq length)"
      k="$(fanout_workers | jq -r --arg id "$id" 'map(.id) | index($id) // empty')"; [[ -n "$k" ]] || die "$id is not a worker this session"
      ctx="$(feature_context "$id")"
      echo "Harness session $n, parallel worker $((k + 1)) of $total. Progress: $("$FL" stats). Target feature: $id. Features awaiting verification: none.${ctx:+ $ctx}
You are one of $total coders building different features at the same time, each in its own git worktree (this directory). Your branch is merged into the main tree after all workers finish, so: stay strictly inside what $id needs, do not refactor or reformat shared code, do not rename shared files, and keep your progress.md entry to your feature. Claim with .harness/feature-list.sh claim $id as usual; the harness applies it after the merge."
      ;;
    merge)
      local w id path branch status question base merged="" conflicts="" n
      n="$(st_get session)"; base="$(st_get head_before)"
      for w in $(fanout_workers | jq -c '.[]'); do
        id="$(jq -r .id <<<"$w")"; path="$(jq -r .path <<<"$w")"; branch="$(jq -r .branch <<<"$w")"
        [[ -d "$path" ]] || continue
        ( cd "$path" && git add -A && { git diff --cached --quiet || git commit -qm "harness: worker $id leftovers"; } ) >/dev/null 2>&1 || true
        status="$(cd "$path" && HARNESS_DIR=.harness "$FL" show "$id" 2>/dev/null | jq -r '.status // ""')"
        question="$(cd "$path" && HARNESS_DIR=.harness "$FL" show "$id" 2>/dev/null | jq -r '.question // ""')"
        # proposals the worker filed: re-file them in the main tree
        if [[ -f "$path/.harness/proposals.json" ]]; then
          local p known; known="$(jq -c '[.proposals[]?.id]' "$PROPS" 2>/dev/null || echo '[]')"
          while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            jq -c .payload <<<"$p" | "$PLUGIN_ROOT/scripts/backlog.sh" propose --by "$(jq -r .by <<<"$p")" --reason "$(jq -r .reason <<<"$p") (from parallel worker $id)" >/dev/null 2>&1 \
              || echo "harness: WARNING could not re-file proposal $(jq -r .id <<<"$p") from worker $id" >&2
          done < <(jq -c --argjson k "$known" --slurpfile base <(git show "$base:.harness/proposals.json" 2>/dev/null || echo '{"proposals":[]}') \
                      '($base[0].proposals | map(.id)) as $b | .proposals[] | select(.status == "pending" and (.id as $i | $b | index($i) | not))' "$path/.harness/proposals.json")
        fi
        # spec and status files never merge: the gate applies the worker's outcome itself
        ( cd "$path" && git checkout -q "$base" -- .harness/feature_list.json .harness/.feature_list.lock.json .harness/proposals.json 2>/dev/null
          git add -A .harness && { git diff --cached --quiet || git commit -qm "harness: worker $id: status files are applied by the merge gate"; } ) >/dev/null 2>&1 || true
        if git merge -q --no-ff --no-edit -m "harness: merge parallel work on $id (session $n)" "$branch" >/dev/null 2>&1; then
          merged="$merged $id"
          case "$status" in
            claimed) "$FL" claim "$id" >/dev/null ;;
            needs_human) "$FL" ask "$id" "${question:-the parallel worker asked for help}" >/dev/null ;;
          esac
        else
          git merge --abort >/dev/null 2>&1 || git reset -q --merge >/dev/null 2>&1 || true
          "$FL" requeue "$id" "merge conflict with other parallel work in session $n; the next attempt starts from the merged code and runs without parallel neighbours" >/dev/null
          conflicts="$conflicts $id"
          echo "harness: $id conflicted with parallel work; its branch $branch is kept for reference" >&2
        fi
        git worktree remove --force "$path" >/dev/null 2>&1 || true
        [[ " $conflicts " == *" $id "* ]] || git branch -q -D "$branch" >/dev/null 2>&1 || true
      done
      git worktree prune >/dev/null 2>&1 || true
      st_set fanout '[]'
      emit MERGED "${merged# }"; [[ -n "$conflicts" ]] && emit CONFLICTS "${conflicts# }"
      fire fanout_merged "session=$n" "merged=${merged# }" "conflicts=${conflicts# }" >&2
      return 0
      ;;
    cleanup) # leftovers of an interrupted fan-out: keep the work on its branch, remove the worktree
      local d
      for d in "$WT_DIR"/*/; do
        [[ -d "$d" ]] || continue
        ( cd "$d" && git add -A && { git diff --cached --quiet || git commit -qm "harness: interrupted worker leftovers"; } ) >/dev/null 2>&1 || true
        git worktree remove --force "$d" >/dev/null 2>&1 && echo "harness: removed leftover worktree $d (its branch is kept)" >&2
      done
      git worktree prune >/dev/null 2>&1 || true
      ;;
    *) die "usage: fanout plan|task <ID>|merge|cleanup" ;;
  esac
}

cmd_unlock() { rm -f "$LOCK"; echo "lock removed"; }

cmd_summary() {
  local reason="${1:-finished}" code="${2:-0}" out="$HARNESS_DIR/last-run.md" start_head
  # Codes 4-7 mean `begin --new-run` refused to start: the lock and state may belong to another,
  # still running loop, so leave them (and last-run.md) alone.
  case "$code" in 4|5|6|7) echo "Run not started: $reason"; fire run_refused "reason=$reason" "code=$code" >&2; return 0 ;; esac
  start_head="$(st_get start_head)"
  local rollout rb base rollout_text=""
  rollout="$(st_get rollout)"; rb="$(st_get run_branch)"; base="$(st_get base_branch)"
  if [[ -n "$rb" ]]; then rollout_text="$(rollout_finish "$rollout" "$rb" "$base")"; fi
  {
    echo "# Harness run summary"
    echo
    echo "- **Stop reason:** $reason (exit code $code)"
    echo "- **Features:** $("$FL" stats)"
    echo "- **Sessions this run:** $(st_get ran)"
    local t; read -r -a t <<<"$(ledger_totals)"
    echo "- **Spend this run:** \$${t[0]} | ${t[1]} tokens | $(run_minutes) min | ${t[2]} agent runs recorded"
    if [[ -n "$rollout_text" ]]; then echo; echo "## Rollout $rollout"; echo; echo "$rollout_text"; fi
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
  fire run_ended "reason=$reason" "code=$code" "stats=$("$FL" stats)" "rollout=${rollout:-L3}" "branch=$rb" >&2
  if [[ -f "$HARNESS_DIR/stop.sh" ]]; then   # dev servers etc. that init.sh started
    if is_trusted; then bash "$HARNESS_DIR/stop.sh" >> "$HARNESS_DIR/sessions/stop.log" 2>&1 < /dev/null || echo "harness: WARNING .harness/stop.sh failed (see sessions/stop.log)" >&2
    else echo "harness: .harness/stop.sh skipped (not trusted)" >&2; fi
  fi
  if [[ "$rollout" == L1 && -n "$base" && "$(git branch --show-current 2>/dev/null)" == "$rb" ]]; then
    if [[ -z "$(git status --porcelain)" ]]; then git checkout -q "$base" 2>/dev/null || echo "harness: WARNING could not switch back to $base" >&2
    else echo "harness: WARNING working tree not clean; staying on $rb (switch back with: git checkout $base)" >&2; fi
  fi
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
  run-step)    cmd_run_step "$@" ;;
  fanout)      cmd_fanout "$@" ;;
  summary)     cmd_summary "$@" ;;
  trust)       cmd_trust "$@" ;;
  note)        cmd_note "$@" ;;
  ledger)      cmd_ledger "$@" ;;
  budget)      cmd_budget ;;
  unlock)      cmd_unlock ;;
  *) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
