#!/bin/bash
# harness-replay.sh - replay a feature's locked examples against the RUNNING application.
#
# The engine, not the coder, evaluates the results: examples are data, an adapter performs the call,
# and the comparison below produces PASS/FAIL. The coder cannot change the examples (spec lock) and
# cannot supply its own evaluation logic.
#
# Usage: replay.sh <ID> [--example EX001] [--list] [--quiet]
# Exit:  0 all examples passed   1 at least one failed   2 usage / bad example
#        3 blocked (app unreachable / command not runnable)   4 replay not configured
#
# Config (.harness/config.json -> replay): adapter (http|cli; default from preset: api/web -> http,
# cli -> cli), base_url (or env BASE_URL), command (cli adapter, e.g. "./bin/mytool"), timeout_seconds.
# An example may set its own "adapter". Comparison modes per expect key (assertions): exact | partial
# (expected is a subset of actual) | contains | regex; default exact, partial when expected is an object.
# Evidence per run: .harness/evidence/<ID>/<EX>/{request.json,actual.json,result.json,*.log} (git-ignored).

set -uo pipefail
HARNESS_DIR="${HARNESS_DIR:-.harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
FL="$HERE/feature-list.sh"; CFG="$HARNESS_DIR/config.json"
die() { echo "replay: $*" >&2; exit 2; }
command -v jq >/dev/null || die "jq is required"

ID="${1:-}"; shift || true
[[ -n "$ID" ]] || die "usage: replay.sh <ID> [--example EX001] [--list] [--quiet]"
ONLY=""; LIST=0; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --example) ONLY="${2:?example id}"; shift 2 ;;
    --list) LIST=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done

examples="$("$FL" examples "$ID")" || exit 2
[[ -n "$examples" ]] || die "$ID has no examples"
if [[ -n "$ONLY" ]]; then
  examples="$(while IFS=$'\t' read -r f j; do jq -e --arg o "$ONLY" '.id == $o' <<<"$j" >/dev/null && printf '%s\t%s\n' "$f" "$j"; done <<<"$examples")"
  [[ -n "$examples" ]] || die "$ID has no example $ONLY"
fi
if [[ $LIST -eq 1 ]]; then
  while IFS=$'\t' read -r _ j; do jq -r '"\(.id)\t\(.name)"' <<<"$j"; done <<<"$examples"; exit 0
fi

cfg() { jq -r "$1" "$CFG" 2>/dev/null; }
preset="$(cfg '.preset // ""')"
cfg_adapter="$(cfg '.replay.adapter // ""')"
if [[ -z "$cfg_adapter" ]]; then case "$preset" in api|web) cfg_adapter=http ;; cli) cfg_adapter=cli ;; esac; fi
export BASE_URL="${BASE_URL:-$(cfg '.replay.base_url // ""')}"
export REPLAY_COMMAND="$(cfg '.replay.command // ""')"
export REPLAY_TIMEOUT="$(cfg '.replay.timeout_seconds // 30')"
sha="$(git rev-parse HEAD 2>/dev/null || echo none)"
run_id="$(date +%s)$$"

# comparison: jq program, fed {expect, assertions, actual}; prints one check object per expect key
CMP='
def sub($e; $a):
  if ($e | type) == "object" then (($a | type) == "object") and ($e | to_entries | all(. as $kv | ($a | has($kv.key)) and sub($kv.value; $a[$kv.key])))
  elif ($e | type) == "array" then (($a | type) == "array") and (($e | length) == ($a | length)) and ([range(0; $e | length)] | all(. as $i | sub($e[$i]; $a[$i])))
  else $e == $a end;
def chk($m; $e; $a):
  if $m == "exact" then $e == $a
  elif $m == "partial" then sub($e; $a)
  elif $m == "contains" then
    (if ($a | type) == "string" then ($a | contains($e | tostring))
     elif ($a | type) == "array" then (if ($e | type) == "array" then ($e | all(. as $x | $a | index([$x]) != null)) else ($a | index([$e]) != null) end)
     else false end)
  elif $m == "regex" then (try (($a | tostring) | test($e | tostring)) catch false)
  else false end;
.actual as $act | .assertions as $as
| .expect | to_entries | map(
    .key as $k | .value as $e
    | ($as[$k] // (if ($e | type) == "object" then "partial" else "exact" end)) as $m
    | {key: $k, mode: $m, expected: $e, actual: ($act[$k] // null), present: ($act | has($k))}
    | .pass = (.present and chk(.mode; .expected; .actual)))'

any_fail=0; any_blocked=0; total=0; passed=0
while IFS=$'\t' read -r _ j; do
  [[ -z "$j" ]] && continue
  total=$((total + 1))
  exid="$(jq -r .id <<<"$j")"; name="$(jq -r .name <<<"$j")"
  adapter="$(jq -r '.adapter // ""' <<<"$j")"; adapter="${adapter:-$cfg_adapter}"
  if [[ -z "$adapter" ]]; then echo "replay: not configured (set replay.adapter, or a preset api/web/cli, in $CFG)" >&2; exit 4; fi
  [[ "$adapter" =~ ^(http|cli)$ ]] || die "$exid: unknown adapter '$adapter' (http or cli)"
  if [[ "$adapter" == http && -z "$BASE_URL" ]]; then echo "replay: not configured (set replay.base_url in $CFG or BASE_URL)" >&2; exit 4; fi
  if [[ "$adapter" == cli && -z "$REPLAY_COMMAND" ]]; then echo "replay: not configured (set replay.command in $CFG)" >&2; exit 4; fi

  dir="$HARNESS_DIR/evidence/$ID/$exid"; rm -rf "$dir"; mkdir -p "$dir"
  printf '%s\n' "$j" > "$dir/example.json"
  export RALPH_NAMESPACE="ralph_${ID}_${exid}_${run_id}"
  t0="$(date +%s)"; arc=0
  "$HERE/adapters/$adapter.sh" "$dir/example.json" "$dir" > "$dir/adapter.log" 2>&1 || arc=$?
  status=""
  case $arc in
    0) checks="$(jq -c --slurpfile a "$dir/actual.json" '{expect, assertions: (.assertions // {}), actual: $a[0]}' "$dir/example.json" | jq -c "$CMP")"
       if jq -e 'all(.[]; .pass)' <<<"$checks" >/dev/null; then status=pass; else status=fail; fi ;;
    3) status=blocked; checks='[]' ;;
    *) status=error; checks='[]' ;;
  esac
  jq -n --arg id "$ID" --arg ex "$exid" --arg n "$name" --arg s "$status" --arg sha "$sha" --arg ad "$adapter" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson dur "$(( $(date +%s) - t0 ))" --argjson c "$checks" --arg log "$(head -c 300 "$dir/adapter.log")" \
        '{feature: $id, example: $ex, name: $n, status: $s, adapter: $ad, commit_sha: $sha, at: $at, duration_s: $dur, checks: $c, detail: $log}' > "$dir/result.json"
  case "$status" in
    pass) passed=$((passed + 1)); [[ $QUIET -eq 1 ]] || echo "PASS  $ID/$exid  $name" ;;
    fail) any_fail=1; echo "FAIL  $ID/$exid  $name"
          jq -r '.checks[] | select(.pass | not) | "      \(.key) (\(.mode)): expected \(.expected | tojson | .[0:160]) got \(if .present then (.actual | tojson | .[0:160]) else "<missing>" end)"' "$dir/result.json" ;;
    blocked) any_blocked=1; echo "BLOCKED  $ID/$exid  $name: $(head -c 200 "$dir/adapter.log")" ;;
    *) any_fail=1; echo "ERROR  $ID/$exid  $name: $(head -c 200 "$dir/adapter.log")" ;;
  esac
done <<<"$examples"

[[ $QUIET -eq 1 ]] || echo "replay $ID: $passed/$total examples passed (evidence: $HARNESS_DIR/evidence/$ID/)"
[[ $any_blocked -eq 1 ]] && exit 3
[[ $any_fail -eq 1 ]] && exit 1
exit 0
