---
description: "Check the harness: tools, git, config, feature list, trust, wrappers, and whether every pipeline extension (other plugins' agents, skills) and hook resolves"
allowed-tools: ["Bash(.harness/doctor.sh)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-doctor.sh)"]
---

# Harness doctor

Run `.harness/doctor.sh` with the Bash tool. If that wrapper does not exist yet, run `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-doctor.sh"` instead.

Summarize the result for the user: list every `✗` problem with its fix, then the `!` warnings in one short group. For a pipeline step that references another plugin's agent or skill that is not installed, tell them which plugin provides it (from the name before the colon), or suggest marking the step `"optional": true` in `.harness/config.json`. Do not change anything yourself.
