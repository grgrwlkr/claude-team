# Claude team plugin — shared development guidance

<!-- shared-instruction-standard:start -->
## Shared agent instructions

`AGENTS.md` is the project instruction source for every agent. `CLAUDE.md`, when
present, contains only `@AGENTS.md`. Maintain project skills in `.agents/skills/`;
client folders may contain operational adapters, not separate copies of rules or skills.
Read applicable nested `AGENTS.md` and the references named by this file. Shared
references remain authoritative regardless of a `.codex/` directory name. Use the
current client's real tools; this convention grants no publication, deployment,
credential access or permission beyond the user's authorized task.
<!-- shared-instruction-standard:end -->

Read the committed README.md, docs/design.md and affected scripts before changing this plugin. Its orch launcher, hooks and state formats are product contracts for Claude; shared agent instructions do not change that backend.

Use native collaboration tools of the current client for work on this repository. Do not invoke orch to launch Codex agents. Validate affected code with the existing tests/guard.test.sh and tests/orch.test.sh after inspecting the harness. Preserve other work. Publication, spawning external sessions and destructive changes need applicable explicit user authorization.
