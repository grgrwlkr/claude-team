#!/usr/bin/env bash
# orch CLI: init, plan, brief composition, pause/resume, spawn --dry-run. Never launches a real session.
. "$(dirname "$0")/lib.sh"
ORCH="$PLUGIN_ROOT/bin/orch"
# with_arch <plan file>: puts first the architect design task every plan with code needs; tests that
# are not about the architect accept it with --force right after orch plan.
with_arch() {
  jq '.tasks = [{id:"arch", role:"architect", name:("arch-" + .run), phase:"design", goal:"map", pathsAllowed:["docs/architecture/**"], acceptance:["map checked"], dependsOn:[], budget:20}] + .tasks' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

fresh_tmp
stub_claude
REPO="$TMP_BASE/repo"; make_repo "$REPO"
cd "$REPO" || exit 1

echo "# doctor"
expect_exit 0 "doctor passes in a git repo" "$ORCH" doctor --no-daemon

echo "# init"
expect_exit 0 "init creates run" "$ORCH" init r1 --base main
[ -f .orchestrator/r1/sessions.json ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL sessions.json missing"; }
[ -d .orchestrator/r1/handoffs ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL handoffs dir missing"; }
expect_grep '^\.orchestrator/$' .git/info/exclude "init excludes .orchestrator from git"
expect_exit 1 "init refuses an existing run" "$ORCH" init r1 --base main
"$ORCH" acceptance r1 off > /dev/null

echo "# plan"
cat > "$TMP_BASE/plan.json" <<'JSON'
{"run":"r1","goal":"Add dark mode","baseBranch":"main","tasks":[
 {"id":"spec","role":"analyst","name":"analyst-spec","goal":"Write the spec.","pathsAllowed":["docs/**"],"acceptance":["testable"],"dependsOn":[],"budget":80},
 {"id":"impl","role":"developer","name":"dev-impl","goal":"Implement it.","pathsAllowed":["src/**"],"acceptance":["tests green"],"dependsOn":["spec"],"budget":200},
 {"id":"qa-impl","role":"qa","name":"qa-impl","goal":"Cases and audit.","pathsAllowed":["docs/qa/**"],"acceptance":["cases"],"dependsOn":["spec"],"qaOf":"impl","budget":60},
 {"id":"rev-impl","role":"reviewer","name":"rev-impl","goal":"Review the implementation.","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":60},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"Merge the branches.","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":[],"budget":90}
]}
JSON
with_arch "$TMP_BASE/plan.json"
expect_exit 0 "plan stores the graph" "$ORCH" plan r1 "$TMP_BASE/plan.json"
"$ORCH" accept r1 arch fixture --force > /dev/null
expect_grep '"dev-impl"' .orchestrator/r1/plan.json "plan.json written"
printf '{"run":"r1","tasks":[{"id":"a","role":"wizard","name":"x","goal":"g","pathsAllowed":[],"acceptance":[],"dependsOn":[],"budget":1}]}' > "$TMP_BASE/bad.json"
expect_exit 1 "plan rejects unknown role" "$ORCH" plan r1 "$TMP_BASE/bad.json"
printf '{"run":"r1","tasks":[{"id":"a","role":"developer","name":"x","goal":"g","pathsAllowed":["src/**"],"acceptance":[],"dependsOn":[],"budget":1},{"id":"b","role":"developer","name":"y","goal":"g","pathsAllowed":["src/**"],"acceptance":[],"dependsOn":[],"budget":1},{"id":"ra","role":"reviewer","name":"ra","goal":"g","pathsAllowed":[],"acceptance":[],"dependsOn":["a"],"reviewOf":"a","budget":1},{"id":"rb","role":"reviewer","name":"rb","goal":"g","pathsAllowed":[],"acceptance":[],"dependsOn":["b"],"reviewOf":"b","budget":1}]}' > "$TMP_BASE/clash.json"
expect_exit 1 "plan rejects two same-wave tasks sharing a path" "$ORCH" plan r1 "$TMP_BASE/clash.json"
expect_grep 'share paths' "$TMP_BASE/err" "the path clash is the reason, not a missing reviewer"

echo "# brief"
expect_exit 0 "brief renders for a ready task" "$ORCH" brief r1 spec
expect_grep 'role: analyst' "$TMP_BASE/out" "brief names the role"
expect_grep 'team-rules.md' "$TMP_BASE/out" "brief points at the rules file"
expect_grep 'handoffs/analyst-spec.md' "$TMP_BASE/out" "brief names the handoff path"
expect_grep 'Write the spec.' "$TMP_BASE/out" "brief carries the goal verbatim"
expect_exit 1 "brief refuses a task whose dependencies are not done" "$ORCH" brief r1 impl

echo "# spawn --dry-run"
expect_exit 0 "spawn dry-run prints the command" "$ORCH" spawn r1 spec --dry-run
expect_grep '--agent orchestrator:analyst' "$TMP_BASE/out" "spawn uses the plugin agent"
expect_grep '--name analyst-spec' "$TMP_BASE/out" "spawn names the session"
expect_grep '--model opus' "$TMP_BASE/out" "spawn pins the model"
expect_grep '--effort high' "$TMP_BASE/out" "spawn pins effort high"
expect_grep 'CLAUDE_CODE_CHILD_SESSION' "$TMP_BASE/out" "spawn strips the child-session marker"
expect_grep 'outputStyle' "$TMP_BASE/out" "spawn pins the Concise output style"
expect_grep '"disableRemoteControl":true' "$TMP_BASE/out" "team sessions start without Remote Control, so no mirror shares their name"
expect_exit 0 "spawn with Remote Control kept" env ORCH_REMOTE_CONTROL=1 "$ORCH" spawn r1 spec --dry-run
expect_no_grep 'disableRemoteControl' "$TMP_BASE/out" "ORCH_REMOTE_CONTROL=1 keeps it"

echo "# pause / resume / decide"
expect_exit 0 "pause one" "$ORCH" pause r1 analyst-spec "drifting into code"
[ -f .orchestrator/r1/PAUSE-analyst-spec ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL pause file missing"; }
expect_grep 'drifting into code' .orchestrator/r1/PAUSE-analyst-spec "pause file carries the reason"
expect_exit 0 "resume one" "$ORCH" resume r1 analyst-spec
[ ! -f .orchestrator/r1/PAUSE-analyst-spec ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL pause file still there"; }
expect_exit 0 "pause all" "$ORCH" pause r1 all "user changed the goal"
[ -f .orchestrator/r1/PAUSE ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL global pause missing"; }
expect_exit 0 "resume all" "$ORCH" resume r1 all
expect_exit 0 "decide appends" "$ORCH" decide r1 "Spec wins: keep the toggle in Settings."
expect_grep 'Spec wins' .orchestrator/r1/decisions.md "decision recorded"

echo "# status without live sessions"
expect_exit 0 "status runs with an empty roster" "$ORCH" status r1 --no-live

echo "# first-run fixes: authorize, accept, address, handoff-put, exit codes"
expect_exit 0 "ready exits 0 even when nothing is ready" "$ORCH" ready r1
expect_exit 0 "address sets the orchestrator's session name" "$ORCH" address r1 "migration cleanup and verification"
expect_grep 'migration cleanup and verification' .orchestrator/r1/plan.json "address stored in plan.json"
expect_exit 0 "authorize push-base" "$ORCH" authorize r1 push-base on
expect_exit 0 "authorize delete-merged" "$ORCH" authorize r1 delete-merged on
expect_grep '"pushBase": true' .orchestrator/r1/plan.json "authorize stored"
expect_exit 0 "plan reload keeps address and authorize" "$ORCH" plan r1 "$TMP_BASE/plan.json"
expect_grep 'migration cleanup and verification' .orchestrator/r1/plan.json "address survives orch plan"
expect_grep '"pushBase": true' .orchestrator/r1/plan.json "authorize survives orch plan"
expect_exit 1 "authorize rejects an unknown flag" "$ORCH" authorize r1 launch-missiles on

printf '# analyst-spec\n## Status\npartial — waiting on a fact\n' > "$TMP_BASE/h.md"
expect_exit 0 "handoff-put writes the handoff from stdin" sh -c "'$ORCH' handoff-put r1 analyst-spec < '$TMP_BASE/h.md'"
expect_grep 'waiting on a fact' .orchestrator/r1/handoffs/analyst-spec.md "handoff-put content landed"
expect_exit 1 "handoff-put refuses an unknown session name" sh -c "echo x | '$ORCH' handoff-put r1 nobody"
expect_exit 1 "brief still refuses a dependent task while the dependency is partial" "$ORCH" brief r1 impl
expect_exit 0 "accept records acceptance outside the handoff" "$ORCH" accept r1 spec "partial is fine, fact not needed" --force
expect_exit 0 "brief renders once the task is accepted" "$ORCH" brief r1 impl
expect_grep 'analyst-spec' "$TMP_BASE/out" "accepted dependency handoff is pasted into the brief"
expect_exit 0 "ready lists the unblocked task" "$ORCH" ready r1
expect_grep 'impl' "$TMP_BASE/out" "impl became ready after accept"
expect_exit 1 "accept refuses an unknown task" "$ORCH" accept r1 nosuch

echo "# brief wording per role"
expect_exit 0 "brief for the integrator" "$ORCH" brief r1 merge-task
expect_grep 'you merge into it' "$TMP_BASE/out" "integrator brief does not forbid the base branch"
expect_grep 'orch handoff-put' "$TMP_BASE/out" "brief names the deadlock-free handoff route"
expect_grep 'scratch' "$TMP_BASE/out" "brief names a per-session scratch dir"
expect_exit 0 "brief for a developer" "$ORCH" brief r1 impl
expect_grep 'never commit to it' "$TMP_BASE/out" "developer brief keeps the base-branch ban"

echo "# status columns"
expect_exit 0 "status runs" "$ORCH" status r1 --no-live
expect_grep 'HANDOFF' "$TMP_BASE/out" "status has a handoff column"

echo "# review is mandatory, has rounds and a venue"
printf '{"run":"r1","baseBranch":"main","tasks":[{"id":"impl","role":"developer","name":"d1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":50}]}' > "$TMP_BASE/noreview.json"
expect_exit 1 "plan refuses a developer task nobody reviews" "$ORCH" plan r1 "$TMP_BASE/noreview.json"
expect_grep 'reviewer' "$TMP_BASE/err" "the refusal names the missing reviewer"
cat > "$TMP_BASE/reviewed.json" <<'JSON'
{"run":"r1","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":50},
 {"id":"qa","role":"qa","name":"qa-1","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"qaOf":"impl","budget":40},
 {"id":"rev","role":"reviewer","name":"rev-1","goal":"review impl","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":40},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":["rev"],"budget":60}
]}
JSON
with_arch "$TMP_BASE/reviewed.json"
expect_exit 0 "plan accepts a reviewed graph" "$ORCH" plan r1 "$TMP_BASE/reviewed.json"
expect_exit 0 "review venue defaults to branch" "$ORCH" review r1 venue branch
expect_exit 0 "review venue can be a pull request" "$ORCH" review r1 venue pr
expect_grep '"venue": "pr"' .orchestrator/r1/plan.json "venue stored"
expect_exit 1 "review rejects an unknown venue" "$ORCH" review r1 venue carrier-pigeon
expect_exit 0 "review rounds are configurable" "$ORCH" review r1 rounds 2
expect_grep '"maxRounds": 2' .orchestrator/r1/plan.json "rounds stored"
expect_exit 0 "plan reload keeps the review settings" "$ORCH" plan r1 "$TMP_BASE/reviewed.json"
expect_grep '"venue": "pr"' .orchestrator/r1/plan.json "venue survives orch plan"

echo "# briefs carry the venue"
"$ORCH" accept r1 impl "so the reviewer brief can render" --force > /dev/null
expect_exit 0 "developer brief in pr mode" "$ORCH" brief r1 impl
expect_grep 'pull request' "$TMP_BASE/out" "developer is told to open a PR"
expect_exit 0 "reviewer brief in pr mode" "$ORCH" brief r1 rev
expect_grep 'thread' "$TMP_BASE/out" "reviewer is told to comment in threads"
expect_grep 'round 1 of 2' "$TMP_BASE/out" "reviewer brief names the round"
expect_exit 0 "switch back to branch review" "$ORCH" review r1 venue branch
expect_exit 0 "reviewer brief in branch mode" "$ORCH" brief r1 rev
expect_grep 'diff' "$TMP_BASE/out" "branch-mode reviewer reads the diff"

echo "# review rounds spawn under distinct names"
expect_exit 0 "round 1 dry-run" "$ORCH" spawn r1 rev --dry-run
expect_grep '--name rev-1' "$TMP_BASE/out" "round 1 keeps the plan name"
expect_exit 0 "round 2 dry-run" "$ORCH" spawn r1 rev --round 2 --dry-run
expect_grep '--name rev-1-r2' "$TMP_BASE/out" "round 2 gets its own session name"
expect_exit 1 "round beyond maxRounds is refused" "$ORCH" spawn r1 rev --round 3 --dry-run

echo "# interactive verification: tools inventory, tester role, install authorization"
expect_exit 0 "tools inventory runs" "$ORCH" tools
expect_grep 'playwright MCP  *available' "$TMP_BASE/out" "inventory reads the stubbed claude, never the real one"
expect_exit 0 "tools inventory runs again" "$ORCH" tools
expect_calls 1 "second run is served from the cache"
expect_exit 0 "tools --refresh bypasses the cache" "$ORCH" tools --refresh
expect_calls 2 "--refresh asked claude again"
expect_exit 0 "tools survives a claude mcp list that hangs" env STUB_SLOW=1 ORCH_MCP_TIMEOUT=1 "$ORCH" tools --refresh
expect_grep 'playwright MCP  *unknown' "$TMP_BASE/out" "a timed-out MCP list reads unknown, not missing"
expect_grep 'did not finish' "$TMP_BASE/err" "the timeout is said out loud"
expect_grep 'browser' "$TMP_BASE/out" "inventory covers browser automation"
expect_grep 'screenshot' "$TMP_BASE/out" "inventory covers screenshots"
expect_grep 'available' "$TMP_BASE/out" "inventory marks each tool"
expect_exit 0 "interactive on" "$ORCH" interactive r1 on
expect_grep '"interactive": true' .orchestrator/r1/plan.json "interactive flag stored"
expect_exit 1 "plan with interactive on refuses a developer task without a tester" "$ORCH" plan r1 "$TMP_BASE/reviewed.json"
expect_grep 'tester' "$TMP_BASE/err" "the refusal names the tester role"
cat > "$TMP_BASE/tested.json" <<'JSON'
{"run":"r1","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":50},
 {"id":"qa","role":"qa","name":"qa-1","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"qaOf":"impl","budget":40},
 {"id":"rev","role":"reviewer","name":"rev-1","goal":"review impl","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":40},
 {"id":"run","role":"tester","name":"tester-1","goal":"run the app and exercise the criteria","pathsAllowed":[],"acceptance":["every criterion has evidence"],"dependsOn":["impl"],"verifies":"impl","budget":80},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":["rev","run"],"budget":60}
]}
JSON
with_arch "$TMP_BASE/tested.json"
expect_exit 0 "plan with a tester per developer task is accepted" "$ORCH" plan r1 "$TMP_BASE/tested.json"
expect_grep '"interactive": true' .orchestrator/r1/plan.json "interactive survives orch plan"
"$ORCH" accept r1 impl "for the tester brief" --force > /dev/null
expect_exit 0 "tester brief renders" "$ORCH" brief r1 run
expect_grep 'evidence' "$TMP_BASE/out" "tester brief demands evidence"
expect_grep 'orch tools' "$TMP_BASE/out" "tester brief points at the inventory"
expect_grep 'install' "$TMP_BASE/out" "tester brief states the install policy"
expect_exit 0 "authorize install-tools" "$ORCH" authorize r1 install-tools on
expect_grep '"installTools": true' .orchestrator/r1/plan.json "install authorization stored"
expect_exit 0 "interactive off" "$ORCH" interactive r1 off
expect_exit 0 "plan without testers is accepted again when interactive is off" "$ORCH" plan r1 "$TMP_BASE/reviewed.json"

echo "# acceptance gates what builds on code; verification roles start on the developer's done"
expect_exit 0 "init second run" "$ORCH" init r2 --base main
"$ORCH" acceptance r2 off > /dev/null
cat > "$TMP_BASE/gate.json" <<'JSON'
{"run":"r2","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":5},
 {"id":"qa","role":"qa","name":"qa-2","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"qaOf":"impl","budget":10},
 {"id":"rev","role":"reviewer","name":"rev-1","goal":"review impl","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":40},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":["impl","rev"],"budget":60}
]}
JSON
with_arch "$TMP_BASE/gate.json"
expect_exit 0 "plan for the gate run" "$ORCH" plan r2 "$TMP_BASE/gate.json"
"$ORCH" accept r2 arch fixture --force > /dev/null
printf '# d1\n## Status\nblocked — waiting until the analyst is done\n## Branch\nw1 at 0000000\n' > "$TMP_BASE/h1.md"
expect_exit 0 "developer hands off blocked" sh -c "'$ORCH' handoff-put r2 d1 < '$TMP_BASE/h1.md'"
expect_exit 0 "ready after a blocked handoff" "$ORCH" ready r2
expect_no_grep '^rev$' "$TMP_BASE/out" "status is the first word, not a substring: 'blocked … is done' unblocks nobody"
printf '# d1\n## Status\n\nDone — implemented\n## Branch\nw1 at 0000000\n' > "$TMP_BASE/h2.md"
expect_exit 0 "developer hands off done" sh -c "'$ORCH' handoff-put r2 d1 < '$TMP_BASE/h2.md'"
expect_exit 0 "ready after done" "$ORCH" ready r2
expect_grep '^rev$' "$TMP_BASE/out" "the reviewer is ready on the developer's done"
expect_no_grep '^merge-task$' "$TMP_BASE/out" "the integrator is not"
printf '# rev-1\n## Status\ndone\n' > "$TMP_BASE/h3.md"
expect_exit 0 "reviewer hands off" sh -c "'$ORCH' handoff-put r2 rev-1 < '$TMP_BASE/h3.md'"
expect_exit 0 "ready after the review" "$ORCH" ready r2
expect_no_grep '^merge-task$' "$TMP_BASE/out" "the integrator waits for orch accept of the developer task"
expect_exit 1 "integrator brief refused before acceptance" "$ORCH" brief r2 merge-task
expect_grep 'orch accept' "$TMP_BASE/err" "the refusal names orch accept"

echo "# review rounds can hand off"
expect_exit 0 "round-2 session delivers its handoff" sh -c "'$ORCH' handoff-put r2 rev-1-r2 < '$TMP_BASE/h3.md'"
expect_grep 'done' .orchestrator/r2/handoffs/rev-1-r2.md "round-2 handoff landed"
expect_exit 1 "a round beyond maxRounds cannot hand off" sh -c "'$ORCH' handoff-put r2 rev-1-r9 < '$TMP_BASE/h3.md'"
expect_exit 1 "a round of an unknown task cannot hand off" sh -c "'$ORCH' handoff-put r2 nobody-r2 < '$TMP_BASE/h3.md'"

echo "# budget: per-spawn override and the 80% mark"
expect_exit 0 "round 2 with its own budget" "$ORCH" spawn r2 rev --round 2 --budget 25 --dry-run
expect_grep 'budget=25' "$TMP_BASE/out" "dry-run shows the overridden budget"
echo '[{"taskId":"impl","name":"d1","role":"developer","id":"aaaa1111","sessionId":"sid-d1","pathsAllowed":["src/**"],"budget":5}]' > .orchestrator/r2/sessions.json
for _ in 1 2 3 4; do echo "2026-09-20T00:00:00Z|sid-d1|d1|Bash|allow|ls" >> .orchestrator/r2/events.log; done
expect_exit 0 "status with a nearly spent budget" "$ORCH" status r2 --no-live
expect_grep '4/5!' "$TMP_BASE/out" "status marks a session at 80% of its budget"

echo "# close"
mkdir -p "$CLAUDE_ORCH_STATE"
(cd .orchestrator/r2 && pwd -P) > "$CLAUDE_ORCH_STATE/sid-d1"
echo "/somewhere/else" > "$CLAUDE_ORCH_STATE/sid-other"
expect_exit 1 "close refuses while tasks are not accepted" "$ORCH" close r2
expect_grep 'merge-task' "$TMP_BASE/err" "the refusal lists the unaccepted tasks"
for t in impl rev merge-task; do "$ORCH" accept r2 "$t" ok --force > /dev/null; done
expect_exit 0 "close succeeds once everything is accepted" "$ORCH" close r2
expect_grep '1 refs checked' "$TMP_BASE/out" "close counts the refs it verified"
expect_grep 'contained in main: w1' "$TMP_BASE/out" "close reports containment per branch"
expect_exit 1 "this run's index entry is gone" test -f "$CLAUDE_ORCH_STATE/sid-d1"
expect_exit 0 "another run's index entry stays" test -f "$CLAUDE_ORCH_STATE/sid-other"
expect_exit 0 "CLOSED marker written" test -f .orchestrator/r2/CLOSED

echo "# wave 3: orch budget reaches the guard's copy"
expect_exit 0 "budget raises a live session" "$ORCH" budget r2 d1 9
expect_grep '"budget": 9' .orchestrator/r2/sessions.json "sessions.json, which the guard reads, carries the new budget"
expect_grep '"budget": 9' .orchestrator/r2/plan.json "plan.json carries it too"
expect_grep '|budget|' .orchestrator/r2/events.log "the change is logged"
expect_exit 1 "budget refuses an unknown name" "$ORCH" budget r2 nobody 5
expect_exit 1 "budget refuses a non-number" "$ORCH" budget r2 d1 lots

echo "# wave 3: close settles a review with the task it reviews, and says when branches are already gone"
expect_exit 0 "init third run" "$ORCH" init r3 --base main
"$ORCH" acceptance r3 off > /dev/null
expect_exit 0 "plan for the third run" "$ORCH" plan r3 "$TMP_BASE/gate.json"
"$ORCH" accept r3 arch fixture --force > /dev/null
printf '# d1\n## Status\ndone\n## Branch\ngone-branch at 0000000\n' > "$TMP_BASE/h4.md"
expect_exit 0 "developer hands off a branch that was cleaned up since" sh -c "'$ORCH' handoff-put r3 d1 < '$TMP_BASE/h4.md'"
"$ORCH" accept r3 impl ok --force > /dev/null
expect_exit 1 "close still refuses: the integrator task is open" "$ORCH" close r3
expect_no_grep 'not accepted:.* rev ' "$TMP_BASE/err" "the review of an accepted task is not listed as open"
"$ORCH" accept r3 merge-task ok --force > /dev/null
expect_exit 0 "close passes with the review task unaccepted" "$ORCH" close r3
expect_grep '0 refs checked' "$TMP_BASE/out" "nothing left to check"
expect_grep '1 already deleted' "$TMP_BASE/out" "close says the branch was deleted before it ran"

echo "# wave 4: the lead is not tied to one model"
: > "$TMP_BASE/claude.calls"
expect_exit 0 "start launches the lead" "$ORCH" start -- "do the thing"
expect_grep '--model opus' "$TMP_BASE/claude.calls" "the lead defaults to the latest Opus"
expect_no_grep 'fable' "$TMP_BASE/claude.calls" "no model is forced on the lead beyond the default"
expect_no_grep 'fallback-model' "$TMP_BASE/claude.calls" "no fallback unless asked"
expect_no_grep 'disableRemoteControl' "$TMP_BASE/claude.calls" "the lead keeps Remote Control"
expect_exit 0 "start with an explicit model and fallback" "$ORCH" start --model fable --fallback opus -- "x"
expect_grep '--model fable --fallback-model opus' "$TMP_BASE/claude.calls" "explicit choices pass through"

echo "# wave 4: run r4"
ROOT_REAL=$(pwd -P)
export ORCH_CLAUDE_JSON="$TMP_BASE/claude.json"
jq -n --arg r "$ROOT_REAL" '{mcpServers:{userA:{command:"a", env:{TOKEN:"t"}}, "playwright-local":{command:"p"}}, projects:{($r):{mcpServers:{localC:{command:"c"}}}}}' > "$ORCH_CLAUDE_JSON"
echo '{"mcpServers":{"repoB":{"command":"b"}}}' > .mcp.json
expect_exit 0 "init r4" "$ORCH" init r4 --base main
"$ORCH" acceptance r4 off > /dev/null
cat > "$TMP_BASE/r4.json" <<'JSON'
{"run":"r4","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d4","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":20,"mcp":["userA"]},
 {"id":"qa4","role":"qa","name":"qa-4","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"qaOf":"impl","budget":10},
 {"id":"rev","role":"reviewer","name":"rev-4","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"reviewOf":"impl","budget":10},
 {"id":"run","role":"tester","name":"test-4","goal":"run the app","pathsAllowed":[],"acceptance":["z"],"dependsOn":["impl"],"verifies":"impl","budget":10},
 {"id":"merge-task","role":"integrator","name":"int-4","goal":"merge","pathsAllowed":["**"],"acceptance":["g"],"dependsOn":["impl","rev"],"budget":10},
 {"id":"docs","role":"researcher","name":"res-4","goal":"facts","pathsAllowed":["docs/research/**"],"acceptance":["q"],"dependsOn":[],"budget":10,"mcp":"inherit"}
]}
JSON
with_arch "$TMP_BASE/r4.json"
expect_exit 0 "plan r4" "$ORCH" plan r4 "$TMP_BASE/r4.json"
"$ORCH" accept r4 arch fixture --force > /dev/null

echo "# every session starts without MCP servers and starts one on demand through a helper agent"
expect_exit 0 "developer spawn with an MCP list" "$ORCH" spawn r4 impl --dry-run
expect_grep '--strict-mcp-config' "$TMP_BASE/out" "strict MCP config on"
expect_grep '--mcp-config [^ ]*mcp/d4.json' "$TMP_BASE/out" "the session's own MCP config file"
jq -r '.mcpServers | length' .orchestrator/r4/mcp/d4.json > "$TMP_BASE/keys"
expect_grep '^0$' "$TMP_BASE/keys" "the session starts with no MCP server at all"
expect_grep '--agents "$(cat [^ ]*mcp/d4.agents.json)"' "$TMP_BASE/out" "helper agents are passed with --agents, inline as the real spawn passes them"
jq -r 'keys | join(",")' .orchestrator/r4/mcp/d4.agents.json > "$TMP_BASE/keys"
expect_grep '^mcp-userA$' "$TMP_BASE/keys" "one helper per server the task may use"
jq -r '."mcp-userA".mcpServers[0].userA.command' .orchestrator/r4/mcp/d4.agents.json > "$TMP_BASE/keys"
expect_grep '^a$' "$TMP_BASE/keys" "the helper carries the server's own definition"
ls -l .orchestrator/r4/mcp/d4.agents.json > "$TMP_BASE/perm"
expect_grep '^-rw-------' "$TMP_BASE/perm" "the helper file is private: server definitions may carry keys"
expect_grep 'command-line argument' "$TMP_BASE/err" "a named server whose definition carries env is flagged: it travels in argv"
expect_exit 0 "researcher inherits the machine's MCP set" "$ORCH" spawn r4 docs --dry-run
expect_no_grep 'strict-mcp-config' "$TMP_BASE/out" "inherit means no MCP flags"
printf '# d4\n## Status\ndone\n## Branch\nw1 at 0000000\n' > "$TMP_BASE/h-d4.md"
expect_exit 0 "developer hands off" sh -c "'$ORCH' handoff-put r4 d4 < '$TMP_BASE/h-d4.md'"
expect_exit 0 "a task without a list gets the repository's servers" "$ORCH" spawn r4 run --dry-run
jq -r 'keys | join(",")' .orchestrator/r4/mcp/test-4.agents.json > "$TMP_BASE/keys"
expect_grep '^mcp-repoB$' "$TMP_BASE/keys" "only .mcp.json by default: user and local servers carry personal credentials and need naming"
expect_exit 0 "tester brief" "$ORCH" brief r4 run
expect_grep 'MCP servers start on demand' "$TMP_BASE/out" "the brief says how servers start"
expect_grep 'mcp-repoB' "$TMP_BASE/out" "and names the helpers"
expect_exit 0 "a task can be given none" "$ORCH" task set r4 rev mcp '[]'
expect_exit 0 "reviewer brief" "$ORCH" brief r4 rev
expect_grep 'MCP servers: none' "$TMP_BASE/out" "a task given none is told so"
expect_exit 0 "reviewer spawn with none" "$ORCH" spawn r4 rev --dry-run
expect_grep '--strict-mcp-config' "$TMP_BASE/out" "none still starts strict"
expect_no_grep '--agents' "$TMP_BASE/out" "and with no helpers"

echo "# wave 4: orch tools shows MCP servers by scope"
expect_exit 0 "tools" "$ORCH" tools
expect_grep 'repo (.mcp.json): repoB' "$TMP_BASE/out" "repo scope listed"
expect_grep 'local: localC' "$TMP_BASE/out" "local scope listed"
expect_grep 'user: playwright-local, userA' "$TMP_BASE/out" "user scope listed"

echo "# wave 4: task add and task set go through the plan's validation"
echo '{"id":"extra","role":"researcher","name":"res-x","goal":"g","pathsAllowed":["docs/x/**"],"acceptance":["a"],"dependsOn":["impl"],"budget":5}' > "$TMP_BASE/t1.json"
expect_exit 0 "task add from a file" "$ORCH" task add r4 "$TMP_BASE/t1.json"
expect_grep '"res-x"' .orchestrator/r4/plan.json "the task landed"
echo '{"id":"dev2","role":"developer","name":"d5","goal":"g","pathsAllowed":["lib/**"],"dependsOn":[]}' > "$TMP_BASE/t2.json"
expect_exit 1 "task add refuses a developer task nobody reviews" sh -c "'$ORCH' task add r4 - < '$TMP_BASE/t2.json'"
expect_no_grep '"d5"' .orchestrator/r4/plan.json "a refused add leaves the plan untouched"
expect_exit 0 "task set a field" "$ORCH" task set r4 extra budget 7
jq -r '.tasks[] | select(.id == "extra") | .budget' .orchestrator/r4/plan.json > "$TMP_BASE/v"
expect_grep '^7$' "$TMP_BASE/v" "task set changed the field"
expect_exit 1 "task set refuses an unknown task" "$ORCH" task set r4 nosuch budget 1
expect_exit 1 "task set refuses a value that is not JSON" "$ORCH" task set r4 extra budget seven
expect_exit 0 "task set can name the servers" "$ORCH" task set r4 impl mcp '["localC"]'
expect_exit 0 "developer spawn after the change" "$ORCH" spawn r4 impl --dry-run
jq -r 'keys | join(",")' .orchestrator/r4/mcp/d4.agents.json > "$TMP_BASE/keys"
expect_grep '^mcp-localC$' "$TMP_BASE/keys" "local-scope servers resolve too"
expect_exit 0 "task set to a missing server" "$ORCH" task set r4 impl mcp '["nope"]'
expect_exit 1 "spawn refuses a server nobody configured" "$ORCH" spawn r4 impl --dry-run
expect_grep 'nope' "$TMP_BASE/err" "the refusal names the server"
"$ORCH" task set r4 impl mcp '["userA"]' > /dev/null

echo "# wave 4: real spawns register, and the hint agrees with the skill"
expect_exit 0 "spawn the developer" "$ORCH" spawn r4 impl
expect_grep 'STARTED' "$TMP_BASE/err" "the hint says to wait for STARTED"
expect_no_grep 'with notify_when_idle, then end your turn' "$TMP_BASE/err" "no subscribe-now advice"
expect_exit 0 "spawn the researcher" "$ORCH" spawn r4 docs

echo "# wave 4: accept takes a session name"
expect_exit 0 "accept by session name" "$ORCH" accept r4 d4 "by name"
jq -r '.[].taskId' .orchestrator/r4/accepted.json > "$TMP_BASE/v"
expect_grep '^impl$' "$TMP_BASE/v" "the name resolved to its task"
expect_exit 0 "accept a review round by its session name" "$ORCH" accept r4 rev-4-r2 "round name" --force
jq -r '.[].taskId' .orchestrator/r4/accepted.json > "$TMP_BASE/v"
expect_grep '^rev$' "$TMP_BASE/v" "rev-4-r2 resolved to rev"
expect_exit 1 "accept still refuses an unknown name" "$ORCH" accept r4 nobody

echo "# wave 4: a later round's brief carries the previous round's findings"
printf '# rev-4\n## Status\ndone\n## What I did\nFINDING-ALPHA in src/a.ts:1\n' > "$TMP_BASE/h-r1.md"
expect_exit 0 "round 1 hands off" sh -c "'$ORCH' handoff-put r4 rev-4 < '$TMP_BASE/h-r1.md'"
expect_exit 0 "round 2 brief" "$ORCH" brief r4 rev 2
expect_grep 'Previous round' "$TMP_BASE/out" "the brief has the previous round"
expect_grep 'FINDING-ALPHA' "$TMP_BASE/out" "with its findings"
printf '# rev-4-r2\n## Status\ndone\n## What I did\nFINDING-BETA\n' > "$TMP_BASE/h-r2.md"
expect_exit 0 "round 2 hands off" sh -c "'$ORCH' handoff-put r4 rev-4-r2 < '$TMP_BASE/h-r2.md'"
expect_exit 0 "round 3 brief" "$ORCH" brief r4 rev 3
expect_grep 'FINDING-BETA' "$TMP_BASE/out" "round 3 reads round 2"

echo "# wave 4: the integrator under venue pr opens no PR of its own"
expect_exit 0 "venue pr" "$ORCH" review r4 venue pr
expect_exit 0 "integrator brief" "$ORCH" brief r4 merge-task
expect_no_grep 'gh pr create' "$TMP_BASE/out" "the integrator is not told to open a PR"
expect_grep 'no PR of your own' "$TMP_BASE/out" "it is told it merges the task PRs"
expect_grep '< .scratch/handoff.md' "$TMP_BASE/out" "briefs lead with the file form of handoff-put"

echo "# wave 4: paths of a live session"
expect_exit 0 "paths add" "$ORCH" paths r4 d4 add knip.json 'config/**'
jq -r '.tasks[] | select(.id == "impl") | .pathsAllowed | join(",")' .orchestrator/r4/plan.json > "$TMP_BASE/v"
expect_grep 'src/\*\*,knip.json,config/\*\*' "$TMP_BASE/v" "the plan has the new paths"
jq -r '.[] | select(.name == "d4") | .pathsAllowed | join(",")' .orchestrator/r4/sessions.json > "$TMP_BASE/v"
expect_grep 'knip.json' "$TMP_BASE/v" "the live session's record, which the guard reads, has them"
expect_exit 1 "paths refuses an unknown task" "$ORCH" paths r4 nobody add x
expect_exit 1 "paths needs at least one glob" "$ORCH" paths r4 d4 add

echo "# wave 4: tester may or may not change dev data"
expect_exit 0 "tester brief before" "$ORCH" brief r4 run
expect_grep 'NOT authorized: creating or changing' "$TMP_BASE/out" "the default forbids writing shared dev data"
expect_exit 0 "authorize mutate-data" "$ORCH" authorize r4 mutate-data on
expect_exit 0 "tester brief after" "$ORCH" brief r4 run
expect_grep 'authorized for this run: creating or changing' "$TMP_BASE/out" "the authorization reaches the brief"

echo "# wave 4: cancel a task"
expect_exit 0 "ready before" "$ORCH" ready r4
expect_grep '^extra$' "$TMP_BASE/out" "extra is ready"
expect_exit 0 "cancel extra" "$ORCH" cancel r4 extra "not needed after all"
expect_exit 0 "ready after" "$ORCH" ready r4
expect_no_grep '^extra$' "$TMP_BASE/out" "a cancelled task is never ready"
expect_exit 0 "status after cancel" "$ORCH" status r4 --no-live
expect_grep 'cancelled: extra' "$TMP_BASE/out" "status names it with the reason"
expect_exit 0 "undo" "$ORCH" cancel r4 extra --undo
expect_exit 0 "ready after undo" "$ORCH" ready r4
expect_grep '^extra$' "$TMP_BASE/out" "undo brings it back"
"$ORCH" cancel r4 extra "not needed after all" > /dev/null

echo "# wave 4: stop sessions"
: > "$TMP_BASE/claude.calls"
RES_ID=$(jq -r '.[] | select(.name == "res-4") | .id' .orchestrator/r4/sessions.json)
expect_exit 0 "stop one" "$ORCH" stop r4 res-4
expect_grep "^stop $RES_ID\$" "$TMP_BASE/claude.calls" "claude stop ran with the session's id"
expect_exit 0 "stop all" "$ORCH" stop r4 all
# d4 was accepted above, so accept already removed it; stop all reaches the sessions still listed.
LIVE4=$(jq '[.[] | select((.removedAt // "") == "")] | length' .orchestrator/r4/sessions.json)
[ "$(grep -c '^stop ' "$TMP_BASE/claude.calls")" -eq $((LIVE4 + 1)) ] && { PASS=$((PASS+1)); echo "ok   stop all reached every session not removed"; } || { FAIL=$((FAIL+1)); echo "FAIL stop all: $(grep -c '^stop ' "$TMP_BASE/claude.calls") stop calls, want $((LIVE4 + 1))"; }
expect_exit 1 "stop refuses an unknown name" "$ORCH" stop r4 nobody

echo "# wave 4: cost per session from the transcripts, one count per message"
export ORCH_PROJECTS_DIR="$TMP_BASE/projects"
RES_SID="$(jq -r '.[] | select(.name == "res-4") | .id' .orchestrator/r4/sessions.json)-0000-4000-8000-000000000000"
mkdir -p "$ORCH_PROJECTS_DIR/-some-worktree"
{
  echo '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}'
  echo '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}'
  echo '{"type":"user","message":{"content":"hi"}}'
  echo '{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":5,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'
} > "$ORCH_PROJECTS_DIR/-some-worktree/$RES_SID.jsonl"
expect_exit 0 "cost" "$ORCH" cost r4
expect_grep 'res-4  *120  *15  *1000  *50' "$TMP_BASE/out" "output, input, cache read, cache write, a duplicated message counted once"
expect_grep 'd4  *-' "$TMP_BASE/out" "a session without a transcript reads -"
expect_grep 'TOTAL  *120' "$TMP_BASE/out" "total line"

echo "# wave 4: close treats a cancelled task as settled"
for t in impl rev merge-task docs run; do "$ORCH" accept r4 "$t" ok --force > /dev/null; done
expect_exit 0 "close with a cancelled task" "$ORCH" close r4

echo "# wave 6: run r5 — qa per developer task, qa-lead, design review, architect, staged"
expect_exit 0 "init r5" "$ORCH" init r5 --base main
cat > "$TMP_BASE/r5.json" <<'JSON'
{"run":"r5","baseBranch":"main","mode":"staged","stages":["design","build"],"tasks":[
 {"id":"arch","role":"architect","name":"arch-5","phase":"design","goal":"map and design","pathsAllowed":["docs/architecture/**"],"acceptance":["map"],"dependsOn":[],"budget":60,"stage":"design"},
 {"id":"spec","role":"analyst","name":"spec-5","goal":"spec","pathsAllowed":["docs/specs/**"],"acceptance":["s"],"dependsOn":["arch"],"budget":20,"stage":"design"},
 {"id":"design","role":"designer","name":"des-5","goal":"design","pathsAllowed":["docs/design/**"],"acceptance":["d"],"dependsOn":["spec"],"budget":20,"stage":"design"},
 {"id":"qal-a","role":"qa-lead","name":"qal-5a","phase":"author","goal":"acceptance tests","pathsAllowed":["tests/acceptance/**"],"acceptance":["red"],"dependsOn":["spec"],"budget":20,"stage":"design"},
 {"id":"impl","role":"developer","name":"dev-5","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":["design","qal-a"],"budget":20,"stage":"build"},
 {"id":"qa","role":"qa","name":"qa-5","qaOf":"impl","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":["design","qal-a"],"budget":20,"stage":"build"},
 {"id":"rev","role":"reviewer","name":"rev-5","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"stage":"build"},
 {"id":"drev","role":"design-reviewer","name":"drev-5","designOf":"impl","goal":"design review","pathsAllowed":[],"acceptance":["z"],"dependsOn":["impl","design"],"budget":10,"stage":"build"},
 {"id":"qal-b","role":"qa-lead","name":"qal-5b","phase":"accept","goal":"accept","pathsAllowed":["tests/acceptance/**"],"acceptance":["green"],"dependsOn":["impl","rev"],"budget":20,"stage":"build"},
 {"id":"arch-up","role":"architect","name":"arch-5u","phase":"update","goal":"update the map","pathsAllowed":["docs/architecture/**"],"acceptance":["map current"],"dependsOn":["qal-b"],"budget":20,"stage":"build"}
]}
JSON
variant() { jq "$1" "$TMP_BASE/r5.json" > "$TMP_BASE/r5v.json"; }
variant 'del(.tasks[] | select(.id == "qa"))'
expect_exit 1 "a developer task without its qa task is refused" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_grep 'qaOf' "$TMP_BASE/err" "the refusal names qaOf"
variant 'del(.tasks[] | select(.id == "drev"))'
expect_exit 1 "a developer task built on a design, with no design reviewer, is refused" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_grep 'design-reviewer' "$TMP_BASE/err" "the refusal names the design-reviewer"
variant 'del(.tasks[] | select(.role == "qa-lead")) | .tasks |= map(.dependsOn |= map(select(. != "qal-a" and . != "qal-b")) | if .id == "arch-up" then .dependsOn = ["rev"] else . end)'
expect_exit 1 "acceptance on and no qa-lead is refused" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_grep 'qa-lead' "$TMP_BASE/err" "the refusal names the qa-lead"
variant '.tasks |= map(if .id == "qal-b" then .dependsOn = ["design"] else . end)'
expect_exit 1 "an accept task that does not come after every developer task is refused" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_grep 'impl' "$TMP_BASE/err" "the refusal names the developer task it misses"
variant '.tasks |= map(if .id == "qal-a" then .phase = "later" else . end)'
expect_exit 1 "a qa-lead phase other than author/accept is refused" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
variant '.tasks |= map(if .id == "arch" then .phase = "sometime" else . end)'
expect_exit 1 "an architect phase other than design/update is refused" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
variant '.tasks |= map(if .id == "spec" then del(.stage) else . end)'
expect_exit 1 "a staged plan refuses a task without a stage" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_grep 'stage' "$TMP_BASE/err" "the refusal names the stage"
variant '.tasks |= map(if .id == "spec" then .dependsOn = ["impl"] else . end)'
expect_exit 1 "a task may not depend on a later stage" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_grep 'later stage' "$TMP_BASE/err" "the refusal says why"
expect_exit 0 "the full plan is stored" "$ORCH" plan r5 "$TMP_BASE/r5.json"
expect_exit 0 "acceptance off" "$ORCH" acceptance r5 off
variant 'del(.tasks[] | select(.role == "qa-lead")) | .tasks |= map(.dependsOn |= map(select(. != "qal-a" and . != "qal-b")) | if .id == "arch-up" then .dependsOn = ["rev"] else . end)'
expect_exit 0 "with acceptance off a plan needs no qa-lead" "$ORCH" plan r5 "$TMP_BASE/r5v.json"
expect_exit 0 "acceptance back on" "$ORCH" acceptance r5 on
expect_exit 0 "the full plan again" "$ORCH" plan r5 "$TMP_BASE/r5.json"

echo "# wave 6: briefs"
"$ORCH" accept r5 arch fixture --force > /dev/null
for t in spec design qal-a; do "$ORCH" accept r5 "$t" ok --force > /dev/null; done
expect_exit 0 "approve the design stage" "$ORCH" approve r5 design "user: looks right, go on"
expect_exit 0 "developer brief" "$ORCH" brief r5 impl
expect_grep 'qa-5' "$TMP_BASE/out" "the developer is told who writes its TDD cases"
expect_grep 'tests/acceptance/\*\*' "$TMP_BASE/out" "and which acceptance tests it must not edit"
expect_grep 'arch-5' "$TMP_BASE/out" "and whom to ask about the architecture"
expect_grep 'stage: build' "$TMP_BASE/out" "the brief names the stage"
expect_exit 0 "qa brief" "$ORCH" brief r5 qa
expect_grep 'dev-5' "$TMP_BASE/out" "qa names its developer"
expect_grep 'before' "$TMP_BASE/out" "cases come before the code"
expect_grep 'audit' "$TMP_BASE/out" "and an audit after"
"$ORCH" accept r5 impl ok --force > /dev/null
expect_exit 0 "design reviewer brief" "$ORCH" brief r5 drev
expect_grep 'des-5' "$TMP_BASE/out" "the design reviewer names the designer whose brief it checks"
expect_exit 0 "qa-lead author brief" "$ORCH" brief r5 qal-a
expect_grep 'acceptance tests for the whole change' "$TMP_BASE/out" "author phase"
expect_exit 0 "architect brief" "$ORCH" brief r5 arch
expect_grep 'architecture map: none yet' "$TMP_BASE/out" "the architect is told there is no map"

echo "# wave 6: orch architecture"
expect_exit 0 "architecture without a map" "$ORCH" architecture
expect_grep 'none yet' "$TMP_BASE/out" "no map reported"
expect_grep 'tracked files' "$TMP_BASE/out" "size of the job"
expect_grep 'git history' "$TMP_BASE/out" "co-change from git history is always available"
mkdir -p docs/architecture
printf '# Architecture\n\nbuilt-at: %s\n' "$(git rev-parse HEAD)" > docs/architecture/README.md
expect_exit 0 "architecture with a map" "$ORCH" architecture
expect_grep '0 commits behind' "$TMP_BASE/out" "a current map reads 0 commits behind"
rm -rf docs/architecture

echo "# wave 6: staged mode"
expect_exit 0 "init r6" "$ORCH" init r6 --base main
expect_exit 0 "plan r6" "$ORCH" plan r6 "$TMP_BASE/r5.json"
expect_exit 0 "ready at the start" "$ORCH" ready r6
expect_grep '^arch$' "$TMP_BASE/out" "the first stage's first task is ready"
expect_exit 1 "approve refuses a stage whose tasks are open" "$ORCH" approve r6 design "go"
expect_grep 'arch' "$TMP_BASE/err" "and lists them"
expect_exit 1 "approve refuses a later stage first" "$ORCH" approve r6 build "go"
expect_grep 'design' "$TMP_BASE/err" "the earlier stage is named"
"$ORCH" accept r6 arch fixture --force > /dev/null
for t in spec design qal-a; do "$ORCH" accept r6 "$t" ok --force > /dev/null; done
expect_exit 0 "ready with the design stage done but not approved" "$ORCH" ready r6
expect_no_grep '^impl$' "$TMP_BASE/out" "the build stage waits for approval"
expect_exit 1 "brief refuses a task of an unapproved stage" "$ORCH" brief r6 impl
expect_exit 1 "approve needs the user's words" "$ORCH" approve r6 design
expect_exit 0 "approve design" "$ORCH" approve r6 design "user: approved in chat"
expect_exit 0 "ready after approval" "$ORCH" ready r6
expect_grep '^impl$' "$TMP_BASE/out" "the build stage opens"
expect_grep '^qa$' "$TMP_BASE/out" "with the developer's qa in the same wave"

echo "# wave 6: stage report"
mkdir -p "$REPO/.claude/worktrees/w1/.scratch/evidence"
printf 'PNG' > "$REPO/.claude/worktrees/w1/.scratch/evidence/shot.png"
printf 'PNG' > "$TMP_BASE/outside.png"
printf '# des-5\n## Status\ndone <b>bold</b>\n## What I did\nScreens: %s and %s\n' "$REPO/.claude/worktrees/w1/.scratch/evidence/shot.png" "$TMP_BASE/outside.png" > "$TMP_BASE/h-des.md"
"$ORCH" handoff-put r6 des-5 < "$TMP_BASE/h-des.md" > /dev/null
expect_exit 0 "stage report" "$ORCH" stage-report r6 design
expect_grep 'stages/design/index.html' "$TMP_BASE/out" "the report path is printed"
expect_grep 'des-5' .orchestrator/r6/stages/design/index.html "the report has the stage's tasks"
expect_grep '&lt;b&gt;bold' .orchestrator/r6/stages/design/index.html "handoff text is escaped"
expect_grep 'img/des-5-shot.png' .orchestrator/r6/stages/design/index.html "evidence inside the repository is embedded"
expect_exit 0 "the image was copied" test -f .orchestrator/r6/stages/design/img/des-5-shot.png
expect_exit 1 "an image outside the repository is not copied" test -f .orchestrator/r6/stages/design/img/des-5-outside.png
expect_grep 'prefers-color-scheme: dark' .orchestrator/r6/stages/design/index.html "the page has a dark theme"
printf 'PNG' > "$TMP_BASE/outside2.png"
ln "$TMP_BASE/outside2.png" "$REPO/.claude/worktrees/w1/.scratch/evidence/hl.png"
printf '# des-5\n## Status\ndone\n## What I did\nScreens: %s and %s\n' "$REPO/.claude/worktrees/w1/.scratch/evidence/shot.png" "$REPO/.claude/worktrees/w1/.scratch/evidence/hl.png" > "$TMP_BASE/h-des2.md"
"$ORCH" handoff-put r6 des-5 < "$TMP_BASE/h-des2.md" > /dev/null
expect_exit 0 "stage report again" "$ORCH" stage-report r6 design
expect_exit 1 "security review: a hard link to a file outside the repository is not copied" test -f .orchestrator/r6/stages/design/img/des-5-hl.png
expect_exit 0 "an ordinary file still is" test -f .orchestrator/r6/stages/design/img/des-5-shot.png

echo "# security review: names that reach the filesystem, and the event log"
jq '.stages = ["design", "../b"] | .tasks |= map(if .stage == "build" then .stage = "../b" else . end)' "$TMP_BASE/r5.json" > "$TMP_BASE/r5v.json"
expect_exit 1 "plan refuses a stage name that is a path" "$ORCH" plan r6 "$TMP_BASE/r5v.json"
expect_exit 1 "stage-report refuses a stage name that is a path" "$ORCH" stage-report r6 "../.."
expect_exit 0 "the runs survive" test -d .orchestrator/r6
expect_exit 1 "init refuses a run name that is a path" "$ORCH" init "../evil" --base main
expect_exit 1 "nothing was created outside .orchestrator" test -e evil
expect_exit 0 "a note with a newline and a pipe" "$ORCH" accept r6 impl "$(printf 'ok\n2026-01-01T00:00:00Z|sid-x|x|Bash|allow|forged')" --force
expect_no_grep '^2026-01-01T00:00:00Z|sid-x' .orchestrator/r6/events.log "a note cannot forge an event line the guard would count"
awk -F'|' 'END {print NF}' .orchestrator/r6/events.log > "$TMP_BASE/v"
expect_grep '^6$' "$TMP_BASE/v" "the accept line keeps its six fields"

echo "# spawn registers by the short id, in parallel; status counts by it; forget drops dead sessions"
expect_exit 0 "init r7" "$ORCH" init r7 --base main
"$ORCH" acceptance r7 off > /dev/null
cat > "$TMP_BASE/r7.json" <<'JSON'
{"run":"r7","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d7","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"qa","role":"qa","name":"qa-7","qaOf":"impl","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"rev","role":"reviewer","name":"rev-7","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"mcp":[]}
]}
JSON
with_arch "$TMP_BASE/r7.json"
expect_exit 0 "plan r7" "$ORCH" plan r7 "$TMP_BASE/r7.json"
"$ORCH" accept r7 arch fixture --force > /dev/null
: > "$TMP_BASE/claude.calls"
expect_exit 0 "spawn the wave" "$ORCH" spawn r7 --wave
jq -r '[.[].name] | sort | join(",")' .orchestrator/r7/sessions.json > "$TMP_BASE/v"
expect_grep '^d7,qa-7$' "$TMP_BASE/v" "both sessions of the wave are registered"
expect_no_grep '^agents' "$TMP_BASE/claude.calls" "spawn no longer polls claude agents"
D7_ID=$(jq -r '.[] | select(.name == "d7") | .id' .orchestrator/r7/sessions.json)
echo "2026-09-24T00:00:00Z|${D7_ID}-0000-4000-8000-000000000000|d7|Bash|allow|ls" >> .orchestrator/r7/events.log
expect_exit 0 "status counts calls by the short id" "$ORCH" status r7 --no-live
expect_grep "^d7 .* 1/20" "$TMP_BASE/out" "one call counted for d7"
expect_exit 0 "live status fills in the full session id" "$ORCH" status r7
jq -r '.[] | select(.name == "d7") | .sessionId' .orchestrator/r7/sessions.json > "$TMP_BASE/v"
expect_grep "^${D7_ID}-0000-4000-8000-000000000000$" "$TMP_BASE/v" "the full id is stored"
grep -v "^${D7_ID}$" "$TMP_BASE/claude.bg" > "$TMP_BASE/bg.tmp"; mv "$TMP_BASE/bg.tmp" "$TMP_BASE/claude.bg"
expect_exit 0 "forget the sessions this machine does not run" "$ORCH" forget r7 --dead
jq -r '[.[].name] | join(",")' .orchestrator/r7/sessions.json > "$TMP_BASE/v"
expect_grep '^qa-7$' "$TMP_BASE/v" "the dead one is gone, the live one stays"
expect_exit 0 "ready after forget" "$ORCH" ready r7
expect_grep '^impl$' "$TMP_BASE/out" "its task can be spawned again"
expect_exit 0 "forget by name" "$ORCH" forget r7 qa-7
jq -r 'length' .orchestrator/r7/sessions.json > "$TMP_BASE/v"
expect_grep '^0$' "$TMP_BASE/v" "no session left"
expect_exit 1 "forget refuses an unknown name" "$ORCH" forget r7 nobody
jq -r '[.[].name] | sort | join(",")' .orchestrator/r7/forgotten.json > "$TMP_BASE/v"
expect_grep '^d7,qa-7$' "$TMP_BASE/v" "forgotten sessions are kept as tombstones the guard holds"
expect_exit 0 "grant is paths add" "$ORCH" grant r7 d7 'lib/**'
jq -r '.tasks[] | select(.id == "impl") | .pathsAllowed | join(",")' .orchestrator/r7/plan.json > "$TMP_BASE/v"
expect_grep 'lib/\*\*' "$TMP_BASE/v" "the grant reached the plan"

echo "# spawn starts each session inside a worktree orch made; a session leaves claude agents once nobody can still need it"
expect_exit 0 "init r8" "$ORCH" init r8 --base main
"$ORCH" acceptance r8 off > /dev/null
cat > "$TMP_BASE/r8.json" <<'JSON'
{"run":"r8","baseBranch":"main","tasks":[
 {"id":"spec","role":"analyst","name":"an-8","goal":"spec","pathsAllowed":["docs/specs/**"],"acceptance":["s"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"impl","role":"developer","name":"d8","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":["spec"],"budget":20,"mcp":[]},
 {"id":"qa","role":"qa","name":"qa-8","qaOf":"impl","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":["spec"],"budget":20,"mcp":[]},
 {"id":"rev","role":"reviewer","name":"rev-8","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"mcp":[]},
 {"id":"merge","role":"integrator","name":"int-8","goal":"merge","pathsAllowed":["**"],"acceptance":["z"],"dependsOn":["impl"],"budget":10,"mcp":[]}
]}
JSON
with_arch "$TMP_BASE/r8.json"
expect_exit 0 "plan r8" "$ORCH" plan r8 "$TMP_BASE/r8.json"
"$ORCH" accept r8 arch fixture --force > /dev/null
expect_exit 0 "spawn an-8" "$ORCH" spawn r8 spec
AN_ID=$(jq -r '.[] | select(.name == "an-8") | .id' .orchestrator/r8/sessions.json)
printf '# an-8\n## Status\ndone\n' > .orchestrator/r8/handoffs/an-8.md
: > "$TMP_BASE/claude.calls"
expect_exit 0 "accept the spec" "$ORCH" accept r8 spec "spec read"
expect_no_grep "^rm $AN_ID\$" "$TMP_BASE/claude.calls" "the analyst stays while developers can still ask it about the spec"
WT8="$REPO/.claude/worktrees/r8-d8"
expect_exit 0 "brief names the worktree" "$ORCH" brief r8 impl
expect_grep "your worktree: $WT8 " "$TMP_BASE/out" "the brief gives the session its worktree and branch"
expect_exit 0 "dry run" "$ORCH" spawn r8 impl --dry-run
[ ! -e "$WT8" ] && { PASS=$((PASS+1)); echo "ok   a dry run makes no worktree"; } || { FAIL=$((FAIL+1)); echo "FAIL a dry run made $WT8"; }
expect_exit 0 "spawn d8" "$ORCH" spawn r8 impl
git -C "$WT8" rev-parse --abbrev-ref HEAD > "$TMP_BASE/v" 2>&1
expect_grep '^r8-d8$' "$TMP_BASE/v" "spawn made the task's worktree on its own branch"
D8_ID=$(jq -r '.[] | select(.name == "d8") | .id' .orchestrator/r8/sessions.json)
expect_grep "^$D8_ID $WT8\$" "$TMP_BASE/claude.cwd" "the session starts inside that worktree, so claude rm never deletes it"
jq -r '.[] | select(.name == "d8") | .worktree' .orchestrator/r8/sessions.json > "$TMP_BASE/v"
expect_grep "^$WT8\$" "$TMP_BASE/v" "the record carries the worktree"
printf '# d8\n## Status\ndone\n## Branch\nr8-d8\n' > .orchestrator/r8/handoffs/d8.md
expect_exit 0 "spawn rev-8" "$ORCH" spawn r8 rev
REV_ID=$(jq -r '.[] | select(.name == "rev-8") | .id' .orchestrator/r8/sessions.json)
expect_exit 0 "second review round" "$ORCH" spawn r8 rev --round 2
REV2_ID=$(jq -r '.[] | select(.name == "rev-8-r2") | .id' .orchestrator/r8/sessions.json)
expect_grep "^$REV2_ID $REPO/.claude/worktrees/r8-rev-8\$" "$TMP_BASE/claude.cwd" "a later round reuses the task's worktree"
: > "$TMP_BASE/claude.calls"
expect_exit 0 "accept d8" "$ORCH" accept r8 impl "tests green"
expect_grep "^rm $REV_ID\$" "$TMP_BASE/claude.calls" "accept removes the review sessions it settles"
expect_grep "^rm $REV2_ID\$" "$TMP_BASE/claude.calls" "every round of them"
expect_no_grep "^rm $D8_ID\$" "$TMP_BASE/claude.calls" "the developer stays while the integrator can still ask it about a conflict"
expect_no_grep "^rm $AN_ID\$" "$TMP_BASE/claude.calls" "the analyst still stays"
jq -r '[.[] | select(.removedAt) | .name] | sort | join(",")' .orchestrator/r8/sessions.json > "$TMP_BASE/v"
expect_grep '^rev-8,rev-8-r2$' "$TMP_BASE/v" "removed sessions are marked, not dropped"
[ -d "$REPO/.claude/worktrees/r8-rev-8" ] && { PASS=$((PASS+1)); echo "ok   the worktree stays"; } || { FAIL=$((FAIL+1)); echo "FAIL the worktree is gone"; }
expect_exit 0 "ready after accept" "$ORCH" ready r8
expect_no_grep '^rev$' "$TMP_BASE/out" "a removed session's task is not offered again"
expect_grep '^merge$' "$TMP_BASE/out" "the integrator is ready"
expect_exit 0 "status" "$ORCH" status r8 --no-live
expect_grep '^rev-8 .* removed ' "$TMP_BASE/out" "status shows the session as removed"
expect_exit 0 "forget --dead after removal" "$ORCH" forget r8 --dead
jq -r '[.[].name] | sort | join(",")' .orchestrator/r8/sessions.json > "$TMP_BASE/v"
expect_grep '^an-8,d8,rev-8,rev-8-r2$' "$TMP_BASE/v" "a removed session is not mistaken for one on another machine"
: > "$TMP_BASE/claude.calls"
expect_exit 0 "stop all after removal" "$ORCH" stop r8 all
expect_no_grep "^stop $REV_ID\$" "$TMP_BASE/claude.calls" "stop skips removed sessions"
expect_exit 0 "spawn int-8" "$ORCH" spawn r8 merge
INT_ID=$(jq -r '.[] | select(.name == "int-8") | .id' .orchestrator/r8/sessions.json)
: > "$TMP_BASE/claude.calls"
expect_exit 0 "rm --settled" "$ORCH" rm r8 --settled
expect_no_grep '^rm ' "$TMP_BASE/claude.calls" "--settled removes nobody an open task may still need"
expect_exit 1 "rm reports a refusal" env STUB_RM_FAIL=1 "$ORCH" rm r8 int-8
expect_grep 'kept' "$TMP_BASE/err" "with claude rm's own words"
jq -r '.[] | select(.name == "int-8") | .removedAt // "none"' .orchestrator/r8/sessions.json > "$TMP_BASE/v"
expect_grep '^none$' "$TMP_BASE/v" "a session claude rm kept is not marked removed"
jq 'map(if .name == "int-8" then del(.worktree) else . end)' .orchestrator/r8/sessions.json > "$TMP_BASE/s.tmp" && mv "$TMP_BASE/s.tmp" .orchestrator/r8/sessions.json
: > "$TMP_BASE/claude.calls"
expect_exit 1 "rm skips a session that made its own worktree" "$ORCH" rm r8 int-8
expect_no_grep '^rm ' "$TMP_BASE/claude.calls" "claude rm never runs on it: it would delete that worktree and its branch"
jq 'map(if .name == "int-8" then .worktree = "x" else . end)' .orchestrator/r8/sessions.json > "$TMP_BASE/s.tmp" && mv "$TMP_BASE/s.tmp" .orchestrator/r8/sessions.json
: > "$TMP_BASE/claude.calls"
expect_exit 0 "accept the merge" "$ORCH" accept r8 merge "merged" --force
expect_grep "^rm $INT_ID\$" "$TMP_BASE/claude.calls" "the integrator goes once its task is accepted"
expect_grep "^rm $D8_ID\$" "$TMP_BASE/claude.calls" "and the developer, once nothing that builds on it is open"
expect_grep "^rm $AN_ID\$" "$TMP_BASE/claude.calls" "and the analyst, once no task is open"
: > "$TMP_BASE/claude.calls"
expect_exit 0 "close" "$ORCH" close r8
expect_no_grep '^rm ' "$TMP_BASE/claude.calls" "close does not remove a session twice"
expect_exit 1 "rm refuses an unknown name" "$ORCH" rm r8 nobody
jq 'map(del(.removedAt))' .orchestrator/r8/sessions.json > "$TMP_BASE/s.tmp" && mv "$TMP_BASE/s.tmp" .orchestrator/r8/sessions.json
expect_exit 0 "rm of sessions claude no longer knows" env STUB_RM_GONE=1 "$ORCH" rm r8 all
jq -r '[.[] | select((.removedAt // "") == "")] | length' .orchestrator/r8/sessions.json > "$TMP_BASE/v"
expect_grep '^0$' "$TMP_BASE/v" "they are marked removed, not reported as kept"

echo "# close leaves no session of the run in claude agents, forgotten ones included"
expect_exit 0 "init r9" "$ORCH" init r9 --base main
"$ORCH" acceptance r9 off > /dev/null
cat > "$TMP_BASE/r9.json" <<'JSON'
{"run":"r9","baseBranch":"main","tasks":[
 {"id":"a","role":"researcher","name":"res-9a","goal":"facts","pathsAllowed":["docs/research/a/**"],"acceptance":["q"],"dependsOn":[],"budget":10,"mcp":[]},
 {"id":"b","role":"researcher","name":"res-9b","goal":"facts","pathsAllowed":["docs/research/b/**"],"acceptance":["q"],"dependsOn":[],"budget":10,"mcp":[]}
]}
JSON
expect_exit 0 "plan r9" "$ORCH" plan r9 "$TMP_BASE/r9.json"
expect_exit 0 "spawn r9" "$ORCH" spawn r9 --wave
A9_ID=$(jq -r '.[] | select(.name == "res-9a") | .id' .orchestrator/r9/sessions.json)
B9_ID=$(jq -r '.[] | select(.name == "res-9b") | .id' .orchestrator/r9/sessions.json)
expect_exit 0 "forget res-9b" "$ORCH" forget r9 res-9b
expect_exit 1 "close fails while a session stays listed" env STUB_RM_FAIL=1 "$ORCH" close r9 --force
expect_grep 'res-9a' "$TMP_BASE/err" "and names it"
expect_grep 'res-9b' "$TMP_BASE/err" "a forgotten session included"
: > "$TMP_BASE/claude.calls"
expect_exit 0 "close again" "$ORCH" close r9 --force
expect_grep "^rm $A9_ID\$" "$TMP_BASE/claude.calls" "close removes the run's sessions"
expect_grep "^rm $B9_ID\$" "$TMP_BASE/claude.calls" "and the forgotten ones"
if grep -qE "^($A9_ID|$B9_ID)\$" "$TMP_BASE/claude.bg"; then FAIL=$((FAIL+1)); echo "FAIL a session of r9 is still listed"; else PASS=$((PASS+1)); echo "ok   no session of r9 is listed after close"; fi

echo "# the architect is mandatory: a plan with code starts with it"
variant 'del(.tasks[] | select(.role == "architect")) | .tasks |= map(.dependsOn |= map(select(. != "arch")))'
expect_exit 1 "a plan with developer tasks and no architect design task is refused" "$ORCH" plan r6 "$TMP_BASE/r5v.json"
expect_grep 'architect' "$TMP_BASE/err" "the refusal names the architect"
variant '.tasks |= map(if .id == "arch" then .dependsOn = ["design"] else . end)'
expect_exit 1 "the architect's design task depends on nothing" "$ORCH" plan r6 "$TMP_BASE/r5v.json"
expect_grep 'first' "$TMP_BASE/err" "because it runs first"
variant '.tasks |= map(if .id == "arch" then .stage = "build" elif .id == "spec" then .dependsOn = [] else . end)'
expect_exit 1 "in a staged plan it belongs to the first stage" "$ORCH" plan r6 "$TMP_BASE/r5v.json"
expect_grep 'first stage' "$TMP_BASE/err" "the refusal names the stage"

echo "# the architect gates the run: nothing else starts before its checked map is accepted"
expect_exit 0 "init r10" "$ORCH" init r10 --base main
"$ORCH" acceptance r10 off > /dev/null
cat > "$TMP_BASE/r10.json" <<'JSON'
{"run":"r10","baseBranch":"main","tasks":[
 {"id":"arch","role":"architect","name":"arch-10","phase":"design","goal":"map","pathsAllowed":["docs/architecture/**"],"acceptance":["map checked"],"dependsOn":[],"budget":30,"mcp":[]},
 {"id":"spec","role":"analyst","name":"an-10","goal":"spec","pathsAllowed":["docs/specs/**"],"acceptance":["s"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"impl","role":"developer","name":"d10","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":["spec"],"budget":20,"mcp":[]},
 {"id":"qa","role":"qa","name":"qa-10","qaOf":"impl","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":["spec"],"budget":20,"mcp":[]},
 {"id":"rev","role":"reviewer","name":"rev-10","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"mcp":[]},
 {"id":"merge","role":"integrator","name":"int-10","goal":"merge","pathsAllowed":["**"],"acceptance":["z"],"dependsOn":["impl"],"budget":10,"mcp":[]}
]}
JSON
expect_exit 0 "plan r10" "$ORCH" plan r10 "$TMP_BASE/r10.json"
jq -r '.tasks[] | select(.id == "arch") | .pathsAllowed | join(",")' .orchestrator/r10/plan.json > "$TMP_BASE/v"
expect_grep '\.claude/rules/architecture/\*\*' "$TMP_BASE/v" "the architect may write the generated path-scoped rules"
expect_exit 0 "ready at the start" "$ORCH" ready r10
expect_grep '^arch$' "$TMP_BASE/out" "the architect is ready"
expect_no_grep '^spec$' "$TMP_BASE/out" "a task with no dependencies still waits for the architect"
expect_exit 1 "brief refuses a task before the map is accepted" "$ORCH" brief r10 spec
expect_grep 'architect' "$TMP_BASE/err" "and says who it waits for"
expect_exit 0 "architect brief" "$ORCH" brief r10 arch
expect_grep 'orch architecture --check' "$TMP_BASE/out" "the architect is told the check it must pass"
expect_exit 1 "accept refuses an architect task that never ran" "$ORCH" accept r10 arch "looks fine"
expect_grep 'worktree' "$TMP_BASE/err" "because there is no map to check"
expect_exit 0 "spawn the architect" "$ORCH" spawn r10 arch
WTA="$REPO/.claude/worktrees/r10-arch-10"
expect_exit 1 "accept refuses a worktree without a map" "$ORCH" accept r10 arch "looks fine"
expect_grep 'README' "$TMP_BASE/err" "the failed check is shown"

echo "# orch architecture --check: the map against the current tree"
mkdir -p "$WTA/docs/architecture/modules"
printf '# Architecture\n\nbuilt-at: %s\n' "$(git -C "$WTA" rev-parse HEAD)" > "$WTA/docs/architecture/README.md"
printf '# core\n' > "$WTA/docs/architecture/modules/core.md"
cat > "$WTA/docs/architecture/modules.json" <<'JSON'
{"modules":[{"name":"core","doc":"modules/core.md","paths":["src/*.ts"],"summary":"Exports the constant a.\nNothing depends on it yet."}],"ignore":[]}
JSON
expect_exit 0 "architecture reads the map of the worktree it runs in, not the main checkout" sh -c "cd '$WTA' && '$ORCH' architecture"
expect_grep '0 commits behind' "$TMP_BASE/out" "the worktree's map is found"
expect_exit 1 "check fails while the rules are not generated" sh -c "cd '$WTA' && '$ORCH' architecture --check"
expect_grep 'sync' "$TMP_BASE/out" "and names the fix"
expect_exit 0 "sync writes the path-scoped rules" sh -c "cd '$WTA' && '$ORCH' architecture --sync"
expect_grep '"src/\*.ts"' "$WTA/.claude/rules/architecture/core.md" "the rule is scoped to the module's paths"
expect_grep 'Nothing depends on it yet' "$WTA/.claude/rules/architecture/core.md" "and carries its summary"
expect_grep 'docs/architecture/modules/core.md' "$WTA/.claude/rules/architecture/core.md" "and points at the full description"
expect_exit 0 "check passes on a synced, current, complete map" sh -c "cd '$WTA' && '$ORCH' architecture --check"
mkdir -p "$WTA/src/deep" "$WTA/lib"
echo 'export const c = 3' > "$WTA/src/deep/c.ts"
echo 'export const x = 1' > "$WTA/lib/x.ts"
expect_exit 1 "check fails on files no module covers" sh -c "cd '$WTA' && '$ORCH' architecture --check"
expect_grep 'lib' "$TMP_BASE/out" "an uncovered directory is named"
expect_grep 'src/deep' "$TMP_BASE/out" "* does not cross a directory, as in Claude Code's paths"
jq '.modules[0].paths = ["src/**", "old/**"] | .ignore = ["lib/**"]' "$WTA/docs/architecture/modules.json" > "$TMP_BASE/m.json" && mv "$TMP_BASE/m.json" "$WTA/docs/architecture/modules.json"
(cd "$WTA" && "$ORCH" architecture --sync > /dev/null)
expect_exit 1 "check fails on a module path that matches no file" sh -c "cd '$WTA' && '$ORCH' architecture --check"
expect_grep 'old/\*\*' "$TMP_BASE/out" "the dead path is named"
jq '.modules[0].paths = ["src/**"]' "$WTA/docs/architecture/modules.json" > "$TMP_BASE/m.json" && mv "$TMP_BASE/m.json" "$WTA/docs/architecture/modules.json"
(cd "$WTA" && "$ORCH" architecture --sync > /dev/null)
expect_exit 1 "check fails when the code moved past built-at" sh -c "cd '$WTA' && '$ORCH' architecture --check"
expect_grep 'core' "$TMP_BASE/out" "the stale module is named"
git -C "$WTA" add src lib
git -C "$WTA" commit -qm 'code moves on'
printf '# Architecture\n\nbuilt-at: %s\n' "$(git -C "$WTA" rev-parse HEAD)" > "$WTA/docs/architecture/README.md"
expect_exit 0 "check passes once built-at is moved to the code the map describes" sh -c "cd '$WTA' && '$ORCH' architecture --check"
printf -- '---\npaths:\n  - "gone/**"\n---\n<!-- Generated by orch architecture --sync from docs/architecture/modules.json. -->\n' > "$WTA/.claude/rules/architecture/gone.md"
expect_exit 1 "check fails on a generated rule whose module is gone" sh -c "cd '$WTA' && '$ORCH' architecture --check"
expect_grep 'gone.md' "$TMP_BASE/out" "the orphan is named"
(cd "$WTA" && "$ORCH" architecture --sync > /dev/null)
[ ! -e "$WTA/.claude/rules/architecture/gone.md" ] && { PASS=$((PASS+1)); echo "ok   sync removes the orphan it generated"; } || { FAIL=$((FAIL+1)); echo "FAIL gone.md survived --sync"; }
expect_exit 1 "accept refuses a map that is not committed on the architect's branch" "$ORCH" accept r10 arch "map checked"
expect_grep 'commit' "$TMP_BASE/err" "an uncommitted map would never reach the integrator"
git -C "$WTA" add docs/architecture .claude/rules/architecture
git -C "$WTA" commit -qm 'docs(architecture): map'
expect_exit 0 "check still passes with the map committed after built-at" sh -c "cd '$WTA' && '$ORCH' architecture --check"
printf '# arch-10\n## Status\ndone\n' | "$ORCH" handoff-put r10 arch-10 > /dev/null
# The code commits above test the map's staleness; the architect is granted them so the path check passes.
"$ORCH" paths r10 arch add 'src/**' 'lib/**' > /dev/null
expect_exit 0 "accept runs the check in the architect's worktree and passes" "$ORCH" accept r10 arch "map checked"
expect_exit 0 "ready after the architect" "$ORCH" ready r10
expect_grep '^spec$' "$TMP_BASE/out" "the run opens"
expect_no_grep '^arch$' "$TMP_BASE/out" "an accepted task is not offered for spawning"

echo "# briefs point at the architect's map and only the modules a task touches"
"$ORCH" accept r10 spec ok --force > /dev/null
expect_exit 0 "developer brief" "$ORCH" brief r10 impl
expect_grep "$WTA/docs/architecture" "$TMP_BASE/out" "the map is read from the architect's worktree"
expect_grep 'modules/core.md' "$TMP_BASE/out" "the module its paths touch is named"
"$ORCH" accept r10 impl ok --force > /dev/null
expect_exit 0 "reviewer brief" "$ORCH" brief r10 rev
expect_grep 'modules/core.md' "$TMP_BASE/out" "a reviewer gets the modules of the task it reviews"
expect_exit 0 "integrator brief" "$ORCH" brief r10 merge
expect_grep 'r10-arch-10' "$TMP_BASE/out" "the integrator merges the architect's branch too"

echo "# accept --force records a skipped check"
expect_exit 0 "init r11" "$ORCH" init r11 --base main
"$ORCH" acceptance r11 off > /dev/null
jq '.run = "r11" | .tasks |= map(.name = (.name + "-11"))' "$TMP_BASE/r10.json" > "$TMP_BASE/r11.json"
"$ORCH" plan r11 "$TMP_BASE/r11.json" > /dev/null
expect_exit 0 "accept --force without a worktree" "$ORCH" accept r11 arch "the user took the risk" --force
expect_grep 'check skipped' .orchestrator/r11/events.log "the skipped check is on record"

echo "# graph tools: a one-shot npx run needs no install"
echo '{}' > package.json
expect_exit 0 "architecture in a js repository" "$ORCH" architecture
expect_grep 'no install' "$TMP_BASE/out" "npx one-shot is offered as allowed"
rm -f package.json

echo "# rounds, targets, dependencies: run r12"
expect_exit 0 "init r12" "$ORCH" init r12 --base main
"$ORCH" acceptance r12 off > /dev/null
cat > "$TMP_BASE/r12.json" <<'JSON'
{"run":"r12","baseBranch":"main","tasks":[
 {"id":"spec","role":"analyst","name":"an-12","goal":"spec","pathsAllowed":["docs/spec/**"],"acceptance":["x"],"dependsOn":[],"budget":10},
 {"id":"impl","role":"developer","name":"dev-12","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":["spec"],"budget":10},
 {"id":"qa","role":"qa","name":"qa-12","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["x"],"dependsOn":["spec"],"qaOf":"impl","budget":10},
 {"id":"rev","role":"reviewer","name":"rev-12","goal":"review","pathsAllowed":[],"acceptance":["x"],"dependsOn":["impl"],"reviewOf":"impl","budget":10},
 {"id":"dr","role":"design-reviewer","name":"dr-12","goal":"design review","pathsAllowed":[],"acceptance":["x"],"dependsOn":["impl"],"designOf":"impl","budget":10},
 {"id":"int","role":"integrator","name":"int-12","goal":"merge","pathsAllowed":["**"],"acceptance":["x"],"dependsOn":["impl","rev"],"budget":10}
]}
JSON
with_arch "$TMP_BASE/r12.json"
"$ORCH" plan r12 "$TMP_BASE/r12.json" > /dev/null
"$ORCH" accept r12 arch fixture --force > /dev/null
# Task branches as orch names them; the reviewer's has no commit of its own.
for b in arch-r12 an-12 dev-12 qa-12 rev-12; do git worktree add -q -b "r12-$b" ".claude/worktrees/r12-$b" main; done
for b in arch-r12 an-12 dev-12 qa-12; do (cd ".claude/worktrees/r12-$b" && echo "$b" > "$b.txt" && git add -A && git commit -qm "$b"); done
SHA_AN=$(git rev-parse r12-an-12); SHA_DEV=$(git rev-parse r12-dev-12)
printf '# an-12\n## Status\ndone\n' | "$ORCH" handoff-put r12 an-12 > /dev/null
printf '# dev-12\n## Status\npartial\n## What I did\nDEV-R1-TEXT\n' | "$ORCH" handoff-put r12 dev-12 > /dev/null
printf '# dev-12-r2\n## Status\ndone\n## What I did\nDEV-R2-TEXT\n' | "$ORCH" handoff-put r12 dev-12-r2 > /dev/null
expect_exit 0 "ready after a later round's done" "$ORCH" ready r12
expect_grep '^rev$' "$TMP_BASE/out" "the latest round's handoff decides: round 2 says done"
echo '[{"taskId":"impl","name":"dev-12","role":"developer","id":"dddd1212","sessionId":"sid-d12","pathsAllowed":["src/**"],"budget":10}]' > .orchestrator/r12/sessions.json
expect_exit 0 "status with a later round" "$ORCH" status r12 --no-live
expect_grep '^dev-12 .* done ' "$TMP_BASE/out" "status shows the latest round's handoff state"
expect_exit 0 "reviewer brief" "$ORCH" brief r12 rev
expect_grep 'DEV-R2-TEXT' "$TMP_BASE/out" "the dependency pasted is the latest round's handoff"
expect_no_grep 'DEV-R1-TEXT' "$TMP_BASE/out" "not the first round's"
expect_no_grep '<its worktree>' "$TMP_BASE/out" "no placeholder left in the reviewer brief"
expect_grep "worktrees/r12-dev-12, branch r12-dev-12, head $SHA_DEV" "$TMP_BASE/out" "reviewer brief names the target's worktree, branch and head"
expect_exit 0 "qa brief" "$ORCH" brief r12 qa
expect_no_grep '<its worktree>' "$TMP_BASE/out" "no placeholder left in the qa brief"
expect_grep "worktrees/r12-dev-12, branch r12-dev-12, head $SHA_DEV" "$TMP_BASE/out" "qa brief names the target's worktree, branch and head"
expect_exit 0 "design-reviewer brief" "$ORCH" brief r12 dr
expect_grep "worktrees/r12-dev-12, branch r12-dev-12, head $SHA_DEV" "$TMP_BASE/out" "design-reviewer brief names the target's worktree, branch and head"
expect_exit 0 "developer brief" "$ORCH" brief r12 impl
expect_grep "worktrees/r12-an-12, branch r12-an-12, head $SHA_AN" "$TMP_BASE/out" "a dependency's header names its worktree, branch and head"
printf '# rev-12\n## Status\ndone\n## Findings\nREV-R1-FINDING\n' | "$ORCH" handoff-put r12 rev-12 > /dev/null
printf '# rev-12-r2\n## Status\ndone\n## Findings\nREV-R2-FINDING\n' | "$ORCH" handoff-put r12 rev-12-r2 > /dev/null
printf '# qa-12\n## Status\ndone\n## Findings\nQA-FINDING\n' | "$ORCH" handoff-put r12 qa-12 > /dev/null
printf '# dr-12\n## Status\ndone\n## Findings\nDR-FINDING\n' | "$ORCH" handoff-put r12 dr-12 > /dev/null
expect_exit 0 "developer round-3 brief" "$ORCH" brief r12 impl 3
expect_grep 'REV-R2-FINDING' "$TMP_BASE/out" "a developer round pastes the reviewer's latest findings"
expect_no_grep 'REV-R1-FINDING' "$TMP_BASE/out" "not its earlier round"
expect_grep 'QA-FINDING' "$TMP_BASE/out" "and qa's"
expect_grep 'DR-FINDING' "$TMP_BASE/out" "and the design-reviewer's"
expect_no_grep 'DEV-R2-TEXT' "$TMP_BASE/out" "not the developer's own previous handoff"
"$ORCH" accept r12 impl ok --force > /dev/null
expect_exit 0 "integrator brief" "$ORCH" brief r12 int
grep ': branch r12-' "$TMP_BASE/out" | sed 's/.*: branch \(r12-[a-z0-9-]*\),.*/\1/' | tr '\n' ' ' > "$TMP_BASE/v"
expect_grep '^r12-arch-r12 r12-an-12 r12-dev-12 r12-qa-12 $' "$TMP_BASE/v" "integrator brief lists every branch with commits off base, architect's included, in dependency order"
expect_grep ": branch r12-dev-12, head $SHA_DEV" "$TMP_BASE/out" "with its head"

echo "# accept, close, spawn: run r13"
expect_exit 0 "init r13" "$ORCH" init r13 --base main
"$ORCH" acceptance r13 off > /dev/null
cat > "$TMP_BASE/r13.json" <<'JSON'
{"run":"r13","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d13","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"qa","role":"qa","name":"qa-13","qaOf":"impl","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"rev","role":"reviewer","name":"rev-13","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"mcp":[]},
 {"id":"res","role":"researcher","name":"res-13","goal":"facts","pathsAllowed":["docs/research/**"],"acceptance":["q"],"dependsOn":[],"budget":10,"mcp":[]},
 {"id":"merge","role":"integrator","name":"int-13","goal":"merge","pathsAllowed":["**"],"acceptance":["z"],"dependsOn":["impl"],"budget":10,"mcp":[]}
]}
JSON
with_arch "$TMP_BASE/r13.json"
"$ORCH" plan r13 "$TMP_BASE/r13.json" > /dev/null
"$ORCH" accept r13 arch fixture --force > /dev/null
mkdir -p "$TMP_BASE/bin-garbled"
cat > "$TMP_BASE/bin-garbled/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP_BASE/claude.calls"
case "\$*" in
  *--bg*) echo "something claude --bg never printed before" ;;
  agents*) echo '[{"id":"feed1234","name":"qa-13","kind":"background","state":"working"},{"id":"other999","name":"qa-13x","kind":"background","state":"working"}]' ;;
esac
EOF
chmod +x "$TMP_BASE/bin-garbled/claude"
: > "$TMP_BASE/claude.calls"
expect_exit 1 "spawn dies when the session id cannot be parsed" env PATH="$TMP_BASE/bin-garbled:$PATH" "$ORCH" spawn r13 qa
expect_grep '^stop feed1234$' "$TMP_BASE/claude.calls" "the session it launched, found by name, is stopped before it dies"
expect_no_grep '^stop other999$' "$TMP_BASE/claude.calls" "no other session is stopped"
expect_grep 'feed1234' "$TMP_BASE/err" "and it says which session it stopped"
expect_exit 1 "accept refuses a task never spawned" "$ORCH" accept r13 qa "looks fine"
expect_grep 'never spawned' "$TMP_BASE/err" "and says why"
expect_exit 0 "spawn d13" "$ORCH" spawn r13 impl
WT13="$REPO/.claude/worktrees/r13-d13"
expect_exit 1 "accept refuses a task with no handoff" "$ORCH" accept r13 impl ok
expect_grep 'none' "$TMP_BASE/err" "the refusal names the handoff state"
printf '# d13\n## Status\npartial\n' | "$ORCH" handoff-put r13 d13 > /dev/null
expect_exit 1 "accept refuses a partial handoff" "$ORCH" accept r13 impl ok
expect_grep 'partial' "$TMP_BASE/err" "the refusal says partial"
printf '# d13\n## Status\nblocked on the user\n' | "$ORCH" handoff-put r13 d13 > /dev/null
expect_exit 1 "accept refuses a blocked handoff" "$ORCH" accept r13 impl ok
expect_grep 'blocked' "$TMP_BASE/err" "the refusal says blocked"
printf '# d13\n## Status\ndone\n## Branch\nr13-d13\n' | "$ORCH" handoff-put r13 d13 > /dev/null
mkdir -p "$WT13/src" "$WT13/docs" "$WT13/lib" "$WT13/.scratch"
echo 'export const b = 2' > "$WT13/src/b.ts"; echo 'notes' > "$WT13/docs/notes.md"
git -C "$WT13" add src docs && git -C "$WT13" commit -qm 'b and notes'
echo 'x' > "$WT13/lib/x.ts"; echo 'h' > "$WT13/.scratch/handoff.md"
expect_exit 1 "accept refuses a branch that changed paths the task does not own" "$ORCH" accept r13 impl ok
expect_grep 'docs/notes.md' "$TMP_BASE/err" "the committed file outside pathsAllowed is named"
expect_grep 'lib/x.ts' "$TMP_BASE/err" "so is an uncommitted one"
expect_no_grep 'src/b.ts' "$TMP_BASE/err" "an allowed file is not"
expect_no_grep 'handoff.md' "$TMP_BASE/err" "nor scratch"
expect_exit 0 "accept --force records it anyway" "$ORCH" accept r13 impl ok --force
expect_grep 'now ready: merge$' "$TMP_BASE/out" "accept prints the tasks it made ready, and only those"
jq -r '.[] | select(.taskId == "impl") | .note' .orchestrator/r13/accepted.json > "$TMP_BASE/v"
expect_grep 'docs/notes.md' "$TMP_BASE/v" "the note records the files outside pathsAllowed"
git -C "$WT13" rm -q docs/notes.md && git -C "$WT13" commit -qm 'drop notes'; rm -f "$WT13/lib/x.ts"
expect_exit 0 "accept passes once the branch keeps to its paths" "$ORCH" accept r13 impl ok
expect_no_grep 'now ready' "$TMP_BASE/out" "nothing new became ready"
jq -r '.[] | select(.taskId == "impl") | .head' .orchestrator/r13/accepted.json > "$TMP_BASE/v"
expect_grep "^$(git rev-parse r13-d13)\$" "$TMP_BASE/v" "accept records the head of the task's branch"
expect_exit 0 "status before the branch moves" "$ORCH" status r13 --no-live
expect_no_grep 'moved since' "$TMP_BASE/out" "nothing flagged"
echo 'export const c = 3' > "$WT13/src/c.ts"; git -C "$WT13" add src && git -C "$WT13" commit -qm 'after accept'
expect_exit 0 "status after the branch moved" "$ORCH" status r13 --no-live
expect_grep 'moved since accept: impl' "$TMP_BASE/out" "status flags an accepted task whose branch moved"
expect_exit 0 "cancel res" "$ORCH" cancel r13 res "not needed"
expect_exit 1 "accept refuses a cancelled task" "$ORCH" accept r13 res ok
expect_grep 'cancelled' "$TMP_BASE/err" "and says so"
"$ORCH" cancel r13 res --undo > /dev/null
printf '# rev-13\n## Status\ndone\n## Branch\nw1\n' | "$ORCH" handoff-put r13 rev-13 > /dev/null
expect_exit 1 "close fails while a session stays listed" env STUB_RM_FAIL=1 "$ORCH" close r13 --force
expect_exit 1 "a failed close leaves no CLOSED marker" test -f .orchestrator/r13/CLOSED
expect_no_grep '|close|' .orchestrator/r13/events.log "nor a close event"
expect_exit 0 "close --force" "$ORCH" close r13 --force
expect_grep 'NOT contained in main: r13-d13 (session, handoff)' "$TMP_BASE/out" "close checks the session's worktree branch and says where each branch came from"
expect_grep 'contained in main: w1 (handoff)' "$TMP_BASE/out" "a branch named only in a handoff"
expect_no_grep 'ready to spawn' "$TMP_BASE/out" "close prints no ready line"
expect_exit 0 "CLOSED marker written on success" test -f .orchestrator/r13/CLOSED
jq -r 'map(.taskId) | sort | join(",")' .orchestrator/r13/cancelled.json > "$TMP_BASE/v"
expect_grep '^merge,res$' "$TMP_BASE/v" "close --force records the open tasks as cancelled"
grep '|close|' .orchestrator/r13/events.log > "$TMP_BASE/v"
expect_grep 'forced: res merge' "$TMP_BASE/v" "the close event names them"

echo "# remote branches, session ids, last events, settled reviews, stage report: run r14"
expect_exit 0 "init r14" "$ORCH" init r14 --base main
"$ORCH" acceptance r14 off > /dev/null
cat > "$TMP_BASE/r14.json" <<'JSON'
{"run":"r14","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d14","stage":"s1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"qa","role":"qa","name":"qa-14","stage":"s1","qaOf":"impl","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"rev","role":"reviewer","name":"rev-14","stage":"s1","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"mcp":[]}
]}
JSON
with_arch "$TMP_BASE/r14.json"
expect_exit 0 "plan r14" "$ORCH" plan r14 "$TMP_BASE/r14.json"
"$ORCH" accept r14 arch fixture --force > /dev/null
git clone -q --bare "$REPO" "$TMP_BASE/origin.git"
git remote add origin "$TMP_BASE/origin.git"
SHA_REMOTE=$(git commit-tree -p main -m 'pushed from another machine' 'main^{tree}')
git push -q origin "$SHA_REMOTE:refs/heads/r14-d14" && git fetch -q origin
expect_exit 0 "spawn a task whose branch exists only on origin" "$ORCH" spawn r14 impl
WT14="$REPO/.claude/worktrees/r14-d14"
git -C "$WT14" rev-parse HEAD > "$TMP_BASE/v"
expect_grep "^$SHA_REMOTE\$" "$TMP_BASE/v" "the worktree starts from origin's branch, not from base"
git -C "$WT14" rev-parse --abbrev-ref '@{upstream}' > "$TMP_BASE/v" 2>&1
expect_grep '^origin/r14-d14$' "$TMP_BASE/v" "the local branch tracks it"
expect_grep 'origin/r14-d14' "$TMP_BASE/err" "spawn says which branch it started from"
D14_ID=$(jq -r '.[] | select(.name == "d14") | .id' .orchestrator/r14/sessions.json)
echo "2026-09-29T00:00:00Z|${D14_ID}-0000-4000-8000-000000000014|d14|Bash|allow|ls" >> .orchestrator/r14/events.log
echo "2026-09-29T00:00:01Z|${D14_ID}-0000-4000-8000-000000000014|d14|Stop|block|no handoff" >> .orchestrator/r14/events.log
mkdir -p "$WT14/.scratch/evidence"; printf 'PNG' > "$WT14/.scratch/evidence/rel.png"
printf '# d14\n## Status\ndone\n## What I did\nScreens: .scratch/evidence/rel.png and .scratch/evidence/missing.png\n' | "$ORCH" handoff-put r14 d14 > /dev/null
expect_exit 0 "status after a Stop block and a handoff-put" "$ORCH" status r14 --no-live
expect_grep '^d14 .*handoff|allow' "$TMP_BASE/out" "the last event is the handoff-put, found by the name column"
expect_exit 0 "accept d14" "$ORCH" accept r14 impl ok
jq -r '.[] | select(.name == "d14") | .sessionId' .orchestrator/r14/sessions.json > "$TMP_BASE/v"
expect_grep "^${D14_ID}-0000-4000-8000-000000000014\$" "$TMP_BASE/v" "accept fills in the full session id from the event log"
expect_exit 0 "spawn qa-14" "$ORCH" spawn r14 qa
QA14_ID=$(jq -r '.[] | select(.name == "qa-14") | .id' .orchestrator/r14/sessions.json)
echo "2026-09-29T00:00:02Z|${QA14_ID}-0000-4000-8000-000000000015|qa-14|Read|allow|x" >> .orchestrator/r14/events.log
expect_exit 0 "rm qa-14" "$ORCH" rm r14 qa-14
jq -r '.[] | select(.name == "qa-14") | .sessionId' .orchestrator/r14/sessions.json > "$TMP_BASE/v"
expect_grep "^${QA14_ID}-0000-4000-8000-000000000015\$" "$TMP_BASE/v" "rm fills it in too"
expect_exit 0 "stage report of s1" "$ORCH" stage-report r14 s1
expect_grep '1 image reference(s) not found' "$TMP_BASE/out" "the report counts the references it could not find"
expect_grep 'rev-14 <span class="role">reviewer</span></h2><p class="state">settled<' .orchestrator/r14/stages/s1/index.html "a review whose task is accepted reads settled"
expect_exit 0 "a relative evidence path of a removed session resolves in its worktree" test -f .orchestrator/r14/stages/s1/img/d14-rel.png

echo "# plan validation: live-together overlap, test paths, cover fields, default budgets, replan: run r15"
expect_exit 0 "init r15" "$ORCH" init r15 --base main
"$ORCH" acceptance r15 off > /dev/null
cat > "$TMP_BASE/r15.json" <<'JSON'
{"run":"r15","baseBranch":"main","tasks":[
 {"id":"spec","role":"analyst","name":"an-15","goal":"spec","pathsAllowed":["docs/spec/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"res","role":"researcher","name":"res-15","goal":"research","pathsAllowed":["docs/research/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"des","role":"designer","name":"des-15","goal":"design","pathsAllowed":["docs/design/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"acc","role":"qa-lead","phase":"author","name":"acc-15","goal":"acceptance tests","pathsAllowed":["tests/acceptance/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"a","role":"developer","name":"da-15","goal":"code a","pathsAllowed":["src/a/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"b","role":"developer","name":"db-15","goal":"code b","pathsAllowed":["src/b/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"qa-a","role":"qa","qaOf":"a","name":"qa-a-15","goal":"cases a","pathsAllowed":["tests/qa/a/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"qa-b","role":"qa","qaOf":"b","name":"qa-b-15","goal":"cases b","pathsAllowed":["tests/qa/b/**"],"acceptance":["x"],"dependsOn":[]},
 {"id":"rev-a","role":"reviewer","reviewOf":"a","name":"rev-a-15","goal":"review a","pathsAllowed":[],"acceptance":["x"],"dependsOn":["a"]},
 {"id":"rev-b","role":"reviewer","reviewOf":"b","name":"rev-b-15","goal":"review b","pathsAllowed":[],"acceptance":["x"],"dependsOn":["b"]},
 {"id":"drev","role":"design-reviewer","designOf":"a","name":"drev-15","goal":"check a","pathsAllowed":[],"acceptance":["x"],"dependsOn":["a"]},
 {"id":"run","role":"tester","verifies":"a","name":"test-15","goal":"run a","pathsAllowed":[],"acceptance":["x"],"dependsOn":["a"]},
 {"id":"int","role":"integrator","name":"int-15","goal":"merge","pathsAllowed":["**"],"acceptance":["x"],"dependsOn":["spec","res","des","acc","a","b","qa-a","qa-b","rev-a","rev-b","drev","run"]},
 {"id":"fin","role":"qa-lead","phase":"accept","name":"fin-15","goal":"accept","pathsAllowed":["docs/acceptance/**"],"acceptance":["x"],"dependsOn":["int"]}
]}
JSON
with_arch "$TMP_BASE/r15.json"
jq '.tasks[0] |= del(.budget)' "$TMP_BASE/r15.json" > "$TMP_BASE/r15-ok.json"
r15_variant() { jq "$1" "$TMP_BASE/r15-ok.json" > "$TMP_BASE/r15-v.json"; }
r15_variant '(.tasks[] | select(.id == "b") | .pathsAllowed) = ["src/a/ui/**"]'
expect_exit 1 "plan refuses a glob inside another live task's glob" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'tasks a and b share paths src/a/\*\* ~ src/a/ui/\*\*' "$TMP_BASE/err" "the overlap is found by the literal prefix, not by equal strings"
r15_variant '(.tasks[] | select(.id == "b")) |= (.pathsAllowed = ["src/a/**"] | .dependsOn = ["spec"])'
expect_exit 1 "plan refuses equal globs of tasks with different dependencies that can run together" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'tasks a and b share paths src/a/\*\*' "$TMP_BASE/err" "different dependsOn is no sequencing"
grep -c . "$TMP_BASE/err" > "$TMP_BASE/v"
expect_grep '^1$' "$TMP_BASE/v" "each error is printed once"
r15_variant '(.tasks[] | select(.id == "b")) |= (.pathsAllowed = ["src/a/**"] | .dependsOn = ["spec", "a"])'
expect_exit 0 "plan accepts the same paths for a task that depends on the other" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
r15_variant '.mode = "staged" | .stages = ["s1", "s2"] | .tasks |= map(.stage = (if .id | IN("b", "rev-b", "int", "fin") then "s2" else "s1" end)) | (.tasks[] | select(.id == "b") | .pathsAllowed) = ["src/a/**"]'
expect_exit 0 "plan accepts the same paths in two stages, which never run together" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
r15_variant '(.tasks[] | select(.id == "a")) |= (.pathsAllowed += ["tests/qa/a/cases.test.ts"] | .dependsOn = ["qa-a"])'
expect_exit 1 "plan refuses a developer path inside its qa task's paths" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'developer task a may write the paths of qa task qa-a' "$TMP_BASE/err" "the qa task is named"
r15_variant '(.tasks[] | select(.id == "b")) |= (.pathsAllowed += ["tests/**"] | .dependsOn = ["acc", "qa-a", "qa-b"])'
expect_exit 1 "plan refuses a developer glob over the acceptance tests" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'developer task b may write the paths of qa-lead task acc' "$TMP_BASE/err" "the qa-lead author task is named"
r15_variant '(.tasks[] | select(.id == "rev-a") | .reviewOf) = "nope"'
expect_exit 1 "plan refuses a reviewOf that names no task" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'task rev-a: reviewOf nope names no developer task' "$TMP_BASE/err" "the dangling reviewOf is the reason"
r15_variant '(.tasks[] | select(.id == "run") | .verifies) = "spec"'
expect_exit 1 "plan refuses a verifies that names an analyst task" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'task run: verifies spec names no developer task' "$TMP_BASE/err" "the wrong target role is the reason"
r15_variant '(.tasks[] | select(.id == "rev-b") | .designOf) = "b"'
expect_exit 1 "plan refuses designOf on a reviewer" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'task rev-b: designOf belongs on a design-reviewer task' "$TMP_BASE/err" "the carrier's role is the reason"
r15_variant '(.tasks[] | select(.id == "qa-b") | .qaOf) = "rev-a"'
expect_exit 1 "plan refuses a qaOf that names a reviewer" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'task qa-b: qaOf rev-a names no developer task' "$TMP_BASE/err" "a reviewer is not a developer task"
expect_exit 0 "plan r15 without budgets" "$ORCH" plan r15 "$TMP_BASE/r15-ok.json"
jq -r '.tasks | map("\(.id)=\(.budget)") | join(" ")' .orchestrator/r15/plan.json > "$TMP_BASE/v"
ARCH15=$((40 + $(git ls-files | wc -l | tr -d ' ') / 20))
expect_grep "^arch=$ARCH15 spec=50 res=70 des=70 acc=80 a=120 b=120 qa-a=60 qa-b=60 rev-a=30 rev-b=30 drev=25 run=50 int=50 fin=40\$" "$TMP_BASE/v" "every role gets its own default budget, the architect the orch architecture heuristic"
"$ORCH" accept r15 arch fixture --force > /dev/null
jq '.interactive = true | .authorize.pushBase = true' "$TMP_BASE/r15-ok.json" > "$TMP_BASE/r15-v.json"
expect_exit 0 "plan with other run settings than the stored ones" "$ORCH" plan r15 "$TMP_BASE/r15-v.json"
expect_grep 'interactive in .* differs from the stored value' "$TMP_BASE/err" "plan warns that interactive stays as stored"
expect_grep 'authorize in .* differs from the stored value' "$TMP_BASE/err" "and that authorize does"
jq -r '.interactive' .orchestrator/r15/plan.json > "$TMP_BASE/v"
expect_grep '^false$' "$TMP_BASE/v" "the stored value is kept"
expect_exit 0 "spawn a" "$ORCH" spawn r15 a
expect_exit 1 "plan refuses once a session is registered" "$ORCH" plan r15 "$TMP_BASE/r15-ok.json"
expect_grep '--replan' "$TMP_BASE/err" "the refusal names --replan"
jq '(.tasks[] | select(.id == "a")) |= (.budget = 77 | .pathsAllowed = ["src/a/**", "src/shared/**"])' "$TMP_BASE/r15-ok.json" > "$TMP_BASE/r15-v.json"
expect_exit 0 "plan --replan" "$ORCH" plan r15 "$TMP_BASE/r15-v.json" --replan
jq -r '.[] | select(.taskId == "a") | "\(.budget) \(.pathsAllowed | join(","))"' .orchestrator/r15/sessions.json > "$TMP_BASE/v"
expect_grep '^77 src/a/\*\*,src/shared/\*\*$' "$TMP_BASE/v" "--replan syncs budget and pathsAllowed into the live session"
expect_exit 0 "task set still works with a registered session" "$ORCH" task set r15 a budget 90
jq -r '.[] | select(.taskId == "a") | .budget' .orchestrator/r15/sessions.json > "$TMP_BASE/v"
expect_grep '^90$' "$TMP_BASE/v" "task set reaches the live session"

echo "# handoff, handoff-put --file and --by-lead, spawn options, the run lock, plugin version: run r16"
PV=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
expect_exit 0 "init r16" "$ORCH" init r16 --base main
jq -r '.pluginVersion' .orchestrator/r16/plan.json > "$TMP_BASE/v"
expect_grep "^$PV\$" "$TMP_BASE/v" "init records the plugin version"
"$ORCH" acceptance r16 off > /dev/null
cat > "$TMP_BASE/r16.json" <<'JSON'
{"run":"r16","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d16","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"qa","role":"qa","name":"qa-16","qaOf":"impl","goal":"cases","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"budget":20,"mcp":[]},
 {"id":"rev","role":"reviewer","name":"rev-16","reviewOf":"impl","goal":"review","pathsAllowed":[],"acceptance":["y"],"dependsOn":["impl"],"budget":10,"mcp":[]}
]}
JSON
with_arch "$TMP_BASE/r16.json"
expect_exit 0 "plan r16" "$ORCH" plan r16 "$TMP_BASE/r16.json"
"$ORCH" accept r16 arch fixture --force > /dev/null
jq -r '.pluginVersion' .orchestrator/r16/plan.json > "$TMP_BASE/v"
expect_grep "^$PV\$" "$TMP_BASE/v" "orch plan keeps the recorded plugin version"

expect_exit 1 "handoff refuses a name that is a path" "$ORCH" handoff r16 ../../r14/handoffs/d14
expect_grep 'plain name' "$TMP_BASE/err" "the name rule is the reason"
expect_exit 1 "handoff of a session that has not handed off" "$ORCH" handoff r16 d16
expect_grep 'no handoff yet from d16' "$TMP_BASE/err" "an orch message, not a raw cat error"

expect_exit 1 "spawn refuses a --round that is not a number" "$ORCH" spawn r16 impl --round x --dry-run
expect_grep '--round needs a round number' "$TMP_BASE/err" "the --round rule is the reason"
expect_exit 1 "spawn refuses --round 0" "$ORCH" spawn r16 impl --round 0 --dry-run
expect_exit 1 "spawn refuses a --round without a value" "$ORCH" spawn r16 impl --dry-run --round
expect_grep '--round needs a round number' "$TMP_BASE/err" "and says so"
expect_exit 1 "spawn refuses --wave with --round" "$ORCH" spawn r16 --wave --round 2 --dry-run
expect_exit 1 "spawn refuses --wave with --budget" "$ORCH" spawn r16 --wave --budget 5 --dry-run
expect_grep '--wave' "$TMP_BASE/err" "the refusal names --wave"
expect_exit 1 "spawn refuses an unknown option" "$ORCH" spawn r16 --rounds 2 impl --dry-run
expect_grep 'unknown option --rounds' "$TMP_BASE/err" "the unknown option is named"
expect_exit 0 "spawn dry-run of r16" "$ORCH" spawn r16 impl --dry-run
expect_grep "^cd $REPO/.claude/worktrees/r16-d16 && env -u CLAUDE_CODE_CHILD_SESSION claude --agent orchestrator:developer " "$TMP_BASE/out" "dry-run prints the command the real spawn runs, in the worktree it runs in"
expect_exit 1 "start refuses an unknown option" "$ORCH" start --effort max -- "x"
expect_grep 'unknown option --effort' "$TMP_BASE/err" "the unknown option is named"

jq '.pluginVersion = "0.0.1"' .orchestrator/r16/plan.json > "$TMP_BASE/v" && mv "$TMP_BASE/v" .orchestrator/r16/plan.json
expect_exit 0 "spawn dry-run on another plugin version" "$ORCH" spawn r16 impl --dry-run
expect_grep "run r16 was started on plugin 0.0.1, installed is $PV" "$TMP_BASE/err" "spawn warns about the version change"
expect_exit 0 "doctor with a run on another plugin version" "$ORCH" doctor --no-daemon
expect_grep "^warn run r16 was started on plugin 0.0.1, installed is $PV" "$TMP_BASE/out" "doctor warns about it too"
jq --arg v "$PV" '.pluginVersion = $v' .orchestrator/r16/plan.json > "$TMP_BASE/v" && mv "$TMP_BASE/v" .orchestrator/r16/plan.json
expect_exit 0 "spawn dry-run on the recorded version" "$ORCH" spawn r16 impl --dry-run
expect_no_grep 'started on plugin' "$TMP_BASE/err" "no warning when the versions agree"

mkdir -p "$TMP_BASE/nojq"
for t in bash env git head dirname cat; do ln -sf "$(command -v "$t")" "$TMP_BASE/nojq/$t"; done
ln -sf "$TMP_BASE/bin/claude" "$TMP_BASE/nojq/claude"
expect_exit 1 "doctor without jq fails" env PATH="$TMP_BASE/nojq" "$ORCH" doctor --no-daemon
expect_grep '^FAIL jq not on PATH' "$TMP_BASE/out" "doctor is the one that reports the missing jq"
expect_exit 0 "help without jq" env PATH="$TMP_BASE/nojq" "$ORCH" help

printf '# d16\n## Status\npartial\nFILE-FORM\n' > "$TMP_BASE/h16.md"
expect_exit 0 "handoff-put --file" sh -c "'$ORCH' handoff-put r16 d16 --file '$TMP_BASE/h16.md' < /dev/null"
expect_grep 'FILE-FORM' .orchestrator/r16/handoffs/d16.md "the handoff comes from the file"
expect_exit 1 "handoff-put --file of a missing file" sh -c "'$ORCH' handoff-put r16 d16 --file '$TMP_BASE/nope.md' < /dev/null"
expect_grep 'no such file' "$TMP_BASE/err" "the missing file is the reason"
expect_exit 1 "handoff-put refuses an unknown option" sh -c "'$ORCH' handoff-put r16 d16 --fiel x < /dev/null"
expect_grep 'unknown option --fiel' "$TMP_BASE/err" "the unknown option is named"
printf '# d16-r2\n## Status\ndone\nROUND-TWO\n' | "$ORCH" handoff-put r16 d16-r2 > /dev/null
expect_exit 0 "handoff prints the latest round" "$ORCH" handoff r16 d16
expect_grep 'ROUND-TWO' "$TMP_BASE/out" "round 2 is printed"
expect_no_grep 'FILE-FORM' "$TMP_BASE/out" "round 1 is not"
expect_grep 'earlier rounds: d16.md' "$TMP_BASE/err" "the other rounds are listed"
printf '# rev-16\n## Status\nblocked on the user\n' | "$ORCH" handoff-put r16 rev-16 --by-lead "the BLOCKED message of rev-16" > /dev/null
expect_grep '^written by the orchestrator from the BLOCKED message of rev-16$' .orchestrator/r16/handoffs/rev-16.md "--by-lead stamps the handoff"
expect_grep 'blocked on the user' .orchestrator/r16/handoffs/rev-16.md "and keeps its text"
expect_grep '|orchestrator|rev-16|handoff-put|allow|written by the orchestrator from the BLOCKED message of rev-16' .orchestrator/r16/events.log "and logs who wrote it"

expect_exit 0 "spawn d16" "$ORCH" spawn r16 impl
mkdir .orchestrator/r16/.lock
"$ORCH" budget r16 d16 33 > /dev/null 2>&1 & P16=$!
sleep 1
jq -r '.[] | select(.name == "d16") | .budget' .orchestrator/r16/sessions.json > "$TMP_BASE/v"
expect_grep '^20$' "$TMP_BASE/v" "budget waits for the run lock"
rmdir .orchestrator/r16/.lock; wait "$P16"
jq -r '.[] | select(.name == "d16") | .budget' .orchestrator/r16/sessions.json > "$TMP_BASE/v"
expect_grep '^33$' "$TMP_BASE/v" "and writes once the lock is free"
mkdir .orchestrator/r16/.lock
"$ORCH" paths r16 d16 add 'lib/**' > /dev/null 2>&1 & P16=$!
sleep 1
jq -r '.[] | select(.name == "d16") | .pathsAllowed | join(",")' .orchestrator/r16/sessions.json > "$TMP_BASE/v"
expect_grep '^src/\*\*$' "$TMP_BASE/v" "paths waits for the run lock"
rmdir .orchestrator/r16/.lock; wait "$P16"
jq -r '.[] | select(.name == "d16") | .pathsAllowed | join(",")' .orchestrator/r16/sessions.json > "$TMP_BASE/v"
expect_grep '^src/\*\*,lib/\*\*$' "$TMP_BASE/v" "and writes once the lock is free"
mkdir .orchestrator/r16/.lock
"$ORCH" task set r16 impl budget 44 > /dev/null 2>&1 & P16=$!
sleep 1
jq -r '.[] | select(.name == "d16") | .budget' .orchestrator/r16/sessions.json > "$TMP_BASE/v"
expect_grep '^33$' "$TMP_BASE/v" "task set waits for the run lock"
rmdir .orchestrator/r16/.lock; wait "$P16"
jq -r '.[] | select(.name == "d16") | .budget' .orchestrator/r16/sessions.json > "$TMP_BASE/v"
expect_grep '^44$' "$TMP_BASE/v" "and writes once the lock is free"

summary
