---
description: "Initialize a long-running agent harness (scaffold + initializer agent: feature list, init.sh, progress log, git)"
argument-hint: "GOAL [--preset web|cli|none] [--max-sessions N] [--branch NAME] [--allow-dirty] [--force]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh:*)", "Bash(.harness/feature-list.sh:*)", "Agent"]
---

# Harness Init

User arguments: $ARGUMENTS

Split the arguments into the **goal** (the free text) and the setup options (`--preset web|cli|none`, `--max-sessions <number>`, `--no-browser`, `--branch <name>`, `--allow-dirty`, `--force`). Never pass the goal text to a shell command.

Do these steps in order:

1. Scaffold the harness (safe re-run, keeps an existing config). Run with the Bash tool:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh" --for-init` plus only the setup options the user gave (verbatim).
   If it fails (already initialized, missing tools, or uncommitted changes in a git project), tell the user and stop. For uncommitted changes suggest committing/stashing, or re-running with `--branch <name>` / `--allow-dirty`.

2. Launch the **initializer** as a fresh-context subagent with the Agent tool (`subagent_type: "wreck-it-ralph-loop:initializer"`). Pass it the user's goal verbatim plus the current working directory. Wait for it to finish. Do not implement any feature yourself.

3. Finalize (validates the feature list, checks init.sh, locks the spec, makes the first commit):
   `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh" --finalize`
   If validation fails, send the error back to a new initializer subagent to fix, then finalize again.

4. Report to the user: number of features, how to run, and the next step - start the loop with `/wreck-it-ralph-loop:harness-run` (interactive: fresh-context subagents in this session), or for unattended runs `/wreck-it-ralph-loop:harness-run-headless` / `.harness/run.sh` in a terminal. Mention `.harness/config.json` (pipeline, limits) and, for the web preset, that the Playwright MCP must be available in the session (start Claude Code with `--mcp-config .harness/mcp.json`).
