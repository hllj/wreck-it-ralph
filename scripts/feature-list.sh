#!/bin/bash
# feature-list.sh - the ONLY sanctioned way to change .harness/feature_list.json.
#
# Agents may change status (claim / pass / fail) but never the spec itself
# (description, steps, ...). `lock`/`verify-lock`/`restore` enforce that.
#
# Usage: feature-list.sh <command> [args]
#   list [--failing]        list features (id, status, description)
#   next                    print the highest-priority feature that is not passing
#   stats                   print "<passing>/<total> (<claimed> awaiting verification)"
#   claim <ID>              coder: implementation done, awaiting tester verification
#   pass <ID>               tester (or runner when no tester): verified end-to-end
#   fail <ID> [note]        verification failed; clears claim, records note
#   claimed                 print ids of claimed (unverified) features
#   done                    exit 0 if every feature passes, else 1
#   validate                check the file schema
#   lock                    snapshot the immutable spec (run once after the initializer)
#   verify-lock             exit 1 if the spec was edited since `lock`
#   restore                 restore the spec from the lock snapshot, keeping statuses

set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-.harness}"
FILE="$HARNESS_DIR/feature_list.json"
LOCK="$HARNESS_DIR/.feature_list.lock.json"

die() { echo "feature-list: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
[[ -f "$FILE" ]] || die "$FILE not found (run /wreck-it-ralph-loop:harness-init first)"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write() { # write jq filter result atomically
  local tmp="$FILE.tmp.$$"
  jq "$@" "$FILE" > "$tmp" && mv "$tmp" "$FILE"
}

need_id() {
  [[ -n "${1:-}" ]] || die "missing feature id"
  jq -e --arg id "$1" '.features[] | select(.id == $id)' "$FILE" >/dev/null || die "unknown feature id: $1"
}

spec_json() { jq -S '[.features[] | del(.passes, .claimed, .notes, .updated_at)]' "$1"; }

cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    filter='.'
    [[ "${1:-}" == "--failing" ]] && filter='select(.passes != true)'
    jq -r ".features[] | $filter | \"\(.id)\t\(if .passes then \"PASS\" elif .claimed then \"CLAIMED\" else \"FAIL\" end)\t\(.description)\"" "$FILE"
    ;;
  next)
    jq -r '[.features[] | select(.passes != true and .claimed != true)] | sort_by(.priority // 999, .id) | .[0] // empty | "\(.id)\t\(.description)"' "$FILE"
    ;;
  stats)
    jq -r '"\([.features[] | select(.passes == true)] | length)/\(.features | length) passing (\([.features[] | select(.claimed == true and .passes != true)] | length) awaiting verification)"' "$FILE"
    ;;
  claim)
    need_id "${1:-}"
    write --arg id "$1" --arg t "$(now)" '(.features[] | select(.id == $id)) |= (.claimed = true | .updated_at = $t)'
    echo "claimed $1"
    ;;
  pass)
    need_id "${1:-}"
    write --arg id "$1" --arg t "$(now)" '(.features[] | select(.id == $id)) |= (.passes = true | .claimed = false | .updated_at = $t)'
    echo "pass $1"
    ;;
  fail)
    need_id "${1:-}"
    write --arg id "$1" --arg n "${2:-}" --arg t "$(now)" '(.features[] | select(.id == $id)) |= (.passes = false | .claimed = false | .notes = $n | .updated_at = $t)'
    echo "fail $1"
    ;;
  claimed)
    jq -r '.features[] | select(.claimed == true and .passes != true) | .id' "$FILE"
    ;;
  done)
    jq -e '(.features | length) > 0 and all(.features[]; .passes == true)' "$FILE" >/dev/null
    ;;
  validate)
    jq -e '
      (.features | type == "array" and length > 0) and
      all(.features[]; (.id | type == "string") and (.description | type == "string")
        and (.steps | type == "array" and length > 0) and (.passes | type == "boolean"))
      and ([.features[].id] | length == (unique | length))
    ' "$FILE" >/dev/null || die "invalid feature_list.json (need unique string ids, description, non-empty steps[], boolean passes)"
    echo "ok: $(jq '.features | length' "$FILE") features"
    ;;
  lock)
    cp "$FILE" "$LOCK"
    echo "locked spec of $(jq '.features | length' "$FILE") features"
    ;;
  verify-lock)
    [[ -f "$LOCK" ]] || exit 0
    [[ "$(spec_json "$FILE")" == "$(spec_json "$LOCK")" ]] || { echo "feature spec was modified (features may only change status)" >&2; exit 1; }
    ;;
  restore)
    [[ -f "$LOCK" ]] || die "no lock snapshot"
    tmp="$FILE.tmp.$$"
    jq --slurpfile cur "$FILE" '
      ($cur[0].features | map({key: .id, value: {passes, claimed, notes, updated_at}}) | from_entries) as $st
      | .features |= map(. + ($st[.id] // {}) | with_entries(select(.value != null)))
    ' "$LOCK" > "$tmp" && mv "$tmp" "$FILE"
    echo "restored spec from lock"
    ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
esac
