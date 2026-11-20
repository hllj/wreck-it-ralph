#!/bin/bash
# harness-doctor.sh - check that this project's harness is healthy and that every pipeline
# extension (other plugins' agents, skills, commands) and hook can be resolved.
#
# Usage: .harness/doctor.sh      (exit 1 if a required check fails; `!` lines are warnings)

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-.harness}"
export HARNESS_DIR
CFG="$HARNESS_DIR/config.json"
FL="$PLUGIN_ROOT/scripts/feature-list.sh"
STEP="$PLUGIN_ROOT/scripts/harness-step.sh"
CACHE="$HOME/.claude/plugins/cache"
FAILS=0; WARNS=0
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; WARNS=$((WARNS + 1)); }
bad()  { echo "  ✗ $*"; FAILS=$((FAILS + 1)); }

KNOWN_EVENTS="run_started session_started feature_claimed verify_failed feature_passed feature_failed needs_human session_ended run_ended step_finished proposal_filed proposal_approved run_refused pr_opened fanout_started fanout_merged"

# Look for a plugin agent / skill / command on disk. Built-in skills are not on disk, so a miss is a warning.
find_plugin_item() { # plugin kind(agents|skills|commands) item
  ls -d "$CACHE"/*/"$1"/*/"$2"/"$3".md "$CACHE"/*/"$1"/*/"$2"/"$3"/SKILL.md 2>/dev/null | head -n1
}
find_skill() { # ref: name | plugin:name | /plugin:cmd args
  local ref="${1#/}"; ref="${ref%% *}"
  if [[ "$ref" == *:* ]]; then
    local pl="${ref%%:*}" it="${ref#*:}"
    find_plugin_item "$pl" skills "$it"; find_plugin_item "$pl" commands "$it"
  else
    ls -d ".claude/skills/$ref/SKILL.md" "$HOME/.claude/skills/$ref/SKILL.md" ".claude/commands/$ref.md" "$HOME/.claude/commands/$ref.md" \
          "$CACHE"/*/*/*/skills/"$ref"/SKILL.md "$CACHE"/*/*/*/commands/"$ref".md 2>/dev/null
  fi | head -n1
}

echo "Tools"
command -v git >/dev/null && ok git || bad "git missing"
command -v jq >/dev/null && ok jq || { bad "jq missing (required)"; echo; echo "doctor: $FAILS problem(s)"; exit 1; }
command -v claude >/dev/null && ok "claude ($(claude --version 2>/dev/null | head -n1))" || warn "claude not on PATH (needed for headless runs)"

echo "Project"
if git rev-parse --git-dir >/dev/null 2>&1; then ok "git repository"; else bad "not a git repository"; fi
if [[ -n "$(git config user.email 2>/dev/null)" && -n "$(git config user.name 2>/dev/null)" ]]; then ok "git identity"; else bad "git identity not set (git config user.name / user.email)"; fi
if [[ ! -f "$CFG" ]]; then bad "$CFG missing: run /wreck-it-ralph:setup or /wreck-it-ralph:init"; echo; echo "doctor: $FAILS problem(s), $WARNS warning(s)"; exit 1; fi
if jq -e 'type == "object"' "$CFG" >/dev/null 2>&1; then ok "config.json (version $(jq -r '.version // 2' "$CFG"))"; else bad "config.json is not valid JSON"; fi
if [[ -f "$HARNESS_DIR/feature_list.json" ]]; then
  if "$FL" validate >/dev/null 2>&1; then ok "feature list: $("$FL" stats)"; else bad "feature list invalid: $("$FL" validate 2>&1 | tail -n1)"; fi
  miss_ex="$("$FL" examples-missing 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${miss_ex:-0}" -gt 0 ]]; then warn "$miss_ex feature(s) have no examples (locked contract cases); see /wreck-it-ralph:backlog"; else ok "every feature has examples"; fi
  if "$FL" verify-lock 2>/dev/null; then ok "spec matches its lock"; else warn "spec differs from its lock (the next session restores it)"; fi
else
  warn "no feature list yet: run /wreck-it-ralph:init \"<goal>\""
fi
if [[ -f pyproject.toml || -f setup.py || -f pytest.ini || -f requirements.txt ]] && [[ -z "$(jq -r '.coverage.cmd // ""' "$CFG" 2>/dev/null)" ]]; then
  py=python3; [[ -x .venv/bin/python ]] && py=.venv/bin/python
  if "$py" -m coverage --version >/dev/null 2>&1; then ok "coverage.py available ($py)"; else warn "coverage.py not installed for $py: the tester cannot report coverage gaps (install it into the project env, e.g. .venv/bin/pip install coverage pytest)"; fi
fi
if [[ -f package.json && -z "$(jq -r '.coverage.cmd // ""' "$CFG" 2>/dev/null)" ]]; then
  r=""; for b in vitest jest c8 nyc; do jq -e --arg b "$b" '((.dependencies // {}) + (.devDependencies // {})) | has($b)' package.json >/dev/null 2>&1 && { r="$b"; break; }; done
  if [[ -z "$r" ]]; then warn "no coverage runner in package.json (vitest, jest, c8 or nyc): the tester cannot report coverage gaps (npm i -D c8)"
  elif [[ -x "node_modules/.bin/$r" ]]; then ok "coverage runner $r installed"; else warn "coverage runner $r is in package.json but not installed (npm install)"; fi
fi
if [[ -f go.mod && -z "$(jq -r '.coverage.cmd // ""' "$CFG" 2>/dev/null)" ]]; then
  if command -v go >/dev/null 2>&1; then ok "go toolchain available (coverage: statements only, no branch data)"; else warn "go is not on PATH: the tester cannot report coverage"; fi
fi
if [[ -x "$HARNESS_DIR/init.sh" ]]; then ok "init.sh executable"; elif [[ -f "$HARNESS_DIR/feature_list.json" ]]; then bad "init.sh missing or not executable"; fi
rc=0; "$HARNESS_DIR/step.sh" trust status >/dev/null 2>&1 || rc=$?
case $rc in
  0) ok "wrappers work; config trusted" ;;
  127) bad "wrappers point at a missing plugin copy: run /wreck-it-ralph:setup --refresh" ;;
  *) if [[ -x "$HARNESS_DIR/step.sh" ]]; then warn "config not trusted: review it with /wreck-it-ralph:trust"; else bad "wrappers missing: run /wreck-it-ralph:setup --refresh"; fi ;;
esac
m="$(jq -r '.mcp_config // ""' "$CFG")"
if [[ -n "$m" ]]; then if [[ -f "$m" ]]; then ok "MCP config $m"; else bad "mcp_config $m does not exist"; fi; fi

echo "Pipeline"
while IFS=$'\t' read -r name use optional; do
  [[ -z "$name" ]] && continue
  tag="$name"; [[ "$optional" == true ]] && tag="$name (optional)"
  miss() { if [[ "$optional" == true ]]; then warn "$tag: $1 - will be skipped"; else bad "$tag: $1"; fi; }
  case "$use" in
    agent:*:*)
      ref="${use#agent:}"; f="$(find_plugin_item "${ref%%:*}" agents "${ref#*:}")"
      if [[ -n "$f" ]]; then ok "$tag: plugin agent $ref"; else miss "plugin agent $ref not installed (looked in $CACHE)"; fi ;;
    agent:*|-)
      ref="${use#agent:}"; [[ "$ref" == - ]] && ref="$name"
      if [[ -f "$HARNESS_DIR/agents/$ref.md" || -f "$PLUGIN_ROOT/agents/$ref.md" || -f "$PLUGIN_ROOT/templates/agents/$ref.md" ]]; then ok "$tag: agent $ref"; else miss "agent $ref not found"; fi ;;
    skill:*|command:*)
      ref="${use#*:}"; ref="${ref# }"; f="$(find_skill "$ref")"
      if [[ -n "$f" ]]; then ok "$tag: $ref ($f)"; else warn "$tag: $ref not found on disk (fine if it is built in to Claude Code; otherwise install its plugin)"; fi ;;
    cmd:*) ok "$tag: shell step \`${use#cmd:}\` (runs in the gate; covered by trust)" ;;
    *) bad "$tag: unknown use '$use' (expected agent:, skill:, command: or cmd:)" ;;
  esac
done < <(jq -r '.pipeline[]? | [(.name // .agent // ((.use // "step") | sub("^[a-z]+:\\s*/?"; "") | gsub("[^A-Za-z0-9_-]+"; "-") | .[0:40])), (.use // "-"), (.optional // false | tostring)] | @tsv' "$CFG")
names="$(jq -r '.pipeline[]? | (.name // .agent // "")' "$CFG" | grep -v '^$' | sort | uniq -d)"
[[ -n "$names" ]] && bad "duplicate step names: $(echo "$names" | tr '\n' ' ') (give each step a unique \"name\")"

echo "Hooks"
hooks="$(jq -r '(.hooks // {}) | to_entries[] | .key as $k | (.value | if type == "string" then [.] else . end)[] | "\($k)\t\(.)"' "$CFG" 2>/dev/null)"
if [[ -z "$hooks" ]]; then ok "none configured"; fi
while IFS=$'\t' read -r ev h; do
  [[ -z "$ev" ]] && continue
  [[ " $KNOWN_EVENTS " == *" $ev "* ]] || warn "hook on unknown event '$ev' (known: $KNOWN_EVENTS)"
  case "$h" in cmd:*) ok "$ev: \`${h#cmd:}\`" ;; *) warn "$ev: '$h' ignored (hooks support cmd: handlers only)" ;; esac
done <<<"$hooks"

echo "Loop state"
if [[ -f "$HARNESS_DIR/.lock" ]]; then
  # shellcheck source=harness-lib.sh
  source "$PLUGIN_ROOT/scripts/harness-lib.sh"
  if lock_live; then ok "a loop is running"; else warn "stale loop lock: clear it with .harness/step.sh unlock"; fi
else ok "no loop running"; fi
[[ -f "$HARNESS_DIR/STOP" ]] && warn "STOP flag set (the next run clears it)"
if [[ -f "$HARNESS_DIR/feature_list.json" ]]; then
  q="$("$FL" questions | wc -l | tr -d ' ')"; [[ "$q" -gt 0 ]] && warn "$q feature(s) wait for your answer (/wreck-it-ralph:backlog questions)"
fi
if [[ -f "$HARNESS_DIR/proposals.json" ]]; then
  p="$(jq '[.proposals[]? | select(.status == "pending")] | length' "$HARNESS_DIR/proposals.json" 2>/dev/null || echo 0)"
  [[ "$p" -gt 0 ]] && warn "$p backlog proposal(s) await approval (/wreck-it-ralph:backlog)"
fi

echo
if [[ $FAILS -eq 0 ]]; then echo "doctor: healthy ($WARNS warning(s))"; else echo "doctor: $FAILS problem(s), $WARNS warning(s)"; fi
[[ $FAILS -eq 0 ]]
