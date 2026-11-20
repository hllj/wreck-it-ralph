#!/bin/bash
# harness-report.sh - the tester's verdict, backed by replay evidence. "No evidence, no PASS."
#
# Usage: report.sh <ID> pass|fail|blocked|inconclusive "<note>"
#        report.sh check <ID> [--since ISO-TIME]
#
# pass          refused unless EVERY locked example of the feature has a passing replay result produced
#               for the current spec (example hash matches) during this tester run (.step_state tester_started_at).
#               On success: feature-list.sh pass.
# fail          verified and broken: feature-list.sh fail <note>.
# blocked       could not be tested (app/environment): the feature stays claimed, no failed attempt is counted.
# inconclusive  not enough evidence to decide: feature-list.sh ask <note> (a human decides).
# check         exit 0 if the evidence is complete (used by the gate at the end of a session).
#
# Writes .harness/evidence/<ID>/report.json and report.md (git-ignored; copy what you want to keep).

set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"; FL="$HERE/feature-list.sh"
die() { echo "report: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

MODE=report
if [[ "${1:-}" == check ]]; then MODE=check; shift; fi
ID="${1:-}"; [[ -n "$ID" ]] || die "usage: report.sh <ID> pass|fail|blocked|inconclusive \"<note>\"  |  report.sh check <ID> [--since T]"
shift
SINCE=""
if [[ "$MODE" == check ]]; then
  [[ "${1:-}" == "--since" ]] && SINCE="${2:-}"
else
  DECISION="${1:-}"; NOTE="${2:-}"
  case "$DECISION" in pass|fail|blocked|inconclusive) ;; *) die "decision must be pass, fail, blocked or inconclusive" ;; esac
  [[ "$DECISION" == pass || -n "$NOTE" ]] || die "$DECISION needs a note (what you saw / what blocks you / the question)"
  st="$HARNESS_DIR/.step_state.json"
  [[ -f "$st" ]] && SINCE="$(jq -r '.tester_started_at // ""' "$st" 2>/dev/null)"
fi

DIR="$HARNESS_DIR/evidence/$ID"
examples="$("$FL" examples "$ID")" || exit 2

# one line per locked example: status of its replay evidence
results="[]"
while IFS=$'\t' read -r _ j; do
  [[ -z "$j" ]] && continue
  exid="$(jq -r .id <<<"$j")"; name="$(jq -r .name <<<"$j")"
  f="$DIR/$exid/result.json"; s="not_run"
  if [[ -f "$f" ]]; then
    want="$(jq -cS . <<<"$j" | sha)"
    if [[ "$(jq -r '.example_sha // ""' "$f")" != "$want" ]]; then s="altered"
    elif [[ -n "$SINCE" && "$(jq -r '.at // ""' "$f")" < "$SINCE" ]]; then s="stale"
    elif [[ "$(jq -r '.partial // false' "$f")" == true ]]; then s="partial"
    else s="$(jq -r '.status' "$f")"; fi
  fi
  results="$(jq -c --arg e "$exid" --arg n "$name" --arg s "$s" --arg p "$f" '. + [{example: $e, name: $n, status: $s, evidence: $p}]' <<<"$results")"
done <<<"$examples"
summary="$(jq -c '{total: length, passed: (map(select(.status == "pass")) | length),
                   failed: (map(select(.status == "fail" or .status == "error")) | length),
                   not_run: (map(select(.status != "pass" and .status != "fail" and .status != "error")) | length)}' <<<"$results")"
complete=0; jq -e '.passed == .total' <<<"$summary" >/dev/null && complete=1

if [[ "$MODE" == check ]]; then
  [[ $complete -eq 1 ]] && exit 0
  echo "report: $ID evidence incomplete: $(jq -r '[.[] | select(.status != "pass") | "\(.example)=\(.status)"] | join(", ")' <<<"$results")" >&2
  exit 1
fi

total="$(jq -r .total <<<"$summary")"
if [[ "$DECISION" == pass && "$total" -gt 0 && $complete -eq 0 ]]; then
  echo "report: NO EVIDENCE, NO PASS. Replay results for $ID are incomplete: $(jq -r '[.[] | select(.status != "pass") | "\(.example)=\(.status)"] | join(", ")' <<<"$results")" >&2
  echo "        run: .harness/replay.sh $ID   (statuses: not_run/stale = run it now; altered = example changed since the replay; partial = only some steps were replayed, run it without --step; fail/error = the feature is not passing)" >&2
  exit 1
fi

case "$DECISION" in pass) status=passed ;; fail) status=failed ;; *) status="$DECISION" ;; esac
mkdir -p "$DIR"
jq -n --arg id "$ID" --arg s "$status" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$(git rev-parse HEAD 2>/dev/null || echo none)" \
      --arg note "$NOTE" --argjson sum "$summary" --argjson r "$results" \
  '{feature_id: $id, status: $s, tested_at: $at, commit_sha: $sha, examples: $sum, coverage: null, note: $note, results: $r,
    replay: (["./.harness/replay.sh \($id)"] + ($r | map("./.harness/replay.sh \($id) --example \(.example)")))}' > "$DIR/report.json"
{
  echo "# $ID: $(printf %s "$status" | tr a-z A-Z)"
  echo
  echo "- Tested: $(jq -r .tested_at "$DIR/report.json") at commit $(jq -r .commit_sha "$DIR/report.json" | cut -c1-10)"
  echo "- Examples: $(jq -r '"\(.examples.passed)/\(.examples.total) passed, \(.examples.failed) failed, \(.examples.not_run) not run"' "$DIR/report.json")"
  [[ -n "$NOTE" ]] && echo "- Note: $NOTE"
  echo
  echo "## Replay evidence"
  jq -r '.results[] | "- \(.example) \(.name): **\(.status | ascii_upcase)** (\(.evidence))"' "$DIR/report.json"
  echo
  echo "## Replay it yourself"
  echo '```bash'
  jq -r '.replay[]' "$DIR/report.json"
  echo '```'
} > "$DIR/report.md"

case "$DECISION" in
  pass) "$FL" pass "$ID" ;;
  fail) "$FL" fail "$ID" "$NOTE" ;;
  blocked) "$FL" blocked "$ID" "$NOTE" ;;
  inconclusive) "$FL" ask "$ID" "$NOTE" ;;
esac
echo "report: $ID $status (examples $(jq -r '"\(.passed)/\(.total)"' <<<"$summary")); see $DIR/report.md"
