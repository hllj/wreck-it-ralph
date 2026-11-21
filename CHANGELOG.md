# Changelog

## Unreleased

- `agents` config block: model (and permission mode) per role, with defaults opus/sonnet/haiku; `step.sh agent-info <role>`; `spawn-info` and the headless runner honor them.
- Tester defaults to `opus`. The coder escalates to `agents.coder.escalate_model` after failed attempts (`escalate_after`), and `ledger report` shows cost per role and model (the ledger now records `model` and `escalated`).
- The planner always runs in plan mode (read-only tools, returns a payload that the caller files); new `run.sh --plan "<request>"`.

## 0.0.1 (pre-release)

The version number was reset to 0.0.1. Everything before this was numbered 3.0.0 to 3.4.1 internally and was never released under that scheme; `docs/ROADMAP-v3.md` and `REVIEW.md` keep those numbers as history. The `"version": 3` in `.harness/config.json` is the config schema version and is unchanged.

### Harness (carried over)
- Living feature backlog with proposals you approve, fresh-context coder, verify gate, tester, curator, escalation to a human, stuck detection, budgets, staged rollout (L1-L3), parallel coders in worktrees, triggers and issue intake, presets and brownfield mode, extensions from other plugins, and the in-session Ralph loop.

### Testing subsystem (new in this release; see `docs/ROADMAP-v4-testing.md`)
- **Locked examples.** `examples[]` on a feature (id `EXnnn`, `input`, `expect`, `assertions` of `exact|partial|contains|regex`), validated and locked with the spec. Optional `steps`, `setup`, `cleanup` with `{{namespace}}`.
- **RED then GREEN.** `feature-list.sh red <ID>` runs the verify commands and replays the examples against the running app; `claim` is refused until RED (or `red --skip`) is recorded.
- **Replay engine.** `replay.sh <ID> [--example|--step|--from/--to|--keep|--list|--steps]` with `http` and `cli` adapters, no shell from examples, evidence under `.harness/evidence/`, exit codes 0/1/2/3 (blocked)/4 (not configured). `/wreck-it-ralph:demo` wraps it.
- **Evidence-based verdicts.** `report.sh <ID> pass|fail|blocked|inconclusive`; `pass` is refused without complete replay evidence from the tester's run, and the end gate resets a feature that passed without it. `blocked` is not a failed attempt; if every claimed feature is blocked the loop stops (code 9).
- **Proposals for examples.** `/wreck-it-ralph:example` and `add_examples` / `examples` in `amend` payloads.
- **Coverage.** `coverage.sh run|gaps|classify|check|show|baseline|ratchet` with a normalized schema; Python (coverage.py), Node (vitest, jest, c8, nyc via Istanbul JSON) and Go (cover profile, statements only), or a custom `coverage.cmd` with `coverage.format`. Changed-file scope (never called feature coverage), gaps with source context classified by the tester, a baseline tied to commit, tool version and config fingerprint, a two-tier ratchet (repository, changed files), and `coverage.mode: gate`.
- **Tester** rewritten: replay integrity, replay, coverage-guided probing, four verdicts, no editing of examples.

### Fixes
- A test that depended on a plugin copy installed under the real `$HOME` (stale wrapper) now isolates `HOME`.
- `jq`'s `//` treats `false` as empty, which made `coverage.branch: false` and `coverage.ratchet.enabled: false` ineffective; fixed.
- `harness-setup.sh` lists the replay, report and coverage wrappers.

### Verified, and not
- 456 script tests pass (fake `claude`; CI runs them on Linux and macOS with shellcheck).
- One real end-to-end run: a small Python API (3 features, 2 sessions, about $1.77). The real coder recorded RED before claiming and found and fixed a crash; the real tester replayed, probed, used coverage and the ratchet, and filed a proposal.
- Not exercised against real projects: jest, vitest and nyc runs, the whole Go path (profile parsing is tested with a hand-written profile), parallel coders with examples.

### Known limits
- No Playwright adapter: `web` projects are replayed at the endpoint level only.
- The `http` adapter always sends JSON (`raw_body` is not implemented), so a malformed body cannot be sent.
- Coverage is attributed per session, not per feature; a regression in a batch fails every feature passed in that session.
- Mutation testing and a static "test has no assertion" check (M11) are not implemented.
