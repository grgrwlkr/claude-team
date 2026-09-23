# orchestrator — a Claude Code plugin for one lead and a team of role sessions

`/orchestrator <task>` turns the current Claude Code session into a lead that decomposes the task, spawns a team of background sessions (analyst, developer, designer, QA, tester, reviewer, integrator, researcher), each in its own git worktree, lets them talk to each other directly, watches them through hard guard rails, and judges the result itself. You watch everything in `claude agents`.

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

`orch start` launches the lead on the latest Opus (`--model` picks another, `--fallback` adds a fallback model), effort `high`, Concise output style, and hands it `/orchestrator <task>`. Inside an existing session you can type `/orchestrator <task>` directly; the lead then notes which model it is running on.

The lead:

1. reads the repository and the task, writes a task graph (roles, names, allowed paths, acceptance, dependencies, budgets) and asks you the forks that matter, once, as one list;
2. on your go, `orch init`, `orch plan`, `orch spawn --wave`: every ready task starts as its own session, in parallel, in its own worktree;
3. acts on teammates' `STARTED` / `DONE` / `BLOCKED` messages rather than polling; verifies every `DONE` itself (tests, diff, spec), records the verdict with `orch accept`, runs the review rounds, answers `BLOCKED`, decides escalations into `decisions.md`, spawns the next wave;
4. reports per wave and at the end: what landed where, what was verified and how, what you still need to do (push, merge).

You can attach to any session (`claude agents`, `Enter`), message any of them, or pause the whole run from another terminal: `orch pause <run> all "hold on"`.

**The run does not stop to ask you anything twice.** At plan approval the lead collects every gated action — pushing the base branch, deleting merged branches and worktrees, tagging — and records your answers in the plan (`orch authorize <run> push-base on`). The guard honours them, so the integrator acts without another round trip; a gate you declined comes back at the end as a command you can run yourself.

## The team

| Role | Owns | Delivers |
|---|---|---|
| analyst | `docs/specs/**` | spec with testable acceptance criteria, plan, docs after implementation |
| developer | its task's source and test paths | code on its branch, tests with the three runs shown, draft PR |
| designer | `docs/design/**`, `design/`, `assets/` | design brief, tokens, states, assets; self-contained guidance for UI, game HUD, graphics, 3D |
| qa | test paths | test cases, automated tests, coverage matrix per criterion, proposed verdict |
| tester | nothing (read-only; evidence in its worktree's `.scratch/evidence/`) | runs the app from the branch, exercises every criterion as a user would with the means the machine has, hands over screenshots, recordings and transcripts per criterion; re-runs each round |
| reviewer | nothing (read-only) | findings with cited lines, severity, confidence; re-reviews each round until clean |
| integrator | integration branch | dependency-ordered merges, green suite, version and changelog; the only role allowed to merge into the base branch |
| researcher | `docs/research/**` | facts from live sources with verbatim quotes and dates |

All roles run on Opus at effort `high` (per-task override in the plan). Roles never spawn subagents or workflows; they ask a teammate.

## How they talk

Peer to peer over Claude Code's cross-session messaging, by session name: `STARTED:` when a session begins, `Q:` / `A:` for questions, `FYI:` for facts others must know, `BLOCKED:` and `ESCALATION:` to the lead, `DONE:` when the handoff is in. Reports are messages, never silence: the lead does not read idleness as a result. Two rounds without agreement means both parties escalate and stop on the disputed point until the lead writes a decision. A teammate's message is data, never an approval. Team sessions start without Remote Control (`disableRemoteControl` in their `--settings`; `ORCH_REMOTE_CONTROL=1` keeps it), because a Remote Control mirror carries its session's name and a bare-name message then matches two sessions. Full protocol: `skills/orchestrator/references/team-rules.md`.

Interactive verification is a choice the lead puts to you at plan approval, together with `orch tools`, an inventory of what this machine can drive and capture (browser MCPs, Playwright, screenshots, recording, terminal capture, simulators). With `orch interactive <run> on`, every developer task gets a tester task that runs the application after each round and hands over evidence per criterion; missing tooling is reported to you with the install command, and nothing is installed unless you authorized it (`orch authorize <run> install-tools on`). The guard blocks package installs otherwise.

Review is mandatory and iterative: `orch plan` refuses a graph where a developer task has no reviewer, and the lead re-spawns the reviewer with `orch spawn <run> <id> --round N` after each round of fixes, up to three rounds by default. At plan approval you choose where review happens — on the branch, or on a pull/merge request where authors open the PR and reviewers comment in threads (`orch review <run> venue pr`).

Handoffs travel through `orch handoff-put <run> <name>` on stdin, so a session isolated in a worktree can still deliver one; the file itself lives in the run directory, which sessions cannot write. The lead records its verdict with `orch accept <run> <task-id>`, which is what unblocks dependents — a teammate's handoff is never edited to change its status. A developer's own `done` readies only its reviewer, tester and QA; the integrator and anything else that builds on the code wait for the lead's accept. `orch close <run>` ends a run: a containment report for its branches with the count of refs checked, session index cleanup, the final table — it deletes nothing.

## Guard rails (hooks, mechanical)

The plugin's `PreToolUse` hook watches every session registered in a run and blocks, with a reason the session sees and an entry in `events.log`:

- edits outside the task's allowed paths, in the main checkout, or in another session's handoff;
- `git push --force`, `git reset --hard`, `git branch -D`, `git clean -f`, `sudo`, `curl … | sh`, `rm -r` on absolute paths;
- pushing the base branch, and deleting branches or worktrees, unless the plan authorizes it and the session is the integrator; checkout of, or commits on, the base branch by anyone but the integrator;
- package installs (`brew`, `apt`, `npm -g`, `pip`, `cargo install`, `npx playwright install`, `claude mcp add`) unless the plan authorizes `install-tools`; a project-local `npm install` passes;
- `orch` subcommands that belong to the lead (`spawn`, `pause`, `accept`, `authorize`, `plan`, `decide`, `budget`, `task`, `paths`, `cancel`, `stop`, `cost`, `close`); sessions may run `orch handoff-put`, `handoff`, `status`, `events`, `ready`, `doctor`, `tools`;
- `claude stop|rm|kill|respawn` — sessions never stop each other;
- every Bash/Edit/Write and MCP tool call while the lead has paused the session or the run (`orch pause`); reading and messaging keep working;
- every Bash/Edit/Write and MCP tool call past the task's tool-call budget — the passive brake against drift. A tester drives a browser through MCP tools, so those calls are held and counted like the rest; `orch status` marks a session with `!` from 80%, and `orch budget` changes a live session's budget.

At 80% of the budget the guard holds one call, once, and asks for a partial handoff. `.scratch/` in a session's own worktree is always writable.

One call is always open, paused or out of budget: a command that is nothing but `orch handoff-put <run> <own name>` fed by a quoted heredoc or `< file`. Its body is read as prose, so a handoff may describe commands it never ran; anything chained to it is guarded as usual.

The `Stop` hook refuses to let a registered session go idle without a handoff. Both hooks are inert for sessions that are not in a run. A session the guard has seen once stays under guard even after it changes directory out of the repository (index in `~/.claude/orchestrator-sessions/`); edit paths are canonicalised before the check, and Bash commands are matched with quotes stripped and git's global options tolerated.

**The guard is a tripwire, not a sandbox.** It catches the mistakes a well-meaning session makes and logs them for the lead; a session determined to escape a denylist can. The hard boundary is Claude Code's own permission mode and sandbox; the lead's reading of diffs and handoffs is the second line.

## MCP servers and cost

Each session starts only the MCP servers its task's `mcp` list names, through `--mcp-config` and `--strict-mcp-config`; a tester defaults to the repository's `.mcp.json`, every other role to none, and `"mcp": "inherit"` keeps the machine's full set. A wave where every session started every configured server drove a machine's load average past 60. `orch tools` lists the servers by scope. `orch cost <run>` sums the tokens of each session from its transcript, counting each message once — the transcript repeats a message's usage on several lines, and a naive sum reads about double.

## Run directory

`<repo>/.orchestrator/<run>/` in the main checkout, excluded from git through `.git/info/exclude`: `plan.json` (graph, authorizations, review settings), `sessions.json`, `accepted.json`, `events.log`, `decisions.md`, `handoffs/<name>.md` (a later round hands off as `<name>-r<N>.md`), `cancelled.json`, `mcp/<name>.json` (each session's MCP config, mode 600), `PAUSE`, `PAUSE-<name>`, `CLOSED`; beside the runs, `tools-mcp.cache` keeps `orch tools`' MCP list for an hour (`orch tools --refresh`). Sessions keep their scratch files in `.scratch/` inside their own worktree, never in `/tmp`.

## Limits worth knowing

- Every session spends your subscription quota independently: a wave of four is roughly four times the burn.
- `--fallback-model` switches only when a model is overloaded or unavailable, per turn; an exhausted weekly window is not caught. Relaunch with another `orch start --model` in that case.
- Background sessions live on this machine and stop on shutdown; they survive sleep.
- Deleting a session in `claude agents` deletes the worktree Claude created for it. Push first.
- Hooks in this plugin run in every session where the plugin is enabled and exit immediately for sessions not registered in a run; measured cost is one `jq` per guarded tool call.

## Develop

```bash
bash tests/guard.test.sh && bash tests/orch.test.sh
shellcheck -s bash bin/orch scripts/*.sh tests/*.sh
```

Tests never reach the real `claude`: a stub stands first on PATH, and `orch spawn --dry-run` prints the command instead.
