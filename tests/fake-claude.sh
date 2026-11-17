#!/bin/bash
# Fake `claude -p` used by tests. Behaviour depends on the agent role in --append-system-prompt.
SYS=""; while [[ $# -gt 0 ]]; do case "$1" in --append-system-prompt) SYS="$2"; shift 2;; *) shift;; esac; done
TASK="$(cat)"
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
