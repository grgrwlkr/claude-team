# Watching the team — what the orchestrator does between spawns

The lead's job after a spawn is to wait cheaply and judge sharply. Nothing here needs polling loops in the conversation.

## Wake-ups, not polling

- After every `orch spawn`, send the new session one `SendMessage` with `notify_when_idle`. One-shot, on this machine only. The notification arrives as a turn when the session goes idle; that is your cue to read its handoff.
- Then end your turn. Do not `sleep`, do not re-run `orch status` in a loop. The user may also see everything in `claude agents`.

## On every wake-up

1. `orch status <run>` — one table: name, role, state (`working`, `blocked`, `done`, `failed`, `stopped`), `waitingFor`, tool calls used of budget, last event.
2. `orch events <run> --since <last seen>` — guard blocks, budget hits, pauses. A block is a signal about the brief as much as about the session: a developer editing outside its paths usually means the paths were wrong or the task leaked.
3. For every `done`: read `orch handoff <run> <name>`; then verify yourself — run the tests, read the diff (`git -C <worktree> diff <base>...HEAD`), open the spec. Accept, or message the session with what is missing and spawn nothing new for that task.
4. For every `blocked`: read `claude logs <id>`; answer through `SendMessage`; if the answer is the user's, ask the user, in one list, at the end of your turn.
5. For every `ESCALATION:` message: read both positions and the spec; write the decision into `decisions.md` (`orch decide <run> "<text>"`); message both parties with it. Decide on the merits; the analyst's spec wins over a developer's preference, a measured fact wins over the spec.
6. Spawn the next wave: tasks whose `dependsOn` are all `done`.

## Brakes

- `orch pause <run> <name> "<reason>"` — the guard refuses every Bash/Edit/Write of that session from the next call; it can still read and message. Use it the moment you see danger (touching the base branch, deleting, network egress of private data) or drift (work on things the task never named, a rewrite where a fix was asked). Then message the session: what you saw, what to do instead. `orch resume` when it acknowledged.
- `orch pause <run> all "<reason>"` — stop the whole wave, for example when the user changes the goal.
- Budget is the passive brake: it is in `plan.json` and the guard enforces it. A session that hits budget writes its handoff and stops; you decide whether to respawn it with a narrower goal.
- `claude stop <id>` is the last resort, for a session that ignores a pause; only you and the user do this, never a teammate.

## What you never delegate

Correctness, completeness and safety are decided here, by you, on evidence you produced or re-ran. QA proposes a verdict with a coverage report; the reviewer proposes findings with cited lines; you confirm both against the code. Merging into the base branch is the integrator's task, but the go for a merge is yours, and pushing to the base branch is the user's unless the brief says otherwise.

## Closing a run

When every task is accepted and the integrator's handoff shows the merged state green: `orch status` one last time, ask each live session to shut down (`SendMessage` "shutdown: run closed, thank you"), then report to the user: what landed, where (branches, PRs), what was verified and how, what remains. Leave the worktrees; the user removes sessions with `claude rm` after pushing.
