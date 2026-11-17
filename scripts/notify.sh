#!/bin/bash
# notify.sh - desktop notification for harness events; meant to be used as a hook handler:
#   "hooks": { "needs_human": ["cmd:.harness/notify.sh"], "run_ended": ["cmd:.harness/notify.sh"] }
# Reads HARNESS_EVENT / HARNESS_FEATURE / HARNESS_QUESTION / HARNESS_REASON (set by the gate).
# macOS: osascript; Linux: notify-send; otherwise a terminal bell + stderr line.
# NOTIFY_DRY_RUN=1 prints the notification instead of showing it (tests, debugging).
set -uo pipefail

ev="${HARNESS_EVENT:-event}"
case "$ev" in
  needs_human)   title="Harness needs you"; msg="${HARNESS_FEATURE:-?}: ${HARNESS_QUESTION:-a decision is needed}" ;;
  run_ended)     title="Harness run ended"; msg="${HARNESS_REASON:-finished} (${HARNESS_STATS:-})" ;;
  verify_failed) title="Harness verify failed"; msg="${HARNESS_FEATURE:-?}: ${HARNESS_COMMAND:-}" ;;
  pr_opened)     title="Harness opened a PR"; msg="${HARNESS_URL:-}" ;;
  *)             title="Harness: $ev"; msg="${HARNESS_FEATURE:-}${HARNESS_REASON:-}" ;;
esac
msg="$(printf '%s' "$msg" | tr '\n' ' ' | cut -c1-220)"
project="$(basename "$(pwd)")"
title="$title ($project)"

if [[ -n "${NOTIFY_DRY_RUN:-}" ]]; then printf 'NOTIFY: %s | %s\n' "$title" "$msg"; exit 0; fi
if [[ "$(uname)" == Darwin ]] && command -v osascript >/dev/null 2>&1; then
  # Text goes in as argv, never interpolated into the AppleScript source.
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' -e 'end run' "$msg" "$title" >/dev/null 2>&1 && exit 0
fi
if command -v notify-send >/dev/null 2>&1; then notify-send "$title" "$msg" && exit 0; fi
printf '\a%s: %s\n' "$title" "$msg" >&2
