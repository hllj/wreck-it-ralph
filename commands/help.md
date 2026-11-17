---
description: "Explain the wreck-it-ralph-loop plugin: the long-running harness and the in-session Ralph loop"
---

# wreck-it-ralph-loop Help

Please explain the following to the user. The plugin has two tools: the **long-running harness** (recommended for building something over many sessions) and the original **in-session Ralph loop**.

# Part 1: The long-running harness

Based on Anthropic's "Effective harnesses for long-running agents": every agent runs in a **fresh context**, and all state lives on disk (`.harness/`) and in git.

**Flow:** setup/init -> loop (coder, then tester, each session) -> summary.

| Command | What it does |
|---|---|
| `/wreck-it-ralph-loop:harness-setup [--preset web\|cli\|none] [--check] [--refresh]` | Create or repair the `.harness/` scaffold: prerequisite check (git, jq, git identity), preset config, wrappers, `.gitignore` entries. Safe to re-run. |
| `/wreck-it-ralph-loop:harness-init "<goal>" [--branch NAME] [--allow-dirty]` | Setup + the initializer agent writes `feature_list.json`, `init.sh`, `progress.md`, then the spec is locked and committed. Refuses on uncommitted changes in a git project. |
| `/wreck-it-ralph-loop:harness-trust` | Review the repo-supplied config (permissions, commands, MCP servers, custom agents) and trust it. Required once per machine and after any change. |
| `/wreck-it-ralph-loop:harness-run [--max-sessions N]` | Interactive loop: this session orchestrates fresh coder and tester subagents. |
| `/wreck-it-ralph-loop:harness-run-headless [--max-sessions N] [--once]` | Unattended loop: separate `claude -p` processes in the background. |
| `/wreck-it-ralph-loop:harness-status` | Features passing, next feature, runner state, recent progress. |
| `/wreck-it-ralph-loop:harness-cancel` | Stop after the current session. |

**Key rules the gates enforce:** one feature per session; the coder may only *claim*, the tester alone marks features *passing* (an unverified pass is reset); the feature spec is locked; the tree is committed clean after every session; a loop stops when all features pass, at the session cap, or when stuck; only one loop runs per project.

Config lives in `.harness/config.json` (pipeline, limits, `final_verify_command`, `allow_dirty`). Details: README.md.

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

### /wreck-it-ralph-loop:ralph-loop <PROMPT> [OPTIONS]

Start a Ralph loop in your current session.

**Usage:**
```
/wreck-it-ralph-loop:ralph-loop "Refactor the cache layer" --max-iterations 20
/wreck-it-ralph-loop:ralph-loop "Add tests" --completion-promise "TESTS COMPLETE"
```

**Options:**
- `--max-iterations <n>` - Max iterations before auto-stop
- `--completion-promise <text>` - Promise phrase to signal completion

**How it works:**
1. Creates `.claude/ralph-loop.local.md` state file
2. You work on the task
3. When you try to exit, stop hook intercepts
4. Same prompt fed back
5. You see your previous work
6. Continues until promise detected or max iterations

---

### /wreck-it-ralph-loop:cancel-ralph

Cancel an active Ralph loop (removes the loop state file).

**Usage:**
```
/wreck-it-ralph-loop:cancel-ralph
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
/wreck-it-ralph-loop:ralph-loop "Fix the token refresh logic in auth.ts. Output <promise>FIXED</promise> when all tests pass." --completion-promise "FIXED" --max-iterations 10
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
