#!/bin/bash

# Ralph Loop Stop Hook
# Prevents session exit while a Ralph loop is active and feeds the SAME prompt back.
#
# The loop ends when:
#   - the completion promise appears in the last assistant text (if one is set) AND
#     the --verify command exits 0 (if one is set): the agent alone cannot declare victory;
#   - <promise>BLOCKED: reason</promise> appears and the loop was started with --allow-blocked;
#   - --max-iterations or --max-minutes is reached;
#   - /wreck-it-ralph:cancel-ralph removes the state file.
# Every ending is recorded in .claude/ralph-loop.last.md (outcome, iterations, prompt).

set -euo pipefail

HOOK_INPUT=$(cat)

RALPH_STATE_FILE=".claude/ralph-loop.local.md"
RALPH_LAST_FILE=".claude/ralph-loop.last.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  exit 0 # no active loop
fi

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
field() { echo "$FRONTMATTER" | grep "^$1:" | head -n1 | sed "s/^$1: *//" || true; }
# Values are written as JSON strings ("...", with escapes) by setup; older files used plain "...".
str_field() {
  local raw; raw="$(field "$1")"
  if [[ -z "$raw" || "$raw" == "null" ]]; then echo ""; return; fi
  printf '%s' "$raw" | jq -r '.' 2>/dev/null || printf '%s' "$raw" | sed 's/^"\(.*\)"$/\1/'
}

ITERATION=$(field iteration)
MAX_ITERATIONS=$(field max_iterations)
MAX_MINUTES=$(field max_minutes); MAX_MINUTES=${MAX_MINUTES:-0}
STARTED_EPOCH=$(field started_epoch); STARTED_EPOCH=${STARTED_EPOCH:-0}
ALLOW_BLOCKED=$(field allow_blocked)
COMPLETION_PROMISE=$(str_field completion_promise)
VERIFY_CMD=$(str_field verify)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

# Session isolation: the state file is project-scoped, but the Stop hook fires in every session.
STATE_SESSION=$(field session_id)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

end_loop() { # outcome, message, [detail]
  {
    echo "---"
    echo "outcome: $1"
    echo "iterations: ${ITERATION:-?}"
    echo "ended_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    echo "detail: $(jq -Rn --arg d "${3:-}" '$d')"
    echo "---"
    echo
    echo "$PROMPT_TEXT"
  } > "$RALPH_LAST_FILE" 2>/dev/null || true
  rm -f "$RALPH_STATE_FILE"
  echo "$2"
  exit 0
}

corrupt() { # problem
  echo "⚠️  Ralph loop: $1" >&2
  echo "   File: $RALPH_STATE_FILE. Ralph loop is stopping; run /wreck-it-ralph:ralph again to start fresh." >&2
  end_loop error "Ralph loop stopped: $1" "$1" >/dev/null
}

[[ "$ITERATION" =~ ^[0-9]+$ ]] || corrupt "'iteration' is not a number (got: '$ITERATION')"
[[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || corrupt "'max_iterations' is not a number (got: '$MAX_ITERATIONS')"
[[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] || corrupt "'max_minutes' is not a number (got: '$MAX_MINUTES')"
[[ "$STARTED_EPOCH" =~ ^[0-9]+$ ]] || STARTED_EPOCH=0
[[ -n "$PROMPT_TEXT" ]] || corrupt "no prompt text found"

if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  end_loop max_iterations "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
fi
if [[ $MAX_MINUTES -gt 0 && $STARTED_EPOCH -gt 0 ]] && (( $(date +%s) - STARTED_EPOCH >= MAX_MINUTES * 60 )); then
  end_loop max_minutes "🛑 Ralph loop: time budget ($MAX_MINUTES min) reached after $ITERATION iterations."
fi

TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')
[[ -f "$TRANSCRIPT_PATH" ]] || corrupt "transcript file not found ($TRANSCRIPT_PATH)"
grep -q '"role":"assistant"' "$TRANSCRIPT_PATH" || corrupt "no assistant messages found in the transcript"

# Each content block is its own JSONL line; take the last text block of the last 100 assistant lines.
LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100)
set +e
LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs 'map(.message.content[]? | select(.type == "text") | .text) | last // ""' 2>&1)
JQ_EXIT=$?
set -e
[[ $JQ_EXIT -eq 0 ]] || corrupt "failed to parse assistant message JSON: $LAST_OUTPUT"

# First <promise>...</promise>, multi-line, whitespace normalized.
PROMISE_TEXT=$(printf '%s' "$LAST_OUTPUT" | jq -Rrs '(capture("<promise>(?<p>[\\s\\S]*?)</promise>") | .p) // "" | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " ")' 2>/dev/null || echo "")

if [[ "$ALLOW_BLOCKED" == "true" && "$PROMISE_TEXT" == BLOCKED:* ]]; then
  end_loop blocked "⛔ Ralph loop: agent reported it is blocked: ${PROMISE_TEXT#BLOCKED:}" "${PROMISE_TEXT#BLOCKED: }"
fi

FEEDBACK=""
PROMISE_OK=1
if [[ -n "$COMPLETION_PROMISE" ]]; then
  [[ -n "$PROMISE_TEXT" && "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]] || PROMISE_OK=0
fi

if [[ $PROMISE_OK -eq 1 && -n "$VERIFY_CMD" ]]; then
  # The verifier, not the agent, decides. Its output tail goes back to the agent when it fails.
  set +e
  VERIFY_OUT=$(bash -c "$VERIFY_CMD" 2>&1 < /dev/null)
  VERIFY_RC=$?
  set -e
  if [[ $VERIFY_RC -eq 0 ]]; then
    end_loop done "✅ Ralph loop: verify command passed ($VERIFY_CMD)$([[ -n "$COMPLETION_PROMISE" ]] && echo " and <promise>$COMPLETION_PROMISE</promise> was given")."
  fi
  FEEDBACK="The loop's verify command failed, so the task is NOT done yet.
\$ $VERIFY_CMD   (exit $VERIFY_RC)
$(printf '%s\n' "$VERIFY_OUT" | tail -n 30)"
elif [[ $PROMISE_OK -eq 1 && -n "$COMPLETION_PROMISE" ]]; then
  end_loop done "✅ Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
fi

# Not complete: continue with the SAME prompt (plus verifier feedback, if any).
NEXT_ITERATION=$((ITERATION + 1))
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION"
if [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="$SYSTEM_MSG | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when it is TRUE - do not lie to exit!)"
fi
[[ -n "$VERIFY_CMD" ]] && SYSTEM_MSG="$SYSTEM_MSG | Ends only when \`$VERIFY_CMD\` passes"
[[ -z "$COMPLETION_PROMISE" && -z "$VERIFY_CMD" ]] && SYSTEM_MSG="$SYSTEM_MSG | No completion promise or verify command set - runs until max iterations or /wreck-it-ralph:cancel-ralph"

REASON="$PROMPT_TEXT"
[[ -n "$FEEDBACK" ]] && REASON="$PROMPT_TEXT

---
$FEEDBACK"

jq -n --arg prompt "$REASON" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
exit 0
