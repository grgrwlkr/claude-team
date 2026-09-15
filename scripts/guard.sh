#!/usr/bin/env bash
# PreToolUse guard for orchestrated team sessions.
# Exit 2 blocks the tool call and tells the session why; exit 0 lets it through.
# Inert (exit 0, no side effects) for any session not registered in a run's sessions.json.
set -u
. "$(dirname "$0")/lib.sh"

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
tool=$(jq -r '.tool_name // empty' <<<"$input")
[ -n "$sid" ] && [ -n "$cwd" ] && [ -n "$tool" ] || exit 0
[ -d "$cwd" ] || exit 0

resolved=$(resolve_run "$cwd" "$sid") || exit 0
run_dir=${resolved%|*}
in_repo=${resolved##*|}
rec=$(session_json "$run_dir" "$sid")
name=$(jq -r '.name' <<<"$rec")
role=$(jq -r '.role' <<<"$rec")
budget=$(jq -r '.budget // 0' <<<"$rec")
base=$(jq -r '.baseBranch // "main"' "$run_dir/plan.json" 2>/dev/null)
[ -n "$base" ] && [ "$base" != null ] || base=main
handoff="$run_dir/handoffs/$name.md"

block() {
  log_event "$run_dir" "$sid" "$name" "$tool" block "$1"
  printf 'orchestrator guard blocked this call for %s (%s): %s\nReport BLOCKED: to the orchestrator instead of working around it.\n' "$name" "$role" "$1" >&2
  exit 2
}
allow() {
  log_event "$run_dir" "$sid" "$name" "$tool" allow "${1:-}"
  exit 0
}

file_path=""
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    file_path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    if [ -n "$file_path" ]; then
      file_path=$(norm_path "$file_path") || block "file path must be absolute and free of . or .. segments (got $(jq -r '.tool_input.file_path // .tool_input.notebook_path' <<<"$input"))"
    fi
    # Own handoff: always writable, never counted, even when paused or out of budget.
    [ -n "$file_path" ] && [ "$file_path" = "$handoff" ] && allow "handoff"
    ;;
esac

# A registered session whose working directory left the repository is held, not released.
if [ "$in_repo" != 1 ]; then
  block "your working directory ($cwd) is outside the repository of run $(basename "$run_dir"); cd back into your worktree before running or editing anything"
fi
# Nor may it sit inside the orchestrator's own directories, where relative paths would dodge the checks below.
cwd_real=$(cd "$cwd" && pwd -P)
case "$cwd_real/" in
  "$run_dir"/*|"$INDEX_DIR"/*) block "your working directory is inside the orchestrator's directory ($cwd_real); cd back into your worktree" ;;
esac

# Pause: the orchestrator stopped this session or the whole wave.
if [ -f "$run_dir/PAUSE-$name" ]; then
  block "paused by the orchestrator: $(cat "$run_dir/PAUSE-$name" 2>/dev/null). Read and answer its message; edits and commands resume when it runs orch resume."
fi
if [ -f "$run_dir/PAUSE" ]; then
  block "the whole run is paused by the orchestrator: $(cat "$run_dir/PAUSE" 2>/dev/null). Wait for its message."
fi

# Budget: allowed guarded calls so far, before this one.
if [ "$budget" -gt 0 ] 2>/dev/null; then
  used=$(grep -c "^[^|]*|$sid|[^|]*|[^|]*|allow|" "$run_dir/events.log" 2>/dev/null || true)
  used=${used:-0}
  if [ "$used" -ge "$budget" ]; then
    block "tool-call budget spent ($used of $budget). Write your handoff at $handoff with Status partial and stop; the orchestrator decides what happens next."
  fi
fi

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    [ -n "$file_path" ] || allow
    case "$file_path" in
      "$run_dir"/handoffs/*) block "that handoff belongs to another session; you may write only $handoff" ;;
      "$run_dir"/*) block "the run directory is the orchestrator's; you may write only $handoff" ;;
    esac
    wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || block "edits are allowed only inside your git worktree"
    common=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
    case "$common" in /*) ;; *) common="$(cd "$cwd" && cd "$common" && pwd -P)";; esac
    if [ "$(dirname "$common")" = "$wt" ]; then
      block "this is the main checkout; move into your own worktree under .claude/worktrees/ before editing"
    fi
    case "$file_path" in
      "$wt"/*) rel=${file_path#"$wt"/} ;;
      *) block "path is outside your worktree ($wt)" ;;
    esac
    ok=0
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      # shellcheck disable=SC2053  # the glob must stay unquoted to act as a pattern
      if [[ "$rel" == $pat ]]; then ok=1; break; fi
    done < <(jq -r '.pathsAllowed[]?' <<<"$rec")
    [ "$ok" -eq 1 ] || block "path $rel is outside your allowed paths ($(jq -r '.pathsAllowed | join(", ")' <<<"$rec")). Ask the orchestrator if the task needs it."
    allow "$rel"
    ;;
  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    [ -n "$cmd" ] || allow
    # Quotes and backslashes stripped, whitespace collapsed: `git "push" --force` reads as `git push --force`.
    flat=$(printf '%s' "$cmd" | tr -d '"'"'"'\\' | tr -s '[:space:]' ' ')
    # git with any global options before the subcommand: git -C dir push, git --git-dir=x reset …
    GIT='git( -[A-Za-z=/._-]+( [^ -][^ ]*)?)*'
    has() { printf '%s' "$flat" | grep -Eq "$1"; }
    if has "${GIT} push[^|;&]*( -f( |$)|--force)"; then block "force push is never allowed"; fi
    if has "${GIT} push[^|;&]*(^| |:|\+)$base( |$)"; then block "pushing the base branch ($base) is the user's call, not a session's"; fi
    if has "${GIT} reset --hard|${GIT} branch -D|${GIT} worktree remove|${GIT} clean -[a-zA-Z]*f|${GIT} push[^|;&]*--delete"; then block "destructive git command; ask the orchestrator"; fi
    if has '(^|[;&| ])claude (stop|kill|rm|respawn)( |$)'; then block "sessions are stopped only by the orchestrator or the user"; fi
    if has '(^|[;&| ])sudo( |$)'; then block "no sudo in a team session"; fi
    if has '(curl|wget)[^|]*\| *(ba|z|da)?sh( |$)'; then block "piping a download into a shell is not allowed; download, read, then run"; fi
    touches_state=0
    has '(\.orchestrator/|orchestrator-sessions)' && touches_state=1
    printf '%s' "$flat" | grep -qF -- "$INDEX_DIR" && touches_state=1
    if [ "$touches_state" -eq 1 ] && has '(>|(^|[;&| ])(tee|mv|cp|rm|truncate|ln|chmod|touch|mkdir|rmdir)( |$)|sed -i|jq[^|;&]* -i|python[^|;&]* -c|perl -[a-zA-Z]*i)'; then
      block "the run directory and the session index are written only by the orchestrator; your handoff goes through the Write tool at $handoff"
    fi
    if has '(^|[;&| ])rm -[a-zA-Z]*[rR]'; then
      tail_part=${flat#*rm }
      for tok in $tail_part; do
        case "$tok" in
          -*) ;;
          /*|~*|..*|\$HOME*) block "rm -r may target only relative paths inside your worktree (saw $tok)" ;;
        esac
      done
    fi
    if [ "$role" != integrator ]; then
      if has "${GIT} (checkout|switch)( [^ ]*)* $base( |$)"; then block "only the integrator works on the base branch ($base)"; fi
      cur=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ "$cur" = "$base" ] && has "${GIT} (commit|merge|rebase|cherry-pick|am)( |$)"; then
        block "you are on the base branch ($base); commits there are the integrator's. Move to your worktree."
      fi
    fi
    allow "$(printf '%s' "$cmd" | cut -c1-120)"
    ;;
  *)
    allow
    ;;
esac
