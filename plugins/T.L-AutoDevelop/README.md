# T.L-AutoDevelop

Interactive queue-aware .NET development orchestration for Claude Code.

## Command

- `/develop [task text or path-to-task-file]`

## What V4 Does

- keeps a shared repo-scoped queue of running, queued, retryable, and pending-merge tasks
- accepts either a direct task text or a file containing multiple tasks
- uses the read-only `scheduler-agent` to plan conservative execution waves
- starts multiple worker pipes asynchronously when their likely edit scopes are disjoint
- leaves successful worker changes on normal branches for later merge preparation
- prepares merges with normal merge semantics instead of squash
- requires explicit user testing and confirmation before committing interactive merges

## Included Components

- `skills/develop/SKILL.md` — Main-Claude interactive orchestrator
- `agents/scheduler-agent.md` — Read-only queue planner
- `agents/reviewer.md` — Independent code reviewer
- `scripts/scheduler.ps1` — Durable repo-local queue engine
- `scripts/auto-develop.ps1` — Worker pipeline engine
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
