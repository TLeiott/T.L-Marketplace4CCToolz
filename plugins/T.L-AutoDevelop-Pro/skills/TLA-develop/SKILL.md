---
name: TLA-develop
description: "Queue-aware autonomous .NET development pipeline. Accepts a task text or a task file and auto-merges successful work."
argument-hint: [task text or path to a task file]
disable-model-invocation: true
---

# /TLA-develop

CRITICAL: You are the Main-Claude orchestrator. You do not implement the requested code changes yourself.

This command uses the same shared queue as `/develop`, but it differs in two ways:
- worker tasks are registered with `sourceCommand = "TLA-develop"`
- once a merge is prepared successfully, it is committed automatically without a user testing checkpoint

Allowed before any worker pipe starts: `Read`, `Glob`, `Grep`, `Bash`.

Do not edit repository files directly in this skill.

## 1. Validate Repository State

Use one Bash call to verify:
- `git rev-parse --is-inside-work-tree` returns `true`
- `git status --porcelain` is empty

If either check fails, stop and explain the problem.

## 2. Resolve the Solution

Find `*.sln` and `*.slnx` in the current directory and up to two parent directories.
- If none are found, stop.
- If more than one is found, ask the user which solution to use.

Use the absolute solution path for all later script calls.

## 3. Resolve the Scheduler Scripts

Find `scheduler.ps1` from the installed plugin and derive:
- `scheduler.ps1`
- `claude-usage-gate.ps1`

If `scheduler.ps1` cannot be found, stop.

## 4. Resolve the Input as Text or File

Interpret `$ARGUMENTS` as follows:
- existing local file path -> task-file mode
- otherwise -> direct task text

Task-file mode rules:
- read the file
- extract tasks from bullet items, numbered items, or plain non-empty lines
- preserve source order
- ignore headings and blank lines
- support optional inline annotations:
  - `[after: <task id or earlier task number>]`
  - `[priority: high|normal|low]`
  - `[serial]`

Semantics:
- `[after: ...]` is a hard execution dependency, not just a planning hint.
- Tasks declared with `[after: ...]` must run in a later wave and must not start in parallel with their dependency target.

Every extracted task must be registered with:
- `taskText`
- `sourceCommand = "TLA-develop"`
- `sourceInputType = "file"` or `"inline"`
- `allowNuget = true` only if the surrounding task context explicitly requires package installation
- optional `declaredDependencies`
- optional `declaredPriority`
- optional `serialOnly`

## 5. Create Temp Artifacts

Use Windows `%TEMP%`, not bash `/tmp`, for all PowerShell-facing paths.

Create one local run id and a shared temp directory such as `%TEMP%\claude-develop`.

For each new task create:
- a prompt markdown file
- a registration JSON record
- a scheduler result file path

Each task prompt file must contain:

```md
## Task
<task text>

## Solution
<absolute solution path>
```

## 6. Probe the Usage Gate

Run the usage gate in `probe` mode with `-ThresholdPercent 90`.

Interpret the result strictly:
- fatal gate error -> stop
- `fiveHourUtilization < 90` -> continue
- `fiveHourUtilization >= 90` -> ask whether this scheduling cycle may overrun the 5h budget
- unavailable statusline/cache -> ask whether the 5h limit should be ignored for this scheduling cycle

Do not silently wait for the budget to drop.

If the user declines, stop after leaving the queue unchanged.

## 7. Snapshot, Register, and Replan the Whole Queue

Use the same queue procedure as `/develop`:
1. `snapshot-queue`
2. `register-tasks`
3. `snapshot-queue` again
4. invoke the read-only `scheduler-agent`
5. `apply-plan`
6. `snapshot-queue` again

The planner input must include:
- all running tasks
- all queued tasks
- all retry-scheduled tasks
- all pending-merge tasks
- the newly added tasks
- recent planner feedback from the queue snapshot
- nearby documentation markdown files relevant to the affected modules

## 8. Start Ready Pipes

For each newly startable task, launch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode run-task -SolutionPath "<solution>" -TaskId "<task id>"
```

These workers may run in parallel when their current wave allows it.

Report to the user:
- which tasks started
- which tasks were queued
- which tasks are retry-scheduled
- whether the circuit breaker is open
- the projected queue cost from `usageProjection`
- a compact progress snapshot from:
  - `queueProgressSummary`
  - `runningTaskProgress`
  - `queuedTaskProgress`
  - `recentQueueEvents`

If `circuitBreaker.status == "manual_override"`, report that the breaker is temporarily suppressed until `manualOverrideUntil`.

Do not reduce this to only "started" / "queued" lines when richer progress data is available.

## 9. Autonomous Merge Flow

Whenever you re-enter after task completion:
1. Snapshot the queue.
2. Before any merge handling, show a compact progress snapshot for the user from:
   - `queueProgressSummary`
   - `runningTaskProgress`
   - `queuedTaskProgress`
   - `mergeTaskProgress`
   - `recentQueueEvents`
3. If a merge is already prepared, inspect that task record and its `sourceCommand`.
4. If `nextMergeTaskId` is present, call `prepare-merge`, then inspect the returned task record and its `sourceCommand`.
5. If the prepared task has `sourceCommand = "TLA-develop"`, call `resolve-merge -Decision commit` immediately.
6. If the prepared task has `sourceCommand = "develop"`, stop and ask the user to test it before any merge commit.
7. After each merge, snapshot again and start any newly startable tasks.

`nextMergeTaskId` may stay empty even when `pendingMergeTaskIds` is non-empty. This is expected while other tasks in the same wave are still `queued` or `running`. Detached worker retries no longer block merge turns for already finished wave work.

Use a normal English merge commit message that describes the actual change.
Do not use squash wording.

For `TLA-develop`, if merge preparation fails only because local dev hosts are locking build outputs, the scheduler may automatically `taskkill` the blocking Visual Studio / IIS Express style processes once and retry the merge build.

If `prepare-merge` fails:
- let the scheduler requeue the task if attempts remain
- report the failure briefly
- continue with the updated queue state

The scheduler may preserve an accepted branch and retry merge preparation separately when the worker result itself is still valid.

## 10. Retry Policy

The scheduler owns retries.

Treat these task states as retryable scheduled work:
- pipeline failures
- unexpected errors
- inconclusive outcomes
- merge conflicts
- build failures during merge preparation

Each task gets at most 3 full attempts.

If a task reaches terminal failure, report that clearly.

## 11. Replanning Rule

Run the scheduler-agent planning pass whenever the queue materially changes:
- new submission
- task-file expansion
- task completion
- retry scheduling
- merge completion
- circuit-breaker clear

Do not continue using stale wave assignments after the queue changed.

## 12. User-Facing Tone

Keep updates short and factual. Report:
- what started
- what is currently running and in which phase
- what merged
- what is queued or blocked
- what changed since the last queue update
- what was requeued
- what exhausted its attempts

When progress fields are present, prefer structured status lines over generic text like "No output available."
