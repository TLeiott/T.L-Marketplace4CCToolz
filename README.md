# T.L Marketplace for Claude Code Tools

A Claude Code plugin marketplace providing .NET development pipeline tools.

## What's Included

### T.L-AutoDevelop (v3.0.0) — Interactive

An interactive development pipeline that orchestrates Claude Code through discovery, investigation, optional bug reproduction, fix planning, implementation, preflight, and review — with user confirmations before each commit.

| Command | Description |
|---------|-------------|
| `/develop [task]` | Scheduler-managed single task with read-only planning, queueing, and merge-ready commit confirmation |
| `/develop-batch [tasks.md]` | Batched git-worktree pipeline with read-only scheduling, statusline-aware launch gating, conservative parallel waves, confirms each commit |

### T.L-AutoDevelop-Pro (v3.0.0) — Autonomous

A fully autonomous development pipeline — zero confirmations. Runs discovery, investigation, optional bug reproduction, fix planning, implement, preflight, review, and commit end-to-end unattended.

| Command | Description |
|---------|-------------|
| `/TLA-develop [task]` | Scheduler-managed single task with read-only planning, queueing, and wave-safe auto-commit |
| `/TLA-develop-batch [tasks.md]` | Batched pipeline with read-only scheduling, statusline-aware launch gating, conservative parallel waves, fully automated after startup |

**Pipeline Flow:**
```
Discover -> Investigate -> optional Reproduce -> Fix Plan -> Implement -> Change Validate -> Verify Repro -> Preflight -> Review
```

**New runtime behavior:**
- Explicit no-op categories instead of generic `IMPL_FAIL`
- Per-run artifacts under `.claude-develop-logs/runs/<taskName>/`
- Per-run temp debug bundles under `%TEMP%\claude-develop\debug\<runId>\`
- Discovery-first routing before detailed planning
- Investigation phase for ambiguous or diagnostic tasks
- Optional failing-test reproduction for testable bugfix work
- Semantic fix-plan validation that rejects placeholder/template plans
- Single-task launchers now perform a read-only context pass, submit into a repo-scoped scheduler, and only merge accepted work in wave order
- Single-task scheduler-managed runs may queue behind active work and only surface interactive commit once a task is merge-ready in sequence
- Batch launchers now perform a read-only context pass, build conservative conflict/dependency waves, and may run up to 20 simultaneous pipelines when scopes are clearly disjoint
- Before each new batch launch slot, the launcher probes the local Claude statusline / usage cache and pauses starts when the 5h usage window is at or above 90%
- The usage helper accepts trusted commands from the main Claude folder, falls back to `%USERPROFILE%\\.claude\\statusline.ps1` when available, and emits JSON for handled unavailable states instead of failing the batch outright
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

## Versioning

Do not push changed plugin or marketplace content under the same version number.

When a pushed change affects distributed behavior or content, bump the affected plugin version in both places:

- `.claude-plugin/marketplace.json`
- `plugins/<plugin>/.claude-plugin/plugin.json`

Minimum rule: increment the patch version even for small shipped changes. If a change affects both plugins or shared packaged behavior, bump both plugin versions together.

This avoids stale Claude plugin cache entries serving older skill or script files under a reused version.

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
