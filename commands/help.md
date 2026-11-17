---
description: "Explain the wreck-it-ralph plugin: the long-running harness with a living backlog, and the in-session Ralph loop"
---

# wreck-it-ralph Help

Please explain the following to the user. The plugin has two tools: the **long-running harness** (recommended for building something over many sessions) and the original **in-session Ralph loop**.

# Part 1: The long-running harness

Every agent runs in a **fresh context**, and all state lives on disk (`.harness/`) and in git. Deterministic gate scripts own the rules, so the model does not have to remember them. Features are built **gradually**: the backlog can grow at any time through proposals you approve.

**Flow:** init -> run (each session: coder -> verify gate -> tester) -> add more features any time -> run again.

| Command | What it does |
|---|---|
| `/wreck-it-ralph:setup [--preset web\|cli\|none] [--check] [--refresh]` | Create or repair the `.harness/` scaffold (prerequisites, preset config, wrappers, `.gitignore`). Safe to re-run. |
| `/wreck-it-ralph:init "<goal>" [--branch NAME] [--allow-dirty]` | Runs setup, then the initializer writes `feature_list.json`, `init.sh` and `progress.md`. The spec is then locked and committed. |
| `/wreck-it-ralph:add "<request>" [--approve]` | The planner turns a request into small, verifiable features (with `verify` commands and `depends_on`) as a proposal for you to approve. |
| `/wreck-it-ralph:backlog [list\|approve P\|reject P\|answer F "..."\|drop F\|priority F N]` | Review proposals, answer questions the loop escalated, drop or reprioritize features. |
| `/wreck-it-ralph:trust` | Review the repo-supplied config (permissions, commands, MCP servers, custom agents, verify commands) and trust it. |
| `/wreck-it-ralph:run [--max-sessions N]` | Interactive loop: this session orchestrates fresh coder and tester subagents. |
| `/wreck-it-ralph:run-headless [--max-sessions N] [--once]` | Unattended loop: separate `claude -p` processes in the background. |
| `/wreck-it-ralph:status` | Features, next ready feature, open questions, pending proposals, runner state. |
| `/wreck-it-ralph:cancel` | Stop after the current session. |
| `/wreck-it-ralph:doctor` | Health check, including whether pipeline extensions (other plugins' agents, skills) and hooks resolve. |

**Working with other plugins:**
- **Pipeline steps:** a step can `use:` `agent:<plugin>:<agent>`, `skill:<name>`, `command:/<plugin>:<cmd>` or `cmd:<shell>`.
- **Missing plugins:** with `optional: true`, a step whose plugin isn't installed is skipped with a note.
- **When steps run:** `when` accepts `always`, `claimed`, `failing`, `passed` or `tag:<tag>`.
- **Events:** every gate transition goes to `.harness/events.jsonl`, and `hooks` run shell handlers on those events.
- **Status contract:** `.harness/status.sh --json` is a stable status snapshot.
- **Loop design:** the `loop-design` skill helps design loops.

**Key rules the gates enforce:**
- One feature per session, taken from the ready queue (not passing, not waiting on a human, dependencies passing, by priority).
- The coder may only *claim*.
- The gate runs each feature's `verify` commands itself; if one fails, the feature fails and the tester is skipped.
- Only the tester marks a feature *passing*. An unverified pass is reset.
- The spec is locked and changes only through approved proposals.
- A feature that keeps failing, or that needs a decision, is escalated to `needs_human`, and the loop moves on.
- The tree is committed clean after every session.
- The loop stops when everything passes, at the session cap, when stuck, when only human-blocked work remains (code 8), or when dependencies can never pass (code 9).
- Only one loop runs per project.

Config lives in `.harness/config.json`: pipeline, limits, `verify_static`, `escalate_after_failures`, `budget` (`max_cost_usd`, `max_tokens`, `max_wall_minutes`, `max_diff_lines`, `on_large_diff`), `final_verify_command`, `allow_dirty`. Spend per agent run is recorded in `.harness/ledger.jsonl`. Stop codes 10 and 11 mean a budget is used up and a session diff is too large. Details are in README.md.

# Part 2: The in-session Ralph loop

## What is Ralph Loop?

Ralph Loop implements the Ralph Wiggum technique - an iterative development methodology based on continuous AI loops, pioneered by Geoffrey Huntley.

**Core concept:**
```bash
while :; do
  cat PROMPT.md | claude -p
done
```

The same prompt is fed to Claude repeatedly. The "self-referential" aspect comes from Claude seeing its own previous work in the files and git history, not from feeding output back as input.

**Each iteration:**
1. Claude receives the SAME prompt
2. Works on the task, modifying files
3. Tries to exit
4. Stop hook intercepts and feeds the same prompt again
5. Claude sees its previous work in the files
6. Iteratively improves until completion

The technique is described as "deterministically bad in an undeterministic world" - failures are predictable, enabling systematic improvement through prompt tuning.

## Available Commands

### /wreck-it-ralph:ralph <PROMPT> [OPTIONS]

Start a Ralph loop in your current session.

**Usage:**
```
/wreck-it-ralph:ralph "Refactor the cache layer" --max-iterations 20
/wreck-it-ralph:ralph "Add tests" --completion-promise "TESTS COMPLETE"
```

**Options:**
- `--max-iterations <n>` - Max iterations before auto-stop
- `--completion-promise <text>` - Promise phrase to signal completion
- `--verify '<command>'` - Must exit 0 before the loop can end. Its failing output is fed back each iteration.
- `--max-minutes <n>` - Wall-clock budget for the loop
- `--allow-blocked` - Allow an honest exit with `<promise>BLOCKED: reason</promise>`

Every ending is recorded in `.claude/ralph-loop.last.md`. `/wreck-it-ralph:add --from-ralph` promotes the task to backlog features.

**How it works:**
1. Creates `.claude/ralph-loop.local.md` state file
2. You work on the task
3. When you try to exit, stop hook intercepts
4. Same prompt fed back
5. You see your previous work
6. Continues until promise detected or max iterations

---

### /wreck-it-ralph:cancel-ralph

Cancel an active Ralph loop (removes the loop state file).

**Usage:**
```
/wreck-it-ralph:cancel-ralph
```

**How it works:**
- Checks for active loop state file
- Removes `.claude/ralph-loop.local.md`
- Reports cancellation with iteration count

---

## Key Concepts

### Completion Promises

To signal completion, Claude must output a `<promise>` tag:

```
<promise>TASK COMPLETE</promise>
```

The stop hook looks for this specific tag. Without it (or `--max-iterations`), Ralph runs infinitely.

### Self-Reference Mechanism

The "loop" doesn't mean Claude talks to itself. It means:
- Same prompt repeated
- Claude's work persists in files
- Each iteration sees previous attempts
- Builds incrementally toward goal

## Example

### Interactive Bug Fix

```
/wreck-it-ralph:ralph "Fix the token refresh logic in auth.ts. Output <promise>FIXED</promise> when all tests pass." --completion-promise "FIXED" --max-iterations 10
```

You'll see Ralph:
- Attempt fixes
- Run tests
- See failures
- Iterate on solution
- In your current session

## When to Use Ralph

**Good for:**
- Well-defined tasks with clear success criteria
- Tasks requiring iteration and refinement
- Iterative development with self-correction
- Greenfield projects

**Not good for:**
- Tasks requiring human judgment or design decisions
- One-shot operations
- Tasks with unclear success criteria
- Debugging production issues (use targeted debugging instead)

## Learn More

- Original technique: https://ghuntley.com/ralph/
- Ralph Orchestrator: https://github.com/mikeyobrien/ralph-orchestrator
