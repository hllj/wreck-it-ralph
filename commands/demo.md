---
description: "Replay a feature's locked examples against the running app: list them, run all, one example, or step by step"
argument-hint: "<ID> [--run] [--example EX001] [--step N | --from A --to B] [--keep]"
allowed-tools: ["Bash(.harness/replay.sh:*)", "Bash(.harness/feature-list.sh show:*)", "Bash(.harness/feature-list.sh examples:*)", "Bash(.harness/feature-list.sh list:*)"]
---

# Replay examples (demo)

User arguments: $ARGUMENTS

The first word is a feature id (for example `F001`). If it is missing, run `.harness/feature-list.sh list` and ask which feature. Pass only the flags below to the script; never put other user text into a shell command.

- No flag: list what can be replayed. Run `.harness/replay.sh <ID> --list` (examples) and `.harness/replay.sh <ID> --steps` (numbered steps), and show them with the one-line description from `.harness/feature-list.sh show <ID>`.
- `--run`: replay every example: `.harness/replay.sh <ID>`.
- `--example EX001`: one example. `--step N` or `--from A --to B`: only those steps (numbered as in `--steps`). Partial runs are marked partial and never count as the tester's evidence.
- `--keep`: do not run cleanup fixtures (test data stays, under the printed namespace), for you to inspect.

The app must already be running (`.harness/init.sh` starts it) and `replay` configured in `.harness/config.json` (`base_url` for HTTP, `command` for a CLI). Exit codes: 0 pass, 1 fail, 3 app unreachable (blocked), 4 not configured.

Show the output. For a failure, show expected vs actual from the output, then tell the user how to try another case: `/wreck-it-ralph:example <ID> "<the case>"` proposes it as a new locked example. If the app is unreachable or replay is not configured, say exactly what to start or set; do not edit config yourself.
