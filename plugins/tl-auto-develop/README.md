# tl-auto-develop

Autonomous .NET development pipeline plugin for Claude Code.

## Skills

- **`/develop`** — Interactive single-task pipeline (plan, implement, preflight, review) with user confirmations
- **`/develop-batch`** — Interactive parallel batch processing via git worktrees
- **`/TLA-develop`** — Fully autonomous single-task pipeline, no confirmations
- **`/TLA-develop-batch`** — Fully autonomous parallel batch, end-to-end automated

## Agents

- **reviewer** — Read-only code reviewer for .NET/WPF/Core.UI. Outputs `ACCEPTED` or `DENIED` with structured feedback. Reviews architecture, Core.UI patterns, code quality, German comments, security, and correctness.

## Scripts

- **auto-develop.ps1** — Main pipeline orchestrator. Manages git worktrees, invokes Claude for plan/implement/review phases, runs preflight checks, handles retry loops.
- **preflight.ps1** — Deterministic validation: build check, forbidden comments, stub detection, class-per-file rule, NuGet audit, and various warnings.

## Requirements

- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI
