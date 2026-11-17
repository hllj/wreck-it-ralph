---
description: "Create or repair the .harness scaffold (presets, prerequisite check, .gitignore, wrappers) without running the initializer"
argument-hint: "[--preset web|cli|api|library|data|docs|none] [--max-sessions N] [--no-browser] [--check] [--refresh] [--notify] [--force]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh:*)"]
---

# Harness Setup

User arguments: $ARGUMENTS

Run the setup script with the Bash tool: `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh"` followed by ONLY these options if the user gave them (copy them verbatim; ignore anything else and never pass free text through):
`--preset web|cli|api|library|data|docs|none`, `--max-sessions <number>`, `--no-browser`, `--check`, `--refresh`, `--notify`, `--force`. (`--notify` adds desktop-notification hooks for `needs_human` and `run_ended`.) (Do not pass `--trust` on the user's behalf; trusting goes through `/wreck-it-ralph:trust`.)

What it does (safe to re-run; it merges and never overwrites config, mcp.json, progress.md unless `--force`):
- checks prerequisites (git, jq required; claude, npx optional),
- creates `.harness/` with config for the chosen preset (default: `web` if the project has a package.json or index.html, otherwise `cli`),
  - `web`: coder -> tester with the Playwright MCP, `cli`: coder -> tester without a browser, `none`: coder only,
- writes the wrappers (`.harness/step.sh`, `run.sh`, `status.sh`, `feature-list.sh`),
- merges ignore entries into `.harness/.gitignore` and the project `.gitignore` (`.playwright-mcp/`, `node_modules/`, `.env*`, keys, logs, ...),
- initializes git if needed.

Afterwards summarize what was created or kept in a few lines. Tell the user the next step is `/wreck-it-ralph:init "<goal>"`, and that they can edit `.harness/config.json` (pipeline, limits, `final_verify_command`) before running the loop.
