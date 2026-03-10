# tl-auto-develop-pro

Fully autonomous .NET development pipeline plugin for Claude Code. Zero confirmations — runs plan, implement, preflight, review, and commit end-to-end unattended.

## Skills

- **`/TLA-develop`** — Fully autonomous single-task pipeline. No user input after launch, auto-commits on success.
- **`/TLA-develop-batch`** — Fully autonomous parallel batch pipeline. No user input, auto-commits all accepted tasks.

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
