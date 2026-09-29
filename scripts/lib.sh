#!/usr/bin/env bash
# Shared by guard.sh and stop-gate.sh. bash 3.2 compatible; needs jq.

# Index of sessions the guard has seen: <sid> -> run dir. Lets the guard keep hold of a
# registered session after it leaves the repository (cd /tmp), instead of failing open.
INDEX_DIR="${CLAUDE_ORCH_STATE:-$HOME/.claude/orchestrator-sessions}"

# A session registers by the short id claude --bg printed, the start of its full id, which orch
# status fills in later; either one identifies it.
MINE='def mine($s): .sessionId == $s or (((.sessionId // "") == "") and ((.id // "") != "") and (.id as $i | $s | startswith($i)));'

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

# find_run <root> <session_id>: prints the run dir whose sessions.json lists the session, or whose
# forgotten.json holds it (orch forget); fails when none does.
find_run() {
  local f
  for f in "$1"/.orchestrator/*/sessions.json "$1"/.orchestrator/*/forgotten.json; do
    [ -f "$f" ] || continue
    if jq -e --arg s "$2" "$MINE"' map(select(mine($s))) | length > 0' "$f" >/dev/null 2>&1; then
      (cd "$(dirname "$f")" && pwd -P); return 0
    fi
  done
  return 1
}

# resolve_run <cwd> <session_id>: run dir via cwd, else via the index; verifies the session is still listed.
# Prints "<run dir>|<cwd-in-repo:1|0>". Fails when the session is registered nowhere; returns 2, with the
# run dir printed, when the index holds it but its existing run no longer lists it.
resolve_run() {
  local root run in_repo=1
  if root=$(repo_root "$1" 2>/dev/null) && run=$(find_run "$root" "$2"); then
    :
  else
    in_repo=0
    [ -f "$INDEX_DIR/$2" ] || return 1
    run=$(cat "$INDEX_DIR/$2")
    jq -e --arg s "$2" "$MINE"' map(select(mine($s))) | length > 0' "$run/sessions.json" >/dev/null 2>&1 \
      || jq -e --arg s "$2" "$MINE"' map(select(mine($s))) | length > 0' "$run/forgotten.json" >/dev/null 2>&1 \
      || {
        # Registered once and its run still there: unlisted or unreadable now is no release.
        [ -d "$run" ] || return 1
        printf '%s|0' "$run"; return 2
      }
  fi
  mkdir -p "$INDEX_DIR" 2>/dev/null && printf '%s' "$run" > "$INDEX_DIR/$2" 2>/dev/null
  printf '%s|%s' "$run" "$in_repo"
}

# session_json <run_dir> <session_id>: the session's record.
session_json() {
  jq -c --arg s "$2" "$MINE"' map(select(mine($s))) | .[0]' "$1/sessions.json"
}

# norm_path <absolute path>: canonical form, its deepest existing directory resolved with symlinks and . / ..,
# the part still to be created appended. A path whose parent does not exist yet is accepted only without
# . or .. segments. Fails otherwise.
norm_path() {
  local p="$1" d b rest=""
  case "$p" in /*) ;; *) return 1 ;; esac
  b=$(basename "$p"); d=$(dirname "$p")
  case "$b" in .|..) return 1 ;; esac
  if [ ! -d "$d" ]; then
    case "/$p/" in */../*|*/./*) return 1 ;; esac
    until [ -d "$d" ]; do rest="/$(basename "$d")$rest"; d=$(dirname "$d"); done
  fi
  d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s%s/%s' "${d%/}" "$rest" "$b"
}

# shell_tokens: reads a shell command on stdin and prints its tokens, one per line as "<type><tab><value>":
#   W a word, quotes removed; U a word holding an expansion ($VAR, $( ), backticks, ~user); G one holding an unquoted glob or brace
#   S a command separator; P and p a subshell's ( and ); Q the start of the commands of a command or process
#     substitution, which follow the tokens of the command they sit in
#   O an output redirection whose target is the next word; D a >& one, whose next word is a file unless it is an fd or -;
#     I an input redirection, whose next word is read, not written
# Heredoc bodies are dropped; the substitutions in a body under an unquoted delimiter are kept as Q commands.
shell_tokens() {
  awk '
function flush() {
  if (inw) { if (w ~ /\n/) wu = 1; gsub(/\n/, " ", w); print (wu ? "U" : (wg ? "G" : "W")) "\t" w }
  inw = 0; w = ""; wu = 0; wg = 0; wq = 0
}
# read_delim: reads the heredoc delimiter after the << (or <<-) ending at i into dl, dquo (it was quoted)
# and ddash (<<-); returns the index of its last character
function read_delim(a, len, i) {
  dl = ""; dquo = 0; ddash = 0
  if (a[i+1] == "-") { i++; ddash = 1 }
  while (i < len && (a[i+1] == " " || a[i+1] == "\t")) i++
  while (i < len && !index(" \t\n;&|<>()", a[i+1])) {
    i++
    if (a[i] == "\047" || a[i] == "\"") dquo = 1
    else if (a[i] == "\\") { dquo = 1; if (i < len) { i++; dl = dl a[i] } }
    else dl = dl a[i]
  }
  return i
}
# skip_body: from the newline at i, skips a heredoc body up to its delimiter line; returns the index of that line end
function skip_body(a, len, s, i, delim, dash,   j, t) {
  while (i < len) {
    for (j = i + 1; j <= len && a[j] != "\n"; j++) ;
    t = substr(s, i + 1, j - i - 1); i = j
    if (dash) sub(/^\t+/, "", t)
    if (t == delim) break
  }
  return i
}
# close_paren: the index of the ) closing a ( opened just before i; quotes and heredoc bodies hide parens
function close_paren(a, len, s, i,   depth, q, pd, pdash) {
  depth = 1; q = ""; pd = ""
  for (; i <= len; i++) {
    if (q == "\047") { if (a[i] == "\047") q = ""; continue }
    if (a[i] == "\\") { i++; continue }
    if (q == "\"") { if (a[i] == "\"") q = ""; continue }
    if (a[i] == "\047" || a[i] == "\"") q = a[i]
    else if (a[i] == "<" && a[i+1] == "<" && a[i+2] != "<") { i = read_delim(a, len, i + 1); pd = dl; pdash = ddash }
    else if (a[i] == "\n" && pd != "") { i = skip_body(a, len, s, i, pd, pdash); pd = "" }
    else if (a[i] == "(") depth++
    else if (a[i] == ")" && --depth == 0) return i
  }
  return len + 1
}
# subst: queues the command of the substitution opening at i ($( <( >( or a backtick) and returns where it closes
function subst(a, len, s, i,   j) {
  if (a[i] == "`") {
    for (j = i + 1; j <= len && a[j] != "`"; j++) if (a[j] == "\\") j++
    q[++nq] = substr(s, i + 1, j - i - 1); return j
  }
  j = close_paren(a, len, s, i + 2); q[++nq] = substr(s, i + 2, j - i - 2); return j
}
function body_substs(b,   a, len, i) {
  len = split(b, a, "")
  for (i = 1; i <= len; i++) {
    if (a[i] == "\\") i++
    else if (a[i] == "`" || (a[i] == "$" && a[i+1] == "(")) i = subst(a, len, b, i)
  }
}
function tok(s,   c, n, i, j, ch, k, line, t, body) {
  n = split(s, c, ""); nh = 0; inw = 0; w = ""; wu = 0; wg = 0; wq = 0
  for (i = 1; i <= n; i++) {
    ch = c[i]
    if (ch == "\\") { if (i < n && c[i+1] != "\n") { w = w c[i+1]; inw = 1 } i++; continue }
    # an unterminated quote leaves the rest of the command unknown
    if (ch == "\047") {
      for (j = i + 1; j <= n && c[j] != "\047"; j++) ;
      w = w substr(s, i + 1, j - i - 1); inw = 1; wq = 1; if (j > n) wu = 1; i = j; continue
    }
    if (ch == "\"") {
      inw = 1; wq = 1
      for (i++; i <= n && c[i] != "\""; i++) {
        if (c[i] == "\\" && i < n && index("\"\\$`\n", c[i+1])) { if (c[i+1] != "\n") w = w c[i+1]; i++ }
        else if (c[i] == "`" || (c[i] == "$" && c[i+1] == "(")) { i = subst(c, n, s, i); wu = 1 }
        else { if (c[i] == "$") wu = 1; w = w c[i] }
      }
      if (i > n) wu = 1
      continue
    }
    if (ch == "`" || (ch == "$" && c[i+1] == "(") || ((ch == "<" || ch == ">") && c[i+1] == "(")) {
      i = subst(c, n, s, i); inw = 1; wu = 1; continue
    }
    if (ch == "~" && !inw) {
      if (i == n || index(" \t\n;&|<>()/", c[i+1])) { w = ENVIRON["HOME"]; inw = 1; continue }
      wu = 1
    }
    if (ch == "#" && !inw) { while (i < n && c[i+1] != "\n") i++; continue }
    if (ch == "$") wu = 1
    if (ch == "*" || ch == "?" || ch == "[" || (ch == "{" && (inw || (i < n && !index(" \t\n", c[i+1]))))) wg = 1
    if (ch == " " || ch == "\t") { flush(); continue }
    if (ch == "\n") {
      flush(); print "S\t"
      for (k = 1; k <= nh; k++) {
        body = ""
        while (i < n) {
          for (j = i + 1; j <= n && c[j] != "\n"; j++) ;
          line = substr(s, i + 1, j - i - 1); i = j
          t = line; if (hdash[k]) sub(/^\t+/, "", t)
          if (t == hdelim[k]) break
          body = body line "\n"
        }
        if (!hquo[k]) body_substs(body)
      }
      nh = 0; continue
    }
    if (ch == ";" || ch == "|" || (ch == "&" && c[i+1] != ">")) {
      flush()
      if (c[i+1] == ch || (ch == "|" && c[i+1] == "&")) i++
      print "S\t"; continue
    }
    if (ch == "(") { flush(); print "P\t"; continue }
    if (ch == ")") { flush(); print "p\t"; continue }
    if (ch == "&") { flush(); i++; if (c[i+1] == ">") i++; print "O\t"; continue }
    if (ch == ">" || ch == "<") {
      # digits right before the operator name an fd, not a word
      if (inw && !wq && !wu && !wg && w ~ /^[0-9]+$/) { inw = 0; w = "" } else flush()
      if (ch == ">") {
        if (c[i+1] == ">" || c[i+1] == "|") i++
        if (c[i+1] == "&") { i++; print "D\t" } else print "O\t"
        continue
      }
      if (c[i+1] == "<" && c[i+2] == "<") { i += 2; print "I\t"; continue }
      if (c[i+1] == "<") {
        i = read_delim(c, n, i + 1); hdelim[++nh] = dl; hquo[nh] = dquo; hdash[nh] = ddash; continue
      }
      if (c[i+1] == ">") { i++; print "O\t"; continue }
      if (c[i+1] == "&") i++
      print "I\t"; continue
    }
    w = w ch; inw = 1
  }
  flush()
}
{ s = s (NR > 1 ? "\n" : "") $0 }
END { nq = 0; tok(s); for (qi = 1; qi <= nq; qi++) { print "Q\t"; tok(q[qi]) } }
'
}

# log_event <run_dir> <sid> <name> <tool> <decision> <detail> [<subject>]: a block line appends the
# command or file path it judged as a 7th field; readers take the reason from field 6.
log_event() {
  local tail=""
  [ $# -ge 7 ] && tail="|$(printf '%s' "$7" | tr '\n|' '  ')"
  printf '%s|%s|%s|%s|%s|%s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$5" "$(printf '%s' "$6" | tr '\n|' '  ')" "$tail" >> "$1/events.log"
}
