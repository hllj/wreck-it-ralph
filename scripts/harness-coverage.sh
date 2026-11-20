#!/bin/bash
# harness-coverage.sh - coverage as VISIBILITY, not as a target. Never a goal for agents.
#
# Usage: coverage.sh run [--id ID] [--since REF]      run the test suite under coverage, write normalized reports
#        coverage.sh gaps <ID> [--all]                list the un-executed branches/lines of the files ID changed
#        coverage.sh classify <ID> <GAP> <class> <confidence> "<reason>" ["<evidence>"] ["<action>"]
#        coverage.sh baseline [--update | --accept-decrease "<reason>"]   record / raise / (human) lower the baseline
#        coverage.sh ratchet [--id ID]                compare with the baseline: repository + changed files
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
# Ratchet (M10): coverage must not DECREASE; it is never a target. Two tiers: repository, and every changed file that
# has a baseline entry (new files: reported, not gated; renames follow `git diff -M`). Exact covered/total ratios are
# compared (rounded percentages never), branches when both sides have branch data, else lines. The baseline
# (.harness/coverage/baseline.json, committed) is tied to a commit, the tool version and a config fingerprint; if
# these differ, or the test run failed, the comparison is "not comparable" (exit 4) and never blocks. `baseline`
# only raises (--update) and refuses inside a loop session; lowering needs --accept-decrease with a reason (human).
# coverage.mode "report" (default) is advisory; "gate" makes step.sh end fail features passed in a session that
# regressed. Config coverage.ratchet: {enabled, scope[repository|changed_files], allow_new_files, tolerance (pp)}.
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
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }

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
    [[ "$(cfg 'if .coverage.branch == null then true else .coverage.branch end')" == false ]] && branch_flag=""
    export COVERAGE_FILE="$COV/.coverage"
    "$py" -m coverage erase >/dev/null 2>&1
    "$py" -m coverage run $branch_flag --source=. --omit="$omit" -m pytest -q > "$COV/run.log" 2>&1 < /dev/null || rc=$?
    "$py" -m coverage json -q -o "$raw" >> "$COV/run.log" 2>&1 || { echo "coverage: no coverage data (did the tests run? see $COV/run.log)" >&2; return 4; }
  else
    echo "coverage: not configured: no supported project type detected (python only for now). Set coverage.tool or coverage.cmd in $CFG" >&2; return 4
  fi
  local fp; fp="$(jq -cS '{tool: (.coverage.tool // ""), cmd: (.coverage.cmd // ""), branch: (if .coverage.branch == null then true else .coverage.branch end), omit: (.coverage.omit // [])}' "$CFG" 2>/dev/null | sha256)"
  jq -n --slurpfile r "$raw" --arg sha "$sha" --arg at "$at" --argjson rc "$rc" --arg fp "$fp" "$LIB"'
    $r[0] as $raw | ($raw.meta.branch_coverage // false) as $br
    | { schema_version: 1, tool: "coverage.py", tool_version: ($raw.meta.version // null), scope: "repository", commit_sha: $sha, generated_at: $at,
        config_fingerprint: $fp, branch_data: $br, tests_exit_code: $rc,
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
    $repo[0] | {schema_version, tool, tool_version, commit_sha, generated_at, config_fingerprint, branch_data, tests_exit_code,
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

# ------------------------------------------------------------------------------------------------ baseline + ratchet
BASE="$COV/baseline.json"
in_session() { [[ "$(jq -r '.in_session // false' "$HARNESS_DIR/.step_state.json" 2>/dev/null)" == true ]]; }

cmd_baseline() {
  local mode=create reason=""
  case "${1:-}" in
    "") ;;
    --update) mode=update ;;
    --accept-decrease) mode=decrease; reason="${2:-}"; [[ -n "$reason" ]] || die 'usage: baseline --accept-decrease "<reason>"' ;;
    *) die 'usage: baseline [--update | --accept-decrease "<reason>"]' ;;
  esac
  in_session && die "the baseline is changed by a human between sessions, not by an agent inside a loop session"
  local repo="$COV/repository.json"; [[ -f "$repo" ]] || die "no $repo: run 'coverage.sh run' first"
  [[ "$(jq -r '.tests_exit_code' "$repo")" == 0 ]] || die "the last test run failed (exit $(jq -r '.tests_exit_code' "$repo")): coverage of a red suite is not a baseline"
  if [[ -f "$BASE" && "$mode" == create ]]; then die "$BASE exists: use --update to raise it (or --accept-decrease \"<reason>\")"; fi
  if [[ ! -f "$BASE" && "$mode" != create ]]; then mode=create; fi
  local old='{}'; [[ -f "$BASE" ]] && old="$(cat "$BASE")"
  if [[ "$mode" != create ]]; then
    [[ "$(jq -r '.config_fingerprint' <<<"$old")" == "$(jq -r '.config_fingerprint' "$repo")" ]] || die "the coverage config changed since the baseline (fingerprint differs); re-create it deliberately: rm $BASE && coverage.sh baseline"
  fi
  jq -n --argjson old "$old" --slurpfile repo "$repo" --arg mode "$mode" --arg reason "$reason" --arg at "$(now)" "$LIB"'
    def rt($x): if ($x == null) or ($x.total // 0) == 0 then null else ($x.covered / $x.total) end;
    def better($a; $b): (rt($a)) as $ra | (rt($b)) as $rb | if $rb == null then $a elif $ra == null then $b elif $ra >= $rb then $a else $b end;
    $repo[0] as $r
    | ($r.files | map({key: .path, value: {lines: {covered: .lines.covered, total: .lines.total}, branches: (if .branches then {covered: .branches.covered, total: .branches.total} else null end)}}) | from_entries) as $cur
    | (if $mode == "update" then
         ($cur | with_entries(.key as $k | .value as $v | ($old.files[$k] // null) as $o
            | .value = (if $o == null then $v else {lines: better($v.lines; $o.lines), branches: (if $v.branches == null or $o.branches == null then ($v.branches // $o.branches) else better($v.branches; $o.branches) end)} end)))
       else $cur end) as $files
    | (if $mode == "update" then {lines: better($r.summary.lines; $old.repository.lines), branches: (if $r.summary.branches == null or $old.repository.branches == null then ($r.summary.branches // $old.repository.branches) else better($r.summary.branches; $old.repository.branches) end)}
       else {lines: {covered: $r.summary.lines.covered, total: $r.summary.lines.total}, branches: (if $r.summary.branches then {covered: $r.summary.branches.covered, total: $r.summary.branches.total} else null end)} end) as $repo_sum
    | {schema_version: 1, created_at: ($old.created_at // $at), updated_at: $at, commit_sha: $r.commit_sha, tool: $r.tool, tool_version: $r.tool_version,
       config_fingerprint: $r.config_fingerprint, branch_data: $r.branch_data,
       repository: $repo_sum, files: $files,
       history: (($old.history // []) + [{at: $at, commit_sha: $r.commit_sha, action: $mode, reason: (if $reason == "" then null else $reason end)}])}' > "$BASE.tmp" \
    && mv "$BASE.tmp" "$BASE" || die "could not write the baseline"
  echo "coverage: baseline $mode at $(jq -r '.commit_sha' "$BASE" | cut -c1-10): $(jq -r '"lines \(.repository.lines.covered)/\(.repository.lines.total)" + (if .repository.branches then ", branches \(.repository.branches.covered)/\(.repository.branches.total)" else ", branches n/a" end)' "$BASE")  ($BASE: commit it)"
}

cmd_ratchet() {
  local ID=""; [[ "${1:-}" == "--id" ]] && ID="${2:-}"
  local repo="$COV/repository.json"; [[ -f "$repo" ]] || die "no $repo: run 'coverage.sh run${ID:+ --id $ID}' first"
  local out="$COV/${ID:-repository}-ratchet.json" mode scope tol allow
  mode="$(cfg '.coverage.mode // "report"')"; tol="$(cfg '.coverage.ratchet.tolerance // 0')"; allow="$(cfg 'if .coverage.ratchet.allow_new_files == null then true else .coverage.ratchet.allow_new_files end')"
  scope="$(cfg '(.coverage.ratchet.scope // ["repository","changed_files"]) | @json')"
  if [[ "$(cfg 'if .coverage.ratchet.enabled == null then true else .coverage.ratchet.enabled end')" == false ]]; then echo "coverage: ratchet disabled (coverage.ratchet.enabled=false)"; return 0; fi
  local verdict="" why=""
  if [[ ! -f "$BASE" ]]; then verdict=not_comparable; why="no baseline: run 'coverage.sh baseline' (human, between sessions) and commit it"
  elif [[ "$(jq -r '.tests_exit_code' "$repo")" != 0 ]]; then verdict=not_comparable; why="the test run failed (exit $(jq -r '.tests_exit_code' "$repo")): coverage of a red suite is not comparable"
  elif [[ "$(jq -r '.config_fingerprint' "$BASE")" != "$(jq -r '.config_fingerprint' "$repo")" ]]; then verdict=not_comparable; why="the coverage config changed since the baseline (fingerprint differs)"
  elif [[ "$(jq -r '.tool' "$BASE")" != "$(jq -r '.tool' "$repo")" || "$(jq -r '.tool_version // "" | split(".")[0]' "$BASE")" != "$(jq -r '.tool_version // "" | split(".")[0]' "$repo")" ]]; then verdict=not_comparable; why="coverage tool or its major version changed since the baseline"
  fi
  if [[ -n "$verdict" ]]; then
    jq -n --arg v "$verdict" --arg w "$why" --arg m "$mode" --arg id "$ID" --arg at "$(now)" '{feature_id: $id, verdict: $v, reason: $w, mode: $m, at: $at, repository: null, files: []}' > "$out"
    echo "coverage: ratchet not comparable: $why" >&2; return 4
  fi
  # file renames since the baseline commit (new path -> old path)
  local renames="{}" bsha; bsha="$(jq -r '.commit_sha' "$BASE")"
  if git rev-parse -q --verify "$bsha^{commit}" >/dev/null 2>&1; then
    renames="$(git diff --name-status -M "$bsha" HEAD 2>/dev/null | jq -R -s -c 'split("\n") | map(select(startswith("R")) | split("\t") | {key: .[2], value: .[1]}) | from_entries')"
  fi
  local changed="$COV/$ID.json"; [[ -n "$ID" && -f "$changed" ]] || changed=/dev/null
  local cf='{"files": []}'; [[ "$changed" != /dev/null ]] && cf="$(cat "$changed")"
  jq -n --slurpfile base "$BASE" --slurpfile repo "$repo" --argjson cf "$cf" --argjson ren "$renames" --argjson scope "$scope" --argjson tol "$tol" \
        --argjson allow "$allow" --arg mode "$mode" --arg id "$ID" --arg at "$(now)" '
    def lt($n; $o): if ($o.total // 0) == 0 or ($n.total // 0) == 0 then false
      elif $tol == 0 then ($n.covered * $o.total) < ($o.covered * $n.total)
      else ((($o.covered / $o.total) - ($n.covered / $n.total)) * 100) > $tol end;
    def cmp($n; $o): (if ($n.branches != null and $o.branches != null) then "branches" else "lines" end) as $m
      | {metric: $m, old: $o[$m], new: $n[$m], regressed: lt($n[$m]; $o[$m])};
    def slim($s): {lines: {covered: $s.lines.covered, total: $s.lines.total}, branches: (if $s.branches then {covered: $s.branches.covered, total: $s.branches.total} else null end)};
    $base[0] as $b | $repo[0] as $r
    | (if ($scope | index("repository")) then (cmp(slim($r.summary); $b.repository) + {scope: "repository"}) else null end) as $rt
    | (if ($scope | index("changed_files")) then
         ($cf.files | map(. as $f | ($ren[$f.path] // $f.path) as $key | ($b.files[$key] // null) as $o
            | if $o != null then (cmp(slim($f); $o) + {scope: "changed_file", path: $f.path, baseline_path: $key, status: "compared"})
              elif $allow then {scope: "changed_file", path: $f.path, status: "new_file", regressed: false}
              else (cmp(slim($f); $b.repository) + {scope: "changed_file", path: $f.path, status: "new_file_vs_repository", baseline_path: null}) end))
       else [] end) as $ft
    | ([$rt] | map(select(. != null))) + $ft | map(select(.regressed)) as $bad
    | {feature_id: $id, verdict: (if ($bad | length) > 0 then "regressed" else "ok" end), mode: $mode, at: $at, baseline_commit: $b.commit_sha, current_commit: $r.commit_sha,
       tolerance_pp: $tol, repository: $rt, files: $ft, regressions: ($bad | map(if .scope == "repository" then "repository \(.metric) \(.old.covered)/\(.old.total) -> \(.new.covered)/\(.new.total)" else "\(.path) \(.metric) \(.old.covered)/\(.old.total) -> \(.new.covered)/\(.new.total)" end))}' > "$out" \
    || die "could not compute the ratchet"
  local v; v="$(jq -r .verdict "$out")"
  if [[ "$v" == regressed ]]; then
    echo "coverage: RATCHET REGRESSED (mode $mode$([[ "$mode" == gate ]] || echo ", advisory")): $(jq -r '.regressions | join("; ")' "$out")" >&2; return 1
  fi
  echo "coverage: ratchet ok vs baseline $(jq -r '.baseline_commit' "$out" | cut -c1-10) ($(jq '[.files[] | select(.status == "compared")] | length' "$out") changed file(s) compared, $(jq '[.files[] | select(.status == "new_file")] | length' "$out") new)"
}

c="${1:-}"; shift || true
case "$c" in
  run) cmd_run "$@" ;;
  gaps) cmd_gaps "$@" ;;
  classify) cmd_classify "$@" ;;
  check) cmd_check "$@" ;;
  show) cmd_show "$@" ;;
  baseline) cmd_baseline "$@" ;;
  ratchet) cmd_ratchet "$@" ;;
  *) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
