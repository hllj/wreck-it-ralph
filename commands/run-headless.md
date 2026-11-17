---
description: "Run the harness loop headless in the background (separate claude -p processes, for unattended runs)"
argument-hint: "[--max-sessions N] [--once]"
allowed-tools: ["Bash(.harness/run.sh:*)", "Bash(.harness/status.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh --refresh)"]
---

# Harness Run (headless)

Arguments given by the user: $ARGUMENTS. The only options you may pass through are `--max-sessions <non-negative integer>` and `--once`; never pass anything else to a command.

First refresh the wrappers: `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh" --refresh`. Then use the Bash tool with `run_in_background: true` to run `.harness/run.sh` plus those options.

This spawns a separate `claude -p` process per agent (needs a valid `claude` login and uses `permission_mode`/`allowed_tools` from `.harness/config.json`; default `acceptEdits` with an explicit tool list. If it is set to `bypassPermissions`, warn the user to use a sandbox). If the runner stops immediately with a "not trusted" or "uncommitted changes" reason, tell the user to run `/wreck-it-ralph:trust` or commit/stash. For an interactive run with subagents in this session use `/wreck-it-ralph:run` instead.

If `.harness/run.sh` does not exist, tell the user to run `/wreck-it-ralph:init` first.

After starting, tell the user: progress via `/wreck-it-ralph:status`, logs in `.harness/sessions/`, stop with `/wreck-it-ralph:cancel`, summary in `.harness/last-run.md`. Do not poll; you are notified when it exits. Do not do the coding work yourself.
