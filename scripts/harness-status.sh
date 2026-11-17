#!/bin/bash
# harness-status.sh - show harness progress.
set -euo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
FL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-list.sh"
[[ -d "$HARNESS_DIR" ]] || { echo "No harness here. Run /wreck-it-ralph-loop:harness-init first."; exit 0; }
echo "Features:  $("$FL" stats)"
NEXT="$("$FL" next || true)"
echo "Next:      ${NEXT:-<none>}"
[[ -f "$HARNESS_DIR/STOP" ]] && echo "STOP flag is set (runner will exit after the current session)"
[[ -f "$HARNESS_DIR/runner.pid" ]] && kill -0 "$(cat "$HARNESS_DIR/runner.pid")" 2>/dev/null && echo "Runner:    running (pid $(cat "$HARNESS_DIR/runner.pid"))" || echo "Runner:    not running"
echo; echo "Recent commits:"; git log --oneline -5 2>/dev/null || true
echo; echo "Last progress entry:"; tail -n 15 "$HARNESS_DIR/progress.md" 2>/dev/null || true
