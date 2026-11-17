# wreck-it-ralph

A Claude Code plugin for building software **gradually, over many sessions**, by combining three ideas:

- **Long-running harness** (Anthropic, [Effective harnesses for long-running agents](https://www.anthropic.com/research/effective-harnesses-for-long-running-agents)):
  - Each session runs in a fresh context.
  - The initializer writes a feature list, `init.sh`, a progress log and git history.
  - Every later session implements one feature, verifies it end to end and leaves a clean tree.
- **Ralph loop** (Geoffrey Huntley): keep feeding the same task to the agent until it is really done. The harness uses this as its inner loop: a feature is retried in fresh contexts, each attempt told why the last one failed.
- **Loop engineering**: the loop itself is the product.
  - Its stop rules, verifiers, budgets and escalation points are declared in config and enforced by deterministic scripts (the *gates*), not left to the model's memory.
  - The agent that writes the code is never the one that decides it passes.

It also ships the original in-session **Ralph loop** (`/wreck-it-ralph:ralph`) for quick, single-task iteration.

## Install

```
/plugin install wreck-it-ralph --marketplace <owner>/<repo>
```

Replace `<owner>/<repo>` with the marketplace that hosts the plugin, or try it locally with `claude --plugin-dir /path/to/wreck-it-ralph`.

Requirements:
- `bash`
- `git`, with `user.name`/`user.email` set
- `jq`
- macOS or Linux (Windows: use WSL, see below)

> Upgrading from `wreck-it-ralph-loop` 2.x:
> - Commands are now shorter (`/wreck-it-ralph:run` instead of `/wreck-it-ralph-loop:harness-run`).
> - Existing `.harness/` folders keep working unchanged.
> - Run `/wreck-it-ralph:setup --refresh` once, then `/wreck-it-ralph:trust`, because the trust record now also covers verify commands, pipeline `use:` steps and hooks.

## Quick start

```bash
/wreck-it-ralph:init "Build a todo web app with auth, lists, and drag-and-drop"
/wreck-it-ralph:run                  # interactive: fresh-context subagents in this session
/wreck-it-ralph:add "Export lists as CSV and import them back"   # grow the backlog at any time
/wreck-it-ralph:backlog              # proposals, questions from the loop, priorities
/wreck-it-ralph:run-headless         # unattended: separate `claude -p` processes
/wreck-it-ralph:status
/wreck-it-ralph:cancel               # stops after the current session
```

| Command | What it does |
|---|---|
| `setup [--preset web\|cli\|none] [--check] [--refresh] [--force]` | Create or repair the `.harness/` scaffold. Checks prerequisites, writes the preset config, wrappers and `.gitignore` entries. Safe to re-run. |
| `init "<goal>" [--branch NAME] [--allow-dirty]` | Runs setup, then the **initializer** agent writes `feature_list.json`, `init.sh` and `progress.md`. The spec is then locked and committed. |
| `add "<request>" [--approve]` | The **planner** agent turns a request into small, verifiable features and files a **proposal**. You review it (including every verify command) and approve it. Works on any initialized project, at any time. |
| `backlog [list\|approve\|reject\|answer\|drop\|priority ...]` | Manage the living backlog: approve or reject proposals, answer questions the loop escalated, drop or reprioritize features. |
| `trust` | Review the repo-supplied config (permissions, commands, MCP servers, custom agents, verify commands) and trust it. |
| `run [--max-sessions N]` | Interactive loop. This session orchestrates fresh coder and tester subagents. |
| `run-headless [--max-sessions N] [--once]` | Unattended loop with separate `claude -p` processes. |
| `status` / `cancel` / `help` | Progress, questions and proposals / stop after the current session / explanation. `.harness/status.sh --json` is the machine-readable form. |
| `doctor` | Health check: tools, git, config, feature list, trust, wrappers, and whether every pipeline extension (other plugins' agents, skills) and hook resolves. |
| `ralph "<prompt>" [--max-iterations N] [--completion-promise T]` / `cancel-ralph` | The original in-session Ralph loop. |

All commands are namespaced: `/wreck-it-ralph:<command>`.

## How a session works

```
begin gate ─▶ coder (fresh) ─▶ verify gate ─▶ tester (fresh) ─▶ [custom agents] ─▶ end gate
   │             claim only      runs the feature's     only role that      reviewer, cleaner,    spec lock, clean tree,
   │                             verify commands        may `pass`          ...                   escalation, stuck check
   └─ picks the next READY feature: not passing, not waiting on a human, all depends_on passing, by priority
```

| Piece | Role |
|---|---|
| **initializer** (`agents/initializer.md`) | Runs once. Writes `feature_list.json` (all `todo`), `init.sh`, `progress.md`. Implements nothing. |
| **planner** (`agents/planner.md`) | Runs from `/add`. Decomposes a request into features with `steps`, `verify`, `depends_on`, `tags`, and files them as one proposal. Implements and approves nothing. |
| **coder** (`agents/coder.md`) | One feature per session. Follows the startup routine (progress, git log, `init.sh` + smoke test, fix breakage first), implements, runs the verify commands, **claims**, commits, logs. It can `ask` a human or propose a split instead of guessing. |
| **verify gate** (`step.sh verify`) | Runs `verify_static` (from config) and the feature's `verify` commands **in the gate, not in an agent**. If any of them fails, the feature fails and the tester is skipped. Logs go to `.harness/sessions/NNN-verify-<ID>.log`. |
| **tester** (`agents/tester.md`) | An independent, skeptical verifier. Exercises the `steps` end to end (Playwright MCP for web), probes beyond them, checks the coder's known issues. It is the only role that marks a feature `passing`. |
| **custom agents** | Any `.harness/agents/<name>.md`; templates are in `templates/agents/` (`reviewer`, `cleaner`). Add them to the pipeline with `every` / `when`. |
| **extensions** | Pipeline steps that `use:` another plugin's agent, a skill, a slash command or a gate-run shell command. See "Working with other plugins". |
| **gates** (`scripts/harness-step.sh`) | The deterministic rules both loop modes share: trust, lock, dirty-tree and identity checks, session cap, stuck detection, the ready queue, the verify gate, unverified-pass reset, the spec lock, escalation and the summary. |

### The living backlog

`.harness/feature_list.json` is the source of truth. A feature looks like this:

```json
{ "id": "F012", "category": "functional", "priority": 12,
  "description": "Export a list as CSV", "steps": ["Open a list", "Click Export", "The CSV has one row per item"],
  "verify": ["npm test -- -t 'csv export'"], "depends_on": ["F004"], "tags": ["export"],
  "status": "todo", "passes": false, "attempts": [] }
```

- **Status**: `todo`, `claimed`, `passing`, `failing`, `needs_human` or `dropped`.
  - Agents change status only through `.harness/feature-list.sh claim|pass|fail|ask`.
  - `attempts[]` keeps the last 20 events.
  - v2 files that only have `passes`/`claimed` are read transparently.
- **The spec is locked.** If an agent edits the spec (description, steps, verify, depends_on, ...), the gate restores it.
- **The spec grows through proposals.**
  - `.harness/backlog.sh propose` (used by the planner, or by the coder for a split) records an `add` / `amend` / `drop` payload in `.harness/proposals.json`.
  - A human approves it with `/wreck-it-ralph:backlog approve`, which validates the result, re-locks the spec and commits only the harness files.
  - Approvals are refused while a session is running. One made anyway (for example by an agent editing the lock directly) is undone at `end`. Proposals filed during the session are kept.
- **Amending a feature** changes its description, steps or verify commands and re-opens it, even if it already passed.

### Escalation instead of spinning

- **Asking a human.** A coder or tester that needs a decision runs `feature-list.sh ask <ID> "<question>"`. The feature waits in `needs_human` and **the loop keeps going with the other features**.
- **Auto-escalation.** After `escalate_after_failures` consecutive failures (default 3, `0` turns it off), the gate escalates the feature itself, with the last failure note as the question.
- **Answering.** Answer with `/wreck-it-ralph:backlog answer F012 "use UTF-8"`. The next coder gets the answer, and the previous failure note, in its task message.
- **Retries.** Every retry of a failed feature is told why the last attempt failed and not to repeat it.

### Stop reasons

| Code | Reason |
|---|---|
| 0 | All features pass (and `final_verify_command` succeeds), or a STOP flag (`/cancel`) |
| 2 | `max_sessions` reached |
| 3 | Stuck: `stuck_limit` sessions without a new passing feature or a new escalation |
| 4 / 5 / 6 / 7 | Dirty tree / config not trusted / no git identity / another loop running |
| 8 | Every remaining feature waits for a human answer |
| 9 | The remaining features have dependencies that can never pass (for example a cycle) |
| 10 | A run budget is used up: `budget.max_cost_usd`, `max_tokens` or `max_wall_minutes` |
| 11 | A session changed more than `budget.max_diff_lines` lines and `on_large_diff` is `stop` (review, then run again) |

### Budgets and the ledger

Every agent run is recorded in `.harness/ledger.jsonl`, which is git-ignored.

**What gets recorded:**
- **Headless mode** reads cost, tokens, duration and turns from `claude -p --output-format json`.
  - The raw JSON is kept as `NNN-<agent>.json` next to the readable `.log`.
  - When the installed CLI supports `--max-budget-usd`, each call is also capped at the budget left for the run.
- **Interactive mode** has the orchestrator record the token count and duration that the Agent tool reports. There is no dollar cost there, so use `max_tokens` and `max_wall_minutes` to cap interactive runs.

**How the caps work:**
- Budgets apply **per run**. Each `run --new-run` starts a fresh budget, so raising a cap or starting again continues the work.
- `0` means unlimited.
- The gates check the caps before every session and after it ends.
- `/status`, the per-session log lines and `.harness/last-run.md` show what was spent. `.harness/step.sh ledger total` prints the totals.

## Working with other plugins

The harness is a host: any installed plugin's agents, skills and commands can be steps in its pipeline, and any tool can follow its progress.

### Pipeline extensions

```json
"pipeline": [
  { "agent": "coder", "blocking": true },
  { "agent": "tester", "blocking": true, "when": "claimed" },
  { "name": "review",   "use": "agent:pr-review-toolkit:code-reviewer", "when": "passed", "optional": true },
  { "name": "security", "use": "skill:security-review", "when": "tag:auth", "optional": true },
  { "name": "changelog","use": "command:/docs:changelog", "every": 10, "optional": true },
  { "name": "build",    "use": "cmd:npm run build" }
]
```

| `use` | Runs as |
|---|---|
| `agent:<name>` | a harness agent (`.harness/agents/`, the plugin's `agents/`, `templates/agents/`) |
| `agent:<plugin>:<agent>` | another plugin's subagent type. Headless runs delegate to it from a `claude -p` session |
| `skill:<name>` · `skill:<plugin>:<skill>` · `command:/<plugin>:<cmd> args` | a fresh subagent that invokes it with the Skill tool |
| `cmd:<shell>` | a shell step run by the gate itself; the exit code is the result |

Step fields:
- `use:` steps default to `blocking: false`.
- `optional: true` skips the step with a note when the plugin is not installed, so a missing plugin never breaks a run.
- `when` also accepts `passed` (a feature passed this session) and `tag:<tag>` (the target feature has that tag).

Extension steps are told the session's commit range and which features passed. They may `fail` a feature they find broken, or `propose` follow-up features. They can never `pass` a feature or edit the spec. Run `/wreck-it-ralph:doctor` to see which references resolve on this machine.

### Events and hooks

Every gate transition is appended to `.harness/events.jsonl` (git-ignored), one JSON object per line:

| Event | Extra fields |
|---|---|
| `run_started` | |
| `session_started` | `target` |
| `feature_claimed` | |
| `verify_failed` | `command` |
| `feature_passed` | `feature` |
| `feature_failed` | `note` |
| `needs_human` | `question` |
| `session_ended` | `stats` |
| `run_ended` | `reason`, `code` |
| `step_finished` | |
| `proposal_filed` | |
| `proposal_approved` | |

`hooks` in the config attach shell handlers to these events:

```json
"hooks": {
  "needs_human": ["cmd:osascript -e \"display notification \\\"$HARNESS_QUESTION\\\" with title \\\"Harness\\\"\""],
  "run_ended":   ["cmd:./scripts/notify.sh"]
}
```

- Each handler gets the event JSON on stdin and `HARNESS_EVENT`, `HARNESS_FEATURE`, `HARNESS_REASON`, `HARNESS_CODE`, `HARNESS_QUESTION`, … in its environment.
- Output goes to `.harness/sessions/hooks.log`.
- A failing handler is reported but never stops the loop.
- Hooks and `cmd:` steps are part of the trust record, so they don't run until you've reviewed them with `/wreck-it-ralph:trust`.

### Status contract

`.harness/status.sh --json` prints a versioned snapshot (`"schema": 1`) for status lines, dashboards and other plugins:
- feature counts by status, and `next`
- `questions` and `proposals_pending`
- `runner` and `session` state
- `spend`
- `last_event`

### Designing loops

The bundled `loop-design` skill teaches Claude how to set up and tune a loop: verification levels, budgets, escalation, pipeline recipes, hooks, and a pre-flight checklist for unattended runs. Ask, for example, "help me harden this loop for an overnight run".

## Configuration (`.harness/config.json`)

```json
{
  "version": 3,
  "max_sessions": 100,
  "stuck_limit": 3,
  "escalate_after_failures": 3,
  "budget": { "max_cost_usd": 25, "max_tokens": 0, "max_wall_minutes": 480, "max_diff_lines": 800, "on_large_diff": "warn" },
  "verify_static": "npm run lint && npx tsc --noEmit",
  "final_verify_command": "npm test",
  "permission_mode": "acceptEdits",
  "allowed_tools": "Bash,Read,Edit,Write,Glob,Grep,NotebookEdit,mcp__playwright",
  "mcp_config": ".harness/mcp.json",
  "pipeline": [
    { "agent": "coder",    "blocking": true },
    { "agent": "tester",   "blocking": true, "when": "claimed" },
    { "agent": "reviewer", "blocking": false, "every": 5 }
  ],
  "allow_dirty": false,
  "lock_timeout_minutes": 120
}
```

- **Where pipeline agents are looked up:** `.harness/agents/`, then the plugin's `agents/`, then `templates/agents/`.
- **`every`:** run the agent every N sessions.
- **`when`:** `always`, `claimed` or `failing`. The verify gate runs before the first `claimed` step.
- **No tester:** if the pipeline has no `tester`, claims that pass the verify gate are accepted as passes.

## Safety model

- **Your work is protected.**
  - Harness commits use `git add -A`, so `init` refuses to start in a git project with uncommitted changes. Use `--branch NAME` to work on a separate branch, or `--allow-dirty` to include them.
  - Starting a loop on a dirty tree is refused unless `allow_dirty` is set. Changes under `.harness/` don't count.
- **Trust.**
  - Some settings come from the repository and can run commands: `permission_mode`, `allowed_tools`, `final_verify_command`, `verify_static`, `claude_bin`, `model`, the MCP config, custom agents in `.harness/agents/`, and the features' `verify` commands.
  - A loop refuses to start until you have reviewed them with `/wreck-it-ralph:trust`. The record is kept in the git-ignored `.harness/.trusted`.
  - Configs that setup generates are trusted automatically. So are verify commands written by the initializer in your session, or approved by you in a proposal.
- **Headless permissions.** The default is `acceptEdits` with an explicit tool list. The runner warns about `bypassPermissions`. Use a sandbox or a throwaway checkout for unattended runs.
- **The tester is independent.** The coder may only `claim`. At `end`, any feature that became passing without being claimed when the tester started is reset.
- **One loop per project.** A heartbeat lock enforces this; clear a stale lock with `.harness/step.sh unlock`.
- **Commits are safe.**
  - Commit failures are reported, not swallowed. Files over 5 MB trigger a warning.
  - Language-specific ignore sets are added and re-detected at every loop start.
  - The wrappers in `.harness/*.sh` contain machine-specific paths, so they are git-ignored and they self-heal.

## Logs and summary

- **Headless agent output:** `.harness/sessions/NNN-<agent>.log`.
- **Verify gate output:** `NNN-verify-<ID>.log`.
- **Interactive notes:** `NNN-notes.md`.
- **Spend per agent run:** `.harness/ledger.jsonl`. The summary shows the run total.
- **Session narrative:** `.harness/progress.md`.
- **Run summary:** every stop writes `.harness/last-run.md`, with the stop reason, every feature with its status and note, open questions, pending proposals, commits and agent notes.

Run the script tests with `bash tests/run-tests.sh`. It uses a fake `claude`, and CI runs it on Linux and macOS plus `shellcheck`.

---

## In-session Ralph loop

`/wreck-it-ralph:ralph "<prompt>" --max-iterations 20 --completion-promise "DONE"` starts a loop inside your current session:
1. A Stop hook blocks Claude from ending its turn.
2. It feeds the **same prompt** back, so Claude sees its own previous work in files and git.
3. The loop ends when:
   - the promise (if set) is given **and** the `--verify` command (if set) exits 0;
   - `--max-iterations` or `--max-minutes` is reached;
   - with `--allow-blocked`, Claude ends honestly with `<promise>BLOCKED: what I need</promise>`;
   - you run `/wreck-it-ralph:cancel-ralph`.

`--verify 'npm test'` is a real check: the hook runs it, and if it fails it feeds the output tail back to Claude with the prompt. So "I'm done" is not enough to end the loop.

Every ending is recorded in `.claude/ralph-loop.last.md` (outcome, iterations, prompt). `/wreck-it-ralph:add --from-ralph` turns that task into backlog features once it outgrows a single loop.

The loop is scoped to the session that started it.

Use it for one well-defined task with an automatic check (for example `--verify 'npm test'`). For anything spanning many features, use the harness, which adds fresh contexts, an independent tester and a tracked backlog.

Prompt tips:
- **Put the completion criteria in the prompt.**
- **Work in phases or with TDD.**
- **Always set `--max-iterations` (or `--max-minutes`)**, and prefer `--verify` over a promise alone.
- **Say what to do when stuck:** document blockers, list what was tried.

Windows: the hook is a bash script and needs Git for Windows. If `bash` resolves to a broken WSL, point `hooks/hooks.json` at `"C:/Program Files/Git/bin/bash.exe"` in the cached plugin copy.

## License and credits

Apache-2.0 (see `LICENSE` and `NOTICE`). Derived from Anthropic's Ralph Loop plugin. The Ralph Wiggum technique is credited to Geoffrey Huntley, and the harness design to Anthropic's long-running agents article. The roadmap is in `docs/ROADMAP-v3.md`.
