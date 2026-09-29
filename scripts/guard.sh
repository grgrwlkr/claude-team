#!/usr/bin/env bash
# PreToolUse guard for orchestrated team sessions.
# Exit 2 blocks the tool call and tells the session why; exit 0 lets it through.
# Inert (exit 0, no side effects) for any session not registered in a run's sessions.json, except one
# running this plugin's agent, which orch has yet to register and is held until it is.
set -u
. "$(dirname "$0")/lib.sh"

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
tool=$(jq -r '.tool_name // empty' <<<"$input")
[ -n "$sid" ] && [ -n "$cwd" ] && [ -n "$tool" ] || exit 0
subject=$(jq -r '.tool_input.command // .tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
subject=${subject:0:120}

resolved=$(resolve_run "$cwd" "$sid"); rc=$?
if [ "$rc" -eq 1 ]; then
  # orch launches a session with --agent orchestrator:<role> before it registers it; a subagent
  # (agent_id set) of this plugin in some other session is not one.
  case "$(jq -r '.agent_type // empty' <<<"$input")|$(jq -r '.agent_id // empty' <<<"$input")" in
    'orchestrator:'*'|') ;;
    *) exit 0 ;;
  esac
  waited=0
  while [ "$rc" -eq 1 ]; do
    if [ "$waited" -ge "${CLAUDE_ORCH_REGISTER_WAIT:-15}" ]; then
      printf 'orchestrator guard: unregistered team session; the orchestrator must register or stop it\n' >&2
      exit 2
    fi
    sleep 1; waited=$((waited + 1))
    resolved=$(resolve_run "$cwd" "$sid"); rc=$?
  done
fi
run_dir=${resolved%|*}
in_repo=${resolved##*|}
if [ "$rc" -eq 2 ]; then
  log_event "$run_dir" "$sid" unknown "$tool" block "in the session index, no longer listed in its run" "$subject"
  printf 'orchestrator guard: this session was registered in run %s and is no longer listed there, or its sessions.json is unreadable; stop and tell the orchestrator.\n' "$(basename "$run_dir")" >&2
  exit 2
fi
rec=$(session_json "$run_dir" "$sid")
if [ -z "$rec" ] || [ "$rec" = null ]; then
  # Removed from the run with orch forget and still running: held, never set free.
  gone=$(jq -r --arg s "$sid" "$MINE"' first(.[] | select(mine($s)) | .name) // "unknown"' "$run_dir/forgotten.json" 2>/dev/null)
  log_event "$run_dir" "$sid" "${gone:-unknown}" "$tool" block "forgotten session" "$subject"
  printf 'orchestrator guard: this session (%s) was removed from run %s with orch forget and may not act in it any more; stop here.\n' "${gone:-unknown}" "$(basename "$run_dir")" >&2
  exit 2
fi
name=$(jq -r '.name' <<<"$rec")
role=$(jq -r '.role' <<<"$rec")
budget=$(jq -r '.budget // empty' <<<"$rec")
base=$(jq -r '.baseBranch // "main"' "$run_dir/plan.json" 2>/dev/null)
[ -n "$base" ] && [ "$base" != null ] || base=main
handoff="$run_dir/handoffs/$name.md"
# Standing authorizations the user gave at plan approval; the lead writes them with `orch authorize`.
auth_push=$(jq -r '.authorize.pushBase // false' "$run_dir/plan.json" 2>/dev/null)
auth_delete=$(jq -r '.authorize.deleteMerged // false' "$run_dir/plan.json" 2>/dev/null)
auth_install=$(jq -r '.authorize.installTools // false' "$run_dir/plan.json" 2>/dev/null)

block() {
  log_event "$run_dir" "$sid" "$name" "$tool" block "$1" "$subject"
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

# sole_handoff_put <command> <own name> <own run>: the command is nothing but `orch handoff-put <own run> <own name>`
# fed by a file or by a quoted heredoc whose terminator is the last line and appears once.
# Only then is a heredoc body prose. A chained command, an unquoted delimiter (its body expands),
# a second terminator line or a heredoc fed to anything else gets the full scan below.
# The command word is bare `orch` or this plugin's own bin/orch, nothing else: a session can write
# a file named orch inside its allowed paths, and a pattern-matched name would run it unscanned.
sole_handoff_put() {
  local cmd="$1" me="$2" run="$3" first rest delim last own
  own=$(cd "$(dirname "$0")/../bin" 2>/dev/null && pwd -P)/orch
  own=$(printf '%s' "$own" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  local head="^[[:space:]]*(orch|${own})[[:space:]]+handoff-put[[:space:]]+([A-Za-z0-9._-]+)[[:space:]]+([A-Za-z0-9-]+)[[:space:]]*"
  local re_file="${head}<[[:space:]]*[A-Za-z0-9._/~-]+[[:space:]]*\$"
  local re_doc="${head}<<[[:space:]]*(['\"])([A-Za-z_][A-Za-z0-9_]*)['\"][[:space:]]*\$"
  first=${cmd%%$'\n'*}
  if [ "$first" = "$cmd" ]; then
    [[ "$cmd" =~ $re_file ]] && [ "${BASH_REMATCH[2]}" = "$run" ] && [ "${BASH_REMATCH[3]}" = "$me" ]
    return
  fi
  [[ "$first" =~ $re_doc ]] || return 1
  [ "${BASH_REMATCH[2]}" = "$run" ] && [ "${BASH_REMATCH[3]}" = "$me" ] || return 1
  delim=${BASH_REMATCH[5]}
  rest=${cmd#*$'\n'}
  [ "$(printf '%s\n' "$rest" | grep -cx -- "$delim")" -eq 1 ] || return 1
  last=$(printf '%s\n' "$rest" | awk 'NF {l=$0} END {print l}')
  [ "$last" = "$delim" ]
}

# canon <absolute path>: where a write to the path lands: its deepest existing directory resolved physically,
# a symlink at its end followed, . and .. in the part still to be created folded.
canon() {
  local p="$1" d rest="" out="" c l n=0 IFS=/
  while [ -L "$p" ] && [ "$n" -lt 8 ]; do
    l=$(readlink "$p"); case "$l" in /*) p=$l ;; *) p=${p%/*}/$l ;; esac; n=$((n + 1))
  done
  d=$p
  until [ -d "$d" ]; do rest="/${d##*/}$rest"; d=${d%/*}; d=${d:-/}; done
  d=$(cd "$d" && pwd -P) || return 1
  set -f
  for c in $d$rest; do case "$c" in ''|.) ;; ..) out=${out%/*} ;; *) out=$out/$c ;; esac; done
  set +f
  printf '%s' "${out:-/}"
}

# Write targets of a Bash command, collected by write_scan into tg (absolute paths); unres=1 when one cannot
# be known: an expansion or glob in it, a relative one after a cd that cannot be followed, or code an
# interpreter, eval or a shell -c runs.
# tgt <token type> <word>: one target, taken relative to the effective cwd ecwd.
tgt() {
  if [ "$1" != W ]; then unres=1; return; fi
  case "$2" in
    /*) tg[${#tg[@]}]=$2 ;;
    *) if [ -n "$ecwd" ]; then tg[${#tg[@]}]=$ecwd/$2; else unres=1; fi ;;
  esac
}
# operands <options that take an argument>: the operands of the command at av[ci] into ov/ot.
operands() {
  local j=$((ci + 1)) end=0
  ov=() ot=()
  while [ "$j" -lt "${#av[@]}" ]; do
    if [ "$end" = 0 ]; then
      case "${av[$j]}" in
        --) end=1; j=$((j + 1)); continue ;;
        -?*) case " $1 " in *" ${av[$j]} "*) j=$((j + 1)) ;; esac; j=$((j + 1)); continue ;;
      esac
    fi
    ov[${#ov[@]}]=${av[$j]}; ot[${#ot[@]}]=${at[$j]}; j=$((j + 1))
  done
}
# all_ops [<first>]: every operand from <first> on is a target.
all_ops() {
  local j
  for ((j = ${1:-0}; j < ${#ov[@]}; j++)); do tgt "${ot[$j]}" "${ov[$j]}"; done
}
# sub_cmd: judges nv/nt, built by the caller from a find -exec or xargs, as a command of its own.
sub_cmd() {
  local av at ci j
  av=() at=()
  for ((j = 0; j < ${#nv[@]}; j++)); do av[j]=${nv[$j]}; at[j]=${nt[$j]}; done
  cmd_targets
}
# cmd_targets: adds the write targets of the simple command in av/at.
cmd_targets() {
  local i=0 n=${#av[@]} c j a k=0 ip=0 sc=0 nv nt
  while [ "$i" -lt "$n" ]; do
    case "${av[$i]}" in
      '{'|'!'|if|then|else|elif|while|until|do|command|builtin|exec|nohup|time) ;;
      env) while [ $((i + 1)) -lt "$n" ]; do case "${av[$((i + 1))]}" in -u|-S|-C) i=$((i + 2)) ;; -*|*=*) i=$((i + 1)) ;; *) break ;; esac; done ;;
      timeout|nice) while [ $((i + 1)) -lt "$n" ]; do case "${av[$((i + 1))]}" in -n|-s|-k) i=$((i + 2)) ;; -*|[0-9]*) i=$((i + 1)) ;; *) break ;; esac; done ;;
      *=*) [[ "${av[$i]%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || break ;;
      *) break ;;
    esac
    i=$((i + 1))
  done
  [ "$i" -lt "$n" ] || return 0
  if [ "${at[$i]}" = U ]; then unres=1; return 0; fi
  ci=$i c=${av[$i]##*/}
  case "$c" in
    cd|pushd)
      operands ""
      if [ "${#ov[@]}" -eq 0 ]; then ecwd=$(canon "$HOME")
      elif [ "${ot[0]}" != W ] || [ "${ov[0]}" = - ]; then ecwd=""
      else
        case "${ov[0]}" in /*) a=${ov[0]} ;; *) a=${ecwd:+$ecwd/${ov[0]}} ;; esac
        if [ -n "$a" ] && a=$(canon "$a") && [ -d "$a" ]; then ecwd=$a; else ecwd=""; fi
      fi ;;
    popd) ecwd="" ;;
    cp|mv|ln|install|gcp|gmv|gln|ginstall)
      case "$c" in *install) operands "-m -o -g -B -f -S -t" ;; *) operands "-S -t" ;; esac
      for ((j = ci + 1; j < n; j++)); do
        case "${av[$j]}" in
          -t) k=1; [ $((j + 1)) -lt "$n" ] && tgt "${at[$((j + 1))]}" "${av[$((j + 1))]}" ;;
          -t?*) k=1; tgt "${at[$j]}" "${av[$j]#-t}" ;;
          --target-directory=*) k=1; tgt "${at[$j]}" "${av[$j]#*=}" ;;
          -d|--directory) case "$c" in *install) k=2 ;; esac ;;
        esac
      done
      if [ "$k" = 2 ]; then all_ops
      elif [ "$k" = 0 ] && [ "${#ov[@]}" -ge 2 ]; then all_ops $((${#ov[@]} - 1))
      elif [ "$k" = 0 ] && [ "${#ov[@]}" -eq 1 ] && [ "${c#g}" = ln ]; then tgt "${ot[0]}" "${ov[0]##*/}"
      fi ;;
    rsync)
      operands "-e -f -T --exclude --include --filter --exclude-from --include-from --files-from --rsh --temp-dir --backup-dir --link-dest --compare-dest --copy-dest --partial-dir --log-file --password-file --chmod --chown"
      if [ "${#ov[@]}" -ge 2 ]; then
        a=${ov[$((${#ov[@]} - 1))]}
        # host:path and rsync:// are remote; a colon after a slash is part of a local name
        case "${a%%:*}" in "$a"|*/*) tgt "${ot[$((${#ov[@]} - 1))]}" "$a" ;; esac
      fi ;;
    tee|rm|rmdir) operands ""; all_ops ;;
    touch) operands "-t -r -d -A"; all_ops ;;
    mkdir) operands "-m"; all_ops ;;
    truncate) operands "-s -r"; all_ops ;;
    chmod) operands ""; all_ops 1 ;;
    dd) for ((j = ci + 1; j < n; j++)); do case "${av[$j]}" in of=*) tgt "${at[$j]}" "${av[$j]#of=}" ;; esac; done ;;
    sed|gsed)
      ov=() ot=()
      for ((j = ci + 1; j < n; j++)); do
        a=${av[$j]}
        case "$a" in
          # BSD sed takes the backup suffix as the next word, '' for none
          -i|-[!-]*i) ip=1; case "${av[$((j + 1))]-x}" in ''|.*) j=$((j + 1)) ;; esac ;;
          -i*|--in-place*) ip=1 ;;
          -e|-f|--expression|--file|-[!-]*[ef]) sc=1; j=$((j + 1)) ;;
          --expression=*|--file=*) sc=1 ;;
          -?*) ;;
          *) ov[${#ov[@]}]=$a; ot[${#ot[@]}]=${at[$j]} ;;
        esac
      done
      [ "$ip" = 0 ] || all_ops $((1 - sc)) ;;
    perl)
      ov=() ot=()
      for ((j = ci + 1; j < n; j++)); do
        a=${av[$j]}
        case "$a" in
          -e|-E|-[anlpswWTtuUXc0]*[eE]) sc=1; j=$((j + 1)) ;;
          -i*|-[anlpswWTtuUXc0]*i*) ip=1 ;;
          -?*) ;;
          *) ov[${#ov[@]}]=$a; ot[${#ot[@]}]=${at[$j]} ;;
        esac
      done
      if [ "$ip" = 1 ]; then all_ops $((1 - sc))
      elif [ "$sc" = 1 ] || [ "${#ov[@]}" -eq 0 ]; then unres=1
      fi ;;
    python|python[0-9]*|node|nodejs|bun|deno|ruby|php)
      operands ""
      for ((j = ci + 1; j < n; j++)); do
        case "${av[$j]}" in
          -c|-e|-p|-pe|--eval|--print|-|eval) sc=1 ;;
          -m) k=1 ;;
        esac
      done
      if [ "$sc" = 1 ] || { [ "$k" = 0 ] && [ "${#ov[@]}" -eq 0 ]; }; then unres=1; fi ;;
    bash|sh|zsh|dash|ksh)
      operands ""
      for ((j = ci + 1; j < n; j++)); do case "${av[$j]}" in -c|-[!-]*c*|-s) sc=1 ;; esac; done
      if [ "$sc" = 1 ] || [ "${#ov[@]}" -eq 0 ]; then unres=1; fi ;;
    eval) unres=1 ;;
    awk|gawk|nawk|mawk)
      operands "-F -v"
      for ((j = ci + 1; j < n; j++)); do case "${av[$j]}" in -f) sc=1 ;; esac; done
      # an awk program writes only through print >, a pipe or system()
      [ "$sc" = 1 ] && unres=1
      case "${ov[0]-}" in *'>'*|*'|'*|*system*) unres=1 ;; esac ;;
    xargs)
      a="" j=$((ci + 1))
      while [ "$j" -lt "$n" ]; do
        case "${av[$j]}" in
          -I|-J) a=${av[$((j + 1))]-}; j=$((j + 2)) ;;
          -n|-P|-L|-s|-E|-d|-a) j=$((j + 2)) ;;
          -I?*) a=${av[$j]#-I}; j=$((j + 1)) ;;
          -*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      nv=() nt=()
      for ((; j < n; j++)); do
        nv[${#nv[@]}]=${av[$j]}
        if [ -n "$a" ] && [ "${av[$j]}" = "$a" ]; then nt[${#nt[@]}]=U; else nt[${#nt[@]}]=${at[$j]}; fi
      done
      # without -I, the words read from stdin are appended
      if [ "${#nv[@]}" -gt 0 ]; then
        [ -n "$a" ] || { nv[${#nv[@]}]=""; nt[${#nt[@]}]=U; }
        sub_cmd
      fi ;;
    find)
      operands ""
      # shellcheck disable=SC2165,SC2167  # the scan resumes after an -exec's ; or +
      for ((j = ci + 1; j < n; j++)); do
        case "${av[$j]}" in
          -delete)
            # the roots are the operands before the first expression word
            for ((k = ci + 1; k < n; k++)); do
              case "${av[$k]}" in -*|'('|'!') break ;; esac
              tgt "${at[$k]}" "${av[$k]}"
            done ;;
          -fprint|-fprint0|-fprintf|-fls) [ $((j + 1)) -lt "$n" ] && tgt "${at[$((j + 1))]}" "${av[$((j + 1))]}" ;;
          -exec|-execdir|-ok|-okdir)
            nv=() nt=()
            for ((j = j + 1; j < n; j++)); do
              case "${av[$j]}" in ';'|'+') break ;; esac
              nv[${#nv[@]}]=${av[$j]}
              if [ "${av[$j]}" = '{}' ]; then nt[${#nt[@]}]=U; else nt[${#nt[@]}]=${at[$j]}; fi
            done
            [ "${#nv[@]}" -eq 0 ] || sub_cmd ;;
        esac
      done ;;
  esac
}
# write_scan <command>: fills tg and unres for the command, starting from the hook's cwd.
write_scan() {
  local t v redir="" ecwd stk ns=0
  ecwd=$(cd "$cwd" 2>/dev/null && pwd -P)
  stk=() av=() at=()
  while IFS=$'\t' read -r t v; do
    case "$t" in
      W|U|G)
        if [ -z "$redir" ]; then av[${#av[@]}]=$v; at[${#at[@]}]=$t
        elif [ "$redir" = O ]; then tgt "$t" "$v"
        elif [ "$redir" = D ]; then case "$v" in -|*[!0-9]*|'') [ "$v" = - ] || tgt "$t" "$v" ;; esac
        fi
        redir="" ;;
      O|D|I) redir=$t ;;
      *)
        cmd_targets; av=() at=(); redir=""
        case "$t" in
          P) stk[ns]=$ecwd; ns=$((ns + 1)) ;;
          p) if [ "$ns" -gt 0 ]; then ns=$((ns - 1)); ecwd=${stk[$ns]}; fi ;;
          Q) ecwd=$(cd "$cwd" 2>/dev/null && pwd -P); ns=0 ;;
        esac ;;
    esac
  done < <(printf '%s' "$1" | shell_tokens)
  cmd_targets
}
# path_ok <path relative to the own worktree>: scratch, one of the session's pathsAllowed, or a directory whose contents are.
path_ok() {
  local pat
  case "$1" in .scratch|.scratch/*) return 0 ;; esac
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2053  # the glob must stay unquoted to act as a pattern
    if [[ "$1" == $pat ]] || [[ "$1/" == $pat ]]; then return 0; fi
  done < <(jq -r '.pathsAllowed[]?' <<<"$rec")
  return 1
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
  [ -d "$cwd" ] || block "your working directory ($cwd) no longer exists; cd back into your worktree before running or editing anything"
  block "your working directory ($cwd) is outside the repository of run $(basename "$run_dir"); cd back into your worktree before running or editing anything"
fi
# Nor may it sit inside the orchestrator's own directories, where relative paths would dodge the checks below.
cwd_real=$(cd "$cwd" && pwd -P)
case "$cwd_real/" in
  "$run_dir"/*|"$INDEX_DIR"/*) block "your working directory is inside the orchestrator's directory ($cwd_real); cd back into your worktree" ;;
esac

# A session orch started inside its worktree stays there: claude rm keeps that worktree, but deletes
# one the session made itself with its branch once the commits are pushed or merged. A session
# spawned before orch made worktrees has no record of one and still makes its own.
if [ "$tool" = EnterWorktree ]; then
  own_wt=$(jq -r '.worktree // ""' <<<"$rec")
  [ -n "$own_wt" ] || allow_free "EnterWorktree"
  [ "$(jq -r '.tool_input.path // ""' <<<"$input")" = "$own_wt" ] && allow_free "EnterWorktree $own_wt"
  block "you already work in the worktree orch made for you: $own_wt. Stay there; a worktree you make yourself is deleted with its branch when your session is removed"
fi

# Handing off must always be possible: a session out of budget or paused is told to write its
# handoff and stop, and the Stop hook demands one. Same standing as a Write of the handoff file.
if [ "$tool" = Bash ] && sole_handoff_put "$(jq -r '.tool_input.command // empty' <<<"$input")" "$name" "$(basename "$run_dir")"; then
  allow_free "handoff-put"
fi

# Pause: the orchestrator stopped this session or the whole wave.
if [ -f "$run_dir/PAUSE-$name" ]; then
  block "paused by the orchestrator: $(cat "$run_dir/PAUSE-$name" 2>/dev/null). Read and answer its message; edits and commands resume when it runs orch resume."
fi
if [ -f "$run_dir/PAUSE" ]; then
  block "the whole run is paused by the orchestrator: $(cat "$run_dir/PAUSE" 2>/dev/null). Wait for its message."
fi

# Budget: allowed guarded calls so far, before this one. 0 is no cap; one that is not a whole number is no licence.
case "$budget" in ''|*[!0-9]*) block "budget unreadable; ask the orchestrator" ;; esac
if [ "$budget" -gt 0 ]; then
  # Held from the count to this call's own log line, or parallel calls of one message all pass the count.
  lock="$run_dir/.budget-$name.lock" tries=0
  until mkdir "$lock" 2>/dev/null; do
    [ "$tries" -lt $(( ${CLAUDE_ORCH_LOCK_WAIT:-10} * 10 )) ] || block "budget lock $lock held for ${CLAUDE_ORCH_LOCK_WAIT:-10} s; tell the orchestrator, which removes it when no call of yours is running"
    sleep 0.1; tries=$((tries + 1))
  done
  trap 'rmdir "$lock" 2>/dev/null' EXIT
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
    [ "$ok" -eq 1 ] || block "path $rel is outside your allowed paths ($(jq -r '.pathsAllowed | join(", ")' <<<"$rec")). Ask the orchestrator if the task needs it: it grants a path with orch paths $(basename "$run_dir") $name add <glob>, never by editing sessions.json."
    allow "$rel"
    ;;
  # Monitor runs its command in the same shell Bash does.
  Bash|Monitor)
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
            [ "$_run" = "$(basename "$run_dir")" ] || block "orch handoff-put may write only into your own run ($(basename "$run_dir")), not ${_run:-<missing>}"
            [ "$arg2" = "$name" ] || block "orch handoff-put may write only your own handoff ($name), not ${arg2:-<missing>}; run is $_run" ;;
          handoff|status|events|ready|doctor|tools) ;;
          # --sync rewrites the generated rules every session loads; only the map's owner runs it. An
          # allowlist over everything up to the next separator, not a match on --sync: a variable,
          # a substitution or ${IFS} glued to the subcommand would hide the flag.
          architecture)
            if [ "$role" != architect ]; then
              while IFS= read -r arch_tail; do
                case "$arch_tail" in
                  ''|' --check') ;;
                  *) block "orch architecture takes only --check outside the architect's session; --sync regenerates the map's rules and is the architect's. Tell the architect what the map gets wrong." ;;
                esac
              done < <(printf '%s\n' "$flat" | grep -Eo '(^|[;&| /])orch +architecture[^;&|<>]*' | sed -E 's/^[;&| /]?orch +architecture//; s/ +$//')
            fi ;;
          *) block "orch $sub is the orchestrator's command; a session may use only orch handoff-put, handoff, status, events, ready, doctor, tools, architecture" ;;
        esac
      done < <(printf '%s\n' "$flat" | grep -Eo '(^|[;&| /])orch +[a-z-]+( +[^ ;&|<>]+)?( +[^ ;&|<>]+)?' | sed -E 's/^[;&| /]?orch +//')
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
    # A session started here is one orch never registered, so the run could not remove it when it ends.
    if has '(^|[;&| /])claude [^|;&]*--(bg|background)( |=|$)'; then block "a team session starts no background session; ask the orchestrator for a teammate"; fi
    # Installing tooling onto the machine is the user's call, given once at plan approval (install-tools).
    # A project-local `npm install` or `bun install` is the project's own dependency step and passes.
    if [ "$auth_install" != true ] && has '(^|[;&| ])(brew|apt|apt-get|dnf|yum|pacman|apk|choco|winget|pipx|cargo|gem) +(install|add)( |$)|(^|[;&| ])(npm|pnpm|yarn|bun) +(install|add|i)( [^|;&]*)? +(-g|--global)( |$)|(^|[;&| ])(pip3?|uv) +(install|pip install|tool install)( |$)|(^|[;&| ])npx +playwright +install|(^|[;&| ])playwright +install|(^|[;&| ])claude +mcp +add( |$)'; then
      block "installing tooling on this machine is not authorized in this run's plan; report BLOCKED: with the tool and the install command from 'orch tools', the orchestrator asks the user and runs orch authorize <run> install-tools on"
    fi
    if has '(^|[;&| ])sudo( |$)'; then block "no sudo in a team session"; fi
    if has '(curl|wget)[^|]*\| *(ba|z|da)?sh( |$)'; then block "piping a download into a shell is not allowed; download, read, then run"; fi
    state_msg="the run directory and the session index are written only by the orchestrator; send your handoff with 'orch handoff-put $(basename "$run_dir") $name' on stdin, or write $handoff with the Write tool when you are not inside a worktree"
    tg=() unres=0
    write_scan "$cmd"
    if [ "${#tg[@]}" -gt 0 ]; then
      orch_dir=${run_dir%/*}
      idx_real=$(canon "$INDEX_DIR")
      own_wt=$(jq -r '.worktree // ""' <<<"$rec")
      [ -n "$own_wt" ] || own_wt=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
      [ -z "$own_wt" ] || own_wt=$(canon "$own_wt")
      on=() op=()
      while IFS='|' read -r o_name o_wt; do
        [ -n "$o_wt" ] || continue
        o_wt=$(canon "$o_wt"); [ "$o_wt" = "$own_wt" ] && continue
        on[${#on[@]}]=$o_name; op[${#op[@]}]=$o_wt
      done < <(jq -r --arg n "$name" '.[] | select(.name != $n) | "\(.name)|\(.worktree // "")"' "$run_dir/sessions.json" 2>/dev/null)
      for ((k = 0; k < ${#tg[@]}; k++)); do
        t=$(canon "${tg[$k]}") || { unres=1; continue; }
        case "$t/" in "$orch_dir"/*|"$idx_real"/*) block "$state_msg (this command writes $t)" ;; esac
        for ((j = 0; j < ${#op[@]}; j++)); do
          case "$t/" in "${op[$j]}"/*) block "$t is in ${on[$j]}'s worktree; a session writes only in its own" ;; esac
        done
        if [ -n "$own_wt" ]; then
          case "$t/" in
            "$own_wt"/*)
              rel=${t#"$own_wt"}; rel=${rel#/}
              path_ok "$rel" || block "path ${rel:-.} is outside your allowed paths ($(jq -r '.pathsAllowed | join(", ")' <<<"$rec")). Ask the orchestrator if the task needs it: it grants a path with orch paths $(basename "$run_dir") $name add <glob>, never by editing sessions.json." ;;
          esac
        fi
      done
    fi
    # A target the scan cannot resolve is judged by the text: naming the run dir or the index is enough.
    if [ "$unres" = 1 ]; then
      has '(\.orchestrator|orchestrator-sessions)' && block "$state_msg"
      printf '%s' "$flat" | grep -qF -- "$INDEX_DIR" && block "$state_msg"
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
