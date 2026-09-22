# plan.json — the run's task graph

Written by the orchestrator with `orch plan`, read by `orch spawn` and the guard. One file per run at `<repo>/.orchestrator/<run>/plan.json`.

```json
{
  "run": "dark-mode",
  "goal": "Verbatim user goal.",
  "baseBranch": "main",
  "createdAt": "2026-09-15T02:40:00+03:00",
  "tasks": [
    {
      "id": "spec",
      "role": "analyst",
      "name": "analyst-spec",
      "goal": "Write docs/specs/dark-mode.md: scope, acceptance criteria, out of scope, open questions.",
      "pathsAllowed": ["docs/specs/**"],
      "acceptance": ["Every acceptance criterion is testable", "Open questions list is empty or each has an owner"],
      "dependsOn": [],
      "budget": 120
    },
    {
      "id": "impl-toggle",
      "role": "developer",
      "name": "dev-toggle",
      "goal": "Implement the Settings toggle per the spec.",
      "pathsAllowed": ["packages/ui/src/settings/**", "packages/ui/test/settings/**"],
      "acceptance": ["Toggle renders", "Preference persists across reload", "Tests B/R/G shown in handoff"],
      "dependsOn": ["spec"],
      "budget": 250
    }
  ]
}
```

Fields:

| Field | Meaning |
|---|---|
| `id` | stable task id, used in `dependsOn` |
| `role` | one of `analyst`, `developer`, `designer`, `qa`, `tester`, `reviewer`, `integrator`, `researcher` |
| `name` | the session's team name (`--name`); unique within the run and not reused from an earlier run on this machine, whose Remote Control mirrors keep the name; letters, digits, hyphens |
| `goal` | one paragraph, verbatim into the brief |
| `pathsAllowed` | globs relative to the worktree root; `*` matches across `/`; the guard blocks edits elsewhere. Two tasks never share a path in the same wave |
| `acceptance` | what the orchestrator will check itself before accepting |
| `dependsOn` | ids whose handoffs are pasted into this task's brief; a task is ready when all are `done` |
| `budget` | guarded tool calls (Bash, Edit, Write, every MCP tool) before the guard stops the session; the brake against drift. `orch spawn … --budget <n>` overrides it for one session, typically a later review round; `orch budget <run> <task-id|name> <n>` changes it for a live one |
| `model`, `effort` | optional per-task overrides; default `opus` / `high` |
| `mcp` | the MCP servers the session starts: names from the scopes `orch tools` lists (local, the repository's `.mcp.json`, user), or `"inherit"` for the machine's full set. Default: a tester gets the repository's `.mcp.json`, every other role none. Launched with `--mcp-config <run dir>/mcp/<name>.json --strict-mcp-config` |
| `verifies` | tester tasks only: the id of the developer task whose build this interactive run checks. Required for every developer task when the plan has `interactive: true` |
| `reviewOf` | reviewer tasks only: the id of the task whose code this review covers. `orch plan` refuses a graph where a developer task has no reviewer |

Every developer task must be covered by a reviewer task (`reviewOf`), and review runs in rounds: the orchestrator re-spawns the same review task with `orch spawn <run> <id> --round N`, which gives the session the name `<name>-r<N>` and a brief telling it to re-read the whole diff and answer its earlier findings. The venue and the round cap live in the plan:

```json
"review": { "venue": "branch", "maxRounds": 3 }
```

`venue: "pr"` means every session that changed code opens a pull or merge request and reviewers comment in threads on it; `branch` means the reviewer reads `git diff <base>...HEAD` and files findings through the orchestrator. Set both with `orch review <run> venue <branch|pr>` and `orch review <run> rounds <n>`.

Rules of thumb: a wave is the set of ready tasks; spawn them together, one session each. The integrator's task depends on every task whose branch it merges. QA's task depends on the developer's task it tests, never runs in the same wave on the same paths. The reviewer reads a branch and edits nothing except its handoff, so its `pathsAllowed` is `[]`.

## Authorizations

`plan.json` carries the user's standing answers for the whole run, collected once at plan approval and never asked again:

```json
"authorize": { "pushBase": false, "deleteMerged": false, "tag": false, "installTools": false, "mutateData": false }
```

The lead writes them with `orch authorize <run> push-base|delete-merged|tag on|off`, `orch plan` preserves them, and `scripts/guard.sh` reads them: with `pushBase` the integrator pushes the base branch, with `deleteMerged` it deletes merged branches and worktrees. No other role gains anything from either flag. `installTools` and `mutateData` (`orch authorize <run> mutate-data on`) reach the tester through its brief: installing the verification tooling, and creating or changing data in development databases and services.

## Interactive verification

`"interactive": true` (set with `orch interactive <run> on`) means a `tester` task with `verifies` covers every developer task: it starts the application from the branch, drives every acceptance criterion the way a user would, and hands over evidence per criterion. `orch tools` lists the machine's means; the tester installs nothing unless `authorize.installTools` is on (`orch authorize <run> install-tools on`), and the guard blocks package installs otherwise.

## Editing the plan mid-run

A session's paths and budget are copied from the plan into `sessions.json` at spawn, and the guard reads that copy, so a hand edit of `plan.json` never reaches a live session. `orch task add <run> <file|->` and `orch task set <run> <task> <field> <json>` run the same validation as `orch plan` against the stored plan; `task set` of `budget` or `pathsAllowed`, `orch paths <run> <task> add <glob>…` and `orch budget` also update the live record. `orch cancel <run> <task> "<why>"` (undo with `--undo`) drops a task: `cancelled.json` keeps it out of `orch ready` and settles it for `orch close`; its dependents stay blocked until re-planned.

## Acceptance

`accepted.json` beside the plan holds the lead's verdicts (`orch accept <run> <task-id> "<note>"`). A task counts as done when it is accepted **or** its handoff says `done`, so a teammate that finished the work but reported `blocked` on something the lead has since resolved does not stall its dependents, and nobody edits a handoff to change its status.

Two refinements. The handoff's status is the first word under `## Status`, not a word found somewhere in it: `blocked — waiting until dev-1 is done` is blocked. And a **developer** task's own `done` opens the door only to the roles that verify it — reviewer, tester, QA; everything that builds on the code (the integrator, a later developer task) becomes ready only after `orch accept`, so review findings can actually hold a merge back.
