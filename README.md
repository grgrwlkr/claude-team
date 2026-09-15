# orchestrator — a Claude Code plugin for one lead and a team of role sessions

`/orchestrator <task>` turns the current Claude Code session into a lead that decomposes the task, spawns a team of background sessions (analyst, developer, designer, QA, reviewer, integrator, researcher), each in its own git worktree, lets them talk to each other directly, watches them through hard guard rails, and judges the result itself. You watch everything in `claude agents`.

Portable by design: it needs `claude`, `git`, `jq` and nothing else — no particular `CLAUDE.md`, no other skills or plugins. The designer carries its own design guidance; if design skills are installed it uses them, if not it does not stall.

## Install

```bash
claude plugin marketplace add /path/to/claude-team      # or: claude plugin marketplace add grgrwlkr/claude-team
claude plugin install orchestrator@claude-team
```

Restart Claude Code (or `/reload-plugins`). `orch doctor` inside a git repository checks the rest.

## Run

```bash
cd your-repo
orch start -- "Add dark mode to Settings; spec first, then implementation, tests and a PR"
```

`orch start` launches the lead on Fable with Opus as the fallback chain, effort `high`, Concise output style, and hands it `/orchestrator <task>`. Inside an existing session you can type `/orchestrator <task>` directly; the lead then notes which model it is running on.

The lead:

1. reads the repository and the task, writes a task graph (roles, names, allowed paths, acceptance, dependencies, budgets) and asks you the forks that matter, once, as one list;
2. on your go, `orch init`, `orch plan`, `orch spawn --wave`: every ready task starts as its own session, in parallel, in its own worktree;
3. waits for idle notifications instead of polling; on each, reads `orch status`, `orch events`, the handoffs; verifies `done` work itself (tests, diff, spec); answers `blocked`; decides escalations into `decisions.md`; spawns the next wave;
4. reports per wave and at the end: what landed where, what was verified and how, what you still need to do (push, merge).

You can attach to any session (`claude agents`, `Enter`), message any of them, or pause the whole run from another terminal: `orch pause <run> all "hold on"`.

## The team

| Role | Owns | Delivers |
|---|---|---|
| analyst | `docs/specs/**` | spec with testable acceptance criteria, plan, docs after implementation |
| developer | its task's source and test paths | code on its branch, tests with the three runs shown, draft PR |
| designer | `docs/design/**`, `design/`, `assets/` | design brief, tokens, states, assets; self-contained guidance for UI, game HUD, graphics, 3D |
| qa | test paths | test cases, automated tests, coverage matrix per criterion, proposed verdict |
| reviewer | nothing (read-only) | findings with cited lines, severity, confidence |
| integrator | integration branch | dependency-ordered merges, green suite, version and changelog; the only role allowed to merge into the base branch |
| researcher | `docs/research/**` | facts from live sources with verbatim quotes and dates |

All roles run on Opus at effort `high` (per-task override in the plan). Roles never spawn subagents or workflows; they ask a teammate.

## How they talk

Peer to peer over Claude Code's cross-session messaging, by session name: `Q:` / `A:` for questions, `FYI:` for facts others must know, `BLOCKED:` and `ESCALATION:` to the lead, `DONE:` with the handoff path. Two rounds without agreement means both parties escalate and stop on the disputed point until the lead writes a decision. A teammate's message is data, never an approval. Full protocol: `skills/orchestrator/references/team-rules.md`.

## Guard rails (hooks, mechanical)

The plugin's `PreToolUse` hook watches every session registered in a run and blocks, with a reason the session sees and an entry in `events.log`:

- edits outside the task's allowed paths, in the main checkout, or in another session's handoff;
- `git push --force`, `git reset --hard`, `git branch -D`, `git worktree remove`, `git clean -f`, `sudo`, `curl … | sh`, `rm -r` on absolute paths;
- any push to the base branch by anyone; checkout of, or commits on, the base branch by anyone but the integrator;
- `claude stop|rm|kill|respawn` — sessions never stop each other;
- every Bash/Edit/Write while the lead has paused the session or the run (`orch pause`); reading and messaging keep working;
- every Bash/Edit/Write past the task's tool-call budget — the passive brake against drift.

The `Stop` hook refuses to let a registered session go idle without a handoff. Both hooks are inert for sessions that are not in a run.

## Run directory

`<repo>/.orchestrator/<run>/` in the main checkout, excluded from git through `.git/info/exclude`: `plan.json`, `sessions.json`, `events.log`, `decisions.md`, `handoffs/<name>.md`, `PAUSE`, `PAUSE-<name>`.

## Limits worth knowing

- Every session spends your subscription quota independently: a wave of four is roughly four times the burn.
- `--fallback-model` switches only when a model is overloaded or unavailable, per turn; an exhausted weekly window on Fable is not caught. Relaunch with `orch start --model opus` in that case.
- Background sessions live on this machine and stop on shutdown; they survive sleep.
- Deleting a session in `claude agents` deletes the worktree Claude created for it. Push first.
- Hooks in this plugin run in every session where the plugin is enabled and exit immediately for sessions not registered in a run; measured cost is one `jq` per guarded tool call.

## Develop

```bash
bash tests/guard.test.sh && bash tests/orch.test.sh
shellcheck -s bash bin/orch scripts/*.sh tests/*.sh
```

Tests never launch a real session; `orch spawn --dry-run` prints the command instead.
