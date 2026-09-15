# Design — why the plugin is shaped this way

Purpose: one lead session runs a team of role sessions on one repository, in parallel, with the lead as the only judge. This note records the decisions that are not obvious from the code, so they are not re-argued.

## Sessions, not subagents, not agent teams

Roles are full background sessions (`claude --agent orchestrator:<role> --bg`), not Agent-tool subagents and not the experimental agent-teams feature. Reasons: a session has its own worktree and survives the lead's process; you can attach to it, read its log, message it; it appears in `claude agents`. Agent teams give none of that (no worktrees, no resume, teammates die with the lead) and change ordinary delegation when enabled. Subagents cannot be attached to and report only to the caller. Workflows are for scripted fan-out where nobody steers mid-run.

## The plan is the contract

`plan.json` holds roles, names, allowed paths, acceptance, dependencies and budgets. The guard reads the same file the brief was rendered from, so what the session was told and what it is allowed to do never diverge. Waves fall out of `dependsOn`; parallelism is the default and path disjointness inside a wave is validated at `orch plan`, then enforced per call by the guard.

## Enforcement is mechanical, judgement is not

Three brakes are hooks, not prose: path ownership, a danger list for Bash, and a tool-call budget. Prose is ignored under pressure; a hook is not. Pause is a file, so the lead or a human in any terminal can stop a session without knowing its process. Everything that requires judgement (is the work correct, is coverage enough, should this merge) stays with the lead, which re-runs checks itself; QA and the reviewer propose. This matches the rule in many users' instruction layers that verification is never delegated, and it is the right split regardless: a verdict from the party that produced the work is not evidence.

## Peer messaging with an escalation ceiling

Roles message each other directly because a developer waiting on the lead to relay a spec question wastes a wave. The ceiling of two rounds before `ESCALATION:` bounds the cost of a disagreement and keeps the lead as the tie-breaker rather than a router.

## Portability constraints

- bash 3.2 (macOS default) and `jq`; no Python, node or bun assumed.
- No dependency on the host's `CLAUDE.md`, skills or plugins; the designer's guidance is inlined and design skills are used only when present.
- Hooks are inert outside a run: they resolve the session id against `sessions.json` and exit 0 when it is absent, so enabling the plugin costs nothing in unrelated sessions.
- The Concise output style is built in everywhere, so pinning it via `--settings` is safe on any machine.
- `env -u CLAUDE_CODE_CHILD_SESSION` on every launch: harmless where the marker is absent, and it prevents an inherited marker from silencing transcripts where it is present.

## Known gaps

- Quota exhaustion on the lead's model is not detected; fallback chains cover overload only.
- Drift that stays inside allowed paths and under budget is caught only by the lead reading handoffs and diffs.
- `orch status` joins on the short session id from `claude agents --json`; if the supervisor forgets a session the row shows `-` and the lead should `claude attach` to check.
