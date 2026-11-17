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
#   stats                   "<passing>/<total> passing (<claimed> awaiting verification)[, <n> need a human]"
#   show <ID>               print one feature as JSON
#   claim <ID>              coder: implementation done, awaiting verification
#   pass <ID>               tester (or runner when no tester): verified end-to-end
#   fail <ID> [note]        verification failed; records the note in the attempt history
#   ask <ID> <question>     escalate: the feature needs a human decision (status needs_human)
#   answer <ID> <text>      human: answer the question; the feature becomes ready again
#   questions               print "<id>\t<question>" for every feature that needs a human
#   claimed                 print ids of claimed (unverified) features
#   ids [--status S]        print ids (optionally only those with status S)
#   count <status>          number of features with that status
#   failures <ID>           failed attempts since the last human answer
#   verify-cmds [ID]        verify commands of one feature (or of all features)
#   done                    exit 0 if every feature that is not dropped passes, else 1
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
    def okfeature($ids):
      (.id | type == "string")
      and (.description | type == "string")
      and (.steps | type == "array" and length > 0)
      and ((.passes | type == "boolean") or (.status | type == "string"))
      and ((.status // "todo") | IN("todo", "claimed", "passing", "failing", "needs_human"))
      and ((.depends_on // []) | type == "array" and all(.[]; . as $d | $ids | index($d) != null))
      and ((.verify // []) | (type == "string") or (type == "array" and all(.[]; type == "string")));
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
  ask)
    need_id "${1:-}"; [[ -n "${2:-}" ]] || die "usage: ask <ID> <question>"
    upd "$1" 'setst("needs_human"; $t) | .question = $n | logev("ask"; $n; $t)' --arg n "$2"
    echo "needs_human $1"
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
    q '.features[] | "| \(.id) | \(lbl) | \(.description | .[0:70]) | \((.question // .notes // "") | gsub("\\|"; "/") | .[0:80]) |"'
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
  validate)
    f="$FILE"; [[ "${1:-}" == "--file" ]] && f="${2:?path required}"
    [[ -f "$f" ]] || die "$f not found"
    validate_file "$f" || die "invalid feature list $f (need unique string ids, description, non-empty steps[], boolean passes or a valid status, depends_on naming existing ids, verify as string or string[])"
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
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
esac
