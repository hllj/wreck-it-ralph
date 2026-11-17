#!/bin/bash
# harness-intake.sh - bring work in from an issue tracker. Fetches open issues that are not yet
# in the backlog; /wreck-it-ralph:intake then has the planner turn each one into a proposal
# (by "intake:<source>"), which a human still has to approve. Issue text is untrusted input.
#
# Usage: .harness/intake.sh <command> [args]
#   github [--label L] [--limit N] [--repo owner/name]   print new open issues as JSON
#                                                        [{source, number, title, body, url}]
#   mark <source-id> [proposal-id]                       record that an item was imported
#   list                                                 imported items
# Other trackers (Linear, Jira, ...): fetch with their MCP tools, then `mark linear:ABC-12 P007`.

set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:-.harness}"
REC="$HARNESS_DIR/intake.json"
die() { echo "intake: $*" >&2; exit 1; }
command -v jq >/dev/null || die "jq is required"
[[ -f "$HARNESS_DIR/feature_list.json" ]] || die "no harness here: run /wreck-it-ralph:init first"
[[ -f "$REC" ]] || echo '{"imported":[]}' > "$REC"
jq -e '.imported | type == "array"' "$REC" >/dev/null 2>&1 || die "$REC is not valid"

cmd="${1:-}"; shift || true
case "$cmd" in
  github)
    label="ralph" limit=10 repo=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) label="${2:?label required}"; shift 2 ;;
        --limit) limit="${2:?number required}"; [[ "$limit" =~ ^[0-9]+$ ]] || die "--limit must be a number"; shift 2 ;;
        --repo) repo="${2:?owner/name required}"; [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be owner/name"; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    command -v gh >/dev/null || die "the GitHub CLI (gh) is required: https://cli.github.com"
    args=(issue list --state open --label "$label" --limit "$limit" --json number,title,body,url)
    [[ -n "$repo" ]] && args+=(--repo "$repo")
    raw="$(gh "${args[@]}")" || die "gh issue list failed"
    jq -c --slurpfile rec "$REC" '
      ($rec[0].imported | map(.source)) as $seen
      | [ .[] | {source: ("github#" + (.number | tostring)), number, title, body: ((.body // "") | .[0:4000]), url}
          | select(.source as $s | $seen | index($s) | not) ]' <<<"$raw"
    ;;
  mark)
    src="${1:?source id required}"; pid="${2:-}"
    [[ "$src" =~ ^[A-Za-z0-9_.-]+[#:][A-Za-z0-9_.#-]+$ ]] || die "source id looks wrong: $src (e.g. github#12, linear:ABC-12)"
    tmp="$REC.tmp.$$"
    jq --arg s "$src" --arg p "$pid" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'if any(.imported[]; .source == $s) then . else .imported += [{source: $s, proposal: $p, at: $t}] end' "$REC" > "$tmp" && mv "$tmp" "$REC"
    echo "marked $src${pid:+ -> $pid}"
    ;;
  list)
    jq -r '.imported[] | "\(.source)\t\(.proposal)\t\(.at)"' "$REC"
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
