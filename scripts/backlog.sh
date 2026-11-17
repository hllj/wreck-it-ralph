#!/bin/bash
# backlog.sh - grow and change the locked feature list through human-approved proposals.
#
# Agents (planner, coder, tester) may only PROPOSE. A human approves with /wreck-it-ralph:backlog,
# which applies the proposal, re-validates, re-locks the spec and commits only the harness files.
# Approvals are refused while a loop session is in progress; one that sneaks in anyway is
# undone by `step.sh end` (it compares the lock with the snapshot taken at `begin`).
#
# Usage: backlog.sh <command> [args]
#   propose [--by NAME] --reason TEXT [--file PATH]   payload JSON on stdin or in PATH:
#           {"add":   [ {feature without status; id optional}, ... ],
#            "amend": [ {"id":"F012", "description"|"steps"|"verify"|"priority"|"depends_on"|"tags"|"category": ...}, ... ],
#            "drop":  [ "F013", ... ]}
#   list [--all]               pending proposals (or all)
#   show <PID>                 one proposal as JSON
#   approve <PID|all>          apply + re-lock + commit            (human only)
#   reject <PID> [reason]                                          (human only)
#   drop <ID> [reason]         propose + approve dropping a feature (human only)
#   priority <ID> <N>          propose + approve a new priority     (human only)

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
FILE="$HARNESS_DIR/feature_list.json"
PROPS="$HARNESS_DIR/proposals.json"
FL="$PLUGIN_ROOT/scripts/feature-list.sh"
# shellcheck source=harness-lib.sh
source "$PLUGIN_ROOT/scripts/harness-lib.sh"

die() { echo "backlog: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
[[ -f "$FILE" ]] || die "$FILE not found (run /wreck-it-ralph:init first)"
[[ -f "$PROPS" ]] || echo '{"proposals":[]}' > "$PROPS"
jq -e '.proposals | type == "array"' "$PROPS" >/dev/null 2>&1 || die "$PROPS is not valid (expected {\"proposals\": [...]})"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Apply a payload ($p) to a feature list (input). Pure jq so propose can dry-run it.
APPLY='
def st: if .dropped == true then "dropped"
  else (.status // (if .passes == true then "passing" elif .claimed == true then "claimed"
                    elif ((.notes // "") != "") then "failing" else "todo" end)) end;
def pad3: tostring | if length < 3 then ("00" + .)[-3:] else . end;
def nextid: ([.features[].id | select(test("^F[0-9]+$")) | ltrimstr("F") | tonumber] | max // 0) + 1 | "F" + pad3;
def maxprio: ([.features[].priority | numbers] | max // 0);
reduce ($p.amend // [])[] as $a (.;
  .features |= map(if .id != $a.id then . else
    ($a | with_entries(select(.key | IN("description","steps","verify","priority","depends_on","tags","category"))) | del(.id)) as $chg
    | . + $chg
    | if (($chg | has("description")) or ($chg | has("steps")) or ($chg | has("verify"))) and (st | IN("passing","claimed","failing"))
      then .status = "todo" | .passes = false | del(.claimed) else . end
  end))
| reduce ($p.drop // [])[] as $d (.; .features |= map(if .id == $d then .dropped = true else . end))
| reduce ($p.add // [])[] as $n (.;
    (if (($n.id // "") | length) > 0 and ([.features[].id] | index($n.id) | not) then $n.id else nextid end) as $id
    | (maxprio + 1) as $pr
    | .features += [ {category: "functional", priority: $pr}
                     + ($n | del(.status, .passes, .claimed, .notes, .attempts, .dropped, .question, .answer))
                     + {id: $id, passes: false, status: "todo", source: ("proposal:" + $pid)} ])
'

check_payload() { # payload-json
  jq -e 'type == "object" and ((.add // []) | type == "array") and ((.amend // []) | type == "array") and ((.drop // []) | type == "array")
         and (((.add // []) + (.amend // []) + (.drop // [])) | length > 0)
         and all((.amend // [])[]; type == "object" and (.id | type == "string"))
         and all((.drop // [])[]; type == "string")' <<<"$1" >/dev/null \
    || die "payload must be an object with non-empty add[] / amend[{id,...}] / drop[\"ID\"]"
  local id
  for id in $(jq -r '((.amend // []) | map(.id)) + (.drop // []) | .[]' <<<"$1"); do
    jq -e --arg id "$id" '.features[] | select(.id == $id)' "$FILE" >/dev/null || die "unknown feature id in payload: $id"
  done
}

dry_run() { # payload pid -> validated result on stdout
  local tmp; tmp="$(mktemp)"
  jq --argjson p "$1" --arg pid "$2" "$APPLY" "$FILE" > "$tmp" || { rm -f "$tmp"; die "could not apply payload"; }
  HARNESS_DIR="$HARNESS_DIR" "$FL" validate --file "$tmp" >/dev/null || { rm -f "$tmp"; die "the feature list would be invalid after this proposal"; }
  cat "$tmp"; rm -f "$tmp"
}

next_pid() { jq -r '([.proposals[].id | ltrimstr("P") | tonumber? ] | max // 0) + 1 | tostring | if length < 3 then ("00" + .)[-3:] else . end | "P" + .' "$PROPS"; }

props_write() { local tmp="$PROPS.tmp.$$"; jq "$@" "$PROPS" > "$tmp" && mv "$tmp" "$PROPS"; }

need_pid() { jq -e --arg id "${1:-}" '.proposals[] | select(.id == $id)' "$PROPS" >/dev/null || die "unknown proposal: ${1:-}"; }

refuse_in_session() {
  if session_in_progress; then
    die "a loop session is in progress; approvals made now would be undone. Stop the loop (/wreck-it-ralph:cancel) or approve between runs."
  fi
}

commit_backlog() { # message
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  git add -- "$FILE" "$HARNESS_DIR/.feature_list.lock.json" "$PROPS" 2>/dev/null || true
  git diff --cached --quiet -- "$FILE" "$HARNESS_DIR/.feature_list.lock.json" "$PROPS" && return 0
  git commit -qm "$1" -- "$FILE" "$HARNESS_DIR/.feature_list.lock.json" "$PROPS" >/dev/null 2>&1 \
    || echo "backlog: WARNING could not commit (git identity? hooks?); the change is applied but uncommitted" >&2
}

do_approve() { # pid
  local pid="$1" payload result tmp
  [[ "$(jq -r --arg id "$pid" '.proposals[] | select(.id == $id) | .status' "$PROPS")" == "pending" ]] || die "$pid is not pending"
  payload="$(jq -c --arg id "$pid" '.proposals[] | select(.id == $id) | .payload' "$PROPS")"
  check_payload "$payload"
  result="$(dry_run "$payload" "$pid")"
  tmp="$FILE.tmp.$$"; printf '%s\n' "$result" > "$tmp" && mv "$tmp" "$FILE"
  "$FL" lock >/dev/null
  props_write --arg id "$pid" --arg t "$(now)" '(.proposals[] | select(.id == $id)) |= (.status = "approved" | .decided_at = $t)'
  # The approver has seen the payload (incl. verify commands): extend trust to them if the config itself is trusted.
  "$PLUGIN_ROOT/scripts/harness-step.sh" trust accept-verify >/dev/null 2>&1 || true
  commit_backlog "backlog: approve $pid ($(jq -r --arg id "$pid" '.proposals[] | select(.id == $id) | .reason | .[0:60]' "$PROPS"))"
  echo "approved $pid: $("$FL" stats)"
}

do_propose() { # by reason payload -> prints pid
  local by="$1" reason="$2" payload="$3" pid
  check_payload "$payload"
  pid="$(next_pid)"
  dry_run "$payload" "$pid" >/dev/null
  props_write --arg id "$pid" --arg by "$by" --arg r "$reason" --arg t "$(now)" --argjson p "$payload" \
    '.proposals += [{id: $id, status: "pending", by: $by, reason: $r, at: $t, payload: $p}]'
  echo "$pid"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  propose)
    by="agent" reason="" file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --by) by="${2:?name required}"; shift 2 ;;
        --reason) reason="${2:?text required}"; shift 2 ;;
        --file) file="${2:?path required}"; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ -n "$reason" ]] || die "--reason is required"
    if [[ -n "$file" ]]; then payload="$(cat "$file")"; else payload="$(cat)"; fi
    payload="$(jq -c . <<<"$payload" 2>/dev/null)" || die "payload is not valid JSON"
    pid="$(do_propose "$by" "$reason" "$payload")"
    echo "proposed $pid (pending human approval: /wreck-it-ralph:backlog approve $pid)"
    ;;
  list)
    filter='select(.status == "pending")'; [[ "${1:-}" == "--all" ]] && filter='.'
    jq -r ".proposals[] | $filter | \"\(.id)\t\(.status)\t\(.by)\t+\((.payload.add // []) | length) ~\((.payload.amend // []) | length) -\((.payload.drop // []) | length)\t\(.reason)\"" "$PROPS"
    ;;
  show)
    need_pid "${1:-}"; jq --arg id "$1" '.proposals[] | select(.id == $id)' "$PROPS"
    ;;
  approve)
    refuse_in_session
    if [[ "${1:-}" == "all" ]]; then
      for pid in $(jq -r '.proposals[] | select(.status == "pending") | .id' "$PROPS"); do do_approve "$pid"; done
    else
      need_pid "${1:-}"; do_approve "$1"
    fi
    ;;
  reject)
    need_pid "${1:-}"
    props_write --arg id "$1" --arg n "${2:-}" --arg t "$(now)" '(.proposals[] | select(.id == $id)) |= (.status = "rejected" | .decided_at = $t | .decision_note = $n)'
    commit_backlog "backlog: reject $1"
    echo "rejected $1"
    ;;
  drop)
    refuse_in_session
    [[ -n "${1:-}" ]] || die "usage: drop <ID> [reason]"
    pid="$(do_propose human "${2:-drop $1}" "$(jq -cn --arg id "$1" '{drop: [$id]}')")"; do_approve "$pid"
    ;;
  priority)
    refuse_in_session
    [[ -n "${1:-}" && "${2:-}" =~ ^[0-9]+$ ]] || die "usage: priority <ID> <N>"
    pid="$(do_propose human "priority of $1 -> $2" "$(jq -cn --arg id "$1" --argjson n "$2" '{amend: [{id: $id, priority: $n}]}')")"; do_approve "$pid"
    ;;
  *)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
    ;;
esac
