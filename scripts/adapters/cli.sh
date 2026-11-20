#!/bin/bash
# cli adapter for the replay engine: runs the project's configured command with the example's arguments.
# Usage: cli.sh <example.json> <out-dir>      env: REPLAY_COMMAND, REPLAY_TIMEOUT, RALPH_NAMESPACE
# Example input: {"args": ["--flag", "value"], "stdin": "text", "env": {"NAME": "value"}}
# The executable comes from the trusted config (replay.command), never from the example. Arguments are
# passed as an array, so nothing is parsed by a shell. stdout/stderr lose one trailing newline.
# Exit: 0 ok (actual.json written), 2 bad example, 3 blocked (command not found / not runnable).
set -uo pipefail
ex="${1:?example.json}"; out="${2:?out-dir}"
mkdir -p "$out"
[[ -n "${REPLAY_COMMAND:-}" ]] || { echo "replay.command is not configured" >&2; exit 2; }
read -r -a base <<<"$REPLAY_COMMAND"
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < <(jq -j '(.input.args // [])[] | tostring + "\u0000"' "$ex")
envs=()
while IFS= read -r kv; do
  [[ -z "$kv" ]] && continue
  [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || { echo "bad input.env entry" >&2; exit 2; }
  envs+=("$kv")
done < <(jq -r '(.input.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$ex")
jq '.input.stdin // ""' -r "$ex" > "$out/stdin.txt"
jq -n --arg c "$REPLAY_COMMAND" --argjson a "$(jq '.input.args // []' "$ex")" '{command: $c, args: $a}' > "$out/request.json"

tmo=""; command -v timeout >/dev/null && tmo="timeout ${REPLAY_TIMEOUT:-30}"; [[ -z "$tmo" ]] && command -v gtimeout >/dev/null && tmo="gtimeout ${REPLAY_TIMEOUT:-30}"
RALPH_NAMESPACE="${RALPH_NAMESPACE:-}" env ${envs[@]+"${envs[@]}"} RALPH_NAMESPACE="${RALPH_NAMESPACE:-}" $tmo "${base[@]}" ${args[@]+"${args[@]}"} \
  < "$out/stdin.txt" > "$out/stdout.log" 2> "$out/stderr.log"
rc=$?
[[ $rc -eq 127 || $rc -eq 126 ]] && { echo "cannot run '${base[0]}': $(head -c 200 "$out/stderr.log")" >&2; exit 3; }
jq -n --argjson rc "$rc" --rawfile o "$out/stdout.log" --rawfile e "$out/stderr.log" \
  '{exit_code: $rc, stdout: ($o | sub("\n$"; "")), stderr: ($e | sub("\n$"; ""))}' > "$out/actual.json"
