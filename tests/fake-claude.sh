#!/bin/bash
# Fake `claude -p` used by tests. Behaviour depends on the agent role in --append-system-prompt.
if [[ "${1:-}" == "--help" ]]; then echo "  --output-format <format>"; [[ -n "${FAKE_BUDGET_FLAG:-}" ]] && echo "  --max-budget-usd <amount>"; exit 0; fi
[[ -n "${FAKE_ARGS_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_ARGS_LOG"
SYS=""; FMT=text; while [[ $# -gt 0 ]]; do case "$1" in --append-system-prompt) SYS="$2"; shift 2;; --output-format) FMT="$2"; shift 2;; *) shift;; esac; done
TASK="$(cat)"
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
  [[ -n "$TARGET" ]] && { echo "impl $TARGET" > "src_$TARGET.txt"; git add -A; git commit -qm "feat: $TARGET"; $FL claim "$TARGET" >/dev/null; }
  [[ "${FAKE_MODE:-}" == "selfpass" && -n "$TARGET" ]] && $FL pass "$TARGET" >/dev/null
  [[ "${FAKE_MODE:-}" == "dirty" ]] && echo junk > leftover.txt
elif [[ "$SYS" == *"TESTER agent"* ]]; then
  for id in $($FL claimed); do $FL pass "$id" >/dev/null; done
fi
echo "fake claude ok"
echo "warning: noisy stderr" >&2
