---
name: codex-orchestrator
description: "Coordinate an explicitly requested Codex team while preserving the separate Claude product runtime."
---

# Native team work in this repository

Use the current client's native collaboration tools for an explicitly requested team. The project's `orch`, `skills/orchestrator/`, Claude hooks and product agents are a separate shipped runtime; do not launch Codex through them or translate their API names into guessed calls.

AGENTS.md owns authorization, briefing and final acceptance. Map independent outcomes, dependencies, owned paths and evidence. Local role definitions, when actually registered by the client, are researcher, analyst, architect, designer, design-reviewer, developer, reviewer, qa, qa-lead and integrator under `.codex/agents/`. Inspect the exposed roles and their actual model/effort settings; filenames do not establish registration. Use an available configured role that fits the task rather than inventing one.

Prepare necessary worktree isolation explicitly and preserve other work. Dispatch ready tasks, resolve conflicting ownership and wait for required evidence. Short handoffs may be inline; substantial evidence goes to the assigned path. Keep instructions/editorial changes with the lead.

## Verification

The lead checks final scope, artifacts and consequential or disputed findings, runs relevant checks and accepts the integrated result. A team grants no extra Git, messaging, external-session or cleanup authority. Before separately authorized cleanup, verify cleanliness, containment and live ownership.
