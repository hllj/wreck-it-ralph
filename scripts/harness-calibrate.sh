#!/bin/bash
# harness-calibrate.sh - evaluator calibration: how often is the evaluator (replay engine + tester) wrong?
#
# A harness is only as good as its verdicts. The dangerous error is a FALSE POSITIVE (evaluator says PASS, the
# feature is actually broken): the loop then builds on a lie. This script measures that, from three sources:
#
#   comparator  known-answer cases fed through the replay comparison engine (harness-compare.jq), deterministic.
#               {id, name, category, expect, assertions, actual, truth}. Seeded by `seed`, extendable by humans.
#   scan        features the tester passed that later failed (a suspected false positive); a human labels them.
#   human       outcomes you record yourself: `record` (evaluator verdict vs the truth you established).
#
# Usage: calibrate.sh <command>
#   seed                               write the starter known-answer cases if cases.json is missing
#   run [--quiet]                      run every case through the comparison engine; exit 1 on any wrong verdict,
#                                      2 if one is a false positive (engine passed a known-bad case)
#   record <ID> <pass|fail> <pass|fail> --case "<name>" [--criterion EX001] [--category <c>]
#                                      the evaluator's verdict for feature <ID>, then the truth
#   scan                               list features that passed and later failed as candidates (open)
#   candidates                         list candidates and their labels
#   label <candidate-id> false_positive|regression|dismiss
#                                      false_positive: the tester passed a broken feature. regression: it was right
#                                      when it passed and a later change broke it (the harness caught it). dismiss: noise
#   report [--json] [--check]          confusion matrix, false-positive / false-negative rates, regression detection
#                                      rate and acceptance-criteria coverage; --check exits 1 above the threshold
#
# Data (tracked in git, human-owned; the gate restores it if an agent edits it):
#   .harness/calibration/cases.json        known-answer cases
#   .harness/calibration/outcomes.jsonl    recorded outcomes (human / scan), append-only
#   .harness/calibration/candidates.json   pass-then-fail candidates and their labels
#   .harness/calibration/last-run.json     result of the last `run` (comparator outcomes; replaced each run)
# Config (.harness/config.json -> calibration): enabled (default true), max_false_positive_rate (default 0).

set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FL="$HERE/feature-list.sh"; CFG="$HARNESS_DIR/config.json"
CAL="$HARNESS_DIR/calibration"; CASES="$CAL/cases.json"; OUT="$CAL/outcomes.jsonl"; CANDS="$CAL/candidates.json"; LAST="$CAL/last-run.json"
die() { echo "calibrate: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
verdict_ok() { [[ "$1" == pass || "$1" == fail ]]; }
classify() { # evaluator truth -> correct | false_positive | false_negative
  if [[ "$1" == "$2" ]]; then echo correct; elif [[ "$1" == pass ]]; then echo false_positive; else echo false_negative; fi
}

seed_cases() {
  mkdir -p "$CAL"
  [[ -f "$CASES" ]] && return 0
  cat > "$CASES" <<'EOF'
{"cases": [
  {"id": "K001", "name": "normal input", "category": "normal",
   "expect": {"status": 200, "body": {"id": 1, "name": "Ada"}}, "assertions": {"body": "exact"},
   "actual": {"status": 200, "body": {"id": 1, "name": "Ada"}}, "truth": "pass"},
  {"id": "K002", "name": "invalid input accepted instead of rejected", "category": "invalid_input",
   "expect": {"status": 400}, "actual": {"status": 200}, "truth": "fail"},
  {"id": "K003", "name": "required field missing from the response", "category": "missing_field",
   "expect": {"body": {"id": 1, "email": "ada@example.com"}}, "actual": {"body": {"id": 1}}, "truth": "fail"},
  {"id": "K004", "name": "unicode value round-trips", "category": "unicode",
   "expect": {"body": {"name": "Zoë 日本語 🙂"}}, "actual": {"body": {"name": "Zoë 日本語 🙂"}}, "truth": "pass"},
  {"id": "K005", "name": "contract violation: number returned as a string", "category": "contract",
   "expect": {"body": {"count": 3}}, "actual": {"body": {"count": "3"}}, "truth": "fail"},
  {"id": "K006", "name": "an expected key is absent from the actual output", "category": "missing_field",
   "expect": {"status": 200, "headers": {"content-type": "application/json"}}, "actual": {"status": 200}, "truth": "fail"},
  {"id": "K007", "name": "partial match tolerates extra fields", "category": "normal",
   "expect": {"body": {"id": 1}}, "actual": {"body": {"id": 1, "created": "2026-01-01"}}, "truth": "pass"},
  {"id": "K008", "name": "exact match rejects an extra field", "category": "contract",
   "expect": {"body": {"id": 1}}, "assertions": {"body": "exact"}, "actual": {"body": {"id": 1, "debug": true}}, "truth": "fail"},
  {"id": "K009", "name": "contains finds the text", "category": "normal",
   "expect": {"stdout": "ok"}, "assertions": {"stdout": "contains"}, "actual": {"stdout": "all ok\n"}, "truth": "pass"},
  {"id": "K010", "name": "contains does not find the text", "category": "invalid_input",
   "expect": {"stdout": "created"}, "assertions": {"stdout": "contains"}, "actual": {"stdout": "error: invalid\n"}, "truth": "fail"},
  {"id": "K011", "name": "regression: a previously correct field changed value", "category": "regression",
   "expect": {"body": {"total": 42}}, "actual": {"body": {"total": 41}}, "truth": "fail"},
  {"id": "K012", "name": "regression: a list lost an element", "category": "regression",
   "expect": {"body": {"items": [1, 2, 3]}}, "actual": {"body": {"items": [1, 2]}}, "truth": "fail"},
  {"id": "K013", "name": "regex does not match", "category": "contract",
   "expect": {"stdout": "^v[0-9]+\\.[0-9]+$"}, "assertions": {"stdout": "regex"}, "actual": {"stdout": "version unknown"}, "truth": "fail"},
  {"id": "K014", "name": "regex matches", "category": "normal",
   "expect": {"stdout": "^v[0-9]+\\.[0-9]+$"}, "assertions": {"stdout": "regex"}, "actual": {"stdout": "v1.2"}, "truth": "pass"},
  {"id": "K015", "name": "null expected but the key is missing (absent is not null)", "category": "missing_field",
   "expect": {"body": null}, "actual": {"status": 204}, "truth": "fail"},
  {"id": "K016", "name": "wrong exit code on the error path", "category": "invalid_input",
   "expect": {"exit_code": 1}, "actual": {"exit_code": 0}, "truth": "fail"}
]}
EOF
}

# one comparison: case json -> "pass" | "fail"
eval_case() { jq -c '{expect, assertions: (.assertions // {}), actual}' <<<"$1" | jq -c -f "$HERE/harness-compare.jq" | jq -r 'if length > 0 and all(.[]; .pass) then "pass" else "fail" end'; }

cmd_run() {
  local quiet=0; [[ "${1:-}" == --quiet ]] && quiet=1
  seed_cases
  jq -e '.cases | type == "array"' "$CASES" >/dev/null 2>&1 || die "$CASES is not valid (need {\"cases\": [...]})"
  local results='[]' c id name cat truth ev res
  while IFS= read -r c; do
    id="$(jq -r .id <<<"$c")"; name="$(jq -r .name <<<"$c")"; cat="$(jq -r '.category // "other"' <<<"$c")"; truth="$(jq -r .truth <<<"$c")"
    verdict_ok "$truth" || die "case $id: truth must be pass or fail"
    ev="$(eval_case "$c")"; res="$(classify "$ev" "$truth")"
    results="$(jq -c --arg id "$id" --arg n "$name" --arg cat "$cat" --arg ev "$ev" --arg t "$truth" --arg r "$res" \
      '. + [{case: $id, name: $n, category: $cat, evaluator: $ev, truth: $t, result: $r}]' <<<"$results")"
  done < <(jq -c '.cases[]' "$CASES")
  jq -n --arg at "$(now)" --argjson r "$results" '{at: $at, results: $r}' > "$LAST"
  local fp fn total
  fp="$(jq '[.[] | select(.result == "false_positive")] | length' <<<"$results")"; fn="$(jq '[.[] | select(.result == "false_negative")] | length' <<<"$results")"
  total="$(jq length <<<"$results")"
  if [[ $quiet -eq 0 || $((fp + fn)) -gt 0 ]]; then
    jq -r '.[] | "\(if .result == "correct" then "ok   " elif .result == "false_positive" then "FP   " else "FN   " end) \(.case)  \(.category)  \(.name)  [truth \(.truth), evaluator \(.evaluator)]"' <<<"$results" \
      | { if [[ $quiet -eq 1 ]]; then grep -v '^ok'; else cat; fi; }
  fi
  echo "calibrate: $total known-answer cases, false positives $fp, false negatives $fn"
  [[ $fp -gt 0 ]] && return 2
  [[ $fn -gt 0 ]] && return 1
  return 0
}

cmd_record() {
  local id="${1:-}" ev="${2:-}" truth="${3:-}" name="" crit="" cat="other"; shift 3 2>/dev/null || die "usage: record <ID> <pass|fail> <pass|fail> --case \"<name>\" [--criterion EX001] [--category <c>]"
  while [[ $# -gt 0 ]]; do case "$1" in
    --case) name="${2:-}"; shift 2 ;; --criterion) crit="${2:-}"; shift 2 ;; --category) cat="${2:-}"; shift 2 ;; *) die "unknown option $1" ;; esac; done
  verdict_ok "$ev" && verdict_ok "$truth" || die "evaluator and truth must each be pass or fail"
  [[ -n "$name" ]] || die "--case \"<name>\" is required"
  "$FL" show "$id" >/dev/null 2>&1 || die "unknown feature $id"
  mkdir -p "$CAL"
  jq -cn --arg at "$(now)" --arg f "$id" --arg n "$name" --arg cr "$crit" --arg cat "$cat" --arg ev "$ev" --arg t "$truth" --arg r "$(classify "$ev" "$truth")" \
    '{at: $at, source: "human", feature: $f, case: $n, criterion: (if $cr == "" then null else $cr end), category: $cat, evaluator: $ev, truth: $t, result: $r} | with_entries(select(.value != null))' >> "$OUT"
  echo "recorded: $id $name -> $(classify "$ev" "$truth")"
}

cmd_scan() {
  mkdir -p "$CAL"
  local found; found="$(jq -c '[.features[] | . as $f | (.attempts // []) as $a
      | ([$a | to_entries[] | select(.value.event == "pass")] | .[]?) as $p
      | ([$a | to_entries[] | select(.key > $p.key and .value.event == "fail")] | .[0]?) as $x
      | select($x != null)
      | {id: "\($f.id)@\($x.value.at)", feature: $f.id, passed_at: $p.value.at, failed_at: $x.value.at, note: ($x.value.note // "" | .[0:200]), status: "open"}]
      | unique_by(.id)' "$HARNESS_DIR/feature_list.json")"
  local before=0 after; [[ -f "$CANDS" ]] && before="$(jq length "$CANDS")"
  local merged; merged="$(jq -c --argjson f "$found" '. as $old | $old + [$f[] | select(.id as $i | $old | map(.id) | index($i) | not)]' <(if [[ -f "$CANDS" ]]; then cat "$CANDS"; else echo '[]'; fi))"
  after="$(jq length <<<"$merged")"
  [[ "$after" -gt "$before" ]] && echo "$merged" > "$CANDS"
  echo "calibrate: $((after - before)) new candidate(s); $(jq '[.[] | select(.status == "open")] | length' <<<"$merged") open (label them: calibrate.sh label <id> false_positive|regression|dismiss)"
}

cmd_candidates() { [[ -f "$CANDS" ]] || { echo "none (run: calibrate.sh scan)"; return 0; }; jq -r '.[] | "\(.status)\t\(.id)\tpassed \(.passed_at), later failed: \(.note)"' "$CANDS"; }

cmd_label() {
  local id="${1:-}" lab="${2:-}"
  case "$lab" in false_positive|regression|dismiss) ;; *) die "usage: label <candidate-id> false_positive|regression|dismiss" ;; esac
  [[ -f "$CANDS" ]] && jq -e --arg i "$id" 'any(.[]; .id == $i)' "$CANDS" >/dev/null || die "no candidate $id (see: calibrate.sh candidates)"
  local feat; feat="$(jq -r --arg i "$id" '.[] | select(.id == $i) | .feature' "$CANDS")"
  jq -c --arg i "$id" --arg l "$lab" 'map(if .id == $i then .status = $l else . end)' "$CANDS" > "$CANDS.tmp.$$" && mv "$CANDS.tmp.$$" "$CANDS"
  case "$lab" in
    false_positive) jq -cn --arg at "$(now)" --arg f "$feat" --arg n "passed, later failed: $id" '{at: $at, source: "scan", feature: $f, case: $n, category: "late_fail", evaluator: "pass", truth: "fail", result: "false_positive"}' >> "$OUT" ;;
    regression) jq -cn --arg at "$(now)" --arg f "$feat" --arg n "regression after a later change: $id" '{at: $at, source: "scan", feature: $f, case: $n, category: "regression", evaluator: "fail", truth: "fail", result: "correct"}' >> "$OUT" ;;
  esac
  echo "labelled $id: $lab"
}

# acceptance-criteria coverage: locked examples with passing, current replay evidence from this machine
coverage_json() {
  local total=0 verified=0 noex=0 feats=0 missing='[]' id j exid want f
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue; feats=$((feats + 1))
    local ex; ex="$("$FL" examples "$id" 2>/dev/null || true)"
    if [[ -z "$ex" ]]; then noex=$((noex + 1)); continue; fi
    while IFS=$'\t' read -r _ j; do
      [[ -z "$j" ]] && continue; total=$((total + 1))
      exid="$(jq -r .id <<<"$j")"; f="$HARNESS_DIR/evidence/$id/$exid/result.json"; want="$(jq -cS . <<<"$j" | sha)"
      if [[ -f "$f" && "$(jq -r '.example_sha // ""' "$f")" == "$want" && "$(jq -r '.status // ""' "$f")" == pass && "$(jq -r '.partial // false' "$f")" != true ]]; then verified=$((verified + 1))
      else missing="$(jq -c --arg k "$id/$exid" '. + [$k]' <<<"$missing")"; fi
    done <<<"$ex"
  done < <(jq -r '.features[] | select((.status // "") != "dropped") | .id' "$HARNESS_DIR/feature_list.json")
  jq -cn --argjson t "$total" --argjson v "$verified" --argjson n "$noex" --argjson f "$feats" --argjson m "$missing" \
    '{features: $f, features_without_examples: $n, examples: $t, examples_verified: $v, unverified: $m}'
}

cmd_report() {
  local json=0 check=0
  while [[ $# -gt 0 ]]; do case "$1" in --json) json=1; shift ;; --check) check=1; shift ;; *) die "unknown option $1" ;; esac; done
  local rows; rows="$( { [[ -f "$LAST" ]] && jq -c '.results[] | {source: "comparator", category, evaluator, truth, result}' "$LAST"; [[ -f "$OUT" ]] && jq -c '{source, category: (.category // "other"), evaluator, truth, result}' "$OUT"; } 2>/dev/null | jq -cs '.')"
  [[ -n "$rows" ]] || rows='[]'
  local cov; cov="$(coverage_json)"
  local open=0; [[ -f "$CANDS" ]] && open="$(jq '[.[] | select(.status == "open")] | length' "$CANDS")"
  local max; max="$(jq -r '.calibration.max_false_positive_rate // 0' "$CFG" 2>/dev/null || echo 0)"
  local rep; rep="$(jq -n --argjson r "$rows" --argjson cov "$cov" --argjson open "$open" --argjson max "$max" '
    def n(f): [$r[] | select(f)] | length;
    (n(.truth == "fail")) as $bad | (n(.truth == "pass")) as $good
    | (n(.result == "false_positive")) as $fp | (n(.result == "false_negative")) as $fn
    | ([$r[] | select(.category == "regression")]) as $reg
    | { cases: ($r | length), truth_fail: $bad, truth_pass: $good, false_positives: $fp, false_negatives: $fn,
        false_positive_rate: (if $bad == 0 then null else ($fp / $bad) end),
        false_negative_rate: (if $good == 0 then null else ($fn / $good) end),
        regression: {cases: ($reg | length), detected: ([$reg[] | select(.truth == "fail" and .evaluator == "fail")] | length),
                     detection_rate: (if ($reg | map(select(.truth == "fail")) | length) == 0 then null else (([$reg[] | select(.truth == "fail" and .evaluator == "fail")] | length) / ($reg | map(select(.truth == "fail")) | length)) end)},
        by_source: ($r | group_by(.source) | map({key: .[0].source, value: {cases: length, false_positives: ([.[] | select(.result == "false_positive")] | length), false_negatives: ([.[] | select(.result == "false_negative")] | length)}}) | from_entries),
        open_candidates: $open, coverage: $cov, max_false_positive_rate: $max,
        status: (if $fp == 0 then "ok" else "false_positives_found" end) }')"
  if [[ $json -eq 1 ]]; then echo "$rep"; else
    jq -r 'def pct: if . == null then "n/a (no cases)" else "\(. * 1000 | round / 10)%" end;
      "Evaluator calibration",
      "  cases with a known truth: \(.cases) (truth=fail \(.truth_fail), truth=pass \(.truth_pass))",
      "  FALSE POSITIVES (evaluator PASS, actually broken): \(.false_positives)  rate \(.false_positive_rate | pct)   <- the dangerous one",
      "  false negatives (evaluator FAIL, actually fine):   \(.false_negatives)  rate \(.false_negative_rate | pct)",
      "  regression detection: \(.regression.detected)/\(.regression.cases) caught  rate \(.regression.detection_rate | pct)",
      "  by source: " + ([.by_source | to_entries[] | "\(.key) \(.value.cases) cases (FP \(.value.false_positives), FN \(.value.false_negatives))"] | join("; ")),
      "  acceptance criteria: \(.coverage.examples_verified)/\(.coverage.examples) locked examples have current passing replay evidence; \(.coverage.features_without_examples) of \(.coverage.features) features have no examples (their criteria are unverified by replay)",
      (if (.coverage.unverified | length) > 0 then "  not yet verified: " + (.coverage.unverified[0:12] | join(", ")) + (if (.coverage.unverified | length) > 12 then " ..." else "" end) else empty end),
      (if .open_candidates > 0 then "  \(.open_candidates) pass-then-fail candidate(s) wait for a label (calibrate.sh candidates)" else empty end)' <<<"$rep"
  fi
  if [[ $check -eq 1 ]]; then
    jq -e '.false_positive_rate == null or .false_positive_rate <= .max_false_positive_rate' <<<"$rep" >/dev/null || { echo "calibrate: false-positive rate above calibration.max_false_positive_rate ($max)" >&2; return 1; }
  fi
  return 0
}

sub="${1:-}"; shift || true
case "$sub" in
  seed)       seed_cases; echo "calibration cases: $CASES" ;;
  run)        cmd_run "$@" ;;
  record)     cmd_record "$@" ;;
  scan)       cmd_scan ;;
  candidates) cmd_candidates ;;
  label)      cmd_label "$@" ;;
  report)     cmd_report "$@" ;;
  *) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
