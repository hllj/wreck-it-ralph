---
name: loop-design
description: Design or tune a wreck-it-ralph loop - .harness/config.json (pipeline, verify gate, budgets, escalation, hooks), feature verify commands and depends_on, and how to plug other plugins' agents and skills into the pipeline. Use when the user wants to set up, harden, extend or debug a long-running agent loop, asks how to make the harness work with another plugin, or wants a loop that verifies itself.
---

# Designing a wreck-it-ralph loop

A loop is only as good as its **verifier**, its **stop rules** and its **escalation**. Before you edit anything, read `.harness/config.json`, `.harness/feature-list.sh stats` and `.harness/doctor.sh`. Change config by editing the file. Change **features** only through proposals (`.harness/backlog.sh propose`, or `/wreck-it-ralph:add`) and let the user approve them. Any change to commands, the pipeline or hooks needs `/wreck-it-ralph:trust` again, and only the user may accept it.

## 1. Verification: the strongest check you can afford

Order of preference:

| Level | Where | Example |
|---|---|---|
| V1 static | `verify_static` in config, run for every claim | `npm run lint && npx tsc --noEmit` |
| V2 command | the feature's `verify: [...]`, run by the gate | `npm test -- -t 'csv export'`, `pytest tests/test_export.py -q` |
| V3 end to end | the tester agent runs `steps` (Playwright MCP for web) | always on when `tester` is in the pipeline |
| V4 judgment | the tester's probing, or extension reviewers | `agent:pr-review-toolkit:code-reviewer` with `when: passed` |
| V5 human | `needs_human`, `/wreck-it-ralph:backlog answer` | ambiguous product decisions |

Rules for `verify` commands:
- They must be deterministic, fast, non-interactive, and exit 0 only when the feature works.
- Prefer a **targeted** test per feature, and a full suite in `final_verify_command`.
- Never `verify` with something the coder could trivially satisfy (for example `test -f src/export.ts`).

## 2. Stop rules and budgets

```json
"max_sessions": 100, "stuck_limit": 3, "escalate_after_failures": 3,
"budget": { "max_cost_usd": 25, "max_tokens": 0, "max_wall_minutes": 480, "max_diff_lines": 800, "on_large_diff": "warn" },
"final_verify_command": "npm test"
```

- **Unattended runs** should always have a cost cap (headless) or a token and time cap (interactive).
- **`on_large_diff: "stop"`** is the right choice while you are still learning to trust a loop.
- **Escalation** keeps the loop moving: a feature that fails `escalate_after_failures` times becomes `needs_human`, and the loop works on the others.

Stop codes:

| Code | Meaning |
|---|---|
| 0 | done |
| 2 | max sessions |
| 3 | stuck |
| 4 | dirty tree |
| 5 | not trusted |
| 6 | no git identity |
| 7 | another loop is running |
| 8 | waiting for a human |
| 9 | blocked by dependencies |
| 10 | budget used up |
| 11 | large diff |

## 3. Pipeline: compose other plugins

Steps run in order after each session's coder. Each step is either `{"agent": "<name>"}` (classic) or a `use:` reference:

| `use` | Runs as |
|---|---|
| `agent:<name>` | a harness agent: `.harness/agents/<name>.md`, the plugin's `agents/`, or `templates/agents/` |
| `agent:<plugin>:<agent>` | another plugin's subagent type, for example `agent:pr-review-toolkit:code-reviewer` |
| `skill:<name>` / `skill:<plugin>:<skill>` | a fresh subagent that invokes the skill with the Skill tool |
| `command:/<plugin>:<cmd> args` | the same, for a slash command |
| `cmd:<shell>` | a shell step run by the gate itself; its exit code is the result |

Step fields:
- `name` (unique, required for `use:` steps)
- `blocking`: `use:` steps default to `false`
- `optional`: skip with a note when the plugin is not installed
- `every: N`
- `when`: one of `always`, `claimed`, `failing`, `passed` (a feature passed this session) or `tag:<tag>` (the target feature has that tag)

Extension steps receive the session's commit range and the features passed this session. They may `fail` a feature they find broken, or `propose` follow-ups, but they never `pass` or edit the spec.

Recipes (check what is installed with `.harness/doctor.sh`):

```json
"pipeline": [
  { "agent": "coder", "blocking": true },
  { "agent": "tester", "blocking": true, "when": "claimed" },
  { "name": "review",   "use": "agent:pr-review-toolkit:code-reviewer", "when": "passed", "optional": true },
  { "name": "security", "use": "skill:security-review", "when": "tag:auth", "optional": true },
  { "name": "docs",     "use": "agent:cleaner", "every": 10 },
  { "name": "bundle",   "use": "cmd:npm run build", "blocking": false }
]
```

## 4. Hooks: let other tools react

Every gate transition is appended to `.harness/events.jsonl` as `{"at", "event", ...}`. These events can be hooked:

| Event | When |
|---|---|
| `run_started` | a run begins |
| `session_started` | a session begins (`target`) |
| `feature_claimed` | the coder claimed a feature |
| `verify_failed` | a verify command failed (`feature`, `command`) |
| `feature_passed` | a feature passed |
| `feature_failed` | a feature failed (`note`) |
| `needs_human` | a feature needs a human (`question`) |
| `session_ended` | a session ended |
| `run_ended` | a run ended (`reason`, `code`) |
| `step_finished` | a `cmd:` step finished |
| `proposal_filed` | a backlog proposal was filed |
| `proposal_approved` | a backlog proposal was approved |

How handlers work:
- Handlers are `cmd:` strings. They get the event JSON on stdin and `HARNESS_EVENT`, `HARNESS_FEATURE`, `HARNESS_REASON`, … in the environment.
- Their output goes to `.harness/sessions/hooks.log`.
- They never stop the loop.

```json
"hooks": {
  "needs_human": ["cmd:osascript -e \"display notification \\\"$HARNESS_QUESTION\\\" with title \\\"Harness needs you\\\"\""],
  "run_ended":   ["cmd:curl -fsS -X POST \"$SLACK_WEBHOOK_URL\" -d \"{\\\"text\\\":\\\"harness: $HARNESS_REASON\\\"}\""]
}
```

For a machine-readable snapshot, other tools can read `.harness/status.sh --json` (`schema: 1`): it gives feature counts, the next feature, questions, pending proposals, runner and session state, spend, and the last event.

## 5. Checklist before an unattended run

1. `.harness/doctor.sh` is healthy, and every non-optional extension resolves.
2. Every feature that can have a `verify` command has one, and `final_verify_command` runs the full suite.
3. A budget is set, `on_large_diff` is chosen, and `escalate_after_failures` is at least 2.
4. `permission_mode` is `acceptEdits` with an explicit `allowed_tools`, in a sandbox or throwaway checkout if it is `bypassPermissions`.
5. A `needs_human` and a `run_ended` hook notify the user, so escalations don't sit unseen.
