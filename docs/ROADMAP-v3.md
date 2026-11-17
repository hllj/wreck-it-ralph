# wreck-it-ralph v3: analysis and improvement plan

Status: **Phases 0 and 1 are implemented in v3.0.0, and Phase 2 in v3.1.0** (2026-11-17). Phases 3 to 5 are still proposals. The plan started from `wreck-it-ralph-loop` v2.1.0.

Implementation notes (where v3.0.0 differs from the plan below):
- State stays in `.harness/` and the config stays `.harness/config.json` (now with `"version": 3`). There is no `.ralph/` directory and no `loop.json` yet. Moving the directory brought churn for existing users and no benefit, so it is deferred until the Phase 3 loop spec needs a new file.
- Verification ladder: V1/V2 are implemented as config `verify_static` plus per-feature `verify` commands. They are run by the gate before the tester (or before acceptance when there is no tester). V3/V4 remain the tester. V5 (human) is the `needs_human` status.
- `blocked` is not a stored status. A feature with unmet `depends_on` is simply not ready, and stop code 9 reports when nothing can ever become ready.
- Retry context: each retry of a failed feature gets the last failure note and any human answer, and is told not to repeat the failed approach. That part of Phase 2's inner loop shipped early. `escalate_after_failures` (default 3) bounds the retries.
- Phase 2, as built:
  - The **inner loop** is the next session retrying the same ready feature in a fresh context, with the failure note and any human answer, bounded by `escalate_after_failures`. There is no extra retry loop inside a session: the orchestrator stays flat, and a session is already the unit of fresh context.
  - **Budgets** live under `budget` in `config.json` (`max_cost_usd`, `max_tokens`, `max_wall_minutes`, `max_diff_lines`, `on_large_diff`). They apply per run and are checked at `begin` and `end`, giving stop codes 10 and 11.
  - The **ledger** is `.harness/ledger.jsonl`. Headless mode parses `claude -p --output-format json` and passes `--max-budget-usd` when the CLI supports it. Interactive mode records the tokens and duration the Agent tool reports, so a dollar cap is exact only in headless mode.
  - **Ralph mode** gained `--verify` (run by the hook; its failing output is fed back), `--max-minutes`, `--allow-blocked` (`<promise>BLOCKED: …</promise>`), JSON-quoted state values (which fixes promises containing quotes), an outcome record in `.claude/ralph-loop.last.md`, `/add --from-ralph`, and a 600 s hook timeout.
  - Not built: an `on_terminal` hook (it belongs to Phase 3's extension points) and a shared state file between Ralph mode and the harness. They stay separate on purpose: Ralph mode is zero-setup.
- Trust now has two parts: the config hash and the verify-command hash. Commands written by the initializer or approved in a proposal are trusted automatically, while repo-supplied ones need `/trust`.

## 1. The three source ideas

### 1.1 Ralph Loop (anthropics/claude-plugins-official, `plugins/ralph-loop`, v1.0.1)

How it works:
- A `Stop` hook reads `.claude/ralph-loop.local.md`. The file has YAML frontmatter (`active`, `iteration`, `session_id`, `max_iterations`, `completion_promise`, `started_at`) and the prompt as its body.
- When Claude tries to stop, the hook returns `{"decision":"block","reason":<same prompt>}` and increments `iteration`.
- The loop ends when the last assistant text block contains `<promise>TEXT</promise>` matching the promise exactly, when `max_iterations` is reached, or when the state file is corrupt.
- `session_id` keeps the loop scoped to the session that started it.

Strengths: very little machinery (one file, one hook). State lives in files and git, and the prompt stays the same, so the agent improves by reading its own past work.

Weaknesses:
- **The agent decides when it is done** (the promise). This is the self-grading anti-pattern.
- There is only one success condition and no named failure states (BLOCKED, NEEDS_HUMAN).
- All iterations share **one growing context**, which is compacted rather than reset.
- No budget other than an iteration count.
- No structure across tasks, and only one loop per project.

### 1.2 Effective harnesses for long-running agents (Anthropic Engineering, Nov 2025)

Problem: each session starts with no memory. Agents either **one-shot** (run out of context halfway through) or **declare victory too early**.

Fix:
- An **initializer** session writes `feature_list.json` (every feature `passes:false`, with `steps`), `init.sh`, a progress file and the first commit.
- Each **coding session** follows a fixed routine (pwd, progress, git log, pick one feature, init.sh plus smoke test), implements **one** feature, verifies it end to end in a browser, commits and logs progress.
- JSON is used for the feature list because models are less likely to overwrite it.
- Agents may only flip `passes`.

Open questions the article lists:
- Specialized agents (QA, cleanup) versus one generalist.
- Domains other than web apps.

### 1.3 Loop engineering (term coined around June 2026)

The engineer's job moves from writing prompts to **designing the loop that prompts, checks and guides the agent**. arXiv 2607.00038 treats a loop as a portable **loop spec** with five parts: trigger, goal, verification, stopping rule and memory. Sources agree a good loop has:

| Building block | Meaning |
|---|---|
| Trigger | Manual, scheduled (cron, routines) or event-based (CI failure, new issue, PR) |
| Durable state ("spine") | Files or a tracker the agent rewrites every cycle. arXiv 2608.21884 found that almost no public repos commit their loop state. |
| Independent verifier | Test suite > separate checker agent > model-as-judge. Never self-grading. |
| Stop rule + named terminal states | success / blocked / budget / stuck / needs-human |
| Budgets | Tokens, cost, time, tool calls, diff size |
| Permissions and isolation | Tool allowlists, worktrees, merge gates |
| Human escalation | Defined handoff points, not so frequent that the loop stops saving time |
| Staged rollout | L1 report-only, then L2 assisted, then L3 unattended |

Pattern families: Ralph (same prompt, fresh agent, until verified), maker-checker, queue-drain, plan-execute-verify, cron refresh / drift, subagent fan-out.

Anti-patterns:
- No exit condition.
- Retrying the same failed approach.
- Context overflow.
- Vague goals.
- Self-grading and reward hacking.
- "Comprehension debt" and "intent debt".

### 1.4 How they fit together

- **Ralph** is the *inner loop* primitive: keep going on one thing until the verifier says yes.
- The **harness** is the *outer loop*: a queue of verifiable units, fresh context per unit, state on disk.
- **Loop engineering** is the *design discipline* over both: make the trigger, verifier, stop rule, budget and escalation explicit, declarative and auditable.

## 2. Where this project stands (v2.1.0)

What is already strong (keep it):
- The full harness: initializer, coder and tester agents.
- A locked spec (hash plus restore).
- A `claim`-only coder and a tester that is the only role allowed to `pass`, with unverified passes reset.
- Deterministic gates in `harness-step.sh`: begin/end, stuck detection, STOP flag, session cap, final verify.
- Trust hashing and a heartbeat lock.
- Interactive (subagent) and headless (`claude -p`) modes that share state.
- A configurable pipeline (`every`, `when`, `blocking`).
- 130 checks in the test suite.

That already covers more than half of the loop-engineering checklist.

Gaps, measured against the combined model:

| # | Gap | Effect |
|---|---|---|
| G1 | **The feature list is frozen after init.** Nothing can be added, split, deprioritized or amended once it is locked. | Not "gradual": a new requirement means re-initializing. |
| G2 | **Two unrelated loops.** The Ralph stop-hook loop ignores the harness gates and still finishes on a self-declared promise. | Two mental models, and the weak verifier survives. |
| G3 | **No verification ladder per feature.** "Passed" always means tester judgment. A feature cannot declare `verify: "npm test -- auth"`. | Missed chance to use the strongest, cheapest verifier: commands. |
| G4 | **Few terminal states.** done / stop / stuck only. No `blocked` or `needs-human` status on a feature. | The loop spins on, or stops entirely, when one feature needs a human. |
| G5 | **No budgets** beyond session count (no cost, tokens, wall-clock, diff size). | Unattended runs have no cost ceiling. |
| G6 | **Weak interop.** The pipeline can only call agents in `.harness/agents/`, plugin `agents/` or templates. It cannot call another plugin's agent (`other-plugin:agent`), a skill, a slash command or a shell verifier. Nothing is emitted for other tools to consume. | Contradicts the goal of working with other plugins. |
| G7 | **Linear, single-threaded queue.** No `depends_on` and no parallel worktree fan-out for independent features. | Slow on large lists. |
| G8 | **No triggers** other than a manual start (no schedule/routine, CI-failure or issue intake). | Not a "loop" in the loop-engineering sense. |
| G9 | **Memory is narrative only.** progress.md grows without bound. `fail` overwrites earlier notes (REVIEW L8). There is no distilled "learnings" file. | Later sessions repeat dead ends. |
| G10 | **Greenfield bias.** The initializer assumes a new web app. There is no brownfield mapping and no non-web domain presets. | Limited reach (the article's own open question). |
| G11 | **Naming.** The plugin is `wreck-it-ralph-loop`, the requested name is `wreck-it-ralph`. Commands are long (`/wreck-it-ralph-loop:harness-run`). | Friction. |
| G12 | Open REVIEW low findings L1–L10 (dev-server cleanup, per-agent `model`, CI/shellcheck, STOP-flag loss, state validation, ...). | Hygiene. |

## 3. Target design: "wreck-it-ralph" v3

Principle: **one loop engine, many loop specs.** Everything the loop does is declared in `.ralph/loop.json` and executed by deterministic gates. Agents do the work, scripts own the rules, and other plugins plug in at named extension points.

```
          trigger (manual | /loop | schedule | CI fail | issue)
                               |
                     +---------v----------+
   backlog --------->|  OUTER LOOP (gates) |  picks next ready unit (DAG, priority)
 (features.json,     |  budget · lock ·    |-----> terminal: done | blocked |
  intake adapters)   |  trust · rollout    |       needs_human | budget | stuck
                     +---------+----------+
                               | one unit, fresh context
                     +---------v----------+
                     |  INNER LOOP (Ralph) |  maker --> verifier ladder --> retry
                     |  max_attempts,      |  (same unit, new context, notes
                     |  per-unit budget    |   from the previous attempt)
                     +---------+----------+
                               | hooks: pre_unit / post_claim / post_pass / on_fail
                     +---------v----------+
                     |  EXTENSION POINTS   |  other plugins' agents, skills,
                     |                     |  commands, shell verifiers, MCP
                     +--------------------+
```

### 3.1 Loop spec (`.ralph/loop.json`)

This replaces and extends `.harness/config.json`, with automatic migration.

```jsonc
{
  "version": 3,
  "goal": "Todo app with auth",               // human intent, kept to avoid "intent debt"
  "rollout": "L3",                             // L1 report-only | L2 assisted (PR/branch, human merges) | L3 unattended
  "trigger": { "kind": "manual" },             // manual | schedule | ci_failure | issue_label (see 3.7)
  "budget": { "max_sessions": 100, "max_wall_minutes": 480, "max_cost_usd": 40, "max_attempts_per_unit": 3, "max_diff_lines": 800 },
  "stop": { "stuck_limit": 3, "final_verify": "npm test && npm run e2e" },
  "escalation": { "on": ["needs_human", "budget", "stuck"], "notify": "push" },
  "parallel": { "max_workers": 1, "isolation": "worktree" },
  "pipeline": [
    { "role": "maker",    "use": "agent:coder" },
    { "role": "verifier", "use": "ladder" },
    { "role": "review",   "use": "agent:engineering:code-review", "blocking": false, "every": 5, "optional": true },
    { "role": "security", "use": "skill:security-review", "when": "tag:auth", "optional": true }
  ],
  "hooks": { "post_pass": ["cmd:git push origin HEAD"], "on_terminal": ["event:log"] },
  "memory": { "learnings": ".ralph/learnings.md", "progress_max_kb": 64 }
}
```

### 3.2 Living backlog (fixes G1, G4, G7)

Feature entries gain fields:
- `depends_on`, `tags`
- `verify` (see 3.3)
- `status`: `todo | in_progress | claimed | passing | failing | blocked | needs_human | dropped`
- `attempts[]`, an append-only history that fixes L8
- `source` (`init | user | intake:github#123 | split:F012`)

The spec lock becomes **append-only plus amendment proposals**:
- Agents can never edit an existing spec field.
- Agents may *propose* changes: `ralph backlog propose split F012 ...` or `propose add ...`. Proposals go to `.ralph/proposals/`.
- A human approves proposals with `/wreck-it-ralph:backlog approve`. At rollout L3, proposals can be auto-approved when a `planner` agent and the verifier agree, configurable and off by default.
- The lock then re-hashes. Tamper-protection stays intact while the list can still grow.

New commands:
- `/wreck-it-ralph:add "<feature or epic>"` runs a small **planner** agent that turns the request into 1..N features with steps and `verify`, appended through a proposal. This is the "gradually implement" entry point and works on any project at any time.
- `/wreck-it-ralph:backlog [list|approve|drop|reprioritize|unblock <id> "<answer>"]`.
- A feature in `needs_human` is **skipped**, not a full stop. The loop continues on the rest, and stops with `needs_human` only when nothing is ready.

### 3.3 Verification ladder (fixes G3, Ralph's self-grading)

Each feature declares the cheapest strong verifiers. The gate runs them in order, and a unit passes only when every declared level passes:

| Level | Kind | Example | Who runs it |
|---|---|---|---|
| V1 | static | `npm run lint && tsc --noEmit` | gate script |
| V2 | command | `npm test -- --grep F012` | gate script (exit code) |
| V3 | e2e steps | `steps[]` through Playwright, or any browser MCP | tester agent |
| V4 | probe/judge | edge-case probing, review against the description | tester or other plugin agent |
| V5 | human | screenshot/report, approve in `/backlog` | user (rollout L2) |

Scripted levels (V1/V2) are run **by the gate**, not by an agent, so the result cannot be faked. The tester is spawned only when V1/V2 are green, which saves cost. `verify` defaults to V3+V4, which is today's behaviour.

### 3.4 Unified Ralph inner loop (fixes G2)

- `/wreck-it-ralph:ralph "<prompt>"` remains as the quick, zero-setup mode. It gets an optional `--verify "<cmd>"` that the Stop hook runs: the stop is allowed only when the command exits 0 **and** (if set) the promise appears. With `--verify`, the promise alone is no longer enough. The hook also gains named outcomes (`<promise>BLOCKED: reason</promise>` ends the loop as blocked and writes a note) and `--max-minutes`.
- Inside the harness, the inner loop is "retry the same unit up to `max_attempts_per_unit` in fresh contexts". Each retry gets the previous attempt's verifier output and notes, and is told **not to repeat the failed approach** (the loop-engineering anti-pattern). After that the unit goes to `failing` or `needs_human`, and the outer loop moves on.
- One state-file format (`.ralph/state.json`) for both modes, scoped by `session_id`. Ralph mode can be "promoted" into a harness backlog with `/wreck-it-ralph:add --from-ralph`.

### 3.5 Budgets and named terminal states (fixes G4, G5)

- Headless mode runs `claude -p --output-format json` and accumulates the reported cost/usage into `.ralph/ledger.jsonl`. It also uses the CLI's turn/budget flags where the installed version supports them. Detect at setup; do not assume.
- Interactive mode tracks wall-clock time and session counts, and has the orchestrator record each subagent's reported usage when available.
- `max_diff_lines` per unit is checked at `end`: an oversized diff becomes `needs_human` at L2 and a warning at L3.
- Terminal reasons become a fixed enum, `done | blocked | needs_human | budget | stuck | cancelled | error`. Each maps to an exit code and an `on_terminal` hook. `escalation.notify: push` uses the push-notification tool where available.

### 3.6 Interop with other plugins (fixes G6)

Make wreck-it-ralph a **host** for other plugins instead of a closed pipeline:

1. **Universal `use:` references** in pipeline steps and hooks:
   - `agent:<name>` or `agent:<plugin>:<name>` becomes a subagent of that type.
   - `skill:<name>` is a general-purpose subagent told to invoke the skill.
   - `command:/<plugin>:<cmd> args` runs a slash command in a subagent.
   - `cmd:<shell>` runs through the gate, inside trust.
   - `event:<name>` only emits.

   `optional: true` means the step is skipped with a note when the plugin is not installed, so a missing plugin never breaks a run. `/wreck-it-ralph:doctor` lists which references resolve.
2. **Extension points**: `pre_run`, `pre_unit`, `post_claim`, `post_pass`, `on_fail`, `on_terminal`, `post_run`. Typical uses:
   - Code review after every pass.
   - Security review for `tag:auth`.
   - Docs/changelog at `post_run`.
   - Opening a PR at L2.
3. **Event stream** `.ralph/events.jsonl`, one JSON line per gate transition (`unit_started`, `verified`, `terminal`, ...). Other plugins, status lines or dashboards can read it without coupling. Add a `ralph status --json` contract.
4. **Intake adapters** (feature sources): `intake: { "kind": "github_issues", "label": "ralph" }`, or Linear/Jira through whatever MCP server the user already has. The adapter is a small agent that maps issues to proposals. It is never auto-approved below L3.
5. **A skill (`skills/loop-design/SKILL.md`)** teaches any session (or other plugin) how to write a good `loop.json` and feature `verify` entries. Claude can then help design loops conversationally, which is the "loop engineering" craft itself.
6. **Be a good neighbour:**
   - The Stop hook exits immediately when no ralph state exists for *this* session.
   - Namespaced state lives only in `.ralph/`.
   - Never block other plugins' hooks.
   - Document the hook ordering.

### 3.7 Triggers (fixes G8)

- `trigger.kind: schedule` creates a scheduled routine or `/loop` that runs `ralph run --headless` (L1 report-only by default for new scheduled loops, per staged rollout).
- `ci_failure`: a GitHub Actions template `templates/ci/ralph-on-failure.yml` runs headless with `rollout: L2`, so it opens a PR and never pushes to main.
- `issue_label`: intake (3.6.4) plus one run.
- Every triggered run is still bounded by the budget and the lock. A trigger never widens permissions.

### 3.8 Parallel fan-out (fixes G7)

- With `parallel.max_workers > 1`, the gate picks up to N **ready** units (all `depends_on` passing, no shared `tags:area`).
- Each unit runs in its own git worktree.
- The merge gate rebases each passing worktree, re-runs V1/V2 on the result and fast-forwards. On conflict the unit goes back to `todo` with a note.
- Default stays 1. Parallelism is opt-in.

### 3.9 Memory (fixes G9)

- `learnings.md`: every N sessions a `curator` step distils progress.md and failure notes into short, durable rules (commands that work, gotchas, conventions). The maker reads it at startup, before progress.md.
- progress.md is rotated to `progress/NNN.md` past `progress_max_kb`. Only the tail and learnings are read.
- `attempts[]` per feature keeps every failure reason (fixes L8).

### 3.10 Domains and brownfield (fixes G10)

- An `initializer --mode brownfield` maps the existing code, writes `init.sh` from the real scripts, and records already-working behaviour as `passing` features with `verify` commands, so they serve as regression guards. Its first proposals need approval.
- Presets beyond `web|cli|none`: `api`, `library` (V1/V2 only, no browser), `data` (notebook/script with output checks), `docs`. A preset only sets default `verify` levels and the pipeline.

## 4. Roadmap

Each phase ships on its own, keeps the test suite green, and migrates state automatically.

### Phase 0: Rename and foundations (small)

- Rename the plugin to `wreck-it-ralph` (plugin.json, README, command namespace, test strings).
- Shorter command names: `init`, `run`, `run-headless`, `status`, `cancel`, `trust`, `setup`, `ralph`, `cancel-ralph`.
- Keep `.harness/` readable; new state goes in `.ralph/`, with a `migrate` step in `setup` that converts `config.json` to `loop.json` (v3) and leaves a symlink or compat shim for one version.
- Fix the cheap REVIEW lows:
  - L5: cancel wording.
  - L6: don't silently delete STOP; report it.
  - L7: validate state with a clear error.
  - L10: drop `perl` from the stop hook, fix the "cannot be stopped" text.
  - L3: `mktemp` logs in tests.
- Add GitHub Actions CI with shellcheck and the test suite (L4).
- **Note:** this directory is not a git repo right now. `git init` plus a first commit is a prerequisite for safe refactoring.

### Phase 1: Living backlog and the ladder (core value for "gradually implement")

- Feature schema v3 (`status` enum, `depends_on`, `tags`, `verify`, `attempts[]`, `source`) with migration from `passes`.
- Proposals plus re-lock flow, the `planner` agent, `/add`, `/backlog`.
- Gate-run V1/V2 verifiers. Spawn the tester only when they pass.
- `needs_human` / `blocked` statuses with skip-and-continue.
- Tests: proposal approve/reject, tamper still restored, DAG ordering, ladder short-circuit.

### Phase 2: Inner loop and budgets

- `max_attempts_per_unit` with retry context ("don't repeat X").
- Ledger, `max_cost_usd`, wall-clock and diff caps, the terminal-state enum plus exit codes.
- Ralph mode: `--verify`, named promises, `--max-minutes`, shared state format, `--from-ralph` promotion.

### Phase 3: Interop

- `use:` resolver (agent / plugin-agent / skill / command / cmd / event) with `optional`.
- Extension points, `events.jsonl`, `status --json`, `/doctor`.
- `loop-design` skill.
- `reviewer` / `cleaner` templates re-expressed as `use:` examples. Document recipes that pair with common plugins (code-review, security-review, testing-strategy, docs).

### Phase 4: Triggers, rollout levels, intake

- `rollout` L1/L2/L3 semantics: L1 writes a report and makes no commits to the main branch; L2 uses a branch plus PR; L3 is today's behaviour.
- Schedule trigger via routines or `/loop`, the CI template, the issue intake adapter.
- Push notification on escalation.

### Phase 5: Scale and reach

- Worktree fan-out plus merge gate.
- `curator` and learnings, progress rotation.
- Brownfield initializer and the new presets.
- Per-role `model` in `loop.json` (cheaper tester or curator; fixes L2).
- Dev-server stop script (L1).

## 5. Risks and decisions to make

| Topic | Recommendation |
|---|---|
| Spec mutability vs tamper safety | Append-only plus human-approved proposals. Auto-approve only at L3 and only when opted in. |
| Subagents cannot spawn subagents | Keep the flat orchestrator. The inner loop is retries by the orchestrator, not nested agents. |
| Interop with plugins that may be missing | Every external `use:` is `optional` by default, resolved by `/doctor`, and skipped with a note. |
| Cost reporting differs by mode | Exact in headless (JSON output), best-effort in interactive. Document the difference. |
| Breaking rename | Ship the rename plus a compat shim in one release, and remove `.harness/` support in the next. |
| Scope creep | Phase 1 alone delivers "gradual feature development". Phases 3–5 can be cut independently. |

## 6. Sources

- Ralph Loop plugin: https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop
- Effective harnesses for long-running agents: https://www.anthropic.com/research/effective-harnesses-for-long-running-agents
- Loop engineering: https://www.ibm.com/think/topics/loop-engineering, https://arxiv.org/abs/2608.21884, https://arxiv.org/abs/2607.00038, https://github.com/cobusgreyling/loop-engineering, https://github.com/rudy2steiner/awesome-agent-loops, https://www.mindstudio.ai/blog/what-is-loop-engineering-ai-coding-agents, https://adtmag.com/articles/2026/07/01/loop-engineering-emerges-as-developers-put-ai-coding-agents-on-repeat.aspx
