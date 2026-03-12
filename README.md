# T.L Marketplace for Claude Code Tools

A Claude Code plugin marketplace providing .NET development pipeline tools.

## What's Included

### T.L-AutoDevelop (v2.3.0) — Interactive

An interactive development pipeline that orchestrates Claude Code through plan, semantic plan validation, investigation, implementation, preflight, and review — with user confirmations before each commit.

| Command | Description |
|---------|-------------|
| `/develop [task]` | Single task with user confirmations before commit |
| `/develop-batch [tasks.md]` | Batched git-worktree pipeline with capped parallelism, confirms each commit |

### T.L-AutoDevelop-Pro (v2.3.0) — Autonomous

A fully autonomous development pipeline — zero confirmations. Runs plan, investigation, implement, preflight, review, and commit end-to-end unattended.

| Command | Description |
|---------|-------------|
| `/TLA-develop [task]` | Single task, zero confirmations, auto-commit |
| `/TLA-develop-batch [tasks.md]` | Batched pipeline with capped parallelism, fully automated end-to-end |

**Pipeline Flow:**
```
Plan -> Plan Validate -> Investigate -> Implement -> Change Validate -> Preflight -> Review
```

**New runtime behavior:**
- Explicit no-op categories instead of generic `IMPL_FAIL`
- Per-run artifacts under `.claude-develop-logs/runs/<taskName>/`
- Per-run temp debug bundles under `%TEMP%\claude-develop\debug\<runId>\`
- Investigation phase for ambiguous or diagnostic tasks
- Semantic plan validation that rejects placeholder/template plans
- Batch launchers should cap concurrency at 2 simultaneous pipelines
- Conditional Sonnet usage for low-risk planning, implementation, and repair phases

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
/plugin install T.L-AutoDevelop
```

```
/plugin install T.L-AutoDevelop-Pro
```

## Configuration

Constants in `auto-develop.ps1`:

| Constant | Default | Description |
|----------|---------|-------------|
| `CONST_MODEL_PLAN` | `claude-opus-4-6` | Model for planning phase |
| `CONST_MODEL_INVESTIGATE` | `claude-opus-4-6` | Model for investigation phase |
| `CONST_MODEL_IMPLEMENT` | `claude-opus-4-6` | Model for implementation |
| `CONST_MODEL_REVIEW` | `claude-opus-4-6` | Model for code review |
| `CONST_MODEL_FAST` | `claude-sonnet-4-6` | Cost-saving model for low-risk phases |
| `CONST_PLAN_ATTEMPTS` | `2` | Plan / replan attempts |
| `CONST_INVESTIGATION_ATTEMPTS` | `2` | Investigation attempts |
| `CONST_IMPLEMENT_ATTEMPTS` | `2` | Fresh implementation attempts |
| `CONST_REMEDIATION_ATTEMPTS` | `2` | Preflight / review remediation attempts |
| `CONST_TIMEOUT_SECONDS` | `900` | Timeout per phase (15 min) |

## Result Categories

`auto-develop.ps1` now returns structured terminal categories such as:

- `ACCEPTED`
- `PLAN_INSUFFICIENT`
- `INVESTIGATION_INCONCLUSIVE`
- `NO_CHANGE_ALREADY_SATISFIED`
- `NO_CHANGE_TARGET_NOT_FOUND`
- `NO_CHANGE_BLOCKED`
- `PREFLIGHT_FAILED`
- `REVIEW_DENIED_MAJOR`
- `REVIEW_DENIED_RETHINK`

The result JSON also includes `summary`, `attemptsByPhase`, `artifacts.runDir`, `artifacts.debugDir`, and `noChangeReason`.

## Model Selection

The pipeline now chooses models per phase:

- `PLAN`: Sonnet for direct edits or already-concrete file targets, Opus otherwise
- `INVESTIGATE`: Opus
- `IMPLEMENT`: Sonnet only when targets are concrete and the step is low-complexity
- `REPAIR`: usually Sonnet for format/fixup loops with concrete hints
- `REVIEW`: Opus

## Language

All prompts, comments, and output are in **German (Deutsch)**. The pipeline is designed for .NET/WPF/Core.UI projects following German coding conventions.

## License

MIT
