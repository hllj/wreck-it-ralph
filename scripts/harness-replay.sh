#!/bin/bash
# harness-replay.sh - replay a feature's locked examples against the RUNNING application.
#
# The engine, not the coder, evaluates the results: examples are data, an adapter performs the call,
# and the comparison below produces PASS/FAIL. The coder cannot change the examples (spec lock) and
# cannot supply its own evaluation logic.
#
# Usage: replay.sh <ID> [--example EX001] [--step N | --from A --to B] [--keep] [--list | --steps] [--quiet]
# Exit:  0 all selected steps passed   1 at least one failed   2 usage / bad example
#        3 blocked (app unreachable / command not runnable)   4 replay not configured
#
# An example is one step ({input, expect, assertions}) or several (`steps: [...]`, run in order, stopping at
# the first failure). Steps are numbered 1..N across the feature's examples; --step/--from/--to replay a
# slice. An example may also declare `setup` and `cleanup` fixture steps ({input, expect?}); they use the same
# adapters (no shell), may contain "{{namespace}}" (replaced by this run's unique namespace), and cleanup always
# runs after the example, pass or fail, unless --keep. A run that replayed only some steps is marked `partial`
# and never counts as complete evidence.
#
# Config (.harness/config.json -> replay): adapter (http|cli; default from preset: api/web -> http,
# cli -> cli), base_url (or env BASE_URL), command (cli adapter, e.g. "./bin/mytool"), timeout_seconds.
# An example or step may set its own "adapter". Comparison modes per expect key (assertions): exact | partial
# (expected is a subset of actual) | contains | regex; default exact, partial when expected is an object.
# Evidence per run: .harness/evidence/<ID>/<EX>/{result.json, actual.json, ...} (+ step-N/, setup-N/, cleanup-N/
# for multi-step examples), git-ignored.

set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FL="$HERE/feature-list.sh"; CFG="$HARNESS_DIR/config.json"
die() { echo "replay: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"

ID="${1:-}"; shift || true
[[ -n "$ID" ]] || die "usage: replay.sh <ID> [--example EX001] [--step N | --from A --to B] [--keep] [--list | --steps] [--quiet]"
ONLY=""; LIST=0; STEPS=0; QUIET=0; KEEP=0; FROM=1; TO=999999
while [[ $# -gt 0 ]]; do
  case "$1" in
    --example) ONLY="${2:?example id}"; shift 2 ;;
    --step) FROM="${2:?step number}"; TO="$FROM"; shift 2 ;;
    --from) FROM="${2:?step number}"; shift 2 ;;
    --to) TO="${2:?step number}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --list) LIST=1; shift ;;
    --steps) STEPS=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
[[ "$FROM" =~ ^[0-9]+$ && "$TO" =~ ^[0-9]+$ ]] || die "--step/--from/--to need numbers"

examples="$("$FL" examples "$ID")" || exit 2
[[ -n "$examples" ]] || die "$ID has no examples"
if [[ -n "$ONLY" ]]; then
  found=0; while IFS=$'\t' read -r _ j; do [[ "$(jq -r .id <<<"$j")" == "$ONLY" ]] && found=1; done <<<"$examples"
  [[ $found -eq 1 ]] || die "$ID has no example $ONLY"
fi

# steps of an example as a JSON array (a plain example is a single step)
steps_of() { jq -c 'if has("steps") then .steps else [{name: .name, input: .input, expect: .expect, assertions: (.assertions // {})}] end' <<<"$1"; }

if [[ $LIST -eq 1 ]]; then
  while IFS=$'\t' read -r _ j; do jq -r '"\(.id)\t\(.name)"' <<<"$j"; done <<<"$examples"; exit 0
fi
if [[ $STEPS -eq 1 ]]; then
  n=0
  while IFS=$'\t' read -r _ j; do
    exid="$(jq -r .id <<<"$j")"; sj="$(steps_of "$j")"
    for ((i = 0; i < $(jq length <<<"$sj"); i++)); do
      n=$((n + 1)); echo "$n	$exid	$(jq -r --argjson i "$i" '.[$i].name // "step \($i + 1)"' <<<"$sj")"
    done
  done <<<"$examples"
  exit 0
fi

cfg() { jq -r "$1" "$CFG" 2>/dev/null; }
preset="$(cfg '.preset // ""')"
cfg_adapter="$(cfg '.replay.adapter // ""')"
if [[ -z "$cfg_adapter" ]]; then case "$preset" in api|web) cfg_adapter=http ;; cli) cfg_adapter=cli ;; esac; fi
export BASE_URL="${BASE_URL:-$(cfg '.replay.base_url // ""')}"
export REPLAY_COMMAND="$(cfg '.replay.command // ""')"
export REPLAY_TIMEOUT="$(cfg '.replay.timeout_seconds // 30')"
sha="$(git rev-parse HEAD 2>/dev/null || echo none)"
hash256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
run_id="$(date +%s)$$"

# comparison: scripts/harness-compare.jq, fed {expect, assertions, actual}; prints one check object per expect key
CMP_FILE="$HERE/harness-compare.jq"

# exec_step <step-json> <dir> <default-adapter>  ->  STEP_STATUS (pass|fail|error|blocked), STEP_CHECKS, STEP_DETAIL
exec_step() {
  local sj="$1" d="$2" default_adapter="$3" adapter arc
  mkdir -p "$d"
  jq --arg ns "$RALPH_NAMESPACE" 'walk(if type == "string" then gsub("\\{\\{namespace\\}\\}"; $ns) else . end)' <<<"$sj" > "$d/example.json"
  adapter="$(jq -r '.adapter // ""' "$d/example.json")"; adapter="${adapter:-$default_adapter}"
  if [[ -z "$adapter" ]]; then echo "replay: not configured (set replay.adapter, or a preset api/web/cli, in $CFG)" >&2; exit 4; fi
  [[ "$adapter" =~ ^(http|cli)$ ]] || die "unknown adapter '$adapter' (http or cli)"
  if [[ "$adapter" == http && -z "$BASE_URL" ]]; then echo "replay: not configured (set replay.base_url in $CFG or BASE_URL)" >&2; exit 4; fi
  if [[ "$adapter" == cli && -z "$REPLAY_COMMAND" ]]; then echo "replay: not configured (set replay.command in $CFG)" >&2; exit 4; fi
  arc=0; "$HERE/adapters/$adapter.sh" "$d/example.json" "$d" > "$d/adapter.log" 2>&1 || arc=$?
  STEP_CHECKS='[]'; STEP_DETAIL="$(head -c 300 "$d/adapter.log")"
  case $arc in
    0) STEP_CHECKS="$(jq -c --slurpfile a "$d/actual.json" '{expect, assertions: (.assertions // {}), actual: $a[0]}' "$d/example.json" | jq -c -f "$CMP_FILE")"
       if jq -e 'all(.[]; .pass)' <<<"$STEP_CHECKS" >/dev/null; then STEP_STATUS=pass; else STEP_STATUS=fail; fi ;;
    3) STEP_STATUS=blocked ;;
    *) STEP_STATUS=error ;;
  esac
}

any_fail=0; any_blocked=0; total_ex=0; passed_ex=0; gn=0
while IFS=$'\t' read -r _ j; do
  [[ -z "$j" ]] && continue
  exid="$(jq -r .id <<<"$j")"; name="$(jq -r .name <<<"$j")"
  sj="$(steps_of "$j")"; nsteps="$(jq length <<<"$sj")"; multi="$(jq 'has("steps")' <<<"$j")"
  sel=(); for ((i = 0; i < nsteps; i++)); do gn=$((gn + 1)); [[ $gn -ge $FROM && $gn -le $TO ]] && sel+=("$i:$gn"); done
  [[ -n "$ONLY" && "$ONLY" != "$exid" ]] && continue
  [[ ${#sel[@]} -eq 0 ]] && continue
  total_ex=$((total_ex + 1))
  partial=false; [[ ${#sel[@]} -lt $nsteps ]] && partial=true

  dir="$HARNESS_DIR/evidence/$ID/$exid"; rm -rf "$dir"; mkdir -p "$dir"
  printf '%s\n' "$j" > "$dir/example.json"
  export RALPH_NAMESPACE="ralph_${ID}_${exid}_${run_id}"
  ex_adapter="$(jq -r '.adapter // ""' <<<"$j")"; ex_adapter="${ex_adapter:-$cfg_adapter}"
  t0="$(date +%s)"; ex_status=pass; ex_detail=""; step_results='[]'; all_checks='[]'

  # fixtures: setup (any failure aborts the example), then the selected steps, then cleanup (always, unless --keep)
  k=0
  while IFS= read -r fx; do
    [[ -z "$fx" ]] && continue; k=$((k + 1))
    exec_step "$fx" "$dir/setup-$k" "$ex_adapter"
    if [[ "$STEP_STATUS" != pass ]]; then ex_status="$STEP_STATUS"; ex_detail="setup $k failed: $STEP_DETAIL"; break; fi
  done < <(jq -c '(.setup // [])[]' <<<"$j")

  if [[ "$ex_status" == pass ]]; then
    for pair in "${sel[@]}"; do
      i="${pair%%:*}"; num="${pair##*:}"
      sdir="$dir"; [[ "$multi" == true ]] && sdir="$dir/step-$((i + 1))"
      exec_step "$(jq -c --argjson i "$i" '.[$i]' <<<"$sj")" "$sdir" "$ex_adapter"
      step_results="$(jq -c --argjson n "$num" --arg s "$STEP_STATUS" --arg nm "$(jq -r --argjson i "$i" '.[$i].name // "step \($i + 1)"' <<<"$sj")" --argjson c "$STEP_CHECKS" \
                        '. + [{n: $n, name: $nm, status: $s, checks: $c}]' <<<"$step_results")"
      all_checks="$(jq -c --argjson c "$STEP_CHECKS" '. + $c' <<<"$all_checks")"
      if [[ "$STEP_STATUS" != pass ]]; then ex_status="$STEP_STATUS"; ex_detail="step $num: $STEP_DETAIL"; break; fi
    done
  fi

  cleanup_failed=false
  if [[ $KEEP -eq 0 ]]; then
    k=0
    while IFS= read -r fx; do
      [[ -z "$fx" ]] && continue; k=$((k + 1))
      exec_step "$fx" "$dir/cleanup-$k" "$ex_adapter"
      [[ "$STEP_STATUS" != pass ]] && { cleanup_failed=true; echo "replay: WARNING cleanup $k of $ID/$exid failed ($RALPH_NAMESPACE): $STEP_DETAIL" >&2; }
    done < <(jq -c '(.cleanup // [])[]' <<<"$j")
  fi

  exsha="$(jq -cS . <<<"$j" | hash256)"
  jq -n --arg id "$ID" --arg ex "$exid" --arg n "$name" --arg s "$ex_status" --arg sha "$sha" --arg exsha "$exsha" --arg ad "$ex_adapter" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson dur "$(( $(date +%s) - t0 ))" --argjson c "$all_checks" --argjson st "$step_results" \
        --arg detail "$ex_detail" --argjson partial "$partial" --argjson total "$nsteps" --argjson selected "${#sel[@]}" \
        --arg ns "$RALPH_NAMESPACE" --argjson kept "$([[ $KEEP -eq 1 ]] && echo true || echo false)" --argjson cf "$cleanup_failed" \
        '{feature: $id, example: $ex, name: $n, status: $s, adapter: $ad, commit_sha: $sha, example_sha: $exsha, at: $at, duration_s: $dur,
          partial: $partial, total_steps: $total, selected_steps: $selected, namespace: $ns, kept: $kept, cleanup_failed: $cf,
          checks: $c, steps: $st, detail: $detail}' > "$dir/result.json"

  label="$ID/$exid"; [[ "$partial" == true ]] && label="$label (steps ${sel[0]##*:}-${sel[${#sel[@]}-1]##*:} of $nsteps)"
  case "$ex_status" in
    pass) passed_ex=$((passed_ex + 1)); [[ $QUIET -eq 1 ]] || echo "PASS  $label  $name" ;;
    fail) any_fail=1; echo "FAIL  $label  $name"
          jq -r '.steps[]? | select(.status != "pass") | .n as $n | .checks[]? | select(.pass | not) | "      step \($n) \(.key) (\(.mode)): expected \(.expected | tojson | .[0:160]) got \(if .present then (.actual | tojson | .[0:160]) else "<missing>" end)"' "$dir/result.json" ;;
    blocked) any_blocked=1; echo "BLOCKED  $label  $name: $ex_detail" ;;
    *) any_fail=1; echo "ERROR  $label  $name: $ex_detail" ;;
  esac
  [[ $KEEP -eq 1 ]] && jq -e '(.setup // []) + (.cleanup // []) | length > 0' <<<"$j" >/dev/null && echo "      kept test data: namespace $RALPH_NAMESPACE (not cleaned up)"
done <<<"$examples"

[[ $total_ex -eq 0 ]] && die "no steps selected (--step/--from/--to out of range?)"
[[ $QUIET -eq 1 ]] || echo "replay $ID: $passed_ex/$total_ex examples passed (evidence: $HARNESS_DIR/evidence/$ID/)"
[[ $any_blocked -eq 1 ]] && exit 3
[[ $any_fail -eq 1 ]] && exit 1
exit 0
