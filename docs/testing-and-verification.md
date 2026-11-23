# Testing and verification in wreck-it-ralph

**English** · [Tiếng Việt](testing-and-verification.vi.md)

A plain-words explanation of the testing and verification ideas this plugin applies, written to be re-read later. Command details live in `README.md`, section "Testing".

## 1. Core ideas

1. **The coder never grades its own work.** The coder writes code and may only `claim` ("I think it is done"). Only the **tester** can mark a feature `pass`.
2. **No evidence, no PASS.** The tester must run the real app and have replay results for every example. Without them the gate resets the feature to `failing`.
3. **What counts as right or wrong is locked data, not the coder's code.** These are the *examples* (test cases) in `feature_list.json`. The coder cannot edit them.
4. **The tester is an independent evaluator.** It runs in a fresh context, reads code, and may not change the product. The gate checks this in code; it does not trust the prompt.
5. **The grader is measured too.** Calibration counts how often the evaluator is wrong, above all false positives (PASS for something that is broken).

## 2. How a session runs

```
coder -> [gate: run verify commands] -> tester -> [gate: check, reset if rules were broken]
```

- **Coder:** implements exactly one feature, RED then GREEN (section 4), then `claim`s it.
- **Verify gate:** the feature's `verify` commands (for example `pytest ...`) are run by the gate, so the coder cannot fake them. If one fails, the feature fails and never reaches the tester.
- **Tester:** replays the examples, probes a few cases beyond them, checks regressions, then gives a verdict.
- **End gate (`step.sh end`):** resets every "pass" that lacks complete evidence, was produced by a tester that edited the product, or was set by the coder.

## 3. Examples: how to write a test case

An example is a locked test case of a feature: an `input`, an `expect`, and `assertions` (how to compare):

```json
{
  "id": "EX001",
  "name": "create a valid user",
  "input":  {"method": "POST", "path": "/users", "body": {"name": "Ada"}},
  "expect": {"status": 201, "body": {"name": "Ada"}},
  "assertions": {"body": "partial"}
}
```

- **Adapters** make the real call against the running app: `http` (sends `method/path/body`, compares `status/headers/body`) or `cli` (sends `args/stdin`, compares `exit_code/stdout/stderr`). An example never contains a shell command.
- **Comparison modes** per key of `expect`: `exact`, `partial` (expected is a subset of actual; the default when expected is an object), `contains`, `regex`.
- **Multi-step:** an example may have `steps: [...]`, plus `setup` and `cleanup` to build and remove data.
- **Who writes examples:** the initializer, when it creates the feature list. To add a case later use `/wreck-it-ralph:example` (a proposal you approve) or let the tester/coder file one with `backlog.sh propose`. Nobody edits an example so that the app looks right.
- **What each feature should cover:** the normal case, invalid input, a missing required field, odd values (unicode, empty), and the error path.

Replay by hand: `.harness/replay.sh <ID>` (or `--example EX001`).

## 4. RED, then GREEN (tests first)

For a feature with examples the coder must:

1. Make the test or example **fail for the right reason** before writing code, then run `.harness/feature-list.sh red <ID>`. It runs `verify` and the replay and records RED only if something really fails.
2. Implement until it passes (GREEN).
3. `claim` is refused without RED. If the behaviour already exists, use `red <ID> --skip "<why>"`; the tester can see that reason.

The point is to prove the test can catch a bug, not that it is always green.

## 5. The tester's verdict

The tester gives its verdict with `.harness/report.sh <ID> <verdict> "<note>"`:

| Verdict | Meaning |
|---|---|
| `pass` | Correct. Refused unless every example was replayed in this run. |
| `fail` | Broken, with a reproduction. Counts as a failed attempt. Add `--findings file.json` so the coder receives structured defects. |
| `blocked` | Could not be tested (app or environment down). Not a logic failure. |
| `inconclusive` | Not enough evidence, or an ambiguous description. Becomes a question for a human. |

Each verdict writes `evidence/<ID>/report.json` and `report.md`: which examples passed, coverage, and the commands to replay it yourself.

Beyond the examples the tester must also check the coder's "known issues", try 3 to 5 extra cases implied by the description (boundaries, empty input, unicode, rapid repeats, restart), and check 1-2 related passing features for regression.

## 6. Coverage: seeing what was not tested

`.harness/coverage.sh run --id <ID>` runs the test suite under coverage. `coverage.sh gaps <ID>` lists branches the feature's diff added that never ran. The tester classifies each gap (needs an example, redundant code, defensive branch, or verified by a probe with evidence).

Two rules: coverage is for **visibility**, not a percentage target; and reaching a branch does not mean the branch is right. A ratchet (`coverage.mode: gate`) can stop coverage from dropping below a baseline that a human recorded.

## 7. The tester is read-only

- The tester may read code and run the app, tests, replays and the browser. It may write only under `.harness/` (evidence, progress, `init.sh` fixes) and a temp directory.
- The gate fingerprints the product tree (everything outside `.harness/`) when the tester starts and when it ends.
  - Tracked file edited, or a new file committed: the gate **reverts it**, resets every feature the tester passed in that session, and reports `TESTER_EDITED`.
  - Only new untracked files (probe leftovers): the gate removes them and warns; verdicts stand.
- Limit: this detects and undoes the change afterwards; it does not block writes during the session. For a hard boundary, run the tester in a separate checkout.
- Config: `tester.read_only` (default true), `tester.allow_paths`.

## 8. Calibration: measuring the grader

The dangerous error is a **false positive**: the evaluator says PASS, the feature is broken, and the loop builds on it. `.harness/calibrate.sh` measures this from three sources:

| Source | What it is | Truth comes from |
|---|---|---|
| `comparator` | Known-answer cases fed through the replay comparison engine. 16 are seeded in `.harness/calibration/cases.json` (normal, invalid input, missing field, unicode, wrong type, regression, ...). | the case's `truth` field |
| `scan` + `label` | A feature that passed and later failed becomes a candidate. You label it `false_positive`, `regression` or `dismiss`. | your label |
| `record` | You (or the tester) log a wrong verdict you found. | you |

An example calibration table:

| Case | Truth | Evaluator | Result |
|---|---|---|---|
| normal input | PASS | PASS | correct |
| invalid input accepted | FAIL | PASS | **false positive** |
| required field missing | FAIL | FAIL | correct |
| unicode | PASS | PASS | correct |

`calibrate.sh report` shows false positives and their rate (over cases whose truth is fail), false negatives and their rate, the regression detection rate, and acceptance-criteria coverage (how many examples have current passing replay evidence, and how many features have no examples at all).

The gate uses it in three places: it refuses to start a new run (code 13) if the comparison engine lets a known-bad case through; every session ends with a scan that warns about features that passed and later failed; and it restores the cases if an agent edits them.

Not done yet: measuring the tester's own judgement (the LLM part). Today it relies on your labels and `record`. There are no planted-defect runs (inject a known bug and check that the tester catches it).

## 9. Quick map: which command does what

| Goal | Command |
|---|---|
| See a feature's examples | `.harness/feature-list.sh examples <ID>` |
| Replay examples | `.harness/replay.sh <ID> [--example EX001]` |
| Record RED | `.harness/feature-list.sh red <ID>` |
| Tester verdict | `.harness/report.sh <ID> pass\|fail\|blocked\|inconclusive "..."` |
| Coverage | `.harness/coverage.sh run\|gaps\|classify\|ratchet` |
| Calibration | `.harness/calibrate.sh run\|record\|scan\|label\|report` |
| Propose a new example | `/wreck-it-ralph:example` or `.harness/backlog.sh propose` |
| Health check | `/wreck-it-ralph:doctor` |

## 10. Things to remember

- Evidence lives in `.harness/evidence/` and is git-ignored. Copy out what you want to keep.
- The rules live in the gate (code), not in prompts. Prompts guide; resets, reverts and the spec lock are done by `step.sh`.
- Pre-release: these mechanisms are covered by scripted tests only; they have not run with a real `claude` yet.
