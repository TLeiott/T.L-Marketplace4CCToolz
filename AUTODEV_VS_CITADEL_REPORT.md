# T.L-AutoDevelop vs. Citadel — Deep Comparative Analysis

> **Generated**: 2026-03-23
> **Citadel Repository**: [github.com/SethGammon/Citadel](https://github.com/SethGammon/Citadel) · [Fleet Docs](https://github.com/SethGammon/Citadel/blob/main/docs/FLEET.md)
> **T.L-AutoDevelop Version**: v4.2.5
> **Methodology**: 11 parallel deep-dive research agents examined every major subsystem of both projects at code level

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Overviews](#2-system-overviews)
3. [Routing & Task Classification](#3-routing--task-classification)
4. [Orchestration Architecture](#4-orchestration-architecture)
5. [Parallel Execution & Wave Model](#5-parallel-execution--wave-model)
6. [Discovery Briefs & Cross-Wave Knowledge](#6-discovery-briefs--cross-wave-knowledge)
7. [Self-Correction & Direction Checks](#7-self-correction--direction-checks)
8. [Retry Intelligence & Decision Logging](#8-retry-intelligence--decision-logging)
9. [Quality Gates & Regression Tracking](#9-quality-gates--regression-tracking)
10. [Hooks & Lifecycle System](#10-hooks--lifecycle-system)
11. [Telemetry & Observability](#11-telemetry--observability)
12. [Knowledge Extraction](#12-knowledge-extraction)
13. [Skill Decomposition & Composability](#13-skill-decomposition--composability)
14. [Where AutoDevelop Is Clearly Stronger](#14-where-autodevelop-is-clearly-stronger)
15. [Where Citadel Is Clearly Stronger](#15-where-citadel-is-clearly-stronger)
16. [Prioritized Improvement Recommendations](#16-prioritized-improvement-recommendations)

---

## 1. Executive Summary

**T.L-AutoDevelop** is a deep, battle-hardened, queue-centric .NET development automation system. It excels at durable state management, merge orchestration, environment recovery, and deterministic validation. Its 4,400-line scheduler and 3,600-line worker pipeline are purpose-built for reliable multi-task execution on Windows/.NET/WPF codebases.

**Citadel** is a wide, cost-efficient, language-agnostic agent orchestration harness. It excels at intelligent routing, composable skills, real-time guardrails via hooks, cross-agent knowledge transfer, and self-correction. Its 24 skills, 4-tier routing, and 8 lifecycle hooks prioritize cost efficiency and adaptability.

**Bottom line**: AutoDevelop is **deeper in its domain**; Citadel is **wider and more cost-efficient**. The highest-value improvements to adopt from Citadel are: **fast-path routing** (skip pipeline phases for simple tasks), **discovery briefs** (cross-wave knowledge sharing), **mid-pipeline direction checks** (catch scope drift early), and **per-edit pattern lint hooks** (catch issues during implementation, not after).

---

## 2. System Overviews

### T.L-AutoDevelop v4.2.5

| Component | File | Lines | Role |
|---|---|---|---|
| Scheduler Engine | `scripts/scheduler.ps1` | ~4,465 | Durable queue, state machine (12 states), wave execution, merge orchestration |
| Worker Pipeline | `scripts/auto-develop.ps1` | ~3,596 | 11-phase execution: VALIDATE → WORKTREE → CONTEXT → DISCOVER → INVESTIGATE → REPRODUCE → FIX_PLAN → IMPLEMENT → VERIFY_REPRO → PREFLIGHT → REVIEW → FINALIZE |
| Scheduler-Agent | `agents/scheduler-agent.md` | — | Read-only LLM planner: wave assignment, conflict prediction, dependency analysis |
| Reviewer Agent | `agents/reviewer.md` | — | Independent code review: ACCEPTED / DENIED_MINOR / DENIED_MAJOR / DENIED_RETHINK |
| Preflight | `scripts/preflight.ps1` | ~311 | Deterministic validation: build, tests, NuGet, XAML, forbidden patterns |
| Usage Gate | `scripts/claude-usage-gate.ps1` | ~629 | 5-hour API budget monitoring with auto-wait |
| Orchestrators | `skills/develop/SKILL.md`, `skills/TLA-develop/SKILL.md` | — | Interactive and autonomous entry points |

### Citadel

| Component | Location | Role |
|---|---|---|
| `/do` Router | `.claude/skills/do/SKILL.md` | 4-tier intent classification cascade |
| 24 Skills | `.claude/skills/*/SKILL.md` | Modular markdown protocols (review, test-gen, refactor, research, etc.) |
| Archon Agent | `.claude/agents/archon.md` | Multi-session campaign engine with self-correction |
| Fleet Agent | `.claude/agents/fleet.md` | Parallel agent coordination with discovery relay |
| 8 Hooks | `.claude/hooks/*.js` | Lifecycle automation (protect-files, post-edit, circuit-breaker, quality-gate, etc.) |
| Coordination | `scripts/coordination.js` | File-based scope claims for multi-instance safety |
| Discovery Compression | `scripts/compress-discovery.cjs` | ~500-token brief extraction from agent outputs |
| Telemetry | `scripts/telemetry-log.cjs`, `scripts/telemetry-report.cjs` | JSONL event logging and reporting |

---

## 3. Routing & Task Classification

### Current State

| Dimension | AutoDevelop | Citadel |
|---|---|---|
| Entry points | 2 fixed commands: `/develop`, `/TLA-develop` | 1 universal router: `/do` |
| Pre-pipeline classification | None — all tasks enter full 11-phase pipeline | 4-tier cascade: regex → active state → keyword → LLM |
| Cost per trivial task | Full pipeline (~4-7 LLM calls, 5-15 min) | Near-zero (~0 tokens for pattern-matched tasks) |

### Deep Findings

**AutoDevelop already has implicit fast-path logic**, just not formalized:

1. **`Get-TaskClass`** (line 2125-2131 in `auto-develop.ps1`) — regex-based classifier producing `INVESTIGATIVE`, `DIRECT_EDIT`, `BUGFIX_DIAGNOSTIC`, or `UNCERTAIN`
2. **DISCOVER phase routing** — the LLM classifies into `DIRECT_EDIT` (skips INVESTIGATE), `BUGFIX_TESTABLE` (full path), `BUGFIX_NONTESTABLE` (skips REPRODUCE), or `UNCERTAIN`
3. **Model tiering** — already downgrades to Sonnet for DIRECT_EDIT discover, concrete-target plans, low-complexity implementations, and low-risk reviews

**The scheduler-agent produces `effortClass` (LOW/MEDIUM/HIGH) but it is never consumed by the worker pipeline.** This is a free classification signal that is computed during wave planning but wasted.

### Citadel's 4-Tier Cascade (Code-Level)

| Tier | Method | Cost | What It Catches |
|---|---|---|---|
| 0 | Regex on raw input | ~0 tokens, <1ms | "typecheck", "build", "test", "fix typo in X" |
| 1 | Active state short-circuit | ~0 tokens, <100ms | Resumes active campaigns/fleet sessions |
| 2 | Keyword table match against 24 skills | ~0 tokens, <10ms | Single confident skill match → invoke directly |
| 3 | LLM complexity classifier (6 dimensions) | ~500 tokens, 1-2s | Routes by scope, complexity (1-5), persistence, parallelism needs |

A **Skill Registry Check** runs before classification: compares skill directory count against `registeredSkillCount` in `harness.json`. If new skills detected, reads only lines 1-10 of each new SKILL.md. 99% of invocations do one number comparison and zero file reads.

### What Could Be Improved

The biggest remaining win is **FIX_PLAN elimination for truly trivial tasks**. For a typo fix or label rename, DISCOVER already identifies the target — the FIX_PLAN phase adds little value. Merging DISCOVER output directly into the IMPLEMENT prompt for TRIVIAL tasks would save one full LLM invocation.

Proposed classification tiers for AutoDevelop:

| Tier | Signals | Phases Skipped | Savings |
|---|---|---|---|
| **TRIVIAL** | `Get-TaskClass` = DIRECT_EDIT + scheduler `effortClass` = LOW + single known file | FIX_PLAN, REVIEW (downgrade to preflight-only) | ~30-50% tokens, 2-5 min |
| **SIMPLE** | DIRECT_EDIT or BUGFIX_DIAGNOSTIC + concrete targets + ≤3 files | INVESTIGATE (already partial) | ~15-25% tokens, 1-3 min |
| **COMPLEX** | Everything else | None | 0% |

**Risk of skipping REVIEW is the highest concern.** Even for trivial tasks, the reviewer catches logic errors, dead code, wrong encoding. Downgrading to Sonnet review (already done for low-risk cases via `Test-LowRiskReview`) is safer than eliminating it.

**Where the classifier would fit:** Between WORKTREE and DISCOVER (lines 2382-2450 in `auto-develop.ps1`), where `Get-TaskClass` and `Test-InvestigationRequired` are already called. The classifier would read `Get-TaskClass` result + `plannerMetadata` from the scheduler task record and produce a `pipelineProfile`: TRIVIAL / SIMPLE / COMPLEX.

---

## 4. Orchestration Architecture

### Structural Comparison

| Dimension | AutoDevelop | Citadel |
|---|---|---|
| Tiers | 2 (interactive / autonomous) | 4 (Skill → Marshal → Archon → Fleet) |
| Orchestrator model | Infrastructure-driven (PowerShell state machine is the loop) | Agent-driven (LLM itself is the loop) |
| Planning agent | Scheduler-Agent (read-only wave planner) | Archon (amnesiac campaign strategist) |
| Execution | Single monolithic worker pipeline (11 phases) | Sub-agents using composable skills |
| State persistence | `state.json` + `events.jsonl` | Campaign markdown files with decision logs |

### Citadel's Escalation Ladder

| Tier | Name | Role | Cost |
|---|---|---|---|
| 1 | **Skill** | Domain expert (single concern) | Lowest — one focused prompt |
| 2 | **Marshal** | Session commander (multi-step chaining) | Low-medium — chains skills |
| 3 | **Archon** | Autonomous strategist (multi-session campaigns) | Medium-high — full campaign lifecycle |
| 4 | **Fleet** | Parallel coordinator (3+ workstreams) | Highest — multiple agents + compression |

Every task takes the cheapest path. Under-routing (skill fails, user re-invokes) is far cheaper than over-routing (Archon spends 30 minutes on a typo fix).

### Key Architectural Differences

AutoDevelop's infrastructure-driven approach is **more deterministic and auditable** — the PowerShell state machine enforces strict state transitions, merge gates, and wave boundaries. Citadel's agent-driven approach is **more adaptive** — the LLM decides wave composition at runtime.

AutoDevelop's single pipeline shape means every task gets the same treatment (with some conditional phase skipping). Citadel's 24 composable skills mean tasks get exactly the capability they need, nothing more.

---

## 5. Parallel Execution & Wave Model

### Mechanics Comparison

| Dimension | AutoDevelop | Citadel Fleet |
|---|---|---|
| Parallelism unit | Wave (group of tasks) | Wave (group of agents) |
| Isolation | Git worktree per task | Git worktree per agent |
| Wave planning | LLM scheduler-agent analyzes full queue, outputs JSON with waveNumber, blockedBy, conflict risk | Fleet LLM decides wave composition at runtime |
| Scope overlap prevention | **Predictive** — planner estimates likelyFiles, serializes on uncertainty | **Runtime claims** — file-based scope claims, hard gate on overlap |
| Merge gate | Strict — no task in wave N+1 starts until all wave N merges resolve | Implicit — Fleet merges branches between waves |

### Scope Claiming Deep-Dive

**Citadel** uses `scripts/coordination.js` with runtime file-based claims:
- Each instance registers with a unique ID and gets a JSON file in `.planning/coordination/instances/`
- Before starting work, agents call `claim --id X --scope dir1,dir2`
- `scopesOverlap()` checks parent/child directory conflicts: `cleanA.startsWith(cleanB) || cleanB.startsWith(cleanA)`
- `(read-only)` scoped directories never conflict
- Supports multi-session coordination (multiple Archon/Fleet sessions on same repo)

**AutoDevelop** uses upfront prediction only:
- Scheduler-agent predicts `likelyFiles` and `likelyAreas` per task
- If two tasks "might touch the same file, same shared project, same DTO/API contract, same schema, same global config, or same central module" → separate waves
- No runtime claim mechanism — once a wave plan is applied, it is trusted
- Merge gate catches actual conflicts after the fact

**AutoDevelop's approach is simpler but misses two things:**
1. **Read-only scope exemption** — tasks that only read files could safely parallelize with tasks that write to those files
2. **Multi-session coordination** — only one scheduler can operate per repo (enforced by `state.lock`)

### Circuit Breaker Comparison

| Dimension | AutoDevelop | Citadel |
|---|---|---|
| Scope | Queue-level (correlated task failures) | Agent-level (individual tool calls) |
| Trigger | 3+ failures in same wave AND same category (wave breaker); 4+ across waves (session breaker) | 3 consecutive tool failures |
| Categories | 9 classified categories (environment_state, build_infra, locked_environment, etc.) | None — counts all failures equally |
| Recovery | Automatic on subsequent success; manual override with `admin-clear-breaker` | Resets counter on trip; no success-based reset |
| Sophistication | **Higher** — correlation-based, category-aware, won't trip on isolated flaky tasks | **Simpler** — any 3 failures trip it regardless of cause |

### Dead Instance Recovery

**AutoDevelop** is significantly more robust:
- Continuous reconciliation on every state access (`Reconcile-State` runs on every snapshot/wait call)
- PID-based liveness check + **result file recovery** (a worker that wrote its result before dying is recovered without penalty)
- External merge detection (branch already in HEAD → auto-mark merged)
- Orphan worktree/branch cleanup in `Prepare-Environment`

**Citadel** requires an explicit sweep command:
- PID check via `process.kill(pid, 0)` zero-signal probe
- Staleness timer (2 hours)
- `npm run coord:sweep` iterates instances, deletes dead ones and their claims

---

## 6. Discovery Briefs & Cross-Wave Knowledge

### The Gap

This is Citadel's standout innovation. After each wave, agent outputs are compressed to ~500-token structured briefs and injected into next-wave agents. AutoDevelop workers operate in **complete isolation** — they receive no context about prior waves.

### How Citadel's compress-discovery.cjs Works

The script (~140 lines) uses pure regex extraction (no LLM):
1. **HANDOFF blocks**: finds `---HANDOFF---` delimited sections, splits into bullet points
2. **Decisions**: scans for keywords `decided|decision|chose|chosen|picked` (≤200 chars), caps at 5
3. **Files**: extracts paths matching `(src|lib|app|pages|components|api|test|spec)/...`, caps at 10
4. **Failures**: scans for `failed|error|broke|broken|couldn't|cannot|blocked` (≤200 chars), caps at 3

Output format:
```markdown
## Agent: {name}
**Status:** complete | partial | failed
**Built:** first 2 handoff items
**Remaining:** remaining handoff items
**Decisions:** up to 5 lines
**Failures:** up to 3 lines
**Files:** up to 10 paths
```

Compression ratio logged to `.planning/telemetry/compression-stats.jsonl`. Typical: 5x-25x compression (10K-50K chars → ~2K chars).

### What AutoDevelop Currently Passes Between Waves

- **plannerFeedbackSummary**: statistical prediction-accuracy metric ("your file predictions were tight/acceptable/broad/missed")
- **Task snapshots** with `finalStatus`, `finalCategory`, `summary`, `feedback`, `actualFiles`, `runs[]` history
- **recentQueueEvents**: timeline of state transitions

Workers receive **none of this**. They get only their `promptFile` (the raw task text).

### Proposed Discovery Brief for AutoDevelop

```json
{
  "taskId": "task-001",
  "waveNumber": 1,
  "status": "ACCEPTED",
  "taskSummary": "Fix null reference in OrderService.GetById",
  "whatWasBuilt": "Added null-safe navigation in OrderService.cs:L45, added unit test",
  "discoveries": [
    "OrderService shares CustomerDto with ShippingService",
    "Test project uses InMemoryDb, not Moq",
    "appsettings.json has FeatureFlags section"
  ],
  "failures": "First attempt failed: dotnet restore requires specific feed auth",
  "filesChanged": ["src/Services/OrderService.cs", "tests/OrderServiceTests.cs"],
  "filesInvestigated": ["src/DTOs/CustomerDto.cs", "src/Services/ShippingService.cs"],
  "conflictHints": "CustomerDto is shared across Order and Shipping modules"
}
```

### Implementation Approach

**Recommended: Hybrid — template extraction by scheduler, injected into both planner and workers.**

1. **Generation** (in scheduler, after `Apply-PipelineResultToTask`): extract structured fields directly from existing result JSON (status, summary, actualFiles, investigationConclusion, feedback). This is free — no LLM call needed. Covers ~70% of value.
2. **Storage**: `discoveryBrief` field on task object in scheduler state
3. **Injection into planner**: add `completedTaskBriefs` to `Get-SnapshotPayload`. Directly improves wave planning accuracy.
4. **Injection into workers**: pass briefs via new `--BriefsFile` parameter on `auto-develop.ps1`, injected into DISCOVER and INVESTIGATE phase prompts.

**Expected benefits:**
- Reduced investigation time (1-3 min saved per worker in multi-wave scenarios)
- Fewer merge conflicts (planner uses `actualFiles` ground truth instead of predictions)
- Better retry planning (briefs from failed attempts show what was tried)
- Improved planner confidence (ground-truth signals raise confidence from MEDIUM to HIGH)

---

## 7. Self-Correction & Direction Checks

### The Gap

AutoDevelop's quality checking is **heavily end-loaded**: the reviewer is the only agent that checks semantic alignment, and it runs after IMPLEMENT + PREFLIGHT (the most expensive phases). Citadel checks alignment proactively before expensive work.

### Citadel's Three Self-Correction Mechanisms

| Mechanism | Frequency | What It Catches |
|---|---|---|
| **Direction alignment check** | Every 2 phases | Scope drift, scope truncation, goal divergence |
| **Quality spot-check** | Every phase | Below-bar output quality |
| **Regression guard** | Every build phase | 5+ new typecheck errors → park campaign |

### AutoDevelop's Current Alignment Checking

- **Reviewer** (post-implementation): checks "Is this the smallest reasonable change?", "Were unnecessary deviations introduced?", "Does the code solve the stated task?" Can return `DENIED_RETHINK` for "fundamentally wrong approach." But this fires only after IMPLEMENT + PREFLIGHT have already consumed the majority of the pipeline budget.
- **Plan validation** (`Get-PlanValidation`): structural quality only (has Goal/Files/Order sections, not too short). Does NOT check whether the plan aligns with the original task intent.
- **Implementation outcome detection**: only checks whether files were actually changed, not whether changes match the task.
- **No mid-pipeline direction check exists.**

### Types of Scope Drift in AutoDevelop

1. **Over-engineering in FIX_PLAN** — plan refactors adjacent code, adds unnecessary abstractions
2. **Scope expansion during IMPLEMENT** — agent fixes unrelated warnings, refactors code it reads while locating targets
3. **Architectural drift in INVESTIGATE** — investigation concludes a broader change is needed than the task asks for
4. **Remediation drift** — fix attempts for PREFLIGHT/REVIEW feedback spill beyond the specific issue

### Proposed Direction Checks

**Checkpoint A — After FIX_PLAN, before IMPLEMENT** (highest value):

```
ORIGINAL TASK: $taskPrompt
PROPOSED PLAN: $planOutput
DISCOVERED TARGETS: $planTargets

RESPOND EXACTLY:
ALIGNMENT: ON_TRACK | MINOR_DRIFT | MAJOR_DRIFT
DRIFT_DESCRIPTION: <what exceeds scope>
RECOMMENDATION: CONTINUE | TRIM_PLAN | ABORT
```

- **Model**: Sonnet (`$CONST_MODEL_FAST`) — this is a classification task, not deep reasoning
- **Cost**: ~2-3% of total pipeline cost per run
- **Savings when drift caught**: ~70-80% of pipeline cost (skips IMPLEMENT → PREFLIGHT → REVIEW → REMEDIATE)
- **Pipeline flow**: ON_TRACK → continue; MINOR_DRIFT → inject narrowing context into IMPLEMENT prompt; MAJOR_DRIFT → loop back to FIX_PLAN with drift reason as critique

**Checkpoint B — After IMPLEMENT, before PREFLIGHT** (deterministic, zero LLM cost):

```powershell
# Compare changed files against plan targets
$unexpectedFiles = @($changedFiles | Where-Object {
    $file = $_
    -not ($planTargets | Where-Object { $file -match [regex]::Escape($_) })
})
if ($unexpectedFiles.Count -gt ($changedFiles.Count * 0.5)) {
    # More than half the changes are outside plan scope — flag it
}
```

Even if drift only occurs in 10-15% of runs, the expected savings from Checkpoint A are positive: 2-3% cost always vs. 70-80% cost saved when caught.

---

## 8. Retry Intelligence & Decision Logging

### The Gap: Worker Amnesia Between Retries

**The worker starts completely cold on every retry.** It receives only the original, unchanged `promptFile`. It does NOT receive:
- The `runs[]` array from scheduler state
- What approaches were tried previously
- What files were touched and failed
- What investigation conclusions were reached
- What review feedback caused rejection
- What phases failed and why

The scheduler **has all this data** (rich run records with `finalStatus`, `finalCategory`, `summary`, `feedback`, `actualFiles`, `investigationConclusion`, `reproductionConfirmed`). It just doesn't pass it through.

Within a single run, the worker is sophisticated about internal retries (maintains `feedbackHistory`, passes "PRIOR FEEDBACK" blocks, uses `implementationHistoryHashes` to detect blind loops). But all of this is ephemeral.

### Citadel's Approach

Campaign files include a **Decision Log** with timestamped entries and reasoning. Each Archon invocation is amnesiac but rebuilds context from the campaign file. This prevents:
- Re-debating settled decisions
- Repeating failed approaches
- Losing investigation results

### Proposed Decision/Lesson Structure

```json
{
  "lessons": [
    {
      "timestamp": "2026-03-23T14:22:00Z",
      "phase": "INVESTIGATE",
      "approachTried": "Searched for DTO mapping in AutoMapper profiles",
      "whatFailed": "DTO is mapped inline in controller, not in profiles",
      "constraintLearned": "OrderDto mapping lives in OrderController.cs",
      "avoidNext": "Do not search AutoMapper profiles for this DTO",
      "tryNext": "Check controller-level inline mapping"
    }
  ]
}
```

### Implementation

**Recommended: Worker produces lessons in result JSON → scheduler stores in run records → on retry, scheduler compiles lessons into a context file.**

1. Worker: add lessons extraction to `Write-ResultJson` (use existing `feedbackHistory` entries)
2. Scheduler: store lessons in run records via `Apply-PipelineResultToTask`
3. On retry: `Run-Task` compiles lessons from `$task.runs[]` into a `RetryContextFile`
4. Worker: new `-RetryContextFile` parameter, injected into DISCOVER/INVESTIGATE/PLAN prompts using the existing "PRIOR FEEDBACK" injection pattern (lines 2521-2546)

### Expected Impact

- Reduce blind-repeat retries by 60-80%
- Improve second-attempt success rate by 20-40%
- Faster escalation to `manual_debug_needed` for genuinely hard tasks

---

## 9. Quality Gates & Regression Tracking

### Current Preflight (Binary Pass/Fail)

AutoDevelop's `preflight.ps1` checks:
- **BLOCKER 1**: `dotnet build --no-restore` (pass/fail)
- **BLOCKER 2**: App startup (5-second crash test)
- **BLOCKER 3-5**: Static patterns on changed .cs files (forbidden comments, stubs, class-per-file)
- **BLOCKER 6**: NuGet audit (before/after comparison — the ONE place it does a delta)
- **XAML**: XML parse validation
- **Tests**: `dotnet test` (pass/fail)
- **WARNINGS 7-11**: Informational (catch spam, file length, dispatcher usage, MessageBox, secrets)

**Key gap: All checks except NuGet are strictly binary. No counts or deltas are tracked. Build warnings, test counts, and analyzer diagnostics are captured in raw output but never parsed into structured metrics.**

### Citadel's Approach

- **Phase 0 Baseline**: records typecheck/test counts before work begins
- **Per-phase end condition**: "no new typecheck errors" and "existing tests pass"
- **Regression guard**: 5+ new typecheck errors → park the campaign
- **Per-edit typecheck via hooks**: catches errors during implementation, not after

### Proposed Baseline Regression Tracking

**Baseline capture** at end of CONTEXT phase (after `dotnet restore`, before any implementation):
1. `dotnet build` → parse warning count and warning codes
2. `dotnet test --verbosity normal` → parse test counts (passed/failed/skipped/total)
3. Store as `quality-baseline.json` artifact

**Comparison** inside existing PREFLIGHT phase:
1. Parse warning count from build output (already captured)
2. Parse test counts from test output (already captured)
3. Accept `-BaselineFile` parameter
4. Emit delta entries as blockers or warnings

| Metric | Threshold | Action |
|---|---|---|
| New build warnings | >0 | WARNING (inform reviewer) |
| New build warnings | >5 | BLOCKER (fail preflight, mirrors Citadel's "5+ = park") |
| Test count decrease | Any | BLOCKER (tests were deleted/skipped) |
| New test failures | Any | Already a BLOCKER |

**Time cost**: One extra build + test run (~30-90 seconds). Can run as background job during DISCOVER to avoid blocking.

**Implementation stages:**
1. Parse warning/test counts from existing preflight output (low effort)
2. Add `Capture-QualityBaseline` function to `auto-develop.ps1` after `dotnet restore` (medium effort)
3. Add baseline comparison to `preflight.ps1` with `-BaselineFile` parameter (medium effort)

---

## 10. Hooks & Lifecycle System

### Current State

**AutoDevelop has no hooks.** No `.claude/settings.json` exists in the repository. No hooks directory or `hooks.json` exists in the plugin. All validation is in the pipeline scripts (preflight.ps1) and runs post-implementation.

Workers launch via `claude -p` without `--bare`, meaning **hooks ARE active** if configured. The infrastructure is available — it's just unused.

### Citadel's 8 Hooks (Code-Level Detail)

| Hook | Event | What It Does |
|---|---|---|
| **protect-files.js** | PreToolUse (Edit/Write/Read) | Blocks edits to `.claude/settings.json`, `.claude/hooks/*`; blocks reads on `.env` files. **Fails closed** — parse errors block the action. |
| **post-edit.js** | PostToolUse (Edit/Write) | Per-file typecheck (TS: `tsc --noEmit`, Python: `mypy`/`pyright`, Go: `go vet`, Rust: `cargo check`), performance lint, dependency-aware pattern detection, design manifest lint |
| **circuit-breaker.js** | PostToolUseFailure | Tracks consecutive failures. 3 = suggest different approach. 5 lifetime trips = hard "STOP and rethink". State in `.claude/circuit-breaker-state.json` (atomic write via temp+rename) |
| **quality-gate.js** | Stop | Scans `git diff --name-only HEAD` for anti-patterns (confirm/alert, transition-all, magic intervals). Custom regex rules from `harness.json` |
| **intake-scanner.js** | SessionStart | Reports pending work items from `.planning/intake/` |
| **pre-compact.js** | PreCompact | Saves active campaign/fleet state before context compression |
| **restore-compact.js** | SessionStart (compact) | Re-injects saved state after compaction |
| **worktree-setup.js** | WorktreeCreate | Auto-installs deps in agent worktrees, copies `.env` files |

**Shared utility** (`harness-health-util.js`): config reading, stack detection, input validation (shell metacharacter rejection), telemetry logging.

### Per-Edit Typecheck: .NET Feasibility

**Full `dotnet build` per-edit is NOT feasible for .NET:**
- 5-30s per build vs. TypeScript's <1s `tsc --noEmit`
- 10-20 edits per implementation = 100-600s build overhead
- Mid-implementation build errors are expected (multi-file changes)
- No `tsc --noEmit` equivalent exists for C#

**What IS feasible — per-edit static pattern lint:**
- Sub-second execution (pure regex)
- Catches: forbidden comments, `NotImplementedException` stubs, class-per-file violations, file length, secret patterns, MessageBox misuse, dispatcher usage
- These are exactly the same checks from preflight lines 211-263, adapted for per-file
- Would reduce remediation cycles by catching easy issues during implementation

### Recommended Hooks for AutoDevelop

**High value:**

1. **Post-edit pattern lint** — lightweight PostToolUse hook running preflight's static checks per-file. Catches common preflight failures during implementation instead of after.

```json
// plugins/T.L-AutoDevelop/hooks/hooks.json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write|MultiEdit",
      "hooks": [{
        "type": "command",
        "command": "powershell -NoProfile -ExecutionPolicy Bypass -File ${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-lint.ps1",
        "timeout": 5
      }]
    }]
  }
}
```

2. **Protect-files** (concept) — prevent agents from modifying pipeline scripts, scheduler config, or `plugin.json`. Currently no pre-edit guard exists.

3. **Pre-compact/restore-compact** (concept) — long-running sessions can lose context on compression. Saving task name, cycle number, accumulated feedback, and worktree path would prevent mid-task disorientation.

**Medium value:**

4. **Quality gate on stop** — catch issues when Claude decides to stop mid-implementation (before reaching preflight). .NET-specific checks would complement existing preflight.

---

## 11. Telemetry & Observability

### Current Data Sources

AutoDevelop already has excellent raw data:

| Source | Location | Content |
|---|---|---|
| Scheduler events | `events.jsonl` | 18 event kinds (registered, started, completed, merge_*, environment_*, circuit_breaker_*, plan_applied, planner_feedback, etc.) |
| Pipeline history | `pipeline-history.jsonl` | Per-run: status, finalCategory, attempts, attemptsByPhase, failureReasons, changedFiles |
| Per-run artifacts | `runs/<taskName>/` | timeline.json, phase-metrics.json (model, tokens, duration per call), metrics-summary.json, scheduler-snapshot.json |
| Result files | `scheduler/results/<taskId>.json` | Full outcome including metrics, route, testability, reproduction data |

### The Gap

**There is no report command.** The data quality is solid; the consumption layer is missing.

### Comparison with Citadel

| Capability | Citadel | AutoDevelop | Gap |
|---|---|---|---|
| JSONL event log | Hooks, agents, campaigns | 18 event kinds + pipeline history | Comparable |
| Per-run timing | Hook timings | phase-metrics.json | Already present |
| Token/cost tracking | Estimated | Estimated per phase | Comparable |
| **Report command** | `telemetry-report.cjs` | **None** | **Primary gap** |
| **Postmortem skill** | Structured reports | **None** | Missing |
| Aggregate summaries | Cross-session | Per-run only | Missing cross-run |

### What Reports Could Be Generated Today

From existing data:
- Task throughput and success rate per time window
- Average attempts per task
- Most common failure reasons (ranked by frequency)
- Phase timing averages (from phase-metrics.json)
- Merge conflict frequency
- Circuit breaker trip frequency and duration
- Planner prediction accuracy trends
- Model escalation frequency
- Route distribution (BUGFIX vs DIRECT_EDIT vs UNCERTAIN)
- Usage budget utilization patterns (requires adding logging to usage gate)

### Implementation

A single `autodevelop-report.ps1` script (~200-300 lines) reading `events.jsonl` + `pipeline-history.jsonl` + `runs/*/phase-metrics.json`. The `Read-JsonLinesFile` function already exists in `scheduler.ps1` (lines 311-338) and correctly parses JSONL.

---

## 12. Knowledge Extraction

### The Gap

AutoDevelop processes tasks, produces rich results, and then throws away the institutional knowledge. Citadel has a `knowledge-extractor` agent that extracts reusable patterns from completed campaigns.

### What Knowledge Is Extractable from Existing Data

| Knowledge Type | Data Source | Example |
|---|---|---|
| **File co-change patterns** | `actualFiles[]` across merged tasks | "Tasks touching OrderVM.cs usually also need OrderView.xaml" |
| **Failure-cause patterns** | `finalCategory` + `actualFiles[]` cross-reference | "Build failures in Services/ usually caused by missing DI registration" |
| **Review denial patterns** | `verdict.feedback` + remediation outcomes | "DENIED_MAJOR for missing error handling → fixed by try/catch in service layer" |
| **Effort calibration** | `taskClass` + `attemptsByPhase` + `metrics` | "INVESTIGATIVE tasks in DataAccess/ average 2.3 attempts" |
| **Planner accuracy** | `plannerFeedback` (already computed but ephemeral) | "Planner consistently misses test file changes in Module X" |

### Proposed Architecture

**Storage:** `.claude-develop-logs/knowledge/` directory
```
co-changes.json          # file co-change clusters
failure-patterns.json    # area → common failure categories
review-patterns.md       # human-readable review denial patterns
effort-calibration.json  # taskClass + area → actual effort stats
planner-accuracy.json    # persistent planner feedback (currently ephemeral)
summary.md               # high-level summary for agent injection
```

**Extraction trigger:** Post-merge hook in `resolve-merge` mode + end-of-session batch for cross-task patterns.

**Consumption:**
1. **Scheduler-agent** (highest impact): add `knowledgeSummary` to `Get-SnapshotPayload`. The agent already accepts "recent planner feedback" — extending to include persistent knowledge is natural.
2. **Worker pipeline** (medium impact): inject area-specific knowledge into DISCOVER/PLAN phase prompts.
3. **Reviewer** (lower priority): too much context risks bias.

**Staleness mitigation:** Timestamp entries, confidence decay (weight recent tasks higher), entry limits (evict oldest low-confidence), reset on major structure changes.

### Minimum Viable Implementation

Phase 1 (no new agents): `Extract-TaskKnowledge` function in `scheduler.ps1` after `merge_resolved` events. Appends to `co-changes.json` and `planner-accuracy.json`. Pure PowerShell, no LLM cost.

Phase 2: Inject `knowledgeSummary` into scheduler-agent input via `Get-SnapshotPayload`.

---

## 13. Skill Decomposition & Composability

### Current State

AutoDevelop has a **monolithic worker pipeline** (~3,600 lines, ~50K tokens) with 11 phases in a fixed sequence. The current skill framework has:
- `SKILL.md` files with basic frontmatter (`name`, `description`, `argument-hint`)
- Agent definitions as markdown (reviewer, scheduler-agent)
- Plugin registration via `plugin.json` + `marketplace.json`

All existing skills (`/develop`, `/develop-prepare`, `/TLA-develop`) are orchestrator-level commands that instruct Main-Claude how to call the scheduler.

### Citadel's Skill Architecture

- 24 modular skills as markdown protocols with YAML frontmatter
- Each has: Identity, Orientation, Protocol, Quality Gates, Exit Protocol
- Skills can be chained by Marshal (e.g., review → test-gen → refactor)
- Skills cost zero tokens when not loaded
- `/create-skill` generates new skills from repeating patterns

### What Could Be Extracted

**High feasibility (already self-contained):**
- `/investigate` — DISCOVER + INVESTIGATE as standalone read-only skill
- `/review` — already uses a separate agent definition
- `/preflight` — already a separate script

**Medium feasibility (needs context forwarding):**
- `/reproduce` — standalone bug reproduction
- `/plan` — standalone planning (accepts investigation output or just task text)
- `/implement` — needs plan + worktree

**Lower feasibility (tightly coupled):**
- `/remediate` — feedback loop between PREFLIGHT/REVIEW and IMPLEMENT
- `/verify-repro` — extremely narrow input contract

### Migration Path

1. **Phase 1**: Extract `/investigate`, `/review`, `/preflight` as standalone skills (low risk, high value for debugging and user flexibility)
2. **Phase 2**: Extract `/reproduce` and `/plan` (medium risk, needs worktree management)
3. **Phase 3**: Refactor monolith to compose skills (high complexity — introduce inter-skill contract format)
4. **Phase 4**: Enable user-level composition (`/investigate then /plan`, `/implement --skip-investigation`)

### Framework Extensions Needed

- **Input/output contracts** in SKILL.md frontmatter
- **Skill chaining/composition** mechanism (Marshal equivalent)
- **Artifact passing** between skills (shared directory or structured handoff files)
- **Model and tool declarations** per skill

### Key Risk

The IMPLEMENT-PREFLIGHT-REVIEW-REMEDIATE feedback loop shares mutable state across 4 phases. This loop would likely need to remain as a single composite skill rather than being split, at least initially.

---

## 14. Where AutoDevelop Is Clearly Stronger

| Area | Why AutoDevelop Wins | Detail |
|---|---|---|
| **Queue management** | Durable, lock-protected, concurrent-safe queue with full state machine (12 states) | Citadel has no real queue — just campaign files |
| **Merge orchestration** | Sophisticated preparation, validation, user testing checkpoints, abort/discard/requeue | Citadel does basic `git merge` |
| **Environment recovery** | Stale worktree detection, selective cleanup, result-file recovery for zombie workers, circuit breaker with category classification | Citadel has basic dead instance recovery requiring explicit sweep |
| **Wave planning intelligence** | LLM scheduler-agent analyzing conflict risk, file overlap, dependency hints, effort class | Citadel uses LLM runtime decisions without structured analysis |
| **Usage budget management** | 5-hour budget probing, automatic wait, usage cache, launch gate with projected cost | Citadel has no API budget awareness |
| **Deterministic validation** | Deep preflight: build, tests, app startup, NuGet policy, XAML validity, forbidden patterns, 5 warning types | Citadel relies on typecheck + basic anti-patterns |
| **Domain expertise** | Purpose-built for .NET/WPF with specific checks (XAML, NuGet, Core.UI patterns, WPF dispatcher) | Citadel is language-agnostic |
| **State machine rigor** | 12 formal states with defined transitions, merge gate enforcement, strict wave boundaries | Citadel relies on agent judgment for state management |
| **Circuit breaker sophistication** | Correlation-based, category-aware (9 categories), wave-scoped and session-scoped | Citadel counts all failures equally |
| **Reconciliation** | Continuous on every state read; recovers zombie workers with result files | Citadel requires explicit sweep commands |

---

## 15. Where Citadel Is Clearly Stronger

| Area | Why Citadel Wins | Detail |
|---|---|---|
| **Cost efficiency** | 4-tier routing means trivial tasks cost ~0 tokens | AutoDevelop runs full pipeline for everything |
| **Skill composability** | 24 modular skills chainable by Marshal | AutoDevelop has one monolithic pipeline |
| **Discovery relay** | Compressed ~500-token briefs between waves, preventing rediscovery | AutoDevelop workers have zero cross-wave context |
| **Self-correction** | Direction alignment every 2 phases, quality spot-checks, regression guards — all mandatory | AutoDevelop only checks at the end via reviewer |
| **Hooks/guardrails** | 8 lifecycle hooks providing real-time per-edit validation | AutoDevelop validates post-hoc only |
| **Campaign persistence** | Decision logs prevent re-debating; continuation state enables multi-session work | AutoDevelop retry starts cold every time |
| **Knowledge extraction** | Extracts reusable patterns from completed work | AutoDevelop discards institutional knowledge |
| **Portability** | Language/framework agnostic with stack auto-detection | AutoDevelop is Windows/.NET only (by design) |
| **Context preservation** | Pre-compact/restore-compact hooks survive context compression | AutoDevelop has no compaction awareness |
| **Fail-closed security** | protect-files hook blocks on parse errors, never allows on uncertainty | AutoDevelop has no pre-edit guards |

---

## 16. Prioritized Improvement Recommendations

### Tier 1 — High Impact, Moderate Effort

Status update as of 2026-03-24: recommendations #1 and #2 were implemented by commit `d0b4d22` (`auto: wire planner effort and add discovery briefs`).

| # | Improvement | Status | Source Inspiration | Expected Impact | Effort |
|---|---|---|---|---|---|
| 1 | **Wire `effortClass` from scheduler-agent to worker pipeline** | Done 2026-03-24 in `d0b4d22` | Citadel's /do router | Free classification signal already computed but wasted. Enables pipeline profile selection. | Low — pass through existing data |
| 2 | **Discovery briefs (template-extracted) → scheduler-agent** | Done 2026-03-24 in `d0b4d22` | Citadel's compress-discovery.cjs | Directly improves wave planning accuracy using ground-truth data from completed tasks. | Low-Medium — new function in scheduler post-processing |
| 3 | **Direction check after FIX_PLAN** | Open | Citadel's Archon alignment check | One Sonnet call (~2-3% cost) saves 70-80% when drift caught. | Medium — new pipeline phase |
| 4 | **Retry context injection** | Open | Citadel's Decision Log | Workers currently start cold. Passing prior attempt lessons would reduce blind retries 60-80%. | Medium — extend result JSON + add `-RetryContextFile` parameter |

### Tier 2 — Medium Impact, Lower Effort

| # | Improvement | Status | Expected Impact | Effort |
|---|---|---|---|---|
| 5 | **Baseline regression tracking** | Open | Catches tasks that "pass" but degrade quality. 5+ new warnings = blocker. | Medium — baseline capture + preflight comparison |
| 6 | **Telemetry report script** | Open | Data-driven pipeline optimization. Surface patterns like "REPRODUCE phase has 60% failure rate." | Low — PowerShell script over existing JSONL |
| 7 | **Post-edit pattern lint hook** | Open | Catches common preflight failures during implementation. Reduces remediation cycles. | Low-Medium — reuse preflight regex in a hook |
| 8 | **Deterministic file-scope check after IMPLEMENT** | Done 2026-03-24 in `4.2.9` line | Zero-cost check comparing `$changedFiles` against `$planTargets`. Flags unexpected scope expansion. | Low — add after line 3272 in auto-develop.ps1 |

### Tier 3 — Lower Priority, Higher Value Over Time

| # | Improvement | Status | Expected Impact | Effort |
|---|---|---|---|---|
| 9 | **Knowledge extraction (co-changes + planner accuracy)** | Open | Persistent learning improves planning over time. | Medium — new function in scheduler + storage |
| 10 | **Standalone skills: /investigate, /review, /preflight** | Open | User flexibility, debugging, partial reruns. | Medium — extract from monolith, define contracts |
| 11 | **Pre-compact context preservation hook** | Open | Prevents mid-task disorientation on context compression. | Low — simple save/restore hook |
| 12 | **FIX_PLAN elimination for TRIVIAL tasks** | Open | Merge DISCOVER+IMPLEMENT for true one-line changes. Saves 1 LLM call. | Medium — conditional pipeline flow |

### Implementation Roadmap

```
Phase 1 (Quick wins):
  ├─ [Done 2026-03-24] Wire effortClass to worker (#1)
  ├─ Telemetry report script (#6)
  └─ [Done 2026-03-24] Deterministic file-scope check (#8)

Phase 2 (Core improvements):
  ├─ [Done 2026-03-24] Discovery briefs → scheduler-agent (#2)
  ├─ Direction check after FIX_PLAN (#3)
  └─ Baseline regression tracking (#5)

Phase 3 (Retry intelligence):
  ├─ Retry context injection (#4)
  └─ Post-edit pattern lint hook (#7)

Phase 4 (Long-term evolution):
  ├─ Knowledge extraction (#9)
  ├─ Standalone skills (#10)
  ├─ Pre-compact hook (#11)
  └─ TRIVIAL fast-path (#12)
```

---

*Report generated by 11 parallel research agents examining both codebases at code level. Each agent read the actual source files (PowerShell scripts, markdown protocols, JavaScript hooks) and compared implementation details, not just documentation.*
