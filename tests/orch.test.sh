#!/usr/bin/env bash
# orch CLI: init, plan, brief composition, pause/resume, spawn --dry-run. Never launches a real session.
. "$(dirname "$0")/lib.sh"
ORCH="$PLUGIN_ROOT/bin/orch"

fresh_tmp
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
 {"id":"impl","role":"developer","name":"dev-impl","goal":"Implement it.","pathsAllowed":["src/**"],"acceptance":["tests green"],"dependsOn":["spec"],"budget":200}
]}
JSON
expect_exit 0 "plan stores the graph" "$ORCH" plan r1 "$TMP_BASE/plan.json"
expect_grep '"dev-impl"' .orchestrator/r1/plan.json "plan.json written"
printf '{"run":"r1","tasks":[{"id":"a","role":"wizard","name":"x","goal":"g","pathsAllowed":[],"acceptance":[],"dependsOn":[],"budget":1}]}' > "$TMP_BASE/bad.json"
expect_exit 1 "plan rejects unknown role" "$ORCH" plan r1 "$TMP_BASE/bad.json"
printf '{"run":"r1","tasks":[{"id":"a","role":"developer","name":"x","goal":"g","pathsAllowed":["src/**"],"acceptance":[],"dependsOn":[],"budget":1},{"id":"b","role":"developer","name":"y","goal":"g","pathsAllowed":["src/**"],"acceptance":[],"dependsOn":[],"budget":1}]}' > "$TMP_BASE/clash.json"
expect_exit 1 "plan rejects two same-wave tasks sharing a path" "$ORCH" plan r1 "$TMP_BASE/clash.json"

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

summary
