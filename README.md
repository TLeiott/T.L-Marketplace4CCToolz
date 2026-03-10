# T.L Marketplace for Claude Code Tools

A Claude Code plugin marketplace providing .NET development pipeline tools.

## What's Included

### tl-auto-develop (v2.0.0) — Interactive

An interactive development pipeline that orchestrates Claude Code through plan, implement, preflight-check, and code-review stages — with user confirmations before each commit.

| Command | Description |
|---------|-------------|
| `/develop [task]` | Single task with user confirmations before commit |
| `/develop-batch [tasks.md]` | Parallel batch via git worktrees, confirms each commit |

### tl-auto-develop-pro (v2.0.0) — Autonomous

A fully autonomous development pipeline — zero confirmations. Runs plan, implement, preflight, review, and commit end-to-end unattended.

| Command | Description |
|---------|-------------|
| `/TLA-develop [task]` | Single task, zero confirmations, auto-commit |
| `/TLA-develop-batch [tasks.md]` | Parallel batch, fully automated end-to-end |

**Pipeline Flow:**
```
Plan (read-only) -> Implement (write) -> Preflight (build + lint) -> Review (LLM judge) -> Retry or Accept
```

## Prerequisites

- **Windows** (PowerShell 5.1+)
- **.NET SDK** (for `dotnet build`)
- **Git** (with worktree support)
- **Claude CLI** installed and authenticated

## Installation

Add this marketplace to Claude Code:

```
/plugin marketplace add TLeiott/T.L-Marketplace4CCToolz
```

Then install the plugin(s) you want:

```
/plugin install tl-auto-develop
```

```
/plugin install tl-auto-develop-pro
```

## Configuration

Constants in `auto-develop.ps1`:

| Constant | Default | Description |
|----------|---------|-------------|
| `CONST_MODEL_PLAN` | `claude-opus-4-6` | Model for planning phase |
| `CONST_MODEL_IMPLEMENT` | `claude-opus-4-6` | Model for implementation |
| `CONST_MODEL_REVIEW` | `claude-opus-4-6` | Model for code review |
| `CONST_MAX_RETRIES` | `10` | Max retry attempts |
| `CONST_TIMEOUT_SECONDS` | `900` | Timeout per phase (15 min) |

## Language

All prompts, comments, and output are in **German (Deutsch)**. The pipeline is designed for .NET/WPF/Core.UI projects following German coding conventions.

## License

MIT
