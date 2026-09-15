#!/usr/bin/env bash
# Shared by guard.sh and stop-gate.sh. bash 3.2 compatible; needs jq.

# Index of sessions the guard has seen: <sid> -> run dir. Lets the guard keep hold of a
# registered session after it leaves the repository (cd /tmp), instead of failing open.
INDEX_DIR="${CLAUDE_ORCH_STATE:-$HOME/.claude/orchestrator-sessions}"

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
      (cd "$(dirname "$f")" && pwd -P); return 0
    fi
  done
  return 1
}

# resolve_run <cwd> <session_id>: run dir via cwd, else via the index; verifies the session is still listed.
# Prints "<run dir>|<cwd-in-repo:1|0>". Fails when the session is registered nowhere.
resolve_run() {
  local root run in_repo=1
  if root=$(repo_root "$1" 2>/dev/null) && run=$(find_run "$root" "$2"); then
    :
  else
    in_repo=0
    [ -f "$INDEX_DIR/$2" ] || return 1
    run=$(cat "$INDEX_DIR/$2")
    [ -f "$run/sessions.json" ] || return 1
    jq -e --arg s "$2" 'map(select(.sessionId == $s)) | length > 0' "$run/sessions.json" >/dev/null 2>&1 || return 1
  fi
  mkdir -p "$INDEX_DIR" 2>/dev/null && printf '%s' "$run" > "$INDEX_DIR/$2" 2>/dev/null
  printf '%s|%s' "$run" "$in_repo"
}

# session_json <run_dir> <session_id>: the session's record.
session_json() {
  jq -c --arg s "$2" 'map(select(.sessionId == $s)) | .[0]' "$1/sessions.json"
}

# norm_path <absolute path>: canonical form (symlinks and . / .. resolved) for an existing parent dir;
# for a not-yet-existing parent, the path is accepted only when it has no . or .. segments. Fails otherwise.
norm_path() {
  local p="$1" d b
  case "$p" in /*) ;; *) return 1 ;; esac
  b=$(basename "$p"); d=$(dirname "$p")
  case "$b" in .|..) return 1 ;; esac
  if [ -d "$d" ]; then
    d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s' "$d" "$b"
  else
    case "/$p/" in */../*|*/./*) return 1 ;; esac
    printf '%s' "$p"
  fi
}

# log_event <run_dir> <sid> <name> <tool> <decision> <detail>
log_event() {
  printf '%s|%s|%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$5" "$(printf '%s' "$6" | tr '\n|' '  ')" >> "$1/events.log"
}
