# harness-compare.jq - the replay comparison engine. Input: {expect, assertions, actual}; output: one check
# object per expect key. Shared by harness-replay.sh and harness-calibrate.sh (which feeds it known-answer cases).
def sub($e; $a):
  if ($e | type) == "object" then (($a | type) == "object") and ($e | to_entries | all(. as $kv | ($a | has($kv.key)) and sub($kv.value; $a[$kv.key])))
  elif ($e | type) == "array" then (($a | type) == "array") and (($e | length) == ($a | length)) and ([range(0; $e | length)] | all(. as $i | sub($e[$i]; $a[$i])))
  else $e == $a end;
def chk($m; $e; $a):
  if $m == "exact" then $e == $a
  elif $m == "partial" then sub($e; $a)
  elif $m == "contains" then
    (if ($a | type) == "string" then ($a | contains($e | tostring))
     elif ($a | type) == "array" then (if ($e | type) == "array" then ($e | all(. as $x | $a | index([$x]) != null)) else ($a | index([$e]) != null) end)
     else false end)
  elif $m == "regex" then (try (($a | tostring) | test($e | tostring)) catch false)
  else false end;
.actual as $act | .assertions as $as
| (.expect // {}) | to_entries | map(
    .key as $k | .value as $e
    | ($as[$k] // (if ($e | type) == "object" then "partial" else "exact" end)) as $m
    | {key: $k, mode: $m, expected: $e, actual: ($act[$k] // null), present: ($act | has($k))}
    | .pass = (.present and chk(.mode; .expected; .actual)))
