#!/bin/bash
# http adapter for the replay engine: sends ONE request described by an example and writes actual.json.
# Usage: http.sh <example.json> <out-dir>      env: BASE_URL, REPLAY_TIMEOUT, RALPH_NAMESPACE
# Example input: {"method": "POST", "path": "/api/checkout", "headers": {...}, "query": {...}, "body": {...}}
# No shell is built from the example: method and path are validated, everything else is passed as data.
# Exit: 0 ok (actual.json written), 2 bad example, 3 blocked (the app could not be reached).
set -uo pipefail
ex="${1:?example.json}"; out="${2:?out-dir}"
mkdir -p "$out"
method="$(jq -r '.input.method // (if (.input | has("body")) then "POST" else "GET" end)' "$ex")"
path="$(jq -r '.input.path // ""' "$ex")"
[[ "$method" =~ ^[A-Z]+$ ]] || { echo "bad input.method: $method" >&2; exit 2; }
[[ "$path" == /* ]] || { echo "http example needs input.path starting with /" >&2; exit 2; }
[[ "${BASE_URL:-}" =~ ^https?:// ]] || { echo "BASE_URL must be an http(s) URL" >&2; exit 2; }
query="$(jq -r '(.input.query // {}) | to_entries | map("\(.key | @uri)=\(.value | tostring | @uri)") | join("&")' "$ex")"
url="${BASE_URL%/}$path"; [[ -n "$query" ]] && { [[ "$url" == *\?* ]] && url="$url&$query" || url="$url?$query"; }

args=(-sS -m "${REPLAY_TIMEOUT:-30}" -X "$method" -D "$out/resp.headers" -o "$out/resp.body" -w '%{http_code}'
      -H "X-Ralph-Namespace: ${RALPH_NAMESPACE:-}")
has_ct=0
while IFS= read -r h; do
  [[ -z "$h" ]] && continue
  [[ "$h" =~ ^[Cc]ontent-[Tt]ype: ]] && has_ct=1
  args+=(-H "$h")
done < <(jq -r '(.input.headers // {}) | to_entries[] | "\(.key): \(.value)"' "$ex" | tr -d '\r')
if jq -e '.input | has("body")' "$ex" >/dev/null; then
  jq -c '.input.body' "$ex" > "$out/request.body"
  [[ $has_ct -eq 0 ]] && args+=(-H "Content-Type: application/json")
  args+=(--data-binary "@$out/request.body")
fi
jq -n --arg m "$method" --arg u "$url" '{method: $m, url: $u}' > "$out/request.json"

code="$(curl "${args[@]}" "$url" 2> "$out/stderr.log")" || { echo "request failed: $(tr '\n' ' ' < "$out/stderr.log")" >&2; exit 3; }

# headers of the last response only (curl -D also dumps redirects / 100-continue blocks)
n="$(grep -n '^HTTP/' "$out/resp.headers" | tail -n1 | cut -d: -f1)"
hdrs="$(tail -n +$((${n:-0} + 1)) "$out/resp.headers" | jq -R -s '
  split("\n") | map(rtrimstr("\r") | select(contains(":")) | capture("^(?<k>[^:]+):[ \t]*(?<v>.*)$"))
  | map({key: (.k | ascii_downcase), value: .v}) | from_entries')"
if [[ -s "$out/resp.body" ]] && jq -e . "$out/resp.body" >/dev/null 2>&1; then body="$(jq -c . "$out/resp.body")"
else body="$(jq -Rs . "$out/resp.body")"; fi
jq -n --argjson s "${code:-0}" --argjson h "${hdrs:-{\}}" --argjson b "$body" '{status: $s, headers: $h, body: $b}' > "$out/actual.json"
