#!/usr/bin/env bash
# Shared helpers for the plugin's test scripts. bash 3.2 compatible.
set -u

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="$PLUGIN_ROOT/tests/.tmp"
export CLAUDE_ORCH_STATE="$TMP_BASE/state"
PASS=0
FAIL=0

fresh_tmp() {
  rm -rf "$TMP_BASE"
  mkdir -p "$TMP_BASE"
}

# stub_claude: a fake `claude` first on PATH, so no test reaches the real CLI, its MCP servers or the network.
# Every invocation is appended to $TMP_BASE/claude.calls.
stub_claude() {
  mkdir -p "$TMP_BASE/bin"
  cat > "$TMP_BASE/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP_BASE/claude.calls"
bg=0; for a in "\$@"; do [ "\$a" = --bg ] && bg=1; done
if [ "\$bg" = 1 ]; then
  # Unique across the parallel spawns of a wave, as real session ids are.
  id=\$(printf '%04x%04x' \$(( \$\$ % 65536 )) "\$RANDOM"); echo "\$id" >> "$TMP_BASE/claude.bg"
  echo "session backgrounded · \$id"; exit 0
fi
case "\$*" in
  --version) echo "0.0.0 (stub)" ;;
  "mcp list") [ -n "\${STUB_SLOW:-}" ] && sleep 5; echo "playwright: npx -y @playwright/mcp@latest - ✓ Connected" ;;
  agents*) [ -f "$TMP_BASE/claude.bg" ] && jq -R '{id: ., sessionId: (. + "-0000-4000-8000-000000000000"), state: "working"}' "$TMP_BASE/claude.bg" | jq -s . || echo '[]' ;;
esac
EOF
  chmod +x "$TMP_BASE/bin/claude"
  PATH="$TMP_BASE/bin:$PATH"; export PATH
}

# make_repo <dir>: a git repo with one commit on main and a linked worktree at .claude/worktrees/w1
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  mkdir -p "$dir/src" "$dir/docs"
  echo 'export const a = 1' > "$dir/src/a.ts"
  git -C "$dir" add -A
  git -C "$dir" commit -qm 'init'
  mkdir -p "$dir/.claude/worktrees"
  git -C "$dir" worktree add -q -b w1 "$dir/.claude/worktrees/w1" main
}

# make_run <repo> <run> : run dir with plan.json and sessions.json holding two sessions
make_run() {
  local d="$1/.orchestrator/$2"
  mkdir -p "$d/handoffs"
  : > "$d/events.log"
  cat > "$d/plan.json" <<'JSON'
{"run":"r1","goal":"test","baseBranch":"main","tasks":[
 {"id":"impl","role":"developer","name":"dev-1","goal":"implement","pathsAllowed":["src/**","test/**"],"acceptance":["x"],"dependsOn":[],"budget":2},
 {"id":"merge","role":"integrator","name":"int-1","goal":"merge","pathsAllowed":["**"],"acceptance":["x"],"dependsOn":["impl"],"budget":50}
]}
JSON
  cat > "$d/sessions.json" <<'JSON'
[
 {"taskId":"impl","name":"dev-1","role":"developer","id":"aaaa1111","sessionId":"sid-dev","pathsAllowed":["src/**","test/**"],"budget":2},
 {"taskId":"merge","name":"int-1","role":"integrator","id":"bbbb2222","sessionId":"sid-int","pathsAllowed":["**"],"budget":50}
]
JSON
}

# hook_input <session_id> <cwd> <tool> <tool_input_json>
hook_input() {
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2" "$3" "$4"
}

# hook_bash <session_id> <cwd> <command>: a Bash hook input built with jq, so the command may span lines
hook_bash() {
  jq -cn --arg s "$1" --arg c "$2" --arg cmd "$3" '{session_id:$s, cwd:$c, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$cmd}}'
}

# expect_exit <expected> <label> <cmd...>  — runs cmd with stdin already redirected by caller
expect_exit() {
  local want="$1" label="$2"; shift 2
  local got=0
  "$@" >"$TMP_BASE/out" 2>"$TMP_BASE/err" || got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1)); printf 'ok   %s\n' "$label"
  else
    FAIL=$((FAIL+1)); printf 'FAIL %s (want exit %s, got %s)\n  stderr: %s\n' "$label" "$want" "$got" "$(cat "$TMP_BASE/err")"
  fi
}

expect_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file"; then PASS=$((PASS+1)); printf 'ok   %s\n' "$label"
  else FAIL=$((FAIL+1)); printf 'FAIL %s (pattern %s not in %s)\n' "$label" "$pattern" "$file"; fi
}

expect_no_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -q -- "$pattern" "$file"; then FAIL=$((FAIL+1)); printf 'FAIL %s (pattern %s found in %s)\n' "$label" "$pattern" "$file"
  else PASS=$((PASS+1)); printf 'ok   %s\n' "$label"; fi
}

# expect_calls <n> <label>: how many times the stubbed claude was asked for `mcp list`
expect_calls() {
  local got; got=$(grep -c '^mcp list$' "$TMP_BASE/claude.calls" 2>/dev/null || true)
  if [ "${got:-0}" -eq "$1" ]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$2"
  else FAIL=$((FAIL+1)); printf 'FAIL %s (claude mcp list ran %s times, want %s)\n' "$2" "${got:-0}" "$1"; fi
}

summary() {
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
