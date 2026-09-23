# Design — why the plugin is shaped this way

Purpose: one lead session runs a team of role sessions on one repository, in parallel, with the lead as the only judge. This note records the decisions that are not obvious from the code, so they are not re-argued.

## Sessions, not subagents, not agent teams

Roles are full background sessions (`claude --agent orchestrator:<role> --bg`), not Agent-tool subagents and not the experimental agent-teams feature. Reasons: a session has its own worktree and survives the lead's process; you can attach to it, read its log, message it; it appears in `claude agents`. Agent teams give none of that (no worktrees, no resume, teammates die with the lead) and change ordinary delegation when enabled. Subagents cannot be attached to and report only to the caller. Workflows are for scripted fan-out where nobody steers mid-run.

## The plan is the contract

`plan.json` holds roles, names, allowed paths, acceptance, dependencies and budgets. The guard reads the same file the brief was rendered from, so what the session was told and what it is allowed to do never diverge. Waves fall out of `dependsOn`; parallelism is the default and path disjointness inside a wave is validated at `orch plan`, then enforced per call by the guard.

## Enforcement is mechanical, judgement is not

Three brakes are hooks, not prose: path ownership, a danger list for Bash, and a tool-call budget. Prose is ignored under pressure; a hook is not. Pause is a file, so the lead or a human in any terminal can stop a session without knowing its process. Everything that requires judgement (is the work correct, is coverage enough, should this merge) stays with the lead, which re-runs checks itself; QA and the reviewer propose. This matches the rule in many users' instruction layers that verification is never delegated, and it is the right split regardless: a verdict from the party that produced the work is not evidence.

## A developer's "done" readies its verifiers, nothing else

Readiness used to be "accepted, or the handoff says done" for every dependent, which let an integrator start on a developer's word while the review still had blockers. Requiring acceptance for every dependent would deadlock the other way: the lead accepts only after a clean review round, and the reviewer could not start before acceptance. So the dependent's role decides: reviewer, tester and QA start on the developer's `done`; whatever builds on the code waits for `orch accept`.

## Peer messaging with an escalation ceiling

Roles message each other directly because a developer waiting on the lead to relay a spec question wastes a wave. The ceiling of two rounds before `ESCALATION:` bounds the cost of a disagreement and keeps the lead as the tie-breaker rather than a router.

## Portability constraints

- bash 3.2 (macOS default) and `jq`; no Python, node or bun assumed.
- No dependency on the host's `CLAUDE.md`, skills or plugins; the designer's guidance is inlined and design skills are used only when present.
- Hooks are inert outside a run: they resolve the session id against `sessions.json` and exit 0 when it is absent, so enabling the plugin costs nothing in unrelated sessions.
- The Concise output style is built in everywhere, so pinning it via `--settings` is safe on any machine.
- `env -u CLAUDE_CODE_CHILD_SESSION` on every launch: harmless where the marker is absent, and it prevents an inherited marker from silencing transcripts where it is present.

## What the guard is and is not

The guard is a tripwire against the mistakes a cooperative session makes, and a log the lead reads. It is not a sandbox: a session with an unrestricted Bash tool can reach any file the user can, so every filesystem check here (allowed paths, the run directory, the session index) can be defeated by a session that sets out to defeat it, through `sh -c`, `eval`, encoded commands, or an interpreter. Two commit security reviews (2026-09-15) found and we closed the cheap bypasses: cd out of the repository, `..` and symlinks in edit paths, quoting and global git options in the denylist, Bash writes into the run directory and the index, cwd inside those directories. The remaining class is closed only by Claude Code's own permission mode and sandbox on the worker sessions; run them in `acceptEdits` or with the sandbox on when the task is sensitive, and treat the guard as defence in depth, not as the boundary.

## The handoff free pass

One command shape skips the scan, the budget and the pause: nothing but `orch handoff-put <run> <own name>` fed by `< file` or by a quoted heredoc whose terminator comes once and last. It exists because a spent or paused session still owes a handoff the Stop hook demands, and because a handoff's prose names commands it never ran. The shape is anchored at both ends and the command word is the literal `orch` or this plugin's own `bin/orch`; a security review (2026-09-21) caught an earlier pattern that accepted any path ending in `orch`, which a session could have planted inside its allowed paths. `tests/guard.test.sh` pins the shapes that must not qualify. The same review (2026-09-23) of the `.scratch/` carve-out found that edits went through a symlinked file to wherever it pointed — in any allowed path, not only scratch — since only the directories of a path were resolved; edits to a symlink are now refused. Its follow-up flagged what that check still misses — a hardlink to an outside file, a symlink created by a parallel call in the same batch after the check ran, and writes through Bash, which the guard never checks by path. All three need a session that sets out to evade, and such a session can already write anywhere through Bash; they belong to the class above, closed only by Claude Code's permission mode and sandbox. What remains is the class above, not a new one: the bare `orch` resolves through the session's PATH, exactly as `git` does for every denylist rule, and the shape leaves no room for a `PATH=` prefix.

## MCP servers are per task, not per machine

A background session starts every MCP server configured for the user and the repository. In one wave that meant a dozen browser servers and headless Chrome instances and a load average past 60, while most roles needed none. A running session cannot pick up a server added to its config — the docs say config changes take effect at the next start — but a subagent can carry one: servers defined inline in an agent connect when it starts and disconnect when it finishes, and `--strict-mcp-config` does not filter servers passed with `--agents`. So `orch spawn` starts every session with an empty MCP config and hands it one `mcp-<server>` helper per server it may use; the guard lets a team session start those helpers and no other subagent. The cost is a server start per helper call, and the helper definitions travel as a command-line argument, visible to `ps` on this machine: `--agents` reads a file only with `--print`, no settings key carries agents, a plugin's agents ignore `mcpServers`, and project or `--add-dir` agents need a folder trust entry orch would have to write into `~/.claude.json`. A security review (2026-09-23) of the first cut, which let every session start every configured server, led to the current default — the repository's `.mcp.json` only, checked into git and so free of secrets by convention; user- and local-scope servers must be named per task, and `orch spawn` warns when a named one carries `env` or `headers`. `"inherit"` is the escape hatch.

## OpenSpec is an input, not a rival

OpenSpec structures specifications and runs no agents; this plugin runs agents and structures no specifications beyond a handoff. Where a repository uses it, the analyst writes into its format and the lead reads a change's `tasks.md` and scenarios into the task graph, rather than the plugin growing a spec format of its own.

## Names and notes that reach the disk

A security review (2026-09-23) of 0.6.0 found that a stage name became a path under `rm -rf` and that a note could carry a newline into `events.log`, where the guard counts `allow` lines as budget and a `nudge` line as the reminder given. Run and stage names are now plain single path components, and every event line goes through one helper that turns newlines and pipes into spaces. `orch stage-report` copies only images a handoff names from inside the repository, never a symlink and never a file with a second hard link, which could be a file outside the repository under a name inside it; a session that swaps a file for a symlink between that check and the copy belongs to the class above.

## Sessions register by their short id

`claude --bg` prints an 8-character id, the start of the session's full id. `orch spawn` used to poll `claude agents --json` until the full id appeared, and under a load average near 100 each poll took seconds, so a wave spent minutes per session. Now a session is registered by the short id at once, the guard recognises it by that prefix, `orch status` fills in the full id when it next lists the agents, and the sessions of a wave launch in parallel with `sessions.json` written under a lock. Two sessions of one run whose full ids share their first 8 characters would confuse the guard; the odds are 1 in 4 billion per pair.

## Known gaps

- Quota exhaustion on the lead's model is not detected; fallback chains cover overload only.
- Drift that stays inside allowed paths and under budget is caught only by the lead reading handoffs and diffs.
- `orch status` joins on the short session id from `claude agents --json`; if the supervisor forgets a session the row shows `-` and the lead should `claude attach` to check.
