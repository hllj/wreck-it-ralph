#!/bin/bash
# harness-report.sh - the tester's verdict, backed by replay evidence. "No evidence, no PASS."
#
# Usage: report.sh <ID> pass|fail|blocked|inconclusive "<note>" [--findings <file.json>]
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
  DECISION="${1:-}"; NOTE="${2:-}"; FINDINGS="[]"
  if [[ "${3:-}" == "--findings" ]]; then
    ff="${4:-}"; [[ -f "$ff" ]] || die "--findings needs a JSON file (an array of {kind, criterion, input, expected, observed, severity})"
    jq -e 'type == "array" and all(.[]; type == "object")' "$ff" >/dev/null 2>&1 || die "$ff must be a JSON array of finding objects"
    FINDINGS="$(jq -c . "$ff")"
  fi
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
cov="null"
if [[ -f "$HARNESS_DIR/coverage/$ID.json" ]]; then
  cov="$(jq -c '{scope, note, since, tool, tool_version, commit_sha, tests_exit_code, changed_files: .summary, repository: .repository_summary}' "$HARNESS_DIR/coverage/$ID.json")"
  if [[ -f "$HARNESS_DIR/coverage/$ID-gaps.json" ]]; then
    cov="$(jq -c --slurpfile g "$HARNESS_DIR/coverage/$ID-gaps.json" '. + {gaps: ($g[0].gaps | {total: length, unclassified: (map(select(.classification == null)) | length),
         by_class: (map(select(.classification != null) | .classification) | group_by(.) | map({key: .[0], value: length}) | from_entries)})}' <<<"$cov")"
  fi
fi
if [[ "$cov" != null && -f "$HARNESS_DIR/coverage/$ID-ratchet.json" ]]; then
  cov="$(jq -c --slurpfile r "$HARNESS_DIR/coverage/$ID-ratchet.json" '. + {ratchet: ($r[0] | {verdict, mode, reason, regressions, baseline_commit})}' <<<"$cov")"
fi
jq -n --arg id "$ID" --arg s "$status" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$(git rev-parse HEAD 2>/dev/null || echo none)" \
      --arg note "$NOTE" --argjson findings "${FINDINGS:-[]}" --argjson sum "$summary" --argjson r "$results" --argjson cov "$cov" \
  '{feature_id: $id, status: $s, tested_at: $at, commit_sha: $sha, examples: $sum, coverage: $cov, note: $note, findings: $findings, results: $r,
    replay: (["./.harness/replay.sh \($id)"] + ($r | map("./.harness/replay.sh \($id) --example \(.example)")))}' > "$DIR/report.json"
{
  echo "# $ID: $(printf %s "$status" | tr a-z A-Z)"
  echo
  echo "- Tested: $(jq -r .tested_at "$DIR/report.json") at commit $(jq -r .commit_sha "$DIR/report.json" | cut -c1-10)"
  echo "- Examples: $(jq -r '"\(.examples.passed)/\(.examples.total) passed, \(.examples.failed) failed, \(.examples.not_run) not run"' "$DIR/report.json")"
  [[ -n "$NOTE" ]] && echo "- Note: $NOTE"
  jq -r 'if (.findings | length) > 0 then "\n## Findings for the coder\n" + ([.findings[] | "- [\(.severity // "?")/\(.kind // "?")] \(.criterion // "") input: \(.input | tojson) | expected: \(.expected | tojson) | observed: \(.observed | tojson)"] | join("\n")) else empty end' "$DIR/report.json"
  echo
  jq -r 'if .coverage then "- Coverage (\(.coverage.scope), \(.coverage.note)): lines \(.coverage.changed_files.lines.covered)/\(.coverage.changed_files.lines.total)" + (if .coverage.changed_files.branches then ", branches \(.coverage.changed_files.branches.covered)/\(.coverage.changed_files.branches.total)" else ", branches n/a" end) + (if .coverage.gaps then "; gaps \(.coverage.gaps.total), unclassified \(.coverage.gaps.unclassified)" else "" end) + (if .coverage.ratchet then "; ratchet \(.coverage.ratchet.verdict) (\(.coverage.ratchet.mode))" else "" end) else empty end' "$DIR/report.json"
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
