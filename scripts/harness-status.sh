#!/bin/bash
# harness-status.sh - show harness progress.
set -euo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
FL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-list.sh"
STEP="$(dirname "$FL")/harness-step.sh"

# --json: a stable, versioned contract for other plugins, status lines and dashboards.
if [[ "${1:-}" == "--json" ]]; then
  [[ -f "$HARNESS_DIR/feature_list.json" ]] || { echo '{"schema":1,"initialized":false}'; exit 0; }
  counts="{}"; for st in passing claimed failing todo needs_human dropped; do
    counts="$(jq -c --arg k "$st" --argjson v "$("$FL" count "$st")" '.[$k] = $v' <<<"$counts")"; done
  next="$("$FL" next || true)"
  questions="$("$FL" questions | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {id: .[0], question: (.[1] // "")})')"
  proposals="[]"; [[ -f "$HARNESS_DIR/proposals.json" ]] && proposals="$(jq -c '[.proposals[]? | select(.status == "pending") | {id, by, reason}]' "$HARNESS_DIR/proposals.json" 2>/dev/null || echo '[]')"
  pid=""; [[ -f "$HARNESS_DIR/runner.pid" ]] && kill -0 "$(cat "$HARNESS_DIR/runner.pid")" 2>/dev/null && pid="$(cat "$HARNESS_DIR/runner.pid")"
  state="{}"; [[ -f "$HARNESS_DIR/.step_state.json" ]] && state="$(jq -c . "$HARNESS_DIR/.step_state.json" 2>/dev/null || echo '{}')"
  spend=""; [[ -f "$HARNESS_DIR/.step_state.json" ]] && spend="$("$STEP" ledger total 2>/dev/null || true)"
  last="null"; [[ -s "$HARNESS_DIR/events.jsonl" ]] && last="$(tail -n 1 "$HARNESS_DIR/events.jsonl" | jq -c . 2>/dev/null || echo null)"
  jq -n --argjson c "$counts" --arg next "$next" --argjson q "$questions" --argjson p "$proposals" --arg pid "$pid" \
        --argjson st "$state" --arg spend "$spend" --argjson last "$last" --argjson stop "$([[ -f "$HARNESS_DIR/STOP" ]] && echo true || echo false)" '
    def kv($k): ($spend | split("\n") | map(select(startswith($k + "="))) | .[0] // "" | sub("^[A-Z]+="; ""));
    { schema: 1, initialized: true,
      features: ($c + {total: ($c | to_entries | map(select(.key != "dropped") | .value) | add)}),
      next: (if $next == "" then null else ($next | split("\t") | {id: .[0], description: .[1]}) end),
      questions: $q, proposals_pending: $p,
      runner: {running: ($pid != ""), pid: (if $pid == "" then null else ($pid | tonumber) end)},
      stop_flag: $stop,
      session: {in_progress: ($st.in_session // false), number: ($st.session // null), target: ($st.target // null)},
      spend: (if $spend == "" then null else {cost_usd: (kv("COST") | tonumber? // 0), tokens: (kv("TOKENS") | tonumber? // 0), cache_read_tokens: (kv("CACHE_READ") | tonumber? // 0), minutes: (kv("MINUTES") | tonumber? // 0)} end),
      last_event: $last }'
  exit 0
fi

[[ -f "$HARNESS_DIR/feature_list.json" ]] || { echo "No harness here. Run /wreck-it-ralph:init first."; exit 0; }
echo "Features:  $("$FL" stats)"
NEXT="$("$FL" next || true)"
echo "Next:      ${NEXT:-<none ready>}"
[[ -f "$HARNESS_DIR/STOP" ]] && echo "STOP flag is set (the loop exits before its next session)"
[[ -f "$HARNESS_DIR/runner.pid" ]] && kill -0 "$(cat "$HARNESS_DIR/runner.pid")" 2>/dev/null && echo "Runner:    running (pid $(cat "$HARNESS_DIR/runner.pid"))" || echo "Runner:    not running"
if [[ -f "$HARNESS_DIR/.step_state.json" ]]; then
  SPEND="$("$(dirname "$FL")/harness-step.sh" ledger total 2>/dev/null || true)"
  kvs() { sed -n "s/^$1=//p" <<<"$SPEND"; }
  if [[ -n "$SPEND" ]]; then echo "Usage:     $(kvs TOKENS) tokens (+ $(kvs CACHE_READ) cache reads) | $(kvs MINUTES) min this run$(jq -rn --arg c "$(kvs COST)" 'if (($c | tonumber? // 0) > 0) then " | cost $" + $c else "" end')"; fi
fi
if [[ -f "$HARNESS_DIR/calibration/cases.json" || -s "$HARNESS_DIR/calibration/outcomes.jsonl" ]]; then
  CAL="$("$(dirname "$FL")/harness-calibrate.sh" report --json 2>/dev/null || true)"
  [[ -n "$CAL" ]] && echo "Evaluator: $(jq -r 'def p: if . == null then "n/a" else "\(. * 1000 | round / 10)%" end; "false positives \(.false_positives) (rate \(.false_positive_rate | p)), false negatives \(.false_negatives), examples verified \(.coverage.examples_verified)/\(.coverage.examples)"' <<<"$CAL")"
fi
Q="$("$FL" questions)"
if [[ -n "$Q" ]]; then echo; echo "Waiting for a human (answer with /wreck-it-ralph:backlog answer <ID> \"...\"):"; printf '%s\n' "$Q" | sed 's/\t/: /; s/^/  /'; fi
if [[ -f "$HARNESS_DIR/proposals.json" ]]; then
  P="$(jq -r '.proposals[]? | select(.status == "pending") | "  \(.id) (\(.by)): \(.reason)"' "$HARNESS_DIR/proposals.json" 2>/dev/null || true)"
  if [[ -n "$P" ]]; then echo; echo "Backlog proposals awaiting approval (/wreck-it-ralph:backlog):"; echo "$P"; fi
fi
echo; echo "Recent commits:"; git log --oneline -5 2>/dev/null || true
echo; echo "Last progress entry:"; tail -n 15 "$HARNESS_DIR/progress.md" 2>/dev/null || true
