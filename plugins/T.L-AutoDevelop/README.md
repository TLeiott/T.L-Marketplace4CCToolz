# T.L-AutoDevelop

Interactive .NET development pipeline plugin for Claude Code with explicit investigation and no-op handling.

## Skills

- **`/develop`** — Interactive single-task pipeline (plan, validate, investigate, implement, preflight, review) with user confirmations
- **`/develop-batch`** — Interactive batch processing via git worktrees with capped parallelism and per-commit confirmations

## Agents

- **reviewer** — Read-only code reviewer for .NET/WPF/Core.UI. Outputs `ACCEPTED` or `DENIED` with structured feedback. Reviews architecture, Core.UI patterns, code quality, German comments, security, and correctness.

## Scripts

- **auto-develop.ps1** — Main pipeline orchestrator. Manages git worktrees, persists per-run artifacts, validates plans semantically, runs investigation before implementation when needed, classifies no-op outcomes, and performs preflight/review remediation.
- **preflight.ps1** — Deterministic validation: build check, forbidden comments, stub detection, class-per-file rule, NuGet audit, and various warnings.

## Runtime Output

Each run writes artifacts under `.claude-develop-logs/runs/<taskName>/` and returns structured result fields such as:

- `finalCategory`
- `summary`
- `attemptsByPhase`
- `artifacts.runDir`
- `investigationConclusion`
- `noChangeReason`

## Requirements

- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI
