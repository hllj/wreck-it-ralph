#!/bin/bash
# harness-trigger.sh - set up triggers that start the harness without you: local schedules,
# GitHub Actions (schedule / when CI fails), or an interactive /loop.
#
# New triggers default to rollout L1 (shadow branch, report only) and 3 sessions per run:
# promote to L2 (branch + PR) once the shadow runs look right. Nothing is installed into your
# system: cron/launchd entries are printed (or written under .harness/triggers/) for you to load.
#
# Usage: .harness/trigger.sh <kind> [options]
#   cron    [--every 30m|2h|daily|weekly] [--rollout L1|L2|L3] [--max-sessions N]   print a crontab line
#   launchd [--every ...] [--rollout ...] [--max-sessions N]   write a macOS LaunchAgent plist, print how to load it
#   github  [--cron "0 3 * * *"] [--on-failure "<workflow name>"] [--rollout L1|L2] [--max-sessions N]
#           [--plugin-repo owner/name] [--force]                write .github/workflows/wreck-it-ralph.yml
#   loop    [--every 2h] [--rollout ...] [--max-sessions N]      print the /loop command for an interactive session

set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-.harness}"

die() { echo "trigger: $*" >&2; exit 1; }
kind="${1:-}"; shift || true
EVERY="2h"; ROLLOUT="L1"; MAXS=3; CRON="0 3 * * *"; ON_FAILURE=""; FORCE=0; PLUGIN_REPO="<owner>/wreck-it-ralph"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --every) EVERY="${2:?value required}"; shift 2 ;;
    --rollout) ROLLOUT="${2:?L1|L2|L3}"; shift 2 ;;
    --max-sessions) MAXS="${2:?number required}"; shift 2 ;;
    --cron) CRON="${2:?cron expression required}"; shift 2 ;;
    --on-failure) ON_FAILURE="${2:?workflow name required}"; shift 2 ;;
    --plugin-repo) PLUGIN_REPO="${2:?owner/name required}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$ROLLOUT" =~ ^L[123]$ ]] || die "--rollout must be L1, L2 or L3"
[[ "$MAXS" =~ ^[0-9]+$ ]] || die "--max-sessions must be a number"
[[ -f "$HARNESS_DIR/config.json" ]] || die "no harness here: run /wreck-it-ralph:init first"

PROJECT="$(pwd)"
RUN_ARGS="--rollout $ROLLOUT --max-sessions $MAXS"

every_cron() {
  case "$EVERY" in
    daily) echo "0 3 * * *" ;;
    weekly) echo "0 3 * * 1" ;;
    *m) local n="${EVERY%m}"; [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le 59 ]] || die "--every Nm needs 1-59"; echo "*/$n * * * *" ;;
    *h) local n="${EVERY%h}"; [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -le 23 ]] || die "--every Nh needs 1-23"; echo "0 */$n * * *" ;;
    *) die "--every must be like 30m, 2h, daily or weekly" ;;
  esac
}
every_seconds() {
  case "$EVERY" in
    daily) echo 86400 ;; weekly) echo 604800 ;;
    *m) every_cron >/dev/null; echo $(( ${EVERY%m} * 60 )) ;;
    *h) every_cron >/dev/null; echo $(( ${EVERY%h} * 3600 )) ;;
    *) every_cron ;;
  esac
}
shell_cmd() { printf 'cd %q && PATH=%q ./.harness/run.sh %s >> .harness/sessions/trigger.log 2>&1' "$PROJECT" "$PATH" "$RUN_ARGS"; }

case "$kind" in
  cron)
    expr="$(every_cron)" || exit 1
    echo "Add this line with \`crontab -e\` (runs $RUN_ARGS every $EVERY):"
    echo
    echo "$expr $(shell_cmd)"
    echo
    echo "Headless runs need a non-interactive claude login (or ANTHROPIC_API_KEY in the line above). Output: .harness/sessions/trigger.log"
    ;;
  launchd)
    label="com.wreck-it-ralph.$(basename "$PROJECT" | tr -c 'A-Za-z0-9.-' '-' | sed 's/-*$//')"
    mkdir -p "$HARNESS_DIR/triggers"
    plist="$HARNESS_DIR/triggers/$label.plist"
    secs="$(every_seconds)" || exit 1
    xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-c</string><string>$(xml "$(shell_cmd)")</string></array>
  <key>StartInterval</key><integer>$secs</integer>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
EOF
    echo "Wrote $plist (runs $RUN_ARGS every $EVERY). Load it yourself with:"
    echo
    echo "  cp $plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/$label.plist"
    echo
    echo "Unload: launchctl unload ~/Library/LaunchAgents/$label.plist"
    ;;
  github)
    [[ "$ROLLOUT" != L3 ]] || die "GitHub-triggered runs must use L1 or L2 (never commit to the default branch from CI)"
    out=".github/workflows/wreck-it-ralph.yml"
    [[ -f "$out" && $FORCE -eq 0 ]] && die "$out exists (use --force to overwrite)"
    mkdir -p .github/workflows
    onf=""
    if [[ -n "$ON_FAILURE" ]]; then
      onf="  workflow_run:
    workflows: [$(jq -Rn --arg w "$ON_FAILURE" '$w')]
    types: [completed]"
    fi
    [[ "$CRON" =~ ^[0-9*/,\ -]+$ ]] || die "--cron must be a cron expression like \"0 3 * * *\""
    [[ "$PLUGIN_REPO" =~ ^[A-Za-z0-9_.\<\>-]+/[A-Za-z0-9_.-]+$ ]] || die "--plugin-repo must be owner/name"
    shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2: keep '&' literal in replacements
    tpl="$(cat "$PLUGIN_ROOT/templates/ci/wreck-it-ralph.yml")"
    tpl="${tpl//__CRON__/$CRON}"; tpl="${tpl//__ROLLOUT__/$ROLLOUT}"
    tpl="${tpl//__MAX_SESSIONS__/$MAXS}"; tpl="${tpl//__PLUGIN_REPO__/$PLUGIN_REPO}"
    tpl="${tpl//__ON_FAILURE__/$onf}"
    printf '%s\n' "$tpl" > "$out"
    echo "Wrote $out (cron \"$CRON\"$([[ -n "$ON_FAILURE" ]] && echo ", and when workflow \"$ON_FAILURE\" fails"), rollout $ROLLOUT, $MAXS sessions)."
    echo "Before committing it: set the ANTHROPIC_API_KEY secret, check plugin repo \"$PLUGIN_REPO\", and read the TRUST note at the top."
    ;;
  loop)
    echo "In an interactive Claude Code session, run:"
    echo
    echo "  /loop $EVERY /wreck-it-ralph:run $RUN_ARGS"
    echo
    echo "It repeats in that session while it stays open. For unattended runs use cron, launchd or github instead."
    ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
esac
