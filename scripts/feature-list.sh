#!/bin/bash
# feature-list.sh - the ONLY sanctioned way to change .harness/feature_list.json.
#
# Agents may change status (claim / pass / fail / ask) but never the spec itself
# (description, steps, verify, depends_on, ...). `lock`/`verify-lock`/`restore` enforce that.
# The spec grows or changes only through approved proposals (see backlog.sh).
#
# Usage: feature-list.sh <command> [args]
#   list [--failing | --status S]   list features (id, STATUS, description)
#   next                    highest-priority READY feature (todo/failing, dependencies passing)
#   batch <N>               up to N ready features that can be built in parallel: the next one, plus
#                           others whose tags are disjoint from the batch (untagged features never fan out)
#   stats                   "<passing>/<total> passing (<claimed> awaiting verification)[, <n> need a human]"
#   show <ID>               print one feature as JSON
#   claim <ID>              coder: implementation done, awaiting verification
#   pass <ID>               tester (or runner when no tester): verified end-to-end
#   fail <ID> [note]        verification failed; records the note in the attempt history
#   blocked <ID> <reason>   tester: could not be verified (app/environment). Stays claimed, NOT a failed attempt
#   blocked-ids [--since T] claimed features whose latest event is `blocked` (optionally at/after ISO time T)
#   ask <ID> <question>     escalate: the feature needs a human decision (status needs_human)
#   requeue <ID> <note>     gate: put a feature back in the queue without counting a failure
#                           (a parallel worker's merge conflict); it then runs alone, never in a parallel batch
#   answer <ID> <text>      human: answer the question; the feature becomes ready again
#   questions               print "<id>\t<question>" for every feature that needs a human
#   claimed                 print ids of claimed (unverified) features
#   ids [--status S]        print ids (optionally only those with status S)
#   count <status>          number of features with that status
#   failures <ID>           failed attempts since the last human answer
#   verify-cmds [ID]        verify commands of one feature (or of all features)
#   done                    exit 0 if every feature that is not dropped passes, else 1
#   examples [ID]           print "<feature>\t<example json>" for the locked examples (one feature or all)
#   next-example-id <ID>    the next free EXnnn for a feature
#   examples-missing        print ids of live features that have no examples yet
#   red <ID> [--skip WHY | --note TEXT]
#                           coder: prove RED before implementing. Runs the feature's verify commands and
#                           requires at least one to FAIL. --skip WHY (feature already works / refactor) or
#                           --note TEXT (no verify commands: what you ran and saw) log it without running.
#                           `claim` refuses a feature that has examples until RED was recorded.
#   validate [--file PATH]  check the file schema
#   lock                    snapshot the immutable spec (run after the initializer / an approval)
#   verify-lock             exit 1 if the spec was edited since `lock`
#   restore                 restore the spec from the lock snapshot, keeping statuses
#
# Statuses: todo | claimed | passing | failing | needs_human | dropped (dropped is part of the spec).
# v2 files (passes/claimed booleans, no status) are read transparently.

set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-.harness}"
FILE="$HARNESS_DIR/feature_list.json"
LOCK="$HARNESS_DIR/.feature_list.lock.json"

die() { echo "feature-list: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Shared jq definitions. `st` derives the status for v2 files that only have passes/claimed.
DEFS='
def st: if .dropped == true then "dropped"
  else (.status // (if .passes == true then "passing" elif .claimed == true then "claimed"
                    elif ((.notes // "") != "") then "failing" else "todo" end)) end;
def lbl: {"passing":"PASS","claimed":"CLAIMED","failing":"FAIL","todo":"TODO","needs_human":"NEEDS_HUMAN","dropped":"DROPPED"}[st] // "?";
def live: select(.dropped != true);
def setst($s; $t): .status = $s | .passes = ($s == "passing") | del(.claimed) | .updated_at = $t;
def logev($e; $n; $t): .attempts = (((.attempts // []) + [{at: $t, event: $e, note: $n}]) | .[-20:]);
def verifies: (.verify // []) | if type == "string" then [.] else . end | map(select(type == "string" and length > 0));
def has_red: (.attempts // []) as $a
  | ([$a | to_entries[] | select(.value.event | IN("fail", "requeue", "answer", "claim")) | .key] | max // -1) as $last
  | any($a | to_entries[]; .key > $last and (.value.event | IN("red", "red-skip")));
def statuses: (.features | map({key: .id, value: st}) | from_entries);
def ready($s): live | select(st == "todo" or st == "failing")
  | select(all((.depends_on // [])[]; ($s[.] // "missing") as $d | $d == "passing" or $d == "dropped"));
'
SPEC_STATE_FIELDS='passes, claimed, status, notes, updated_at, attempts, question, answer'   # status-only fields
SPEC_STATE_PATHS='.passes, .claimed, .status, .notes, .updated_at, .attempts, .question, .answer'

q() { jq -r "$DEFS $1" "${@:2}" "$FILE"; }       # filter [jq args...]
write() { # filter [jq args...]  (atomic)
  local f="$1" tmp="$FILE.tmp.$$"; shift
  jq "$DEFS $f" "$@" "$FILE" > "$tmp" && mv "$tmp" "$FILE"
}
need_id() {
  [[ -n "${1:-}" ]] || die "missing feature id"
  jq -e --arg id "$1" '.features[] | select(.id == $id)' "$FILE" >/dev/null || die "unknown feature id: $1"
}
upd() { # id filter-on-feature [jq args...]
  local id="$1" f="$2"; shift 2
  write "(.features[] | select(.id == \$id)) |= ($f)" --arg id "$id" --arg t "$(now)" "$@"
}
spec_json() { jq -S "[.features[] | del($SPEC_STATE_PATHS)]" "$1"; }

validate_file() { # path
  jq -e "$DEFS"'
    def okmodes: ((.assertions // {}) | type == "object" and all(.[]; IN("exact", "partial", "contains", "regex")));
    def okio: type == "object" and has("input") and (.expect | type == "object" and length > 0) and okmodes;
    def okfix: type == "object" and has("input") and ((.expect // {}) | type == "object") and okmodes;
    def okex:
      type == "object"
      and (.id | type == "string" and test("^EX[0-9]+$"))
      and (.name | type == "string" and length > 0)
      and (if has("steps") then (.steps | type == "array" and length > 0 and all(.[]; okio)) else okio end)
      and ((.setup // []) | type == "array" and all(.[]; okfix))
      and ((.cleanup // []) | type == "array" and all(.[]; okfix));
    def okfeature($ids):
      (.id | type == "string")
      and (.description | type == "string")
      and (.steps | type == "array" and length > 0)
      and ((.passes | type == "boolean") or (.status | type == "string"))
      and ((.status // "todo") | IN("todo", "claimed", "passing", "failing", "needs_human"))
      and ((.depends_on // []) | type == "array" and all(.[]; . as $d | $ids | index($d) != null))
      and ((.verify // []) | (type == "string") or (type == "array" and all(.[]; type == "string")))
      and ((.examples // []) | type == "array" and all(.[]; okex) and ([.[].id] | length == (unique | length)));
    (.features | type == "array" and length > 0)
    and ([.features[].id] | length == (unique | length))
    and ([.features[].id] as $ids | all(.features[]; okfeature($ids)))
  ' "$1" >/dev/null
}

cmd="${1:-}"; shift || true
[[ "$cmd" == "validate" || "$cmd" == "" || "$cmd" == "-h" || "$cmd" == "--help" || -f "$FILE" ]] \
  || die "$FILE not found (run /wreck-it-ralph:init first)"

case "$cmd" in
  list)
    filter='.'
    case "${1:-}" in
      --failing) filter='select(st != "passing" and st != "dropped")' ;;
      --status)  filter="select(st == \"${2:?status required}\")" ;;
    esac
    q ".features[] | $filter | \"\(.id)\t\(lbl)\t\(.description)\""
    ;;
  next)
    q '(statuses) as $s | [.features[] | ready($s)] | sort_by(.priority // 999, .id) | .[0] // empty | "\(.id)\t\(.description)"'
    ;;
  batch)
    [[ "${1:-}" =~ ^[0-9]+$ ]] || die "usage: batch <N>"
    # A tag that every live feature carries (e.g. "cli" in a CLI project) says nothing about
    # the area a feature touches, so it is ignored when checking for overlap.
    q '([.features[] | live | (.tags // [])]) as $all
       | (if ($all | length) > 1 then reduce $all[1:][] as $t ($all[0]; . - (. - $t)) else [] end) as $common
       | def area: (.tags // []) - $common;
       (statuses) as $s | ([.features[] | ready($s)] | sort_by(.priority // 999, .id)) as $r
       | if ($r | length) == 0 then empty else
         reduce $r[1:][] as $f ({b: [$r[0]], tags: ($r[0] | area),
                                 open: ((($r[0] | area | length) > 0) and (any(($r[0].attempts // [])[]; .event == "requeue") | not))};
            if (.open | not) or (.b | length) >= $max then .
            elif ($f | area | length) == 0 then .
            elif any(($f.attempts // [])[]; .event == "requeue") then .
            elif (.tags as $u | [($f | area)[] | select(. as $x | $u | index($x))] | length) > 0 then .
            else .b += [$f] | .tags += ($f | area) end)
         | .b[].id end' --argjson max "$1"
    ;;
  stats)
    q '[.features[] | live] as $f
       | ([$f[] | select(st == "needs_human")] | length) as $h
       | "\([$f[] | select(st == "passing")] | length)/\($f | length) passing (\([$f[] | select(st == "claimed")] | length) awaiting verification)"
         + (if $h > 0 then ", \($h) need a human" else "" end)'
    ;;
  show)
    need_id "${1:-}"; q '.features[] | select(.id == $id)' --arg id "$1"
    ;;
  claim)
    need_id "${1:-}"
    [[ "$(q '.features[] | select(.id == $id) | ((.examples // []) | length > 0) and (has_red | not)' --arg id "$1")" == "true" ]] \
      && die "$1 has locked examples but no RED was recorded: run '.harness/feature-list.sh red $1' BEFORE implementing (or 'red $1 --skip \"<why>\"')"
    upd "$1" 'setst("claimed"; $t) | logev("claim"; ""; $t)'
    echo "claimed $1"
    ;;
  pass)
    need_id "${1:-}"
    upd "$1" 'setst("passing"; $t) | logev("pass"; ""; $t)'
    echo "pass $1"
    ;;
  fail)
    need_id "${1:-}"
    upd "$1" 'setst("failing"; $t) | .notes = $n | logev("fail"; $n; $t)' --arg n "${2:-}"
    echo "fail $1"
    ;;
  blocked)
    need_id "${1:-}"; [[ -n "${2:-}" ]] || die "usage: blocked <ID> <reason>"
    upd "$1" '(if st == "claimed" then . else setst("claimed"; $t) end) | logev("blocked"; $n; $t)' --arg n "$2"
    echo "blocked $1"
    ;;
  blocked-ids)
    since=""; [[ "${1:-}" == "--since" ]] && since="${2:-}"
    q '.features[] | live | select(st == "claimed" and ((.attempts // [])[-1] | (.event // "") == "blocked" and (.at // "") >= $s)) | .id' --arg s "$since"
    ;;
  ask)
    need_id "${1:-}"; [[ -n "${2:-}" ]] || die "usage: ask <ID> <question>"
    upd "$1" 'setst("needs_human"; $t) | .question = $n | logev("ask"; $n; $t)' --arg n "$2"
    echo "needs_human $1"
    ;;
  requeue)
    need_id "${1:-}"
    upd "$1" 'setst("todo"; $t) | .notes = $n | logev("requeue"; $n; $t)' --arg n "${2:-}"
    echo "requeued $1"
    ;;
  answer)
    need_id "${1:-}"; [[ -n "${2:-}" ]] || die "usage: answer <ID> <text>"
    upd "$1" '(if st == "needs_human" then setst("todo"; $t) else . end) | .answer = $n | del(.question) | logev("answer"; $n; $t)' --arg n "$2"
    echo "answered $1"
    ;;
  questions)
    q '.features[] | live | select(st == "needs_human") | "\(.id)\t\(.question // "")"'
    ;;
  table) # markdown rows for the run summary
    q '.features[] | "| \(.id) | \(lbl) | \(.description | .[0:70]) | \(if st == "passing" then "" else (.question // .notes // "") end | gsub("\\|"; "/") | .[0:80]) |"'
    ;;
  claimed)
    q '.features[] | live | select(st == "claimed") | .id'
    ;;
  ids)
    if [[ "${1:-}" == "--status" ]]; then q '.features[] | select(st == $s) | .id' --arg s "${2:?status required}"
    else q '.features[].id'; fi
    ;;
  count)
    q '[.features[] | select(st == $s)] | length' --arg s "${1:?status required}"
    ;;
  failures)
    need_id "${1:-}"
    q '.features[] | select(.id == $id) | (.attempts // []) as $a
       | ([$a | to_entries[] | select(.value.event == "answer") | .key] | max // -1) as $last
       | [$a | to_entries[] | select(.key > $last and .value.event == "fail")] | length' --arg id "$1"
    ;;
  verify-cmds)
    if [[ -n "${1:-}" ]]; then need_id "$1"; q '.features[] | select(.id == $id) | verifies[]' --arg id "$1"
    else q '.features[] | live | verifies[] '; fi
    ;;
  done)
    jq -e "$DEFS"' [.features[] | live] | length > 0 and all(.[]; st == "passing")' "$FILE" >/dev/null
    ;;
  examples)
    if [[ -n "${1:-}" ]]; then need_id "$1"; q '.features[] | select(.id == $id) | .id as $i | (.examples // [])[] | "\($i)\t\(tojson)"' --arg id "$1"
    else q '.features[] | live | .id as $i | (.examples // [])[] | "\($i)\t\(tojson)"'; fi
    ;;
  next-example-id)
    need_id "${1:-}"
    q '.features[] | select(.id == $id) | ([(.examples // [])[].id | select(test("^EX[0-9]+$")) | ltrimstr("EX") | tonumber] | max // 0) + 1 | "EX" + (tostring | if length < 3 then ("00" + .)[-3:] else . end)' --arg id "$1"
    ;;
  examples-missing)
    q '.features[] | live | select(((.examples // []) | length) == 0) | .id'
    ;;
  red)
    need_id "${1:-}"; id="$1"; shift
    mode="run"; why=""
    case "${1:-}" in
      --skip) mode="skip"; why="${2:-}"; [[ -n "$why" ]] || die "usage: red <ID> --skip <reason>" ;;
      --note) mode="note"; why="${2:-}"; [[ -n "$why" ]] || die "usage: red <ID> --note <what you ran and saw>" ;;
      "") ;;
      *) die "usage: red <ID> [--skip WHY | --note TEXT]" ;;
    esac
    if [[ "$mode" == "skip" ]]; then
      upd "$id" 'logev("red-skip"; $n; $t)' --arg n "$why"; echo "red-skip $id"; exit 0
    fi
    cmds="$(q '.features[] | select(.id == $id) | verifies[]' --arg id "$id")"
    has_ex="$(q '.features[] | select(.id == $id) | ((.examples // []) | length) > 0' --arg id "$id")"
    # examples are replayed against the running app by the engine (rc: 0 pass, 1 fail, 3 blocked, 4 not configured)
    rrc=4; rout=""
    if [[ "$has_ex" == "true" && -x "$(dirname "$0")/harness-replay.sh" ]]; then
      rrc=0; rout="$("$(dirname "$0")/harness-replay.sh" "$id" 2>&1)" || rrc=$?
    fi
    failed=0; sum=""
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      rc=0; bash -c "$c" >/dev/null 2>&1 < /dev/null || rc=$?
      [[ $rc -ne 0 ]] && failed=$((failed+1))
      sum="$sum[$rc] $c; "
    done <<<"$cmds"
    [[ $rrc -eq 1 ]] && { failed=$((failed+1)); sum="${sum}replay: failing examples; "; }
    if [[ $failed -eq 0 ]]; then
      if [[ "$mode" == "note" && -z "$cmds" && ( $rrc -eq 4 || $rrc -eq 3 ) ]]; then
        upd "$id" 'logev("red"; $n; $t)' --arg n "$why"; echo "red $id (noted)"; exit 0
      fi
      [[ $rrc -eq 3 ]] && die "$id: cannot prove RED, the app is not reachable ($(tail -n 3 <<<"$rout" | tr '\n' ' ')). Start it (.harness/init.sh) and retry"
      if [[ -z "$cmds" && $rrc -eq 4 ]]; then
        die "$id has no verify commands and replay is not configured: run its examples by hand against the app and record 'red $id --note \"<command, observed failure>\"'"
      fi
      die "$id is not RED: every verify command and example already passes. Write the failing test/example first (or 'red $id --skip \"<why>\"' if the behaviour already exists)"
    fi
    upd "$id" 'logev("red"; $n; $t)' --arg n "$(cut -c1-300 <<<"$sum")"
    echo "red $id ($failed failing check(s))"
    ;;
  validate)
    f="$FILE"; [[ "${1:-}" == "--file" ]] && f="${2:?path required}"
    [[ -f "$f" ]] || die "$f not found"
    validate_file "$f" || die "invalid feature list $f (need unique string ids, description, non-empty steps[], boolean passes or a valid status, depends_on naming existing ids, verify as string or string[], examples[] with id EXnnn, name, input, non-empty expect object, assertions in exact|partial|contains|regex)"
    echo "ok: $(jq '.features | length' "$f") features"
    ;;
  lock)
    cp "$FILE" "$LOCK"
    echo "locked spec of $(jq '.features | length' "$FILE") features"
    ;;
  verify-lock)
    [[ -f "$LOCK" ]] || exit 0
    a="$(spec_json "$FILE")" || die "cannot read $FILE"; b="$(spec_json "$LOCK")" || die "cannot read $LOCK"
    [[ "$a" == "$b" ]] || { echo "feature spec was modified (features may only change status)" >&2; exit 1; }
    ;;
  restore)
    [[ -f "$LOCK" ]] || die "no lock snapshot"
    tmp="$FILE.tmp.$$"
    jq --slurpfile cur "$FILE" "
      (\$cur[0].features | map({key: .id, value: {$SPEC_STATE_FIELDS}}) | from_entries) as \$st
      | .features |= map(. + (\$st[.id] // {}) | with_entries(select(.value != null)))
    " "$LOCK" > "$tmp" && mv "$tmp" "$FILE"
    echo "restored spec from lock"
    ;;
  *)
    sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
esac
