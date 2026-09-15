#!/usr/bin/env bash
# Stop gate for orchestrated team sessions: a registered session may not go idle without a handoff.
# Exit 2 sends the session back to work with the reason; exit 0 lets it stop.
set -u
. "$(dirname "$0")/lib.sh"

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")
active=$(jq -r '.stop_hook_active // false' <<<"$input")
[ -n "$sid" ] && [ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

resolved=$(resolve_run "$cwd" "$sid") || exit 0
run_dir=${resolved%|*}
# Second attempt after we already sent it back once: let it stop rather than loop.
[ "$active" = true ] && exit 0

name=$(session_json "$run_dir" "$sid" | jq -r '.name')
handoff="$run_dir/handoffs/$name.md"

if [ -f "$handoff" ] && grep -q '^## Status' "$handoff"; then
  log_event "$run_dir" "$sid" "$name" Stop allow "handoff present"
  exit 0
fi
log_event "$run_dir" "$sid" "$name" Stop block "no handoff"
printf 'Before stopping, write your handoff at %s in the team format (it must contain a "## Status" section), then send the orchestrator "DONE: handoff at %s".\n' "$handoff" "$handoff" >&2
exit 2
