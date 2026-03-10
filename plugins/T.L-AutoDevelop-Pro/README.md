# T.L-AutoDevelop-Pro

Autonomous addon for [T.L-AutoDevelop](../T.L-AutoDevelop/). Zero confirmations — auto-commits on success without user input.

**Requires T.L-AutoDevelop** (all engine scripts and agents live there).

## Skills

- **`/TLA-develop`** — Fully autonomous single-task pipeline. No user input after launch, auto-commits on success.
- **`/TLA-develop-batch`** — Fully autonomous parallel batch pipeline. No user input, auto-commits all accepted tasks.

## Differences from T.L-AutoDevelop

| Feature | T.L-AutoDevelop | T.L-AutoDevelop-Pro |
|---------|-----------------|---------------------|
| Pipeline engine | Included | Uses T.L-AutoDevelop's |
| Reviewer agent | Included | Uses T.L-AutoDevelop's |
| Commit on ACCEPTED | Asks user first | Auto-commits |
| User confirmations | Yes | None |

## Requirements

- **T.L-AutoDevelop** plugin installed
- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI
