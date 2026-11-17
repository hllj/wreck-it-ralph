---
description: "Start the harness without you: print a cron line, write a launchd agent or a GitHub Actions workflow (schedule / when CI fails), or set up a /loop. New triggers default to rollout L1 (shadow, report only)"
argument-hint: "cron|launchd|github|loop [--every 2h] [--cron \"0 3 * * *\"] [--on-failure \"CI\"] [--rollout L1|L2] [--max-sessions N] [--plugin-repo owner/name] [--force]"
allowed-tools: ["Bash(.harness/trigger.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-trigger.sh:*)"]
---

# Harness triggers

User arguments: $ARGUMENTS

Run `.harness/trigger.sh` (or `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-trigger.sh"` if the wrapper is missing). Pass the kind (`cron`, `launchd`, `github` or `loop`) and only these options, copied verbatim when the user gave them: `--every`, `--cron`, `--on-failure`, `--rollout`, `--max-sessions`, `--plugin-repo`, `--force`. If no kind was given, explain the four kinds in one line each and ask which one they want.

Then explain the result:
- **cron / launchd.** The script only prints or writes the entry. The user installs it themselves; never run `crontab` or `launchctl` for them. Headless runs need a claude login that works without a terminal, or `ANTHROPIC_API_KEY`.
- **github.**
  - The workflow file was written but not committed.
  - The user must add the `ANTHROPIC_API_KEY` secret and point `--plugin-repo` at where this plugin lives.
  - Read them the TRUST note: CI accepts the committed `.harness` config without the interactive review, so `.harness/` changes must go through code review.
  - CI runs never use L3.
- **loop.** It repeats inside an open interactive session only.

Recommend starting with rollout **L1** (a shadow branch and a report; your branch is never touched). Move to **L2** (branch, push and PR) once a few shadow runs look right.
