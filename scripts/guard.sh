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
# Standing authorizations the user gave at plan approval; the lead writes them with `orch authorize`.
auth_push=$(jq -r '.authorize.pushBase // false' "$run_dir/plan.json" 2>/dev/null)
auth_delete=$(jq -r '.authorize.deleteMerged // false' "$run_dir/plan.json" 2>/dev/null)
auth_install=$(jq -r '.authorize.installTools // false' "$run_dir/plan.json" 2>/dev/null)

block() {
  log_event "$run_dir" "$sid" "$name" "$tool" block "$1"
  printf 'orchestrator guard blocked this call for %s (%s): %s\nReport BLOCKED: to the orchestrator instead of working around it.\n' "$name" "$role" "$1" >&2
  exit 2
}
allow() {
  log_event "$run_dir" "$sid" "$name" "$tool" allow "${1:-}"
  exit 0
}
# The handoff channel is never counted against the budget: the budget check counts "allow" lines only.
allow_free() {
  log_event "$run_dir" "$sid" "$name" "$tool" allow-free "${1:-}"
  exit 0
}

# sole_handoff_put <command> <own name>: the command is nothing but `orch handoff-put <run> <own name>`
# fed by a file or by a quoted heredoc whose terminator is the last line and appears once.
# Only then is a heredoc body prose. A chained command, an unquoted delimiter (its body expands),
# a second terminator line or a heredoc fed to anything else gets the full scan below.
# The command word is bare `orch` or this plugin's own bin/orch, nothing else: a session can write
# a file named orch inside its allowed paths, and a pattern-matched name would run it unscanned.
sole_handoff_put() {
  local cmd="$1" me="$2" first rest delim last own
  own=$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd -P)/orch
  own=$(printf '%s' "$own" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  local head="^[[:space:]]*(orch|${own})[[:space:]]+handoff-put[[:space:]]+[A-Za-z0-9._-]+[[:space:]]+([A-Za-z0-9-]+)[[:space:]]*"
  local re_file="${head}<[[:space:]]*[A-Za-z0-9._/~-]+[[:space:]]*\$"
  local re_doc="${head}<<[[:space:]]*(['\"])([A-Za-z_][A-Za-z0-9_]*)['\"][[:space:]]*\$"
  first=${cmd%%$'\n'*}
  if [ "$first" = "$cmd" ]; then
    [[ "$cmd" =~ $re_file ]] && [ "${BASH_REMATCH[2]}" = "$me" ]
    return
  fi
  [[ "$first" =~ $re_doc ]] || return 1
  [ "${BASH_REMATCH[2]}" = "$me" ] || return 1
  delim=${BASH_REMATCH[4]}
  rest=${cmd#*$'\n'}
  [ "$(printf '%s\n' "$rest" | grep -cx -- "$delim")" -eq 1 ] || return 1
  last=$(printf '%s\n' "$rest" | awk 'NF {l=$0} END {print l}')
  [ "$last" = "$delim" ]
}

file_path=""
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    file_path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    if [ -n "$file_path" ]; then
      file_path=$(norm_path "$file_path") || block "file path must be absolute and free of . or .. segments (got $(jq -r '.tool_input.file_path // .tool_input.notebook_path' <<<"$input"))"
      # norm_path resolves the directories, not the file itself: a write goes through a symlinked file to its target.
      [ -L "$file_path" ] && block "$file_path is a symlink; edit its target by its own path"
    fi
    # Own handoff: always writable, never counted, even when paused or out of budget.
    [ -n "$file_path" ] && [ "$file_path" = "$handoff" ] && allow_free "handoff"
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

# Handing off must always be possible: a session out of budget or paused is told to write its
# handoff and stop, and the Stop hook demands one. Same standing as a Write of the handoff file.
if [ "$tool" = Bash ] && sole_handoff_put "$(jq -r '.tool_input.command // empty' <<<"$input")" "$name"; then
  allow_free "handoff-put"
fi

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
    block "tool-call budget spent ($used of $budget). Send your handoff with Status partial — a command that is only 'orch handoff-put $(basename "$run_dir") $name' with a quoted heredoc or '< file' is outside the budget — and stop; the orchestrator decides what happens next."
  fi
  # From 80%, hold one call so the work lands in a partial handoff while the session can still write one.
  if [ $((used * 5)) -ge $((budget * 4)) ] && ! grep -q "^[^|]*|$sid|[^|]*|[^|]*|nudge|" "$run_dir/events.log" 2>/dev/null; then
    log_event "$run_dir" "$sid" "$name" "$tool" nudge "$used of $budget"
    printf 'orchestrator guard for %s: %s of %s guarded calls used (80%%). Send a partial handoff now — orch handoff-put %s %s < .scratch/handoff.md — so the work survives if the budget runs out, then repeat this call. This reminder comes once.\n' "$name" "$used" "$budget" "$(basename "$run_dir")" "$name" >&2
    exit 2
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
    # Scratch space the team rules send every session to, whatever its task's paths.
    case "$rel" in .scratch/*) allow "$rel" ;; esac
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
    # orch: read-only subcommands and the handoff channel are the session's; the rest is the lead's.
    # Every occurrence is checked, however orch is reached (bare, by path, via bash), and
    # handoff-put may name only the caller's own session.
    if has '(^|[;&| /])orch +[a-z-]'; then
      while IFS=' ' read -r sub _run arg2 _; do
        case "$sub" in
          handoff-put)
            [ "$arg2" = "$name" ] || block "orch handoff-put may write only your own handoff ($name), not ${arg2:-<missing>}; run is $_run" ;;
          handoff|status|events|ready|doctor|tools|architecture) ;;
          *) block "orch $sub is the orchestrator's command; a session may use only orch handoff-put, handoff, status, events, ready, doctor, tools, architecture" ;;
        esac
      done < <(printf '%s\n' "$flat" | grep -Eo '(^|[;&| /])orch +[a-z-]+( +[^ ;&|<>]+)?( +[^ ;&|<>]+)?' | sed -E 's/^.*orch +//')
    fi
    if has "${GIT} push[^|;&]*( -f( |$)|--force)"; then block "force push is never allowed"; fi
    if has "${GIT} push[^|;&]*(^| |:|\+)$base( |$)"; then
      if [ "$role" = integrator ] && [ "$auth_push" = true ]; then
        :  # the plan carries the user's standing authorization for this run
      elif [ "$role" = integrator ]; then
        block "pushing the base branch ($base) is not authorized in this run's plan. Report BLOCKED: and let the orchestrator set it with orch authorize <run> push-base on after the user says so."
      else
        block "pushing the base branch ($base) is the integrator's, and only when the plan authorizes it"
      fi
    fi
    if has "${GIT} reset --hard|${GIT} branch -D|${GIT} clean -[a-zA-Z]*f|${GIT} push[^|;&]*--delete"; then block "destructive git command; ask the orchestrator"; fi
    if has "${GIT} (branch -d|worktree remove)( |$)"; then
      if [ "$role" = integrator ] && [ "$auth_delete" = true ]; then
        :  # cleanup of merged branches and worktrees is authorized for this run
      else
        block "deleting branches or worktrees needs role integrator and delete-merged in the plan's authorize block; verify containment in $base first and ask the orchestrator"
      fi
    fi
    if has '(^|[;&| ])claude (stop|kill|rm|respawn)( |$)'; then block "sessions are stopped only by the orchestrator or the user"; fi
    # Installing tooling onto the machine is the user's call, given once at plan approval (install-tools).
    # A project-local `npm install` or `bun install` is the project's own dependency step and passes.
    if [ "$auth_install" != true ] && has '(^|[;&| ])(brew|apt|apt-get|dnf|yum|pacman|apk|choco|winget|pipx|cargo|gem) +(install|add)( |$)|(^|[;&| ])(npm|pnpm|yarn|bun) +(install|add|i)( [^|;&]*)? +(-g|--global)( |$)|(^|[;&| ])(pip3?|uv) +(install|pip install|tool install)( |$)|(^|[;&| ])npx +playwright +install|(^|[;&| ])playwright +install|(^|[;&| ])claude +mcp +add( |$)'; then
      block "installing tooling on this machine is not authorized in this run's plan; report BLOCKED: with the tool and the install command from 'orch tools', the orchestrator asks the user and runs orch authorize <run> install-tools on"
    fi
    if has '(^|[;&| ])sudo( |$)'; then block "no sudo in a team session"; fi
    if has '(curl|wget)[^|]*\| *(ba|z|da)?sh( |$)'; then block "piping a download into a shell is not allowed; download, read, then run"; fi
    touches_state=0
    has '(\.orchestrator/|orchestrator-sessions)' && touches_state=1
    printf '%s' "$flat" | grep -qF -- "$INDEX_DIR" && touches_state=1
    if [ "$touches_state" -eq 1 ] && has '(>|(^|[;&| ])(tee|mv|cp|rm|truncate|ln|chmod|touch|mkdir|rmdir)( |$)|sed -i|jq[^|;&]* -i|python[^|;&]* -c|perl -[a-zA-Z]*i)'; then
      block "the run directory and the session index are written only by the orchestrator; send your handoff with 'orch handoff-put $(basename "$run_dir") $name' on stdin, or write $handoff with the Write tool when you are not inside a worktree"
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
  Agent|Task)
    # A team session starts no subagent but the MCP helpers orch spawn gave this very session:
    # the names in its helper file, not anything that merely looks like one.
    st=$(jq -r '.tool_input.subagent_type // empty' <<<"$input")
    helpers="$run_dir/mcp/$name.agents.json"
    if [ -n "$st" ] && [ -f "$helpers" ] && jq -e --arg s "$st" 'has($s)' "$helpers" >/dev/null 2>&1; then
      allow "helper $st"
    fi
    block "a team session starts only the MCP helper agents orch spawn gave it (listed in your brief), not ${st:-a general-purpose agent}; ask a teammate instead"
    ;;
  *)
    allow
    ;;
esac
