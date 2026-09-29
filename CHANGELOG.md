# Changelog

## 0.10.0

Breaking:
- **tester is merged into qa.** A qa task writes the cases before the code, audits the tests, and, when interactive verification is on, runs the app and hands over evidence per criterion. `orch plan` rewrites a `tester` task to `qa` (its `verifies` becomes `qaOf`); a stored plan that still names tester spawns qa.
- **qa is optional.** It is required for every developer task only with `interactive` on. Otherwise the developer asks for it with `orch qa-request <run> <own name> "<what to check>"`, which adds the qa task for the lead to spawn.
- `orch accept` refuses a task never spawned, a cancelled one, one whose handoff is none, partial, blocked or failed, and one whose branch changed files outside its paths, unless `--force` (the reason goes into the note).

Guard:
- Bash writes are judged by their resolved targets: inside the session's own worktree and paths or `.scratch/`, never the main checkout, `$HOME`, `/tmp`, another session's worktree, the run directory or the index. Reads of the run directory pass. A target that cannot be resolved stays a tripwire behind the accept-time diff check.
- Edit and Write are judged by the worktree of the file, through symlinked ancestors; a worktree that cannot be resolved blocks.
- `Monitor` and `Task` go through the guard. An `orchestrator:*` session orch has not registered yet is held.
- Git is judged by its normalised argv in the directory it runs in: `-C`, a leading `cd`, refspec pushes to base, `--all`, `--mirror`, a bare push to base's upstream, `+refspec` and combined `-f` flags, `gh pr merge` and merges through `gh api`, destructive forms with split flags.
- `orch` calls are recognised where they run, behind wrappers too, not in prose; `--help` passes; `orch architecture --sync` is the architect's.
- The install gate reads the whole argv and where a package lands (`--user`, `--prefix`, `--target`, `uv --python`, `npm --prefix`, …).
- `orch handoff-put` reads a handoff only from a file in the own worktree (`< file` or `--file`).
- The budget is counted under a lock; Stop lines no longer count; block lines carry the command; the Stop hook lets a paused session stop; the same command a third time in a row draws one loop reminder.

orch:
- Rounds: a task's latest round's handoff is the one that counts; a developer's round brief carries its reviewers' findings; briefs name target worktrees, branches and heads; the integrator gets the list of branches to merge.
- Plan: overlap between any two tasks that can be live together, test paths kept out of developer paths, cover fields validated, role-aware default budgets, `--replan`, `resources`, cross-run overlap against live sessions, `setup`, `maxParallel`, `maxLoad`, `chore` developer tasks.
- New commands: `orch events --blocks/--new`, `orch runs`, `orch graph`, `orch inbox`, `orch lead-branch`, `orch followups`, `orch freeze`, `orch thaw`, `orch resume-brief`, `orch continue`, `orch task patch`, `orch approve --rest`, `orch budget +N`, `orch decide --for`, `orch handoff-put --file/--by-lead`.
- `orch status` shows per-task calls across rounds and context size; `orch cost` sums every transcript of a session; close writes CLOSED last and checks orch's own branches too; spawn stops a session it could not register.
- The plugin version is recorded at init; spawn and doctor warn when it changed.

Docs: handoff template with `## Follow-ups` and `## Tried and dropped`; developer self-review and a test per criterion; security and break-it lenses for the reviewer; CI, docs sweep and suite health for the integrator; a valid plan example (tested).

## 0.9.0

- **The architect is mandatory in every run with developer tasks.** Its design task depends on nothing, and every other task waits until the lead accepts it. `orch accept` of an architect task runs `orch architecture --check` in its worktree and refuses a map that fails or is not committed.
- `docs/architecture/modules.json` indexes the map; `orch architecture --sync` generates `.claude/rules/architecture/<module>.md`, path-scoped rules Claude Code loads when a session opens a module's file; `--check` compares the map with the tree (coverage, dead paths, changes since built-at, rules in sync).
- `orch architecture` reads the worktree it runs in; briefs point at the map in the architect's worktree and name only the modules a task touches.
