# T.L-AutoDevelop

Interactive .NET development pipeline plugin for Claude Code with discovery-first routing, explicit investigation, optional test-backed bug reproduction, and no-op handling.

## Skills

- **`/develop`** — Interactive single-task pipeline (discover, investigate, optional reproduce, fix-plan, implement, preflight, review) with user confirmations
- **`/develop-batch`** — Interactive batch processing via git worktrees with read-only task scheduling, statusline-aware 5h launch gating, conservative parallel waves, and per-commit confirmations

## Agents

- **reviewer** — Read-only code reviewer for .NET/WPF/Core.UI. Outputs `ACCEPTED` or `DENIED` with structured feedback. Reviews architecture, Core.UI patterns, code quality, German comments, security, and correctness.

## Scripts

- **auto-develop.ps1** — Main pipeline orchestrator. Manages git worktrees, persists per-run artifacts, performs discovery-first routing, investigates before optional test-backed bug reproduction, validates fix plans semantically with repair loops, classifies no-op outcomes, and performs targeted verification, preflight, and review remediation.
- **claude-usage-gate.ps1** — Shared helper for batch launchers. Probes the local Claude statusline / usage cache, trusts env-expanded commands that resolve into the main Claude folder, falls back to `%USERPROFILE%\\.claude\\statusline.ps1` when present, and emits JSON even for handled unavailable states.
- **preflight.ps1** — Deterministic validation: build check, forbidden comments, stub detection, class-per-file rule, NuGet audit, and various warnings.

## Runtime Output

Each run writes artifacts under `.claude-develop-logs/runs/<taskName>/` and returns structured result fields such as:

- `finalCategory`
- `summary`
- `attemptsByPhase`
- `artifacts.runDir`
- `artifacts.debugDir`
- `discoverConclusion`
- `route`
- `testability`
- `testProjects`
- `investigationConclusion`
- `reproductionAttempted`
- `reproductionConfirmed`
- `reproductionTests`
- `targetedVerificationPassed`
- `noChangeReason`

In addition, the pipeline now mirrors low-level diagnostics into `%TEMP%\claude-develop\debug\<runId>\`, including full Claude prompt/output captures, per-phase metadata, and detailed preflight build/test/run logs.

## Model Policy

- `DISCOVER`, `INVESTIGATE`, and `REVIEW` stay on Opus by default unless routing is obviously low-risk
- `FIX_PLAN` may drop to Sonnet for direct edits or already-concrete targets
- `IMPLEMENT` and narrow repair loops may use Sonnet only when file targets are concrete and the step is low-complexity

## Requirements

- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI
