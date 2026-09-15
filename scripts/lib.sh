#!/usr/bin/env bash
# Shared by guard.sh and stop-gate.sh. bash 3.2 compatible; needs jq.

# repo_root <cwd>: the main checkout's root, also from inside a linked worktree. Fails outside git.
repo_root() {
  local common
  common=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$(cd "$1" && cd "$common" && pwd -P)" ;;
  esac
  dirname "$common"
}

# find_run <root> <session_id>: prints the run dir whose sessions.json lists the session; fails when none does.
find_run() {
  local f
  for f in "$1"/.orchestrator/*/sessions.json; do
    [ -f "$f" ] || continue
    if jq -e --arg s "$2" 'map(select(.sessionId == $s)) | length > 0' "$f" >/dev/null 2>&1; then
      dirname "$f"; return 0
    fi
  done
  return 1
}

# session_json <run_dir> <session_id>: the session's record.
session_json() {
  jq -c --arg s "$2" 'map(select(.sessionId == $s)) | .[0]' "$1/sessions.json"
}

# log_event <run_dir> <sid> <name> <tool> <decision> <detail>
log_event() {
  printf '%s|%s|%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$5" "$(printf '%s' "$6" | tr '\n|' '  ')" >> "$1/events.log"
}
