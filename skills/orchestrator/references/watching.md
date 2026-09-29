# Watching the team — what the orchestrator does between spawns

The lead's job after a spawn is to wait cheaply and judge sharply. Nothing here needs polling loops in the conversation.

## Wake-ups, not polling

- **Teammates report with messages.** `STARTED` when they begin, `DONE` or `BLOCKED` when they finish or stop, `QA: <task id>` when a developer asked for qa with `orch qa-request` (spawn that task). Those messages, not idleness, are what you act on.
- `notify_when_idle` is a cheap extra alarm, not the signal. Subscribe **once, after the session's `STARTED` arrives**, and never re-subscribe to the same session: subscribing to an already-idle session fires immediately and replays the old turn, so a loop of resubscribes wakes you forever while the teammate is merely waiting on its own background command. `SendMessage` requires `message`; for a pure subscription pass `message: ""`.
- On a wake-up with no `DONE`/`BLOCKED` message: check `orch inbox` once. If nothing in it needs you, end your turn without re-subscribing.
- A message to a session running in another permission mode can sit queued without waking it (seen in a run; not documented by Claude Code). If a message gets no reaction, send it once more, and keep every session on one mode with `ORCH_PERMISSION_MODE`.
- If `SendMessage` refuses a name because several sessions carry it (`N agents are named …`), run `ListAgents` and resend to `<name> [ref]` of the row marked `bg`; the others are offline Remote Control mirrors or sessions of earlier runs. Team sessions start without Remote Control for this reason; a name reused from an earlier run still collides with that run's leftover mirrors.
- Under heavy load `SendMessage` can report a timeout although the message arrived. Don't resend at once: wait for a reaction, or look at the recipient's recent events, then resend once.
- Do not `sleep`, do not re-run `orch status` in a loop. The user sees everything in `claude agents` anyway.

## On every wake-up

1. `orch inbox <run>` — only what needs you: unaccepted `done`, `partial`, `blocked` or `failed` handoffs, sessions at 80 % of their budget or more, guard blocks since the last inbox, idle sessions without a handoff, ready tasks. For the whole picture, `orch status <run>`: name, role, session state, handoff state, calls used of budget (`!` from 80 %: look now, before the guard stops the session mid-thought), `TASK` (calls over every round of the task), `CTX` (the session's context size at its last turn), last event; and a `moved since accept` line for an accepted task whose branch changed afterwards. Handoff states: `none`, `written` (a handoff whose `## Status` starts with no known word — read it), `done`, `partial`, `blocked`, `failed`, `accepted`, `settled` (the task it reviews or tests is accepted), `cancelled`. `orch graph <run>` says why a task is not ready yet.
2. `orch events <run> --new` — the log lines since your last look (`--blocks` for guard blocks only). A block is a signal about the brief as much as about the session: a developer editing outside its paths usually means the paths were wrong or the task leaked.
3. For every `done`: read `orch handoff <run> <name>` (the latest round; earlier ones are named); when qa ran the app, open its evidence files (screenshots, transcripts under `.scratch/evidence/` in its worktree) with the Read tool and compare them with the criteria yourself; then verify yourself — run the tests, read the diff (`git -C <worktree> diff <base>...HEAD`), open the spec. Then `orch accept <run> <task-id> "<why>"`. It refuses what plan.md's Acceptance section lists — `--force` only when you know why and the note says it — records the branch head, prints the tasks it made ready, and removes from `claude agents` every session no open task can still need: a reviewer's, qa's or design-reviewer's once the task it covers is accepted, a developer's or designer's once everything built on it is accepted too, the analyst's, researcher's and architect's once no task is open (`claude rm`; worktrees and branches stay; a session `claude rm` keeps is named with the reason). Not accepting is equally explicit: message the session what is missing and spawn nothing new for that task.
4. For every `blocked`: read `claude logs <id>`; answer through `SendMessage`; if the answer is the user's, ask the user, in one list, at the end of your turn.
5. For every `ESCALATION:` message: read both positions and the spec; write the decision into `decisions.md` (`orch decide <run> "<text>" --for <task>`); message both parties with it. Decide on the merits; the analyst's spec wins over a developer's preference, a measured fact wins over the spec.
6. Spawn the next wave: `orch ready` lists it. A developer task's `done` readies its reviewer, qa and design-reviewer; whatever builds on the code waits for your `orch accept`.

A session that stopped without a handoff it can no longer send (removed, crashed): write it for the record from what you have, `orch handoff-put <run> <name> --by-lead "<source>" --file <path>`; the handoff is stamped as yours and the event logged.

## Brakes

- `orch pause <run> <name> "<reason>"` — the guard refuses every Bash, Edit, Write and MCP call of that session from the next call; it can still read and message, and it may stop without a handoff. Use it the moment you see danger (touching the base branch, deleting, network egress of private data) or drift (work on things the task never named, a rewrite where a fix was asked). Then message the session: what you saw, what to do instead. `orch resume` when it acknowledged.
- `orch pause <run> all "<reason>"` — stop the whole wave, for example when the user changes the goal.
- Budget is the passive brake: the plan's value is copied into the session's record at spawn, and the guard enforces the record. At 80 % the guard holds one call and asks the session for a partial handoff, so the work survives a spent budget. A session that hits budget sends its handoff (that one command stays open) and stops. Then decide: when the work is sound and merely bigger than planned, `orch budget <run> <task> +<n>` for a live session, or `orch continue <run> <task>` for a developer whose session stopped — the next round in the same worktree, briefed to finish from `git status`; otherwise re-scope the task narrower. A hand edit of `plan.json` never reaches a live session.
- `claude stop <id>` is the last resort, for a session that ignores a pause; only you and the user do this, never a teammate.

## Stopping and resuming the run

`orch freeze <run> "<why>"` pauses every session, writes `RESUME.md` in the run dir (base head, accepted and open tasks, branches and heads, pending decisions, next commands) and stops them all: the run can go on later, or on another machine. After a restart or on the other machine, `orch resume-brief <run>` prints the same state from the run's files — run it before anything else; then `orch thaw <run>` forgets the sessions this machine does not run (`orch forget <run> --dead`), drops every pause and prints what is ready.

## What you never delegate

Correctness, completeness and safety are decided here, by you, on evidence you produced or re-ran. qa proposes a verdict with a coverage report; the reviewer proposes findings with cited lines; you confirm both against the code. Merging into the base branch is the integrator's task, and the go for a merge is yours.

Your own hands stay off the code. A small fix outside every developer's paths is a chore task (SKILL.md step 1). When you do commit something yourself, on a branch of your own, register it with `orch lead-branch <run> <branch>` so `orch close` checks it is merged.

## Staged runs

When every task of a stage is accepted, follow SKILL.md 4b: `orch stage-report`, show the page, end the turn, and `orch approve` only on the user's word. This is the one pause the run takes on purpose; nothing else waits for the user.

## Never park the run on the user

Every gated action of the run is settled once, at plan approval (SKILL.md step 2). Mid-run, a gate you did not collect is your mistake, not a reason to stop: finish everything else, leave the gated step for the end, and report it in one line with the exact command the user can run. Stop the run only when continuing would be unsafe or would waste the work.

Deletion is authorized the same way and verified mechanically before it happens: every branch and worktree you delete must be contained in the base branch. `orch close <run>` prints that report for the run's branches, with the count. For any other set of refs check it in one command, count what you checked, and refuse when the count is zero (`<prefix>` and `<base>` are yours to fill):

```bash
bash -c 'n=0; for b in $(git branch --format="%(refname:short)" | grep "^<prefix>"); do
  git merge-base --is-ancestor "$b" <base> || { echo "NOT contained: $b"; exit 1; }; n=$((n+1)); done
  [ "$n" -gt 0 ] || { echo "zero refs checked — refusing"; exit 1; }; echo "$n refs contained in <base>"'
```

Run such loops through `bash -c`: in zsh an unquoted `$(…)` does not word-split, so the loop runs once over one non-existent ref and prints a false all-clear.

## Closing a run

When every task is accepted and the integrator's handoff shows the merged state green, close as SKILL.md step 5 says: follow-ups routed, `Left running` cleaned up or reported, `orch close <run>` before any branch cleanup, then the report to the user.
