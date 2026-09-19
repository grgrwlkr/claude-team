#!/usr/bin/env bash
# orch CLI: init, plan, brief composition, pause/resume, spawn --dry-run. Never launches a real session.
. "$(dirname "$0")/lib.sh"
ORCH="$PLUGIN_ROOT/bin/orch"

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

echo "# plan"
cat > "$TMP_BASE/plan.json" <<'JSON'
{"run":"r1","goal":"Add dark mode","baseBranch":"main","tasks":[
 {"id":"spec","role":"analyst","name":"analyst-spec","goal":"Write the spec.","pathsAllowed":["docs/**"],"acceptance":["testable"],"dependsOn":[],"budget":80},
 {"id":"impl","role":"developer","name":"dev-impl","goal":"Implement it.","pathsAllowed":["src/**"],"acceptance":["tests green"],"dependsOn":["spec"],"budget":200},
 {"id":"rev-impl","role":"reviewer","name":"rev-impl","goal":"Review the implementation.","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":60},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"Merge the branches.","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":[],"budget":90}
]}
JSON
expect_exit 0 "plan stores the graph" "$ORCH" plan r1 "$TMP_BASE/plan.json"
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
expect_exit 0 "accept records acceptance outside the handoff" "$ORCH" accept r1 spec "partial is fine, fact not needed"
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
 {"id":"rev","role":"reviewer","name":"rev-1","goal":"review impl","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":40},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":["rev"],"budget":60}
]}
JSON
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
"$ORCH" accept r1 impl "so the reviewer brief can render" > /dev/null
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
 {"id":"rev","role":"reviewer","name":"rev-1","goal":"review impl","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":40},
 {"id":"run","role":"tester","name":"tester-1","goal":"run the app and exercise the criteria","pathsAllowed":[],"acceptance":["every criterion has evidence"],"dependsOn":["impl"],"verifies":"impl","budget":80},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":["rev","run"],"budget":60}
]}
JSON
expect_exit 0 "plan with a tester per developer task is accepted" "$ORCH" plan r1 "$TMP_BASE/tested.json"
expect_grep '"interactive": true' .orchestrator/r1/plan.json "interactive survives orch plan"
"$ORCH" accept r1 impl "for the tester brief" > /dev/null
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
cat > "$TMP_BASE/gate.json" <<'JSON'
{"run":"r2","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":5},
 {"id":"rev","role":"reviewer","name":"rev-1","goal":"review impl","pathsAllowed":[],"acceptance":["findings cited"],"dependsOn":["impl"],"reviewOf":"impl","budget":40},
 {"id":"merge-task","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["green"],"dependsOn":["impl","rev"],"budget":60}
]}
JSON
expect_exit 0 "plan for the gate run" "$ORCH" plan r2 "$TMP_BASE/gate.json"
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
for t in impl rev merge-task; do "$ORCH" accept r2 "$t" ok > /dev/null; done
expect_exit 0 "close succeeds once everything is accepted" "$ORCH" close r2
expect_grep '1 refs checked' "$TMP_BASE/out" "close counts the refs it verified"
expect_grep 'contained in main: w1' "$TMP_BASE/out" "close reports containment per branch"
expect_exit 1 "this run's index entry is gone" test -f "$CLAUDE_ORCH_STATE/sid-d1"
expect_exit 0 "another run's index entry stays" test -f "$CLAUDE_ORCH_STATE/sid-other"
expect_exit 0 "CLOSED marker written" test -f .orchestrator/r2/CLOSED

summary
