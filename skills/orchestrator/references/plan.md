# plan.json — the run's task graph

Written by the orchestrator with `orch plan`, read by `orch spawn` and the guard. One file per run at `<repo>/.orchestrator/<run>/plan.json`. `orch plan` fills `run`, `orchestrator`, `createdAt` and `baseBranch` from `orch init`, and keeps the stored `authorize`, `review`, `interactive` and `acceptance` (it warns when the file's differ; they are set with their own commands).

The smallest graph `orch plan` accepts for a change to code — architect first, spec, acceptance tests, one developer with its reviewer, the merge, the verdict:

```json
{
  "goal": "Verbatim user goal: add dark mode to Settings.",
  "tasks": [
    {
      "id": "arch", "role": "architect", "phase": "design", "name": "dm-arch",
      "goal": "Check the map against the code, bring it up to date, then design the change in docs/architecture/decisions/dark-mode.md.",
      "pathsAllowed": ["docs/architecture/**"],
      "acceptance": ["orch architecture --check passes on the committed map"]
    },
    {
      "id": "spec", "role": "analyst", "name": "dm-spec",
      "goal": "Write docs/specs/dark-mode.md: scope, acceptance criteria, out of scope, open questions.",
      "pathsAllowed": ["docs/specs/**"],
      "acceptance": ["Every acceptance criterion is testable", "Open questions list is empty or each has an owner"],
      "dependsOn": ["arch"]
    },
    {
      "id": "acc-author", "role": "qa-lead", "phase": "author", "name": "dm-acc",
      "goal": "One acceptance test per criterion of docs/specs/dark-mode.md, red on the base branch.",
      "pathsAllowed": ["e2e/dark-mode/**"],
      "dependsOn": ["spec"]
    },
    {
      "id": "toggle", "role": "developer", "name": "dm-toggle",
      "goal": "Implement the Settings toggle per the spec.",
      "pathsAllowed": ["packages/ui/src/settings/**", "packages/ui/test/settings/**"],
      "acceptance": ["Toggle renders", "Preference persists across reload", "Tests B/R/G shown in handoff"],
      "dependsOn": ["spec", "acc-author"]
    },
    {
      "id": "rev-toggle", "role": "reviewer", "reviewOf": "toggle", "name": "dm-rev",
      "goal": "Review dm-toggle's branch against the spec.",
      "dependsOn": ["toggle"]
    },
    {
      "id": "merge", "role": "integrator", "name": "dm-int",
      "goal": "Merge dm-arch and dm-toggle into the base branch in dependency order; suite green after each merge.",
      "pathsAllowed": ["**"],
      "dependsOn": ["arch", "toggle"]
    },
    {
      "id": "acc-accept", "role": "qa-lead", "phase": "accept", "name": "dm-verdict",
      "goal": "Run the acceptance suite on the merged base branch three times and propose the verdict.",
      "pathsAllowed": ["e2e/dark-mode/**"],
      "dependsOn": ["merge"]
    }
  ]
}
```

Task fields:

| Field | Meaning |
|---|---|
| `id` | stable task id, used in `dependsOn` and the covering fields below |
| `role` | one of `architect`, `analyst`, `researcher`, `designer`, `developer`, `qa`, `qa-lead`, `reviewer`, `design-reviewer`, `integrator`. A `tester` task from an older plan is rewritten to `qa` with `qaOf` = its `verifies`, and `orch plan` says so |
| `name` | the session's team name (`--name`): starts with a letter or digit, then letters, digits, hyphens; unique within the run and not reused from an earlier run on this machine, whose Remote Control mirrors keep the name |
| `goal` | one paragraph, verbatim into the brief |
| `pathsAllowed` | globs relative to the worktree root; `*` matches across `/`; the guard blocks edits elsewhere. Only the reviewer, qa and the design-reviewer may own none. Two tasks that can be live together (neither depends on the other, directly or not; same stage) must not share a path: `orch plan` refuses globs whose literal parts overlap. A developer's paths never meet a qa task's or the qa-lead author's: those are tests it must not edit. The integrator (`**`) and the architect's design task are exempt |
| `acceptance` | what the orchestrator will check itself before accepting |
| `dependsOn` | ids whose handoffs are pasted into this task's brief, each with its worktree, branch and head; a task is ready when all are done (see Acceptance) |
| `budget` | guarded tool calls (Bash, Monitor, Edit, Write, every MCP tool) before the guard stops the session; the brake against drift. Left out, `orch plan` sets the role's default: developer 120, qa 60, reviewer 30, design-reviewer 25, integrator 50, analyst 50, researcher 70, designer 70, qa-lead 80 to author and 40 to accept, the architect from the size of its job (`orch architecture` prints it). Set it only when the work is clearly bigger or smaller: a budget several times what the work needs lets drift run that far |
| `model`, `effort` | optional per-task overrides; default `opus` / `high` |
| `mcp` | the MCP servers the session may start on demand: names from the scopes `orch tools` lists (local, the repository's `.mcp.json`, user); default the repository's `.mcp.json` only — user and local servers carry personal credentials and must be named; `[]` none; `"inherit"` starts the machine's full set at launch. The session itself launches with an empty `--mcp-config <run dir>/mcp/<name>.json` and `--strict-mcp-config`, and gets one helper agent per server through `--agents` that carries the server inline |
| `phase` | architect: `design` (the map checked and brought up to date, then the change's design; depends on nothing, first stage of a staged plan; a plan with a developer task needs one, and every other task waits until it is accepted) or `update` (the map after the merge). `orch plan` adds `docs/architecture/**` and `.claude/rules/architecture/**` to every architect task's paths. qa-lead: `author` (acceptance tests after the spec) or `accept` (after every developer task) |
| `reviewOf` | reviewer: the developer task whose branch it reviews. Every developer task needs one, except a `chore` |
| `qaOf` | qa: the developer task whose TDD cases it writes and whose result it audits. Optional per developer task, except with `interactive: true`, where every developer task that is not a `chore` needs one, and that qa also runs the app. A developer adds one itself with `orch qa-request` |
| `designOf` | design-reviewer: the developer task whose implementation is checked against the design. `orch plan` requires one for every developer task that depends, directly or not, on a designer task |
| `chore` | developer only, `true`: a small change the lead reviews itself — no reviewer or qa task required, and `orch accept` requires a note naming the diff read |
| `resources` | what the task holds that no task live beside it may use, as `kind:name` (`port:8000`, `compose:web`); checked like paths within the run, and against live sessions of other open runs at plan and spawn |
| `stage` | staged plans: the stage this task belongs to, one of the plan's `stages`; no task depends on a later stage |

Plan fields besides `tasks`:

| Field | Meaning |
|---|---|
| `goal` | the user's goal, verbatim |
| `mode`, `stages` | `"staged"` with an ordered `stages` list (`["architecture", "spec", "build-1", …]`): `orch ready` holds every task of a stage until `orch approve <run> <stage> "<the user's words>"` has recorded all earlier ones in `approved.json`; `orch approve <run> --rest "<words>"` lifts staging for the rest. Default `"single"` |
| `setup` | shell commands run in every new worktree right after orch makes it, before its session starts (install dependencies, copy an env file); outside the budget, logged |
| `maxParallel` | how many sessions of the run `orch spawn --wave` lets work at once; the rest wait for the next `--wave` |
| `maxLoad` | load average per CPU above which `orch spawn` warns before launching |
| `review` | `{"venue": "branch" \| "pr", "maxRounds": 3}` — `orch review <run> venue …`, `orch review <run> rounds <n>` |
| `interactive` | `orch interactive <run> on\|off`, see below |
| `acceptance` | `orch acceptance <run> on\|off`, see below |
| `authorize` | `orch authorize <run> …`, see below |

## Review rounds

Review runs in rounds: the orchestrator re-spawns the same review task with `orch spawn <run> <id> --round N`, which gives the session the name `<name>-r<N>` and a brief telling it to re-read the whole diff and answer its earlier findings; a developer's round-N brief carries the latest findings of its reviewer, design-reviewer and qa. `--round` refuses to go past `maxRounds`. `venue: "pr"` means every session that changed code opens a pull or merge request and reviewers comment in threads on it; `branch` means the reviewer reads `git diff <base>...HEAD` in the target's worktree and files findings through the orchestrator.

Rules of thumb: a wave is the set of ready tasks; spawn them together, one session each. A qa task depends on the spec, not on its developer: it writes the cases in the developer's wave, before the code, and audits after the developer's `done`. The reviewer depends on the developer task it reviews. The integrator's task depends on every task whose branch it merges; a run may have several integrator tasks, one per batch of accepted branches, merging as the run goes. The reviewer reads a branch and edits nothing except its handoff, so its `pathsAllowed` is `[]`.

## Acceptance testing

`"acceptance": true` (the default; `orch acceptance <run> off` drops it) makes `orch plan` require a qa-lead `author` task and an `accept` task that comes after every developer task, directly or through the integrator.

## Authorizations

`plan.json` carries the user's standing answers for the whole run, collected once at plan approval and never asked again:

```json
"authorize": { "pushBase": false, "deleteMerged": false, "tag": false, "installTools": false, "mutateData": false }
```

The lead writes them with `orch authorize <run> push-base|delete-merged|tag|install-tools|mutate-data on|off`, `orch plan` preserves them, and `scripts/guard.sh` reads them: with `pushBase` the integrator pushes the base branch (and merges pull requests), with `deleteMerged` it deletes merged branches and worktrees. No other role gains anything from either flag. `installTools` lets a session install the verification tooling `orch tools` lists as missing; the guard blocks package installs otherwise. `mutateData` reaches qa through its brief: creating or changing data in development databases and services.

## Interactive verification

`"interactive": true` (set with `orch interactive <run> on`) means a qa task with `qaOf` covers every developer task that is not a `chore`, and its brief adds running the application from the branch: it drives every acceptance criterion the way a user would and hands over evidence per criterion. `orch tools` lists the machine's means.

## Editing the plan mid-run

A session's paths and budget are copied from the plan into `sessions.json` at spawn, and the guard reads that copy, so a hand edit of `plan.json` never reaches a live session. `orch task add <run> <file|->`, `orch task set <run> <task> <field> <json>` and `orch task patch <run> <file>` (`{"<task>": {"<field>": <json>}}`) run the same validation as `orch plan` against the stored plan; `budget` and `pathsAllowed` changes reach the live record too, as do `orch paths <run> <task> add <glob>…` and `orch budget <run> <task> <n|+n>` (the first budget stays as `budgetInitial`). `orch plan` itself refuses once sessions are registered, unless `--replan`, which carries changed budgets and paths into them. `orch cancel <run> <task> "<why>"` (undo with `--undo`) drops a task: `cancelled.json` keeps it out of `orch ready` and settles it for `orch close`; its dependents stay blocked until re-planned.

## Acceptance

`accepted.json` beside the plan holds the lead's verdicts (`orch accept <run> <task> "<note>"`), each with the head of the task's branch; `orch status` flags an accepted task whose branch moved since. `orch accept` refuses, unless `--force` (the note then says so), a task never spawned, a cancelled one, one whose handoff is `none`, `partial` or `blocked`, and one whose branch changed files outside its `pathsAllowed` (it names them). An architect task is accepted only when `orch architecture --check` passes in its worktree on a committed map. A chore needs a note whatever the flags.

A task counts as done when it is accepted **or** its latest handoff says `done`, so a teammate that finished the work but reported `blocked` on something the lead has since resolved does not stall its dependents, and nobody edits a handoff to change its status. The status is the first word under `## Status`: `blocked — waiting until dev-1 is done` is blocked. A **developer** task's own `done` opens the door only to the roles that verify it — reviewer, qa, design-reviewer; everything that builds on the code (the integrator, a later developer task) becomes ready only after `orch accept`, so findings can actually hold a merge back. A reviewer, qa or design-reviewer task is settled once the task it covers is accepted.
