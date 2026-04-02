# T.L-AutoDevelop

Interactive queue-aware .NET development orchestration for Claude Code.

## Command

- `/develop [task text or path-to-task-file]`
- `/develop-prepare`
- `/pipe-feedback [optional: path-to-run-dir or task-id]`
- `/autodev-config [show|set|init-example|validate]`
- `/autodev-session [show|use <profile>|clear]`

## What V4 Does

- keeps a shared repo-scoped queue of running, queued, retryable, and pending-merge tasks
- adds a prepare pass that reconciles queue state and cleans safe AutoDevelop-owned leftovers before new sessions
- accepts either a direct task text or a file containing multiple tasks
- uses the config-driven `scheduler` role to plan conservative execution waves
- reads repo-local execution profile config from `.claude/autodevelop.json`
- resolves the active session execution profile from `.claude-develop-logs/session.json` or the repo default
- resolves worker, reviewer, and scheduler runtime settings per role from shipped CLI profiles plus repo execution profiles
- aggregates usage checks across all active CLI/provider/model-class combinations
- starts multiple worker pipes asynchronously when their likely edit scopes are disjoint
- lets `scheduler.ps1` wait for queue changes after launches instead of relying on external sleep-based polling
- leaves successful worker changes on normal branches for later merge preparation
- prepares merges with normal merge semantics instead of squash
- requires explicit user testing and confirmation before committing interactive merges

## Included Components

- `skills/develop/SKILL.md` — Main-Claude interactive orchestrator
- `skills/develop-prepare/SKILL.md` — Explicit prepare and hygiene command
- `skills/pipe-feedback/SKILL.md` — Post-run pipeline feedback and friction analysis
- `skills/autodev-config/SKILL.md` — Repo-local AutoDevelop config inspector/editor
- `skills/autodev-session/SKILL.md` — Session-local execution profile selector
- `agents/scheduler-agent.md` — Scheduler prompt template body
- `agents/reviewer.md` — Reviewer prompt template body
- `scripts/scheduler.ps1` — Durable repo-local queue engine
- `scripts/auto-develop.ps1` — Worker pipeline engine
- `scripts/planner-runner.ps1` — Config-driven scheduler role runner
- `scripts/autodevelop-config.ps1` — Shared AutoDevelop config and role resolution helpers
- `scripts/autodevelop-role-runner.ps1` — Shared CLI-family role runner
- `scripts/autodevelop-session.ps1` — Session-local execution profile state helper
- `scripts/autodevelop-usage-gate.ps1` — Aggregated usage gate for all active CLI/profile/model combinations
- `scripts/cli-profiles/*.json` — Shipped supported CLI profile manifests
- `scripts/providers/*.ps1` — CLI-family adapters
- `scripts/claude-usage-gate.ps1` — 5h usage probe helper
- `scripts/preflight.ps1` — Deterministic validation checks

## Runtime Notes

- Scheduler state lives under `.claude-develop-logs/scheduler/`
- Worker run artifacts still live under `.claude-develop-logs/runs/<task>/`
- Each task gets up to 3 full attempts
- Queue replanning happens after submissions, completions, retries, and merge resolutions

## Requirements

- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI

## Repo Config

- AutoDevelop reads optional repo-local config from `.claude/autodevelop.json`
- missing config falls back to built-in defaults
- plugin updates do not overwrite repo config
- config version `4` defines repo-local `executionProfiles`
- shipped `cliProfile` manifests define which CLIs, providers, model classes, options, and usage probes are supported by this plugin build
- an execution profile selects `cliProfile`, `provider`, `modelClass`, and options per role
- a session-local selection in `.claude-develop-logs/session.json` can activate a different execution profile for the current Claude conversation
- if no session profile is active, AutoDevelop uses `defaultExecutionProfile`
- an explicit role `modelClass` pins that role to the configured model class
- if a role omits `modelClass`, the built-in default or runtime override can still decide the effective model token
- invalid config values fall back to built-in defaults with warnings instead of crashing the pipeline
- unsupported CLI profiles are rejected; only shipped supported profiles may be used
