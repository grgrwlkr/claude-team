# Watching the team — what the orchestrator does between spawns

The lead's job after a spawn is to wait cheaply and judge sharply. Nothing here needs polling loops in the conversation.

## Wake-ups, not polling

- **Teammates report with messages.** `STARTED` when they begin, `DONE` or `BLOCKED` when they finish or stop. Those messages, not idleness, are what you act on.
- `notify_when_idle` is a cheap extra alarm, not the signal. Subscribe **once, after the session's `STARTED` arrives**, and never re-subscribe to the same session: subscribing to an already-idle session fires immediately and replays the old turn, so a loop of resubscribes wakes you forever while the teammate is merely waiting on its own background command. `SendMessage` requires `message`; for a pure subscription pass `message: ""`.
- On a wake-up with no `DONE`/`BLOCKED` message: check `orch status` once. If the session is `working` or its handoff is `none`, end your turn without re-subscribing.
- A message to a session running in another permission mode can sit queued without waking it (seen in a run; not documented by Claude Code). If a message gets no reaction, send it once more, and keep every session on one mode with `ORCH_PERMISSION_MODE`.
- If `SendMessage` refuses a name because several sessions carry it (`N agents are named …`), run `ListAgents` and resend to `<name> [ref]` of the row marked `bg`; the others are offline Remote Control mirrors or sessions of earlier runs. Team sessions start without Remote Control for this reason; a name reused from an earlier run still collides with that run's leftover mirrors.
- Under heavy load `SendMessage` can report a timeout although the message arrived. Don't resend at once: wait for a reaction, or look at the recipient's recent events, then resend once.
- Do not `sleep`, do not re-run `orch status` in a loop. The user sees everything in `claude agents` anyway.

## On every wake-up

1. `orch status <run>` — one table: name, role, session state, handoff state (`none`, `partial`, `blocked`, `done`, `accepted`), tool calls used of budget (`!` from 80%: look now, before the guard stops the session mid-thought), last event of any kind.
2. `orch events <run> --since <last seen>` — guard blocks, budget hits, pauses. A block is a signal about the brief as much as about the session: a developer editing outside its paths usually means the paths were wrong or the task leaked.
3. For every `done`: read `orch handoff <run> <name>`; for a tester, open its evidence files (screenshots, transcripts under `.scratch/evidence/` in its worktree) with the Read tool and compare them with the criteria yourself; then verify yourself — run the tests, read the diff (`git -C <worktree> diff <base>...HEAD`), open the spec. Then `orch accept <run> <task-id> "<why>"`, which unblocks the dependents. Acceptance is yours and lives outside the handoff on purpose: a teammate that finished the work but wrote `blocked` on something you have since resolved is accepted without anyone rewriting its handoff. Not accepting is equally explicit: message the session what is missing and spawn nothing new for that task.
4. For every `blocked`: read `claude logs <id>`; answer through `SendMessage`; if the answer is the user's, ask the user, in one list, at the end of your turn.
5. For every `ESCALATION:` message: read both positions and the spec; write the decision into `decisions.md` (`orch decide <run> "<text>"`); message both parties with it. Decide on the merits; the analyst's spec wins over a developer's preference, a measured fact wins over the spec.
6. Spawn the next wave: `orch ready` lists it. A developer task's `done` readies its reviewer, tester and QA; whatever builds on the code waits for your `orch accept`.

## Brakes

- `orch pause <run> <name> "<reason>"` — the guard refuses every Bash/Edit/Write of that session from the next call; it can still read and message. Use it the moment you see danger (touching the base branch, deleting, network egress of private data) or drift (work on things the task never named, a rewrite where a fix was asked). Then message the session: what you saw, what to do instead. `orch resume` when it acknowledged.
- `orch pause <run> all "<reason>"` — stop the whole wave, for example when the user changes the goal.
- Budget is the passive brake: it is in `plan.json`, copied into the session's record at spawn, and the guard enforces the record. At 80% the guard holds one call and asks the session for a partial handoff, so the work survives a spent budget. A session that hits budget sends its handoff (that one command stays open) and stops; you decide whether to respawn it with a narrower goal or, when the work is sound and merely bigger than planned, `orch budget <run> <task-id|name> <n>` — a hand edit of `plan.json` never reaches a live session.
- `claude stop <id>` is the last resort, for a session that ignores a pause; only you and the user do this, never a teammate.

## What you never delegate

Correctness, completeness and safety are decided here, by you, on evidence you produced or re-ran. QA proposes a verdict with a coverage report; the reviewer proposes findings with cited lines; you confirm both against the code. Merging into the base branch is the integrator's task, and the go for a merge is yours.

## Staged runs

When every task of a stage is accepted, follow SKILL.md 4b: `orch stage-report`, show the page, end the turn, and `orch approve` only on the user's word. This is the one pause the run takes on purpose; nothing else waits for the user.

## Never park the run on the user

Every gated action of the run is settled once, at plan approval, and written into the plan with `orch authorize <run> push-base|delete-merged|tag on`. The guard reads those flags, so an integrator authorized at approval time pushes without anyone asking again. Mid-run, a gate you did not collect is your mistake, not a reason to stop: finish everything else, leave the gated step for the end, and report it in one line with the exact command the user can run. Stop the run only when continuing would be unsafe or would waste the work.

Deletion is authorized the same way and verified mechanically before it happens: every branch and worktree you delete must be contained in the base branch. `orch close <run>` prints that report for the branches the run's handoffs name, with the count. For any other set of refs check it in one command, count what you checked, and refuse when the count is zero (`<prefix>` and `<base>` are yours to fill):

```bash
bash -c 'n=0; for b in $(git branch --format="%(refname:short)" | grep "^<prefix>"); do
  git merge-base --is-ancestor "$b" <base> || { echo "NOT contained: $b"; exit 1; }; n=$((n+1)); done
  [ "$n" -gt 0 ] || { echo "zero refs checked — refusing"; exit 1; }; echo "$n refs contained in <base>"'
```

Run such loops through `bash -c`: in zsh an unquoted `$(…)` does not word-split, so the loop runs once over one non-existent ref and prints a false all-clear.

## Closing a run

When every task is accepted and the integrator's handoff shows the merged state green: `orch close <run>` before any branch cleanup (containment report with its count, session index cleanup, final table; it deletes nothing; reviewer and tester tasks are settled by the acceptance of the task they cover; `--force` closes a run with unaccepted tasks), read each handoff's `Left running` and clean up or report what it lists, `orch stop <run> all`, then report to the user: what landed, where (branches, PRs), what was verified and how, what remains. Leave the worktrees; the user removes sessions with `claude rm` after pushing.
