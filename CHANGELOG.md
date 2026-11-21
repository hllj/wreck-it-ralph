# Changelog

## 0.0.7 (pre-release)

- Coder and tester prompts: keep checks inside the project. Examples, tests and README commands run with a temporary `HOME` and store paths, and the tester never reads, changes or deletes a pre-existing file at the app's default location. Found by a real `/run` on a todo CLI: the coder ran the README example with the default store location and wrote `~/.todo.json` into the real home directory. This is a prompt rule, not a technical block, and it has not been tried in a real run yet.
- Verified for real on that todo project (6 features): the coder on `sonnet` and the tester on `opus` as configured, the first escalations of the coder to `opus` after failed attempts (twice, on one feature), a tester `inconclusive` that became a question for a human and a run that stopped and resumed after the answer, and the corrected failure count (features that had passed were not escalated).
- Known: the tester kept finding rarer and rarer corrupt-store crashes on one feature (three attempts); there is no natural stopping point for that kind of probing yet. Python 3.8 and coverage were not available on the test machine.

## 0.0.6 (pre-release)

- Initializer prompt: the list is sized to the project (tiny tool 5-12 features, small app 12-40, large product 40-200) and edge cases are grouped into the same feature instead of one feature each. A real `/init` on a 3-command todo CLI produced 30 features with the old prompt and 6 with the new one.
- `/init` now passes the configured initializer model to the Agent call explicitly. Found by a real run: with a `haiku` main session the initializer ran on `haiku`. After the change the Agent call carries `model: opus`.
- Verified for real: `/init` end to end (scaffold, locked spec, examples, first commit, no permission denials). Not awaited before this release: the full result of the last run with the initializer on `opus`; the 6-feature result above came from a `haiku` initializer.
- Known: after `/init` the config can be untrusted because the initializer sets `replay.command`; run `/wreck-it-ralph:trust` before the loop.

## 0.0.5 (pre-release)

- Fix found by running `/add` for real with a `haiku` main session: the orchestrator left the planner Agent call in the background, so the proposal could not be filed (a background subagent finishes in a later turn where the command's `allowed-tools` no longer apply). `/add`, `/intake` and `/init` now require `run_in_background: false`.
- Verified for real: the planner model from `agents` reaches the subagent (a `haiku` session plus an `opus` planner, both in `modelUsage`), and filing works from a `haiku` main session after the fix (2 of 2).
- Known limit: this depends on the model following the instruction; the filing step is not covered by an automated test.

## 0.0.4 (pre-release)

- Fix found by a real `/run`: `feature-list.sh failures` counted every failed attempt since the last human answer, so a feature that failed, was fixed and later re-opened (for example by an amend) was escalated to the stronger coder model for nothing, and could be handed to a human. It now counts only fails since the last pass or answer.
- Verified for real: `/run` end to end (5/5 features, tester fail then fix, a proposal from the tester), the `agents` config applied (model `opus` and the `escalated` flag recorded in the ledger).

## 0.0.3 (pre-release)

- Fix found by running `/add` with a real `claude` session: `/add` and `/intake` now grant `Edit(.harness/tmp/**)` (a `Write(...)` rule is not honored) and file the planner's payload with `backlog.sh propose --file`; a JSON heredoc is rejected by the shell safety check. Existing projects need `/wreck-it-ralph:setup --refresh` so `.harness/tmp/` is git-ignored.
- Verified for real: `run.sh --plan` and `/add` (proposal filed, human approval asked) and the planner's `QUESTIONS` path.

## 0.0.2 (pre-release)

- `agents` config block: model (and permission mode) per role, with defaults opus/sonnet/haiku; `step.sh agent-info <role>`; `spawn-info` and the headless runner honor them.
- Tester defaults to `opus`. The coder escalates to `agents.coder.escalate_model` after failed attempts (`escalate_after`), and `ledger report` shows usage per role and model (the ledger now records `model` and `escalated`).
- Usage is reported in tokens: the ledger stores input, output, cache creation and cache read separately; `TOTAL = input + output + cache creation` (cache reads excluded and shown as `CACHE_READ`); `ledger report --by session`; cost is shown only when known; the run log, `/status` and `last-run.md` show tokens first.
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
