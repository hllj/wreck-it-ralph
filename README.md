# wreck-it-ralph

> **Status: 0.0.6, a pre-release.** The harness has been exercised by its own test suite (`bash tests/run-tests.sh`) and by one small end-to-end run (a Python API, two sessions, three features). Expect rough edges, and read [Known limits](#known-limits) before relying on it. Earlier internal numbering (3.x) was reset to 0.0.1; see `CHANGELOG.md`.

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

The repository is its own one-plugin marketplace (`.claude-plugin/marketplace.json`), so Claude Code can install it straight from GitHub or from a local checkout.

### Requirements

- **Claude Code 2.1.275 or later** for the one-step `--marketplace` install. Older versions can use the two-step form below. Check with `claude --version`.
- **`bash`**, **`git`** with `user.name` and `user.email` set, and **`jq`**.
- **macOS or Linux.** Windows isn't supported, because the scripts need bash and POSIX tools; WSL may work but is untested.
- **Optional:** `gh` (for issue intake and pull requests at rollout L2) and `npx` (for the Playwright browser tester in the `web` preset).

### From GitHub

In Claude Code:

```
/plugin install wreck-it-ralph --marketplace <owner>/wreck-it-ralph
```

Replace `<owner>/wreck-it-ralph` with the GitHub repository that hosts this plugin. The same thing from a terminal:

```bash
claude plugin install wreck-it-ralph --marketplace <owner>/wreck-it-ralph
```

On an older Claude Code, add the marketplace first, then install from it:

```
/plugin marketplace add <owner>/wreck-it-ralph
/plugin install wreck-it-ralph@wreck-it-ralph
```

### From a local checkout

To install it permanently from a folder on disk:

```bash
claude plugin install wreck-it-ralph --marketplace /path/to/wreck-it-ralph
```

A folder install is read live from that folder, so there is nothing to update: edits take effect at the next session, or straight away with `/reload-plugins`.

To try it for a single session without installing anything:

```bash
claude --plugin-dir /path/to/wreck-it-ralph
```

### Scope

Installs go to your user settings by default, so the plugin is available in every project. Add `--scope project` to record it in the project's `.claude/settings.json`, so everyone on the repository gets it. `--scope local` keeps it to this project on your machine.

### Check that it works

In Claude Code, run `/wreck-it-ralph:help`. Then, inside a project, run `/wreck-it-ralph:setup --check` to verify the prerequisites, or `/wreck-it-ralph:doctor` once a harness exists.

### Update or remove

For a GitHub install:

```bash
claude plugin update wreck-it-ralph@wreck-it-ralph
```

To uninstall (either kind):

```bash
claude plugin uninstall wreck-it-ralph@wreck-it-ralph
```

After an update, run `/wreck-it-ralph:setup --refresh` in each project. `/wreck-it-ralph:run` also does this when it starts, so the `.harness/*.sh` wrappers point at the new copy. Uninstalling leaves each project's `.harness/` folder in place.

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
| `init "<goal>" [--brownfield] [--preset P] [--branch NAME] [--allow-dirty]` | Runs setup, then the **initializer** agent writes `feature_list.json`, `init.sh` and `progress.md` (and `stop.sh` if init.sh starts servers). The spec is then locked and committed. `--brownfield` maps an existing codebase first. |
| `add "<request>" [--approve]` | The **planner** agent turns a request into small, verifiable features and files a **proposal**. You review it (including every verify command) and approve it. Works on any initialized project, at any time. |
| `backlog [list\|approve\|reject\|answer\|drop\|priority ...]` | Manage the living backlog: approve or reject proposals, answer questions the loop escalated, drop or reprioritize features. |
| `trust` | Review the repo-supplied config (permissions, commands, MCP servers, custom agents, verify commands) and trust it. |
| `run [--max-sessions N]` | Interactive loop. This session orchestrates fresh coder and tester subagents. |
| `run-headless [--max-sessions N] [--once]` | Unattended loop with separate `claude -p` processes. |
| `status` / `cancel` / `help` | Progress, questions and proposals / stop after the current session / explanation. `.harness/status.sh --json` is the machine-readable form. |
| `trigger cron\|launchd\|github\|loop [--every 2h] [--rollout L1]` | Start runs without you: print a cron line, write a launchd agent or a GitHub Actions workflow (on a schedule, or when CI fails), or a `/loop`. Defaults to rollout L1 with 3 sessions per run. |
| `intake [github] [--label ralph]` | Turn new labelled GitHub issues (or another tracker's items, through its MCP tools) into planner proposals for your approval. |
| `demo <ID> [--run\|--example EX\|--step N\|--from A --to B\|--keep]` | Replay a feature's locked examples against the running app (list, all, one, or step by step) and show expected vs actual. |
| `example <ID> "<case>"` | Propose a new example for a feature's contract. It joins the locked spec only after you approve it. |
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
| **curator** (`agents/curator.md`) | Every 10 sessions (default pipeline), distils `progress.md` and the failure history into `.harness/learnings.md`: commands that work, conventions, approaches that failed, and decisions. Every agent reads it first. |
| **tester** (`agents/tester.md`) | An independent, skeptical verifier. Replays the locked examples on the running app, reads the coverage gaps and probes them, checks the coder's known issues, and records one of four verdicts (`pass`, `fail`, `blocked`, `inconclusive`) with evidence. It is the only role that marks a feature `passing`. |
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
- **Auto-escalation.** After `escalate_after_failures` consecutive failures, counted since the last pass or human answer, (default 3, `0` turns it off), the gate escalates the feature itself, with the last failure note as the question.
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
| 12 | Rollout branch problem: detached HEAD, an empty repository, or the branch was switched mid-run |

### Budgets and the ledger

Every agent run is recorded in `.harness/ledger.jsonl`, which is git-ignored.

**What gets recorded:**
- **Headless mode** reads cost, tokens, duration and turns from `claude -p --output-format json`.
  - The raw JSON is kept as `NNN-<agent>.json` next to the readable `.log`.
  - When the installed CLI supports `--max-budget-usd`, each call is also capped at the budget left for the run.
- **Interactive mode** has the orchestrator record the token count and duration that the Agent tool reports. There is no dollar cost there, so use `max_tokens` and `max_wall_minutes` to cap interactive runs. Usage is reported in **tokens**, not dollars: `TOTAL = input + output + cache creation`; cache reads are shown separately (`CACHE_READ`) and are not counted. Cost appears only where the CLI reports it. `.harness/step.sh ledger report [--all] [--by session]` prints the table; in-session runs report a total only, so their row is marked `*`. Token budgets (`max_tokens`) are checked between agents, never in the middle of one call; only the dollar cap can also limit a single call.

**How the caps work:**
- Budgets apply **per run**. Each `run --new-run` starts a fresh budget, so raising a cap or starting again continues the work.
- `0` means unlimited.
- The gates check the caps before every session and after it ends.
- `/status`, the per-session log lines and `.harness/last-run.md` show what was spent. `.harness/step.sh ledger total` prints the totals.

## Testing: examples, replay, coverage

The testing side of the harness is built on three rules: **no evidence, no PASS**; **coverage is visibility, not correctness**; and **agents point at gaps, humans decide**.

### Contract, example, replay

| Term | Meaning | Where it lives |
|---|---|---|
| Contract | The behaviour that must hold | the feature's `description` in `feature_list.json` (locked) |
| Example | One concrete case of the contract, as data | `examples[]` of the feature (locked with the spec) |
| Replay | How an example is run against the real app | an adapter: `http` or `cli` |

```json
"examples": [{
  "id": "EX001", "name": "empty cart", "description": "Reject checkout when the cart is empty",
  "input": {"method": "POST", "path": "/checkout", "body": {"items": []}},
  "expect": {"status": 400, "body": {"error": "cart cannot be empty"}},
  "assertions": {"status": "exact", "body": "partial"}
}]
```

- **Assertion modes:** `exact`, `partial` (the expected value is a subset of the actual one), `contains`, `regex`. The default is `exact`, or `partial` when the expected value is an object. `expect` must be machine-checkable; prose like "works correctly" is not an oracle.
- **Adapters:** `http` takes `{method, path, headers, query, body}` and compares `status`, `headers` (lowercase names) and `body`. `cli` takes `{args, stdin, env}` and compares `exit_code`, `stdout`, `stderr`. The command comes from the trusted `replay.command`, arguments are passed as an array, and an example never contains a shell command.
- **Flows and fixtures:** an example may have `steps` (run in order, stopping at the first failure), `setup` and `cleanup` (fixture steps with the same adapter). Names can use `{{namespace}}`, a unique id per run, so cleanup removes only what the run created. `--keep` leaves the data for you to inspect.
- **Locked:** examples are part of the spec. A coder or tester cannot edit them. New ones arrive through proposals (`/wreck-it-ralph:example`, or `add_examples` in a proposal) that you approve; approving one sends the feature back to `todo` because its contract changed.

### RED, then GREEN

For a feature with examples the coder works test-first. `.harness/feature-list.sh red <ID>` runs the feature's `verify` commands **and replays its examples** against the running app, and only records RED if something fails. `claim` is refused until RED is recorded. When the behaviour already exists the coder uses `red <ID> --skip "<why>"`, which the tester can see.

### The tester's evidence

`.harness/replay.sh <ID>` replays examples (exit 0 pass, 1 fail, 3 blocked: the app is unreachable, 4 not configured). Results go to `.harness/evidence/<ID>/<EX>/result.json` with the commit, the example's hash and the actual output. Evidence is git-ignored.

The tester gives its verdict with `.harness/report.sh <ID> <verdict> "<note>"`:

| Verdict | Meaning |
|---|---|
| `pass` | Verified and correct. Refused unless every example has a passing replay from this run. |
| `fail` | Verified and broken. Counts as a failed attempt. |
| `blocked` | Could not be tested (app or environment). The feature stays claimed and no attempt is counted. If every claimed feature is blocked, the loop stops with code 9. |
| `inconclusive` | Not enough evidence; becomes a question for you (`needs_human`). |

At the end of a session the gate resets any feature with examples that passed without complete replay evidence. `report.json` and `report.md` in the evidence folder show the examples, the coverage and how you can replay it yourself.

### Coverage

`.harness/coverage.sh run --id <ID>` runs the test suite under coverage and writes normalized reports to `.harness/coverage/`.

| Stack | How |
|---|---|
| Python | `coverage.py` with `--branch`, from the project's `.venv` (never installed for you) |
| Node | Istanbul JSON from vitest, jest, c8 or nyc, using the binaries in `node_modules/.bin` |
| Go | `go test -coverprofile`; statements only, **no branch data** (`branches` is `null`, never 0%) |
| Other | `coverage.cmd` writes `coverage.py`, Istanbul or Go-profile data to `$COVERAGE_JSON`, with `coverage.format` naming the format |

- **Scopes are never mixed.** `repository.json` is the whole repo; `<ID>.json` covers the files changed since the session started and says so: it is changed-file coverage, not feature coverage.
- **Gaps.** `coverage.sh gaps <ID>` lists the branches and lines of the diff that never ran. The tester classifies each one (`needs_example`, `redundant_code`, `defensive_branch`, `inconclusive`, or `verified_by_probe` with evidence of the behaviour it checked, not only that the branch was reached) with a confidence. Nothing is deleted because of a gap, and no test is written just to lift a number.
- **Baseline and ratchet.** A human records `coverage.sh baseline` (committed; tied to a commit, the tool version and a config fingerprint). `coverage.sh ratchet` then fails if coverage dropped, in two tiers: the whole repository, and every changed file that has a baseline entry. New files are only reported, renames follow `git diff -M`, and exact `covered/total` ratios are compared. If the baseline is missing, the config or tool changed, or the suite is red, the result is "not comparable" (exit 4) and never blocks. `baseline --update` only raises; lowering needs `--accept-decrease "<reason>"`; both are refused inside a loop session.
- **Mode.** `coverage.mode` is `report` by default (advisory). With `"gate"`, a session whose passed features lowered coverage fails them.

### Known limits

- **Pre-release.** One end-to-end run with real agents on a small Python API; nothing else. The `jest`, `vitest` and `nyc` commands, and the whole Go path (tested against a hand-written profile only), have not run against real projects.
- **Replay** supports `http` and `cli` only; there is no Playwright adapter, so a `web` project is checked at the endpoint level. The `http` adapter always sends JSON, so it cannot send a malformed body (`raw_body` is not implemented).
- **Coverage is per session.** When several features are verified in one batch, or coders run in parallel, the gate cannot attribute a regression to one feature and fails all of them.
- **Mutation testing** and an automatic check for tests without assertions are not implemented. See `docs/ROADMAP-v4-testing.md`.

## Scale and reach

### Parallel coders (headless)

```json
"parallel": { "max_workers": 3 }
```

With `max_workers > 1`, the headless runner fans the coder step out over **git worktrees** (`.harness/worktrees/<id>`, git-ignored).

- **Batch selection.** The batch is the next ready feature plus further ready features whose `tags` are disjoint from the batch. Untagged features never run in parallel, because their area is unknown, so tag features (`api`, `ui`, `db`, …) to allow it.
- **Workers.** Each worker is a fresh headless coder on its own `harness/wt-<session>-<id>` branch. It is told to stay inside its feature, and it gets an equal share of the remaining budget.
- **Merge gate.** After all workers finish, each branch is merged into the main tree.
  - The spec and status files never merge. The gate applies each worker's claim, question or proposals itself, so the spec lock stays intact.
  - `progress.md` uses git's union merge.
  - A merge conflict fails only that feature, with a note. The branch is kept for reference, and the next attempt starts from the merged code.
- **After the merge.** The verify gate and the tester then check all the claims as usual.
- **Interruptions.** Worktrees left by an interrupted run are cleaned up at the next run, and their work is committed to their branch first.

Interactive runs stay sequential, because subagents cannot be pinned to a worktree's directory reliably.

### Memory

- **`learnings.md`** is short and curated, and every agent reads it before `progress.md`. The curator rewrites it every 10 sessions.
- **`progress.md` rotation.** Over `progress_max_kb` (default 64), the gate moves older entries to `progress/archive-NNN.md`, split at an entry heading, and keeps the newest ~150 lines.
- **`attempts[]`** on each feature keeps the failure history that both of these draw on.

### Presets and existing projects

`setup --preset` / `init --preset`:

| Preset | Pipeline | Guidance for the initializer and tester |
|---|---|---|
| `web` | coder → tester (+ Playwright MCP) → curator | steps are browser interactions |
| `api` | coder → tester → curator | steps are HTTP requests with expected status and body |
| `cli` | coder → tester → curator | run the command, check output and exit code |
| `data` | coder → tester → curator | run pipelines on fixed samples, check outputs |
| `docs` | coder → tester → curator | features are pages; verify by building the docs and checking links |
| `library` | coder → curator (no tester) | every feature needs `verify` tests: the verify gate is the verifier |
| `none` | coder | |

`init --brownfield "<goal>"` maps an existing codebase:
- `init.sh` is written from the real build and run commands, and no product code changes.
- The essential behaviour that already works is recorded as **baseline** features (`status: claimed`, `source: baseline`). The tester verifies them in session 1, and after that they guard against regressions.
- The goal's new work comes after them as `todo` features.

### Per-step models and cleanup

- **Models:** `"model"` on a pipeline step (for example `{ "agent": "tester", "when": "claimed", "model": "haiku" }`) overrides the global model for that step. Interactive runs accept `sonnet`, `opus`, `haiku` and `fable`; headless runs pass any model name to `claude -p`.
- **Models per role:** the `agents` block in `.harness/config.json` sets a model per role. Defaults: initializer, planner and tester `opus` (a weak verifier lets bad passes through), coder `sonnet`, curator `haiku`. **Escalation:** `agents.coder.escalate_model` (default `opus`) replaces the coder model once the target feature has `escalate_after` (default 1) failed attempts, before `escalate_after_failures` hands it to a human; a `model` on the pipeline step pins the model and turns escalation off. `.harness/step.sh ledger report [--all]` shows runs, escalations, cost and tokens per role and model. Precedence: pipeline step `model` > `agents.<role>.model` > top-level `model` > session default; `"inherit"` or `""` means no override. The block is part of the trust record.
- **Planner in plan mode:** the planner always runs read-only (`tools: Read, Grep, Glob`, `--permission-mode plan` headless) and no config can change that. It returns a JSON payload; `/add` and `/intake` file it with `backlog.sh propose`, and you still approve it. Headless: `.harness/run.sh --plan "<request>"`. Plugin agents cannot set `permissionMode` in frontmatter, so the mode is enforced by the tool list and the runner.
- **`.harness/stop.sh`:** written by the initializer when `init.sh` starts servers. The gate runs it when a loop ends, and it is covered by trust.

## Rollout, triggers and intake

Earn trust in a loop step by step, then let it run without you.

### Rollout levels

Set `"rollout"` in the config, or pass `--rollout` to `run` / `run-headless` / `.harness/run.sh`.

| Level | What happens | Your branch |
|---|---|---|
| **L1 shadow** | The loop works on `harness/shadow-<time>`, then switches back and leaves a report (`last-run.md`, with commit count and diffstat). | never touched |
| **L2 assisted** | The loop works on `harness/run-<time>`. With `rollout_push` it pushes the branch; with `rollout_pr` it also opens a PR via `gh`. A new run resumes the same branch if it is checked out. | never touched |
| **L3 unattended** | The loop commits on the current branch (the default and earlier behaviour). | commits land here |

- **Tracking:** the base branch is recorded in `git config branch.<run-branch>.harnessBase`.
- **Branch switches:** if someone switches branches mid-run, the next session stops with code 12 and the fix.
- **Trust:** `rollout_push` and `rollout_pr` are part of the trust record, because they send code out.

### Triggers

`/wreck-it-ralph:trigger` (or `.harness/trigger.sh`) sets up runs that start without you. New triggers default to **L1, 3 sessions per run**: move them to L2 once the shadow reports look right. Nothing is installed into your system for you.

| Kind | What you get |
|---|---|
| `cron --every 30m\|2h\|daily\|weekly` | a crontab line to add with `crontab -e` |
| `launchd --every …` | a LaunchAgent plist under `.harness/triggers/` (git-ignored), plus the `launchctl load` command |
| `github --cron "0 3 * * *" [--on-failure "CI"] --plugin-repo owner/name` | `.github/workflows/wreck-it-ralph.yml`, see below |
| `loop --every 2h` | the `/loop 2h /wreck-it-ralph:run …` command for an open interactive session |

The GitHub workflow:
- runs headless with `ANTHROPIC_API_KEY`;
- opens PRs at L2, or only uploads the report at L1;
- refuses L3, so CI never commits to the default branch;
- accepts the committed `.harness` config without the interactive trust review, so use it only if `.harness/` changes go through code review. The file says this at the top.

### Intake from issue trackers

`/wreck-it-ralph:intake` gets new open issues labelled `ralph` (`--label`, `--limit`, `--repo`) with `gh`. For Linear, Jira and others it uses that tracker's MCP tools if they are connected.
- Each issue goes to the planner and becomes one proposal `by intake:github#12`.
- Imported ids are recorded in `.harness/intake.json`, so nothing is imported twice.
- Issue text is treated as **untrusted**: the planner is told not to follow instructions in it, and approving such a proposal prints its verify commands again with a warning. Approval is always yours.

### Notifications

- **`setup --notify`** adds `needs_human` and `run_ended` hooks that call `.harness/notify.sh`. It uses a desktop notification on macOS (`osascript`) or Linux (`notify-send`), and falls back to a terminal bell.
- **Interactive runs** also send a `PushNotification` when the loop needs you or finishes, if that tool is available.
- **Anything else** (Slack, email, a pager) is a `cmd:` hook away.

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
  "lock_timeout_minutes": 120,
  "replay": { "adapter": "", "base_url": "http://127.0.0.1:3000", "command": "", "timeout_seconds": 30 },
  "coverage": { "tool": "", "cmd": "", "format": "coveragepy", "runner": "", "branch": true, "omit": [], "max_gaps": 50, "mode": "report",
                "ratchet": { "enabled": true, "scope": ["repository", "changed_files"], "allow_new_files": true, "tolerance": 0 } }
}
```

- **Where pipeline agents are looked up:** `.harness/agents/`, then the plugin's `agents/`, then `templates/agents/`.
- **`every`:** run the agent every N sessions.
- **`when`:** `always`, `claimed` or `failing`. The verify gate runs before the first `claimed` step.
- **No tester:** if the pipeline has no `tester`, claims that pass the verify gate are accepted as passes.
- **`replay`:** `adapter` is `http` or `cli` (default from the preset: `api` and `web` use `http`, `cli` uses `cli`); `base_url` (or the `BASE_URL` environment variable) is the running app; `command` is the executable for the `cli` adapter.
- **`coverage`:** `tool` is auto-detected (`go.mod` → go, `package.json` → node, Python markers → python); `cmd` and `format` replace the built-in runner; `runner` picks vitest, jest, c8 or nyc; `omit` takes globs; `mode` is `report` or `gate`.

## Safety model

- **Your work is protected.**
  - Harness commits use `git add -A`, so `init` refuses to start in a git project with uncommitted changes. Use `--branch NAME` to work on a separate branch, or `--allow-dirty` to include them.
  - Starting a loop on a dirty tree is refused unless `allow_dirty` is set. Changes under `.harness/` don't count.
- **Trust.**
  - Some settings come from the repository and can run commands: `permission_mode`, `allowed_tools`, `final_verify_command`, `verify_static`, `replay.command`, `coverage.cmd`, `claude_bin`, `model`, the MCP config, custom agents in `.harness/agents/`, and the features' `verify` commands.
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

Apache-2.0 (see `LICENSE` and `NOTICE`). Derived from Anthropic's Ralph Loop plugin. The Ralph Wiggum technique is credited to Geoffrey Huntley, and the harness design to Anthropic's long-running agents article. The roadmaps are in `docs/ROADMAP-v3.md` (harness) and `docs/ROADMAP-v4-testing.md` (testing).
