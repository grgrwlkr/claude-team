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
| `role` | one of `analyst`, `developer`, `designer`, `qa`, `reviewer`, `integrator`, `researcher` |
| `name` | the session's team name (`--name`); unique within the run; letters, digits, hyphens |
| `goal` | one paragraph, verbatim into the brief |
| `pathsAllowed` | globs relative to the worktree root; `*` matches across `/`; the guard blocks edits elsewhere. Two tasks never share a path in the same wave |
| `acceptance` | what the orchestrator will check itself before accepting |
| `dependsOn` | ids whose handoffs are pasted into this task's brief; a task is ready when all are `done` |
| `budget` | tool calls allowed for Bash/Edit/Write before the guard stops the session; the brake against drift |
| `model`, `effort` | optional per-task overrides; default `opus` / `high` |

Rules of thumb: a wave is the set of ready tasks; spawn them together, one session each. The integrator's task depends on every task whose branch it merges. QA's task depends on the developer's task it tests, never runs in the same wave on the same paths. The reviewer reads a branch and edits nothing except its handoff, so its `pathsAllowed` is `[]`.
