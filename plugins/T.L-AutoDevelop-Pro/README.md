# T.L-AutoDevelop-Pro

Autonomous addon for [T.L-AutoDevelop](../T.L-AutoDevelop/). Zero confirmations — auto-commits on success without user input.

**Requires T.L-AutoDevelop** (all engine scripts and agents live there).

## Skills

- **`/TLA-develop`** — Fully autonomous scheduler-managed single-task pipeline with read-only planning, queueing, and wave-safe auto-commit.
- **`/TLA-develop-batch`** — Fully autonomous batched pipeline with read-only task scheduling, statusline-aware 5h launch gating, and conservative parallel waves. Auto-commits all accepted tasks, with at most one preflight question if both usage sources are unavailable.

## Differences from T.L-AutoDevelop

| Feature | T.L-AutoDevelop | T.L-AutoDevelop-Pro |
|---------|-----------------|---------------------|
| Pipeline engine | Included | Uses T.L-AutoDevelop's |
| Reviewer agent | Included | Uses T.L-AutoDevelop's |
| Commit on ACCEPTED | Asks user first | Auto-commits |
| User confirmations | Yes | None |
| Investigation / no-op logic | Included | Uses T.L-AutoDevelop's |

## Requirements

- **T.L-AutoDevelop** plugin installed
- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI
