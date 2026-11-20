#!/bin/bash
# harness-coverage.sh - coverage as VISIBILITY, not as a target. Never a goal for agents.
#
# Usage: coverage.sh run [--id ID] [--since REF]      run the test suite under coverage, write normalized reports
#        coverage.sh gaps <ID> [--all]                list the un-executed branches/lines of the files ID changed
#        coverage.sh classify <ID> <GAP> <class> <confidence> "<reason>" ["<evidence>"] ["<action>"]
#        coverage.sh check <ID>                       exit 1 while gaps are still unclassified
#        coverage.sh show <ID>                        summary + gap counts
# Exit:  0 ok, 1 check failed, 2 usage / error, 4 coverage not available or not configured
#
# Scopes (never mixed up in reports):
#   repository     whole-repo coverage                      .harness/coverage/repository.json
#   changed_files  coverage of the files changed since REF  .harness/coverage/<ID>.json  (this is NOT "feature
#                  coverage": a file can also run code of other features. Feature-attributed coverage is not claimed.)
# REF defaults to the session's starting commit (.step_state head_before), else HEAD~1.
#
# Normalized schema (schema_version 1): tool, tool_version, scope, commit_sha, summary{lines,branches},
# files[]{path, lines{covered,total,percent}, branches{...}|null, missing_lines, missing_branches[{from_line,to_line,
# description}], diff_ranges}. A tool without branch data gives branches: null, NEVER 0%. Percentages are
# informational; compare covered/total.
#
# Gaps (.harness/coverage/<ID>-gaps.json|md): mechanical list of un-executed branches/lines that fall in the diff
# (--all: whole changed files). The TESTER classifies each: needs_example | redundant_code | defensive_branch |
# inconclusive | verified_by_probe (requires evidence of the BEHAVIOUR being checked, not just the branch being
# reached), with a confidence (high|medium|low). Agents never delete code because of a gap and never write tests
# just to lift a number; needs_example becomes a proposal a human approves.
#
# Config (.harness/config.json -> coverage): tool ("" = auto: python), cmd (custom command that runs the tests and
# writes a coverage.py-format JSON to $COVERAGE_JSON), branch (true), omit (globs), max_gaps (50).

set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
CFG="$HARNESS_DIR/config.json"; COV="$HARNESS_DIR/coverage"
die() { echo "coverage: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"
cfg() { jq -r "$1" "$CFG" 2>/dev/null; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

CLASSES="needs_example redundant_code defensive_branch inconclusive verified_by_probe"
CONFS="high medium low"

LIB='
def pct($c; $t): if $t > 0 then (($c * 10000 / $t | round) / 100) else null end;
def sumof(f): [.[] | f] | add // 0;
def summ: { lines: {covered: sumof(.lines.covered), total: sumof(.lines.total), percent: pct(sumof(.lines.covered); sumof(.lines.total))},
            branches: (if any(.[]; .branches == null) then null
                       else {covered: sumof(.branches.covered), total: sumof(.branches.total), percent: pct(sumof(.branches.covered); sumof(.branches.total))} end),
            files: length };
def arcdesc: if .[1] > 0 then "branch at line \(.[0]) to line \(.[1]) never taken" else "branch at line \(.[0]) to the exit of its block never taken" end;
def inr($l; $r): any($r[]; .[0] <= $l and $l <= .[1]);
'

python_bin() { if [[ -x .venv/bin/python ]]; then echo .venv/bin/python; elif [[ -x venv/bin/python ]]; then echo venv/bin/python; else echo python3; fi; }

cmd_run() {
  local ID="" SINCE=""
  while [[ $# -gt 0 ]]; do case "$1" in --id) ID="${2:?id}"; shift 2 ;; --since) SINCE="${2:?ref}"; shift 2 ;; *) die "unknown option $1" ;; esac; done
  mkdir -p "$COV"
  local tool custom raw="$COV/raw.json" rc=0 sha at; tool="$(cfg '.coverage.tool // ""')"; custom="$(cfg '.coverage.cmd // ""')"
  sha="$(git rev-parse HEAD 2>/dev/null || echo none)"; at="$(now)"
  if [[ -z "$tool" && -z "$custom" ]]; then
    if [[ -f pyproject.toml || -f setup.py || -f setup.cfg || -f pytest.ini || -f tox.ini || -n "$(ls requirements*.txt test_*.py tests/test_*.py 2>/dev/null | head -n1)" ]]; then tool=python; fi
  fi
  rm -f "$raw"
  if [[ -n "$custom" ]]; then
    export COVERAGE_JSON="$raw" COVERAGE_FILE="$COV/.coverage"
    bash -c "$custom" > "$COV/run.log" 2>&1 < /dev/null || rc=$?
    [[ -s "$raw" ]] || { echo "coverage: coverage.cmd produced no coverage.py-format JSON at \$COVERAGE_JSON (see $COV/run.log)" >&2; return 4; }
  elif [[ "$tool" == python ]]; then
    local py omit branch_flag="--branch"; py="$(python_bin)"
    "$py" -m coverage --version >/dev/null 2>&1 || { echo "coverage: coverage.py is not installed for $py. Install it INTO THE PROJECT env (e.g. .venv/bin/pip install coverage pytest), or set coverage.cmd" >&2; return 4; }
    omit="$(cfg '(.coverage.omit // []) | if length == 0 then ["*/tests/*","tests/*","*/test_*.py","test_*.py","*_test.py","conftest.py"] else . end | . + [".venv/*","venv/*","*/site-packages/*",".harness/*"] | join(",")')"
    [[ "$(cfg '.coverage.branch // true')" == false ]] && branch_flag=""
    export COVERAGE_FILE="$COV/.coverage"
    "$py" -m coverage erase >/dev/null 2>&1
    "$py" -m coverage run $branch_flag --source=. --omit="$omit" -m pytest -q > "$COV/run.log" 2>&1 < /dev/null || rc=$?
    "$py" -m coverage json -q -o "$raw" >> "$COV/run.log" 2>&1 || { echo "coverage: no coverage data (did the tests run? see $COV/run.log)" >&2; return 4; }
  else
    echo "coverage: not configured: no supported project type detected (python only for now). Set coverage.tool or coverage.cmd in $CFG" >&2; return 4
  fi
  jq -n --slurpfile r "$raw" --arg sha "$sha" --arg at "$at" --argjson rc "$rc" "$LIB"'
    $r[0] as $raw | ($raw.meta.branch_coverage // false) as $br
    | { schema_version: 1, tool: "coverage.py", tool_version: ($raw.meta.version // null), scope: "repository", commit_sha: $sha, generated_at: $at,
        branch_data: $br, tests_exit_code: $rc,
        files: ($raw.files | to_entries | map(.key as $p | .value as $f | ($f.summary) as $s | {
          path: $p,
          lines: {covered: $s.covered_lines, total: $s.num_statements, percent: pct($s.covered_lines; $s.num_statements)},
          branches: (if $br then {covered: $s.covered_branches, total: $s.num_branches, percent: pct($s.covered_branches; $s.num_branches)} else null end),
          missing_lines: ($f.missing_lines // []),
          missing_branches: (if $br then (($f.missing_branches // []) | map({from_line: .[0], to_line: .[1], description: arcdesc})) else null end) })) }
    | . + {summary: (.files | summ)}' > "$COV/repository.json" 2> "$COV/norm.err" \
    || { echo "coverage: could not normalize $raw: $(head -c 300 "$COV/norm.err")" >&2; return 2; }
  [[ $rc -ne 0 ]] && echo "coverage: NOTE the test command exited $rc; coverage reflects what ran (see $COV/run.log)" >&2
  echo "coverage: repository $(brief "$COV/repository.json")"

  [[ -n "$ID" ]] || return 0
  if [[ -z "$SINCE" ]]; then
    SINCE="$(jq -r '.head_before // ""' "$HARNESS_DIR/.step_state.json" 2>/dev/null)"
    { [[ -n "$SINCE" && "$SINCE" != none ]] && git rev-parse -q --verify "$SINCE^{commit}" >/dev/null 2>&1; } || SINCE="HEAD~1"
  fi
  git rev-parse -q --verify "$SINCE^{commit}" >/dev/null 2>&1 || SINCE="$(git hash-object -t tree /dev/null)"
  local files_json="[]" f ranges
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    jq -e --arg p "$f" '.files[] | select(.path == $p)' "$COV/repository.json" >/dev/null || continue
    ranges="$(git diff -U0 --no-color "$SINCE" -- "$f" 2>/dev/null | sed -n 's/^@@ -[0-9,]* +\([0-9]*\)\(,\([0-9]*\)\)\{0,1\} @@.*/\1 \3/p' \
              | jq -R -s -c 'split("\n") | map(select(length > 0) | split(" ") | (.[0] | tonumber) as $s | ((.[1] // "1") | if . == "" then 1 else tonumber end) as $n | select($n > 0) | [$s, ($s + $n - 1)])')"
    files_json="$(jq -c --arg p "$f" --argjson r "${ranges:-[]}" --slurpfile repo "$COV/repository.json" \
        '. + [($repo[0].files[] | select(.path == $p)) + {diff_ranges: $r}]' <<<"$files_json")"
  done < <(git diff --name-only "$SINCE" -- 2>/dev/null)
  jq -n --slurpfile repo "$COV/repository.json" --argjson files "$files_json" --arg id "$ID" --arg since "$SINCE" "$LIB"'
    $repo[0] | {schema_version, tool, tool_version, commit_sha, generated_at, branch_data, tests_exit_code,
                scope: "changed_files", feature_id: $id, since: $since, note: "changed-file coverage, not feature coverage",
                repository_summary: .summary, files: $files}
    | . + {summary: (.files | summ)}' > "$COV/$ID.json"
  echo "coverage: $ID changed files ($(jq '.files | length' "$COV/$ID.json")) $(brief "$COV/$ID.json")"
}

brief() { jq -r 'if (.summary.files // 0) == 0 then "no changed files with coverage data"
  else "lines \(.summary.lines.covered)/\(.summary.lines.total)" + (if .summary.branches then ", branches \(.summary.branches.covered)/\(.summary.branches.total)" else ", branches n/a (tool gave no branch data)" end) end' "$1"; }

# ------------------------------------------------------------------------------------------------ gaps
GAPS_FIELDS='classification, confidence, reason, evidence, suggested_action, classified_at'

cmd_gaps() {
  local ID="${1:-}" ALL=false; shift || true
  [[ -n "$ID" ]] || die "usage: gaps <ID> [--all]"
  [[ "${1:-}" == "--all" ]] && ALL=true
  local doc="$COV/$ID.json" out="$COV/$ID-gaps.json" max old="[]"
  [[ -f "$doc" ]] || die "no $doc: run 'coverage.sh run --id $ID' first"
  max="$(cfg '.coverage.max_gaps // 50')"; [[ -f "$out" ]] && old="$(jq -c '.gaps' "$out")"
  local gaps; gaps="$(jq -c --argjson all "$ALL" --argjson old "$old" --argjson max "$max" "$LIB"'
    (.files | map(. as $f | ($f.diff_ranges // []) as $r
      | ((($f.missing_branches // []) | map(select($all or inr(.from_line; $r) or (.to_line > 0 and inr(.to_line; $r))))) ) as $bs
      | ($bs | map(.to_line) + map(.from_line)) as $tos
      | ( $bs | map(. as $b | {kind: "branch", file: $f.path, line: $b.from_line, to_line: $b.to_line, description: $b.description,
                               target_unexecuted: ($b.to_line > 0 and (($f.missing_lines | index($b.to_line)) != null))}) )
        + ( $f.missing_lines | map(select(($all or inr(.; $r)) and (. as $l | ($tos | index($l)) == null))
                                   | {kind: "line", file: $f.path, line: ., to_line: null, description: "line \(.) never executed", target_unexecuted: false}) )
      | map(. + {in_diff: (inr(.line; $r) or (.to_line != null and .to_line > 0 and inr(.to_line; $r)))})
    ) | add // []) as $new
    | ($new | map(. + {key: "\(.file):\(.line):\(.to_line // "-"):\(.kind)"})) as $n
    | ($old | map({key: .key, value: .}) | from_entries) as $o
    | (($old | map(.id | ltrimstr("G") | tonumber) | max) // 0) as $top
    | reduce $n[] as $g ({gaps: [], next: ($top + 1)};
        ($o[$g.key] // null) as $prev
        | .gaps += [ $g + (if $prev then ($prev | {id, classification, confidence, reason, evidence, suggested_action, classified_at})
                           else {id: "G\(.next)", classification: null, confidence: null, reason: null, evidence: null, suggested_action: null, classified_at: null} end) ]
        | if $prev then . else .next += 1 end)
    | .gaps | sort_by([(.in_diff | not), .file, .line]) | {total: length, shown: ([length, $max] | min), gaps: .[0:$max]}' "$doc")" || die "could not build gaps"
  # source context for each gap (the condition text is what the tester needs to read)
  local n i file line snip; n="$(jq '.gaps | length' <<<"$gaps")"
  for ((i = 0; i < n; i++)); do
    file="$(jq -r --argjson i "$i" '.gaps[$i].file' <<<"$gaps")"; line="$(jq -r --argjson i "$i" '.gaps[$i].line' <<<"$gaps")"
    snip="[]"
    if [[ -f "$file" ]]; then
      snip="$(awk -v s=$((line > 1 ? line - 1 : 1)) -v e=$((line + 1)) 'NR >= s && NR <= e { printf "%d\t%s\n", NR, $0 }' "$file" \
              | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {n: (.[0] | tonumber), text: (.[1:] | join("\t"))})')"
    fi
    gaps="$(jq -c --argjson i "$i" --argjson s "$snip" '.gaps[$i].snippet = $s' <<<"$gaps")"
  done
  jq --arg id "$ID" --arg at "$(now)" --arg scope "$(jq -r .scope "$doc")" --argjson all "$ALL" --arg sha "$(jq -r .commit_sha "$doc")" \
     '{feature_id: $id, generated_at: $at, scope: $scope, commit_sha: $sha, mode: (if $all then "all changed files" else "changed lines only (diff)" end),
       total_found: .total, truncated: (.total > .shown)} + {gaps: .gaps}' <<<"$gaps" > "$out"
  render_md "$ID"
  summarize "$ID"
}

render_md() {
  local ID="$1" j="$COV/$1-gaps.json"
  {
    echo "# Coverage gaps: $ID"
    echo
    echo "Scope: $(jq -r '.scope' "$j") ($(jq -r '.mode' "$j")), commit $(jq -r '.commit_sha' "$j" | cut -c1-10). Coverage is visibility, not correctness: a gap is a place to LOOK, not a number to fix."
    jq -r 'if .truncated then "\n**Truncated:** \(.total_found) gaps found, showing the first \(.gaps | length) (coverage.max_gaps).\n" else "" end' "$j"
    jq -r '.gaps[] | "## \(.id): \(.file):\(.line)\n\n- Kind: \(.kind)\(if .to_line then " (to line \(.to_line))" else "" end), in diff: \(.in_diff)\n- \(.description)\(if .target_unexecuted then " (its target line was never executed)" else "" end)\n- Code:\n\(.snippet | map("    \(.n): \(.text)") | join("\n"))\n- Classification: \(.classification // "UNCLASSIFIED")\(if .confidence then " (confidence \(.confidence))" else "" end)\n- Reason: \(.reason // "-")\n- Evidence: \(.evidence // "-")\n- Suggested action: \(.suggested_action // "-")\n"' "$j"
  } > "$COV/$ID-gaps.md"
}

summarize() {
  local j="$COV/$1-gaps.json"
  jq -r '"coverage: \(.gaps | length) gap(s) for '"$1"'" + (if .truncated then " (of \(.total_found), truncated)" else "" end)
         + ", unclassified: \([.gaps[] | select(.classification == null)] | length)"
         + (([.gaps[] | select(.classification != null) | .classification] | group_by(.) | map("\(.[0]) \(length)") | join(", ")) as $c | if $c == "" then "" else "; " + $c end)
         + "  (.harness/coverage/'"$1"'-gaps.md)"' "$j"
}

cmd_classify() {
  local ID="${1:-}" GID="${2:-}" CLS="${3:-}" CONF="${4:-}" WHY="${5:-}" EVI="${6:-}" ACT="${7:-}"
  [[ -n "$ID" && -n "$GID" && -n "$CLS" && -n "$CONF" ]] || die 'usage: classify <ID> <GAP> <class> <confidence> "<reason>" ["<evidence>"] ["<action>"]'
  local j="$COV/$ID-gaps.json"; [[ -f "$j" ]] || die "no gaps for $ID: run 'coverage.sh gaps $ID' first"
  [[ " $CLASSES " == *" $CLS "* ]] || die "class must be one of: $CLASSES"
  [[ " $CONFS " == *" $CONF "* ]] || die "confidence must be one of: $CONFS"
  [[ -n "$WHY" ]] || die "a reason is required"
  [[ "$CLS" != verified_by_probe || -n "$EVI" ]] || die "verified_by_probe needs evidence: the input you ran and the BEHAVIOUR you checked (reaching the branch is not enough)"
  jq -e --arg g "$GID" '.gaps[] | select(.id == $g)' "$j" >/dev/null || die "unknown gap $GID in $j"
  jq --arg g "$GID" --arg c "$CLS" --arg cf "$CONF" --arg w "$WHY" --arg e "$EVI" --arg a "$ACT" --arg at "$(now)" \
     '.gaps |= map(if .id == $g then . + {classification: $c, confidence: $cf, reason: $w, evidence: (if $e == "" then null else $e end), suggested_action: (if $a == "" then null else $a end), classified_at: $at} else . end)' \
     "$j" > "$j.tmp" && mv "$j.tmp" "$j"
  render_md "$ID"; echo "classified $GID as $CLS ($CONF)"
}

cmd_check() {
  local ID="${1:-}"; [[ -n "$ID" ]] || die "usage: check <ID>"
  local j="$COV/$ID-gaps.json"; [[ -f "$j" ]] || die "no gaps for $ID"
  local open; open="$(jq -r '[.gaps[] | select(.classification == null) | .id] | join(", ")' "$j")"
  [[ -z "$open" ]] && { echo "coverage: all gaps of $ID classified"; return 0; }
  echo "coverage: unclassified gaps for $ID: $open" >&2; return 1
}

cmd_show() {
  local ID="${1:-}"; [[ -n "$ID" ]] || die "usage: show <ID>"
  [[ -f "$COV/$ID.json" ]] && echo "coverage: $ID changed files $(brief "$COV/$ID.json")"
  [[ -f "$COV/$ID-gaps.json" ]] && summarize "$ID"
  [[ -f "$COV/repository.json" ]] && echo "coverage: repository $(brief "$COV/repository.json")"
  return 0
}

c="${1:-}"; shift || true
case "$c" in
  run) cmd_run "$@" ;;
  gaps) cmd_gaps "$@" ;;
  classify) cmd_classify "$@" ;;
  check) cmd_check "$@" ;;
  show) cmd_show "$@" ;;
  *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
