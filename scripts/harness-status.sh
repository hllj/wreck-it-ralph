#!/bin/bash
# harness-status.sh - show harness progress.
set -euo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
FL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-list.sh"
[[ -f "$HARNESS_DIR/feature_list.json" ]] || { echo "No harness here. Run /wreck-it-ralph:init first."; exit 0; }
echo "Features:  $("$FL" stats)"
NEXT="$("$FL" next || true)"
echo "Next:      ${NEXT:-<none ready>}"
[[ -f "$HARNESS_DIR/STOP" ]] && echo "STOP flag is set (the loop exits before its next session)"
[[ -f "$HARNESS_DIR/runner.pid" ]] && kill -0 "$(cat "$HARNESS_DIR/runner.pid")" 2>/dev/null && echo "Runner:    running (pid $(cat "$HARNESS_DIR/runner.pid"))" || echo "Runner:    not running"
Q="$("$FL" questions)"
if [[ -n "$Q" ]]; then echo; echo "Waiting for a human (answer with /wreck-it-ralph:backlog answer <ID> \"...\"):"; printf '%s\n' "$Q" | sed 's/\t/: /; s/^/  /'; fi
if [[ -f "$HARNESS_DIR/proposals.json" ]]; then
  P="$(jq -r '.proposals[]? | select(.status == "pending") | "  \(.id) (\(.by)): \(.reason)"' "$HARNESS_DIR/proposals.json" 2>/dev/null || true)"
  if [[ -n "$P" ]]; then echo; echo "Backlog proposals awaiting approval (/wreck-it-ralph:backlog):"; echo "$P"; fi
fi
echo; echo "Recent commits:"; git log --oneline -5 2>/dev/null || true
echo; echo "Last progress entry:"; tail -n 15 "$HARNESS_DIR/progress.md" 2>/dev/null || true
