---
description: "Run the harness loop with Claude Code subagents (fresh context per agent): coder -> tester each session"
argument-hint: "[--max-sessions N] [--rollout L1|L2|L3]"
allowed-tools: ["Bash(.harness/step.sh:*)", "Bash(.harness/status.sh:*)", "Bash(.harness/feature-list.sh list:*)", "Bash(.harness/feature-list.sh questions)", "Bash(.harness/backlog.sh list:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh --refresh)", "Agent"]
---

# Harness Orchestrator

Arguments: $ARGUMENTS

You are the **ORCHESTRATOR** of a long-running agent harness. You do NOT write code, read the project's code, or edit `.harness/` files. You only drive a loop: every session you spawn **fresh-context subagents** (default: `coder`, then `tester`) and call the deterministic gate script `.harness/step.sh`, which owns all rules (limits, stuck detection, spec lock, clean tree). Keep your own context tiny: hold no project state in memory, re-read it from the scripts each iteration, and print at most one short line per step. If your context was compacted or restarted, simply continue from step A without `--new-run`.

If `.harness/step.sh` does not exist, tell the user to run `/wreck-it-ralph:init` first and stop. Otherwise first refresh the wrappers (they may point at an older plugin copy): run `"${CLAUDE_PLUGIN_ROOT}/scripts/harness-setup.sh" --refresh`.

The only options you may pass through from the user's arguments are `--max-sessions <non-negative integer>` and `--rollout L1|L2|L3` (both only on the first `begin --new-run`); ignore and never pass anything else to a command.

## The loop

**A. Begin a session.** Run `.harness/step.sh begin --new-run [--max-sessions N]` (use `--new-run` only for the very first iteration of this run; afterwards run plain `.harness/step.sh begin`). Read the `KEY=VALUE` lines:
- `DECISION=continue` → go to B (note `SESSION` and `TARGET`).
- `DECISION=done` or `stop` → go to **Finish** with its `REASON` and `CODE`. If `CODE=5` the config is not trusted: tell the user to run `/wreck-it-ralph:trust`. If `CODE=4` the working tree has uncommitted changes: tell the user to commit or stash them (or set `allow_dirty` in `.harness/config.json`). If `CODE=6` git user.name/user.email are not configured: show the user the command from `REASON`. If `CODE=7` another loop is running (or left a stale lock): tell the user; only the user may decide to clear it with `.harness/step.sh unlock` - never run `unlock` yourself. If `CODE=8` every remaining feature waits for a human answer: show `.harness/feature-list.sh questions` and tell the user to answer with `/wreck-it-ralph:backlog answer <ID> "..."`, then run again. If `CODE=9` the remaining features are blocked by dependencies that cannot pass: show `.harness/feature-list.sh list --failing`. If `CODE=10` a run budget (`budget` in `.harness/config.json`) is used up: tell the user what was spent (`.harness/step.sh ledger total`) and that raising the cap or starting a new run continues. If `CODE=12` the rollout branch is wrong (detached HEAD, empty repository, or someone switched branches mid-run): relay the `REASON`, which includes the fix. A `NOTE=` line is informational; relay it in one line. If `begin --new-run` prints `BRANCH=`, tell the user once that this run works on that branch (rollout `ROLLOUT=`) and their branch `BASE=` is not touched.

**B. Run the pipeline, strictly one step at a time, in order.** Run `.harness/step.sh plan`; each line is `name<TAB>blocking<TAB>every<TAB>when`. For each line (`<agent>` below is the step name):
1. Run `.harness/step.sh task <agent>`. If the output starts with `SKIP:` skip this step (print nothing). Otherwise the output is the task message.
2. Run `.harness/step.sh spawn-info <agent>` and read `TYPE=` and `OPTIONAL=`:
   - `TYPE=general-purpose` → call the Agent tool with `subagent_type: "general-purpose"` and a prompt made of everything after the `---PROMPT---` line (the step's instructions), then a blank line, then the task message.
   - `TYPE=gate` → do not spawn anything: run `.harness/step.sh run-step <agent>` (it runs the configured shell step and records the note itself; its exit code is the result), then continue with step 5.
   - `TYPE=missing` → an optional agent file does not exist: note it as `skipped` and continue.
   - any other `TYPE=<type>` (for example `wreck-it-ralph:coder`, or another plugin's agent such as `pr-review-toolkit:code-reviewer`) → call the **Agent** tool with `subagent_type: "<type>"` and the task message as the prompt.
   - If `OPTIONAL=true` and the step cannot run (the Agent tool rejects the subagent type, or the subagent answers `EXTENSION UNAVAILABLE`), record it with `note <agent> skipped` and go on. It never fails the session.
   - Run it in the foreground and wait. Never run two steps in parallel, and never do a step's work yourself.
3. Record what it cost: if the Agent tool result reports usage (for example `subagent_tokens: N` and `duration_ms: M`), run `.harness/step.sh ledger add <agent> --tokens N --ms M`, passing only the numbers. Skip this if no usage was reported. Budgets (`budget.max_tokens`, `budget.max_wall_minutes`) are checked by the gates from this ledger.
4. Leave a failure trail: run `.harness/step.sh note <agent> ok|failed` with a one-line outcome (max ~200 chars, what happened or why it failed) written via a quoted heredoc on stdin, e.g. `.harness/step.sh note coder ok <<'EOF'` / the line / `EOF`. Use `failed` if the subagent errored or reported it could not finish.
5. If the agent failed and its `blocking` field is `true`, stop running further agents this session.

Do not paste or summarize the subagent's full report. If it flagged something the user must decide, keep that one line for the final message.

**C. End the session.** Run `.harness/step.sh end` and print one line from it (if it prints `UNVERIFIED_RESET=<ids>`, mention that those features were marked passing without tester verification and were reset; if it prints `WARN=`, relay it; `VERIFY_FAILED=<ids>` means the gate's verify commands failed for those features; `NEEDS_HUMAN=<ids>` means they were escalated after repeated failures and the loop moves on without them; `CODE=11` with `NEXT=stop` means the session's diff exceeded `budget.max_diff_lines` and the user should review the commits before running again), e.g. `session 3 | 5/12 passing | commits 2 | diff 140 lines | stuck 0/3`.
- `NEXT=continue` → back to **A**.
- `NEXT=stop` → **Finish** with its `REASON` and `CODE`.

**Notify.** If a `PushNotification` tool is available in this session, send one short notification when `end` reports `NEEDS_HUMAN=`, and one when the run finishes (stop reason and features passing), so a user who stepped away knows. Load it with ToolSearch first if it is only listed as deferred. Never send anything else through it.

**Finish.** Run `.harness/step.sh summary "<REASON>" <CODE>` and give the user a short wrap-up: why it stopped, features passing, and the path `.harness/last-run.md`. If it stopped for being stuck, name the failing features and their notes (`.harness/feature-list.sh list --failing`). Always list open questions (`.harness/feature-list.sh questions`) and pending backlog proposals (`.harness/backlog.sh list`) with how to act on them (`/wreck-it-ralph:backlog answer|approve`).

## Rules
- Fresh context is the point: every agent invocation is a new subagent. Never resume or message an earlier subagent.
- The user can stop the loop with `/wreck-it-ralph:cancel` (it sets a flag that `begin` checks), or by interrupting.
- Never edit `.harness/feature_list.json`, never mark features passing yourself, never answer questions or approve proposals yourself, never run `unlock`, and never skip `step.sh end`. Only the tester marks features passing; only the user answers and approves.
