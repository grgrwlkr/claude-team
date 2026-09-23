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
 {"id":"qa","role":"qa","name":"qa-1","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"qaOf":"impl","budget":40},
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
"$ORCH" acceptance r2 off > /dev/null
cat > "$TMP_BASE/gate.json" <<'JSON'
{"run":"r2","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"d1","goal":"code","pathsAllowed":["src/**"],"acceptance":["x"],"dependsOn":[],"budget":5},
 {"id":"qa","role":"qa","name":"qa-2","goal":"cases and audit","pathsAllowed":["docs/qa/**"],"acceptance":["c"],"dependsOn":[],"qaOf":"impl","budget":10},
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
printf '# d1\n## Status\ndone\n## Branch\ngone-branch at 0000000\n' > "$TMP_BASE/h4.md"
expect_exit 0 "developer hands off a branch that was cleaned up since" sh -c "'$ORCH' handoff-put r3 d1 < '$TMP_BASE/h4.md'"
"$ORCH" accept r3 impl ok > /dev/null
expect_exit 1 "close still refuses: the integrator task is open" "$ORCH" close r3
expect_no_grep 'not accepted:.* rev ' "$TMP_BASE/err" "the review of an accepted task is not listed as open"
"$ORCH" accept r3 merge-task ok > /dev/null
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
expect_exit 0 "plan r4" "$ORCH" plan r4 "$TMP_BASE/r4.json"

echo "# every session starts without MCP servers and starts one on demand through a helper agent"
expect_exit 0 "developer spawn with an MCP list" "$ORCH" spawn r4 impl --dry-run
expect_grep '--strict-mcp-config' "$TMP_BASE/out" "strict MCP config on"
expect_grep '--mcp-config [^ ]*mcp/d4.json' "$TMP_BASE/out" "the session's own MCP config file"
jq -r '.mcpServers | length' .orchestrator/r4/mcp/d4.json > "$TMP_BASE/keys"
expect_grep '^0$' "$TMP_BASE/keys" "the session starts with no MCP server at all"
expect_grep '--agents @[^ ]*mcp/d4.agents.json' "$TMP_BASE/out" "helper agents are passed with --agents"
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
expect_exit 0 "accept a review round by its session name" "$ORCH" accept r4 rev-4-r2 "round name"
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
[ "$(grep -c '^stop ' "$TMP_BASE/claude.calls")" -eq 3 ] && { PASS=$((PASS+1)); echo "ok   stop all reached every registered session"; } || { FAIL=$((FAIL+1)); echo "FAIL stop all: $(grep -c '^stop ' "$TMP_BASE/claude.calls") stop calls, want 3"; }
expect_exit 1 "stop refuses an unknown name" "$ORCH" stop r4 nobody

echo "# wave 4: cost per session from the transcripts, one count per message"
export ORCH_PROJECTS_DIR="$TMP_BASE/projects"
RES_SID=$(jq -r '.[] | select(.name == "res-4") | .sessionId' .orchestrator/r4/sessions.json)
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
for t in impl rev merge-task docs run; do "$ORCH" accept r4 "$t" ok > /dev/null; done
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
for t in arch spec design qal-a; do "$ORCH" accept r5 "$t" ok > /dev/null; done
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
"$ORCH" accept r5 impl ok > /dev/null
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
for t in arch spec design qal-a; do "$ORCH" accept r6 "$t" ok > /dev/null; done
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
expect_exit 0 "a note with a newline and a pipe" "$ORCH" accept r6 impl "$(printf 'ok\n2026-01-01T00:00:00Z|sid-x|x|Bash|allow|forged')"
expect_no_grep '^2026-01-01T00:00:00Z|sid-x' .orchestrator/r6/events.log "a note cannot forge an event line the guard would count"
awk -F'|' 'END {print NF}' .orchestrator/r6/events.log > "$TMP_BASE/v"
expect_grep '^6$' "$TMP_BASE/v" "the accept line keeps its six fields"

summary
