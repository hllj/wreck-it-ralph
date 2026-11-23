#!/bin/bash
# Fake `claude -p` used by tests. Behaviour depends on the agent role in --append-system-prompt.
if [[ "${1:-}" == "--help" ]]; then echo "  --output-format <format>"; [[ -n "${FAKE_BUDGET_FLAG:-}" ]] && echo "  --max-budget-usd <amount>"; exit 0; fi
[[ -n "${FAKE_ARGS_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_ARGS_LOG"
SYS=""; FMT=text; while [[ $# -gt 0 ]]; do case "$1" in --append-system-prompt) SYS="$2"; shift 2;; --output-format) FMT="$2"; shift 2;; *) shift;; esac; done
TASK="$(cat)"
[[ -n "${FAKE_TASK_LOG:-}" ]] && printf '%s\n' "$TASK" >> "$FAKE_TASK_LOG"
[[ -n "${FAKE_SLEEP:-}" ]] && sleep "$FAKE_SLEEP"
if [[ "$FMT" == json ]]; then exec 3>&1 1>"${TMPDIR:-/tmp}/fake-claude-out.$$"; fi
finish() {
  if [[ "$FMT" == json ]]; then
    exec 1>&3
    jq -n --arg r "$(cat "${TMPDIR:-/tmp}/fake-claude-out.$$")" --argjson c "${FAKE_COST:-0.25}" \
      '{type:"result", subtype:"success", is_error:false, duration_ms:1200, num_turns:3, result:$r, total_cost_usd:$c,
        usage:{input_tokens:1000, output_tokens:200, cache_creation_input_tokens:0, cache_read_input_tokens:50}}'
    rm -f "${TMPDIR:-/tmp}/fake-claude-out.$$"
  fi
}
trap finish EXIT
FL=.harness/feature-list.sh
TARGET="$(echo "$TASK" | sed -n 's/.*Target feature: \(F[0-9]*\).*/\1/p')"
if [[ "$SYS" == *"CODER agent"* ]]; then
  [[ "${FAKE_MODE:-}" == "idle" ]] && { echo "did nothing"; exit 0; }
  [[ "${FAKE_MODE:-}" == "stop" ]] && touch .harness/STOP
  if [[ "${FAKE_MODE:-}" == "tamper" ]]; then jq '.features[0].description = "TAMPERED"' .harness/feature_list.json > .harness/x && mv .harness/x .harness/feature_list.json; fi
  [[ "${FAKE_MODE:-}" == "conflict" && -n "$TARGET" ]] && echo "shared by $TARGET" > shared.txt
  if [[ "${FAKE_MODE:-}" == "workerask" && "$TARGET" == "F002" ]]; then $FL ask F002 "need an API key" >/dev/null; echo "asked"; exit 0; fi
  if [[ "${FAKE_MODE:-}" == "workerpropose" && "$TARGET" == "F003" ]]; then
    echo '{"add":[{"description":"follow-up from F003","steps":["x"]}]}' | .harness/backlog.sh propose --by coder --reason "split F003" >/dev/null
  fi
  [[ -n "$TARGET" && -n "$($FL examples "$TARGET" 2>/dev/null)" ]] && $FL red "$TARGET" --skip "fake coder" >/dev/null
  [[ -n "$TARGET" ]] && { echo "impl $TARGET" > "src_$TARGET.txt"; git add -A; git commit -qm "feat: $TARGET"; $FL claim "$TARGET" >/dev/null; }
  [[ "${FAKE_MODE:-}" == "selfpass" && -n "$TARGET" ]] && $FL pass "$TARGET" >/dev/null
  [[ "${FAKE_MODE:-}" == "dirty" ]] && echo junk > leftover.txt
elif [[ "$SYS" == *"TESTER agent"* ]]; then
  [[ "${FAKE_MODE:-}" == "testeredit" && -n "$TARGET" ]] && { echo hacked >> "src_$TARGET.txt"; git add -A; git commit -qm "tester fix" >/dev/null 2>&1; }
  [[ "${FAKE_MODE:-}" == "testerstray" ]] && echo probe > probe-leftover.txt
  [[ "${FAKE_MODE:-}" == "testerharness" ]] && { echo "- tester note" >> .harness/progress.md; git add -A; git commit -qm "harness: tester progress entry" >/dev/null 2>&1; }
  for id in $($FL claimed); do $FL pass "$id" >/dev/null; done
elif [[ "$SYS" == *"Use the Skill tool"* || "$TASK" == *"Use the Agent tool with subagent_type"* ]]; then
  if [[ -n "${FAKE_UNAVAILABLE:-}" ]]; then echo "EXTENSION UNAVAILABLE: x"; exit 0; fi
  echo "fake extension ran"
  [[ -n "${FAKE_EXT_FAIL:-}" ]] && for id in $(jq -r '.features[] | select(.status == "passing") | .id' .harness/feature_list.json | head -n1); do $FL fail "$id" "reviewer found a bug" >/dev/null; done
fi
echo "fake claude ok"
echo "warning: noisy stderr" >&2
