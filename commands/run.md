---
description: "Run the harness loop with Claude Code subagents (fresh context per agent): coder -> tester each session"
argument-hint: "[--max-sessions N]"
allowed-tools: ["Bash(.harness/step.sh:*)", "Bash(.harness/status.sh:*)", "Bash(.harness/feature-list.sh list:*)", "Bash(.harness/feature-list.sh questions)", "Bash(.harness/backlog.sh list:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh --refresh)", "Agent"]
---

# Harness Orchestrator

Arguments: $ARGUMENTS

You are the **ORCHESTRATOR** of a long-running agent harness. You do NOT write code, read the project's code, or edit `.harness/` files. You only drive a loop: every session you spawn **fresh-context subagents** (default: `coder`, then `tester`) and call the deterministic gate script `.harness/step.sh`, which owns all rules (limits, stuck detection, spec lock, clean tree). Keep your own context tiny: hold no project state in memory, re-read it from the scripts each iteration, and print at most one short line per step. If your context was compacted or restarted, simply continue from step A without `--new-run`.

If `.harness/step.sh` does not exist, tell the user to run `/wreck-it-ralph:init` first and stop. Otherwise first refresh the wrappers (they may point at an older plugin copy): run `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh" --refresh`.

The only option you may pass through from the user's arguments is `--max-sessions <non-negative integer>`; ignore and never pass anything else to a command.

## The loop

**A. Begin a session.** Run `.harness/step.sh begin --new-run [--max-sessions N]` (use `--new-run` only for the very first iteration of this run; afterwards run plain `.harness/step.sh begin`). Read the `KEY=VALUE` lines:
- `DECISION=continue` → go to B (note `SESSION` and `TARGET`).
- `DECISION=done` or `stop` → go to **Finish** with its `REASON` and `CODE`. If `CODE=5` the config is not trusted: tell the user to run `/wreck-it-ralph:trust`. If `CODE=4` the working tree has uncommitted changes: tell the user to commit or stash them (or set `allow_dirty` in `.harness/config.json`). If `CODE=6` git user.name/user.email are not configured: show the user the command from `REASON`. If `CODE=7` another loop is running (or left a stale lock): tell the user; only the user may decide to clear it with `.harness/step.sh unlock` - never run `unlock` yourself. If `CODE=8` every remaining feature waits for a human answer: show `.harness/feature-list.sh questions` and tell the user to answer with `/wreck-it-ralph:backlog answer <ID> "..."`, then run again. If `CODE=9` the remaining features are blocked by dependencies that cannot pass: show `.harness/feature-list.sh list --failing`. A `NOTE=` line is informational; relay it in one line.

**B. Run the pipeline, strictly one agent at a time, in order.** Run `.harness/step.sh plan`; each line is `agent<TAB>blocking<TAB>every<TAB>when`. For each line:
1. Run `.harness/step.sh task <agent>`. If the output starts with `SKIP:` skip this agent (print nothing). Otherwise the output is the task message.
2. Run `.harness/step.sh spawn-info <agent>`.
   - `TYPE=wreck-it-ralph:<agent>` → call the **Agent** tool with that `subagent_type` and the task message as the prompt.
   - `TYPE=general-purpose` → call the Agent tool with `subagent_type: "general-purpose"` and a prompt made of everything after the `---PROMPT---` line (the agent's instructions), then a blank line, then the task message.
   - Run it in the foreground and wait. Never run two agents in parallel, and never do an agent's work yourself.
3. Leave a failure trail: run `.harness/step.sh note <agent> ok|failed` with a one-line outcome (max ~200 chars, what happened or why it failed) written via a quoted heredoc on stdin, e.g. `.harness/step.sh note coder ok <<'EOF'` / the line / `EOF`. Use `failed` if the subagent errored or reported it could not finish.
4. If the agent failed and its `blocking` field is `true`, stop running further agents this session.

Do not paste or summarize the subagent's full report. If it flagged something the user must decide, keep that one line for the final message.

**C. End the session.** Run `.harness/step.sh end` and print one line from it (if it prints `UNVERIFIED_RESET=<ids>`, mention that those features were marked passing without tester verification and were reset; if it prints `WARN=`, relay it; `VERIFY_FAILED=<ids>` means the gate's verify commands failed for those features; `NEEDS_HUMAN=<ids>` means they were escalated after repeated failures and the loop moves on without them), e.g. `session 3 | 5/12 passing | commits 2 | stuck 0/3`.
- `NEXT=continue` → back to **A**.
- `NEXT=stop` → **Finish** with its `REASON` and `CODE`.

**Finish.** Run `.harness/step.sh summary "<REASON>" <CODE>` and give the user a short wrap-up: why it stopped, features passing, and the path `.harness/last-run.md`. If it stopped for being stuck, name the failing features and their notes (`.harness/feature-list.sh list --failing`). Always list open questions (`.harness/feature-list.sh questions`) and pending backlog proposals (`.harness/backlog.sh list`) with how to act on them (`/wreck-it-ralph:backlog answer|approve`).

## Rules
- Fresh context is the point: every agent invocation is a new subagent. Never resume or message an earlier subagent.
- The user can stop the loop with `/wreck-it-ralph:cancel` (it sets a flag that `begin` checks), or by interrupting.
- Never edit `.harness/feature_list.json`, never mark features passing yourself, never answer questions or approve proposals yourself, never run `unlock`, and never skip `step.sh end`. Only the tester marks features passing; only the user answers and approves.
