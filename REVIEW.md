# Plugin review: wreck-it-ralph-loop v2.0.0 (high and medium findings fixed; low findings open)

Scope: every file in the repo, the full test suite (68 checks passing), `claude plugin validate` (passes with one README warning), and targeted probes for the suspected problems. Items marked **confirmed** were reproduced; the rest are from reading the code. The four high findings are fixed in v2.1.0 and the seven medium findings in the follow-up (all marked **FIXED** below). The ten low findings are still open.

## Summary

| Severity | Count |
|---|---|
| High | 4 |
| Medium | 7 |
| Low | 10 |

The core design (fresh-context agents, locked feature list, gates in code, tester separate from coder) held up in both real trials. The problems are mostly around safety defaults, brownfield projects and packaging.

## High

**H1. Harness commits sweep up unrelated user work (confirmed).**
**FIXED.** `harness-init` refuses on a dirty git tree (`--branch NAME` or `--allow-dirty` to proceed), `begin --new-run` stops with code 4 on a dirty tree unless `allow_dirty` is set, `.harness/` changes are ignored by the check, and a repo with no commits gets a note. Tests cover each path.

Original finding:
`harness-setup.sh --finalize`, the auto-commit in `step.sh end`, and the spec-restore commit all run `git add -A`. In a project with uncommitted user files, the first harness commit includes them (reproduced: an untracked `mywork.txt` ended up in the initial commit).
Fix: warn or refuse on a dirty tree at `begin --new-run` / setup; run on a dedicated branch (`harness/<date>`); stage only `.harness/` and `.gitignore` at finalize.

**H2. Wrappers hardcode the absolute plugin path (confirmed).**
**FIXED.** Wrappers resolve `$CLAUDE_PLUGIN_ROOT`, then the recorded path, then the newest installed copy under `~/.claude/plugins/cache`, and otherwise exit 127 with a refresh hint; `harness-setup --refresh` and `/harness-run` rewrite them.

Original finding:
`.harness/step.sh`, `run.sh`, `feature-list.sh` and `status.sh` contain `exec "/abs/path/to/plugin/scripts/..."`. After a plugin update, move or cache cleanup they break, and the orchestrator and agents call them every session.
Fix: resolve through `CLAUDE_PLUGIN_ROOT` with a recorded fallback and a clear error ("run /harness-setup to refresh"); have `harness-run` refresh wrappers by running setup (cheap merge) before the loop.

**H3. plugin.json credits "Anthropic <support@anthropic.com>" as author (confirmed).**
**FIXED (placeholder author).** Author is now "wreck-it-ralph-loop contributors" with no email, license field added, version 2.1.0, and a NOTICE plus README credit for the upstream Ralph Loop plugin. Put your own name/repository in `plugin.json` when you publish.

Original finding:
This is derived from the upstream Ralph plugin and now contains a lot of new work, so the author field misattributes it. The Apache-2.0 LICENSE is correct to keep, but there is no NOTICE or attribution to the upstream work.
Fix: set your own author, add `repository`/`homepage`, and add a NOTICE or README credit for the original.

**H4. Untrusted repos can execute code through the harness config.**
**FIXED.** New trust gate: loops refuse to start (code 5) until `/harness-trust` records the permission mode, allowed tools, `claude_bin`, `final_verify_command`, MCP config and custom agents; any change re-requires trust. Default headless mode is `acceptEdits` with an explicit tool list, and the runner warns on `bypassPermissions`. **Not verified against a real `claude -p`:** the `allowed_tools` string (`Bash,Read,Edit,Write,Glob,Grep,NotebookEdit,mcp__playwright`) is untested with a real login; if headless runs get permission errors, set `permission_mode` back to `bypassPermissions` (and re-trust).

Original finding:
`.harness/config.json` (`final_verify_command` is run with `bash -c`), `.harness/mcp.json` (MCP server commands) and `.harness/agents/*.md` (agent prompts) all come from the repository, and the headless runner defaults to `bypassPermissions`. Cloning a repo that ships a `.harness/` and running the loop executes whatever it says.
Fix: show the config's commands and require confirmation on first run (store a hash in a local ignored file); default headless to `acceptEdits` plus an explicit `allowed_tools` list; document the trust model.

## Medium

**M1. Tester independence is prompt-only.**
**FIXED.** `step.sh task tester` records which features were claimed; `step.sh end` resets any feature that became passing without being in that set (reported as `UNVERIFIED_RESET=`, with a failure note). The coder and tester prompts now say so. Tests cover the unit and runner paths.

Original finding:
Every wrapper exposes `pass`, so a coder can mark its own feature as passing and nothing detects it.
Fix: record which features were claimed when the tester starts; in `end`, reset any feature that became passing without a claim, with a note.

**M2. Git identity is not checked and commit failures are swallowed (confirmed).**
**FIXED.** Setup checks git identity as a required prerequisite, `begin --new-run` stops with code 6 without one, all harness commits go through `safe_commit` (failures reported as `WARN=`), finalize fails loudly, and files over 5 MB trigger a warning on auto-commit.

Original finding:
Without `user.name`/`user.email`, `git commit` fails ("Author identity unknown"), and the scripts hide it with `|| true`. Agents' commits fail too, so every session ends with a dirty tree and no history.
Fix: add the identity check to the setup prerequisites; surface commit failures from finalize, auto-commit and restore.

**M3. No mutual exclusion in interactive mode.**
**FIXED.** `begin --new-run` takes a heartbeat lock (`.harness/.lock`; headless runners also register their pid, `lock_timeout_minutes` default 120). A second loop stops with code 7; `summary` releases it; `step.sh unlock` clears a stale one (the orchestrator is told never to run it).

Original finding:
Only the headless runner has a PID lock. Two orchestrators, or an orchestrator plus a headless runner, can run on the same `.step_state.json` and `feature_list.json` at once.
Fix: take a lock in `begin --new-run` (pid file with liveness check), release in `summary`.

**M4. Free-text arguments reach shell commands.**
**FIXED.** The run commands whitelist the options they may pass (`--max-sessions <int>`, `--once`), and `step.sh`/`run.sh` validate numeric options.

Original finding:
`harness-run.md` tells the model to run `begin --new-run $ARGUMENTS`, and `harness-run-headless.md` runs `.harness/run.sh $ARGUMENTS`, with no whitelist (the init and setup commands now have one). `--max-sessions abc` also produced a raw jq error (confirmed; now validated and rejected in `step.sh begin`).
Fix: whitelist and validate options in those two commands; validate numeric options in `step.sh` and `run.sh`.

**M5. Auto-commit can stage build output and large files.**
**FIXED.** Language-aware ignore sets (Node, Python, Rust, Go, JVM, Ruby) are added at setup and again at finalize (after the initializer creates the skeleton); the blanket `*.log` ignore is gone; large files are warned about.

Original finding:
Default ignores cover node_modules, pycache, logs and secrets, but not `dist/`, `build/`, `.venv/`, `target/`, coverage output, and so on. `*.log` is ignored project-wide, which can hide intended files.
Fix: language-aware ignore sets chosen from detected files; make the project-level list opt-out; cap size of auto-commits with a warning.

**M6. Legacy docs are stale and the README misses the install line.**
**FIXED (install line has a placeholder).** `help.md` now covers both tools with the `/wreck-it-ralph-loop:` prefix and the correct state path; the README has an Install section, but `<owner>/<repo>` must be filled in once you host a marketplace (the validator warning remains until then).

Original finding:
`commands/help.md` only covers the original Ralph loop, shows non-namespaced commands, says `claude-code --continue`, and names the state file `.claude/.ralph-loop.local.md` (the real file is `.claude/ralph-loop.local.md`). The validator also warns that the README has no marketplace install line.
Fix: rewrite help for both tools with the `/wreck-it-ralph-loop:` prefix; add a `harness-help` section; add the install line once the repo location is known.

**M7. Interactive runs leave no failure trail.**
**FIXED.** `step.sh note <agent> ok|failed|skipped` appends one line per agent outcome to `.harness/sessions/NNN-notes.md`; the orchestrator writes one after every agent and the summary includes them.

Original finding:
`.harness/sessions/` stays empty in interactive mode, and a subagent failure is visible only if the orchestrator mentions it. The stuck counter is the only automatic signal.
Fix: add `step.sh note <agent> <text>` so the orchestrator appends one line per agent outcome to a per-session file.

## Low

- **L1.** `init.sh` leaves the dev server running; there is no stop script or end-of-run cleanup.
- **L2.** Agents have no `model` or `tools` frontmatter (they inherit everything). Reasonable now, but a cheaper model for the tester would be easy to offer.
- **L3.** **FIXED in v3.0.0** (logs in a per-run `mktemp -d`; the stop hook now has tests). Original: `tests/run-tests.sh` uses fixed `/tmp/hN.log` names (collision-prone), builds checks as eval strings, and has no coverage for `harness-status.sh`, the run commands' prompts, or the legacy stop hook.
- **L4.** **FIXED in v3.0.0** (GitHub Actions: tests on Linux and macOS, `shellcheck -S error`). Original: No CI and no shellcheck run (shellcheck is not installed here).
- **L5.** **FIXED in v3.0.0** (the cancel command says the current agent is not interrupted). Original: `harness-cancel` only takes effect between sessions; the command text should say so.
- **L6.** **FIXED in v3.0.0** (`begin --new-run` reports a cleared flag as `NOTE=`). Original: `begin --new-run` silently deletes a STOP flag, so a stale or just-set flag from another terminal is lost.
- **L7.** **FIXED in v3.0.0** (a corrupted state file stops with a clear message). Original: `.step_state.json` is not validated; a corrupted file surfaces as raw jq errors.
- **L8.** **FIXED in v3.0.0** (per-feature `attempts[]` history). Original: `fail` overwrites the previous note, so the history of attempts on a feature is lost (only progress.md keeps it).
- **L9.** Windows is unsupported (bash and POSIX tools only); this is not documented.
- **L10.** **FIXED in v3.0.0** (no `perl`; the start message mentions `/cancel-ralph`). Original: The inherited Ralph stop hook is untouched and still needs `perl`; its setup script still says it "cannot be stopped manually" even though harness cancel exists for the other mode.

## What held up (checked)

- Fresh-context loop with coder then tester worked end to end in both trials (4/4 CLI, 3/5 web with Playwright before the session cap).
- Spec lock detected and restored tampering (tests, plus intact in both trials).
- Gates: STOP flag, session cap, stuck detection, final verification and the no-tester path behave as designed.
- Setup is idempotent: re-runs keep config, progress and custom ignore lines and repair missing wrappers.
- Scripts run under macOS's default bash 3.2 (the test suite ran on it).

## Suggested fix order

1. H1, M2 (git safety), then H2 (wrappers), since all three can break a real run.
2. H4, M1, M3, M4 (trust, independence, locking, argument handling).
3. H3, M6 (packaging and docs), then the remaining medium and low items.

## Follow-up: findings from the third real trial (all fixed)

1. **Tester passed a feature despite a reported defect.** The coder noted that `ß`/`ø` were dropped, which contradicts "accented characters are transliterated", yet the tester passed it because every listed step worked. Fix: the tester prompt now requires reading "Known issues", probing 3-5 inputs beyond the steps, and failing on any contradiction; the coder prompt says to claim only complete work.
2. **Wrapper scripts were committed** (they contain machine-specific plugin paths). Fix: wrappers are git-ignored via a shared `scripts/harness-ignores.sh`, and wrappers that an older version already committed are untracked automatically at the next loop start.
3. **Language ignores were detected too early** (before any source file existed). Fix: ignore detection is re-run at every `begin --new-run`, and its messages go to stderr so the gate output stays machine-readable.
