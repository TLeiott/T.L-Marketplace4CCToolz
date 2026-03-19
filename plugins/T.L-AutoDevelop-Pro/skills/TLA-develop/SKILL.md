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

If the check fails, stop and explain the problem.

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

Before doing any queue work, run the shared prepare check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode prepare-environment -SolutionPath "<solution>"
```

Interpret the prepare result strictly:
- `status == "blocked"`: stop and report the blocker before any autonomous queue action
- `status == "ready"` or `status == "cleaned"`: continue
- `status == "warning"`: continue, but report the remaining warnings

Always surface:
- cleanup actions that were performed
- dirty repo or unresolved git-operation blockers if present
- remaining unknown AutoDevelop branches or worktrees
- scheduler integrity warnings
- the compact post-prepare queue status:
  - `queueProgressSummary`
  - `queueStall`
  - `circuitBreaker`

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

The prompt file must exist on disk before `register-tasks` is called.
The scheduler now rejects registrations with a missing, empty, or unreadable `promptFile`.

Each task prompt file must contain:

```md
## Task
<task text>

## Solution
<absolute solution path>
```

## 6. Probe the Usage Gate

Run the usage gate in `probe` mode with `-ThresholdPercent 90`.

Use this initial probe only to:
- detect fatal gate errors
- show the current 5h status to the user
- confirm whether statusline/cache data is currently available

Interpret the initial probe strictly:
- fatal gate error -> stop
- available or unavailable non-fatal result -> continue to queue planning

Important:
- Do not treat this initial probe as sufficient for the rest of the session.
- Before every actual worker launch set, you must run a fresh usage probe again.
- The real launch decision is based on the projected cost of the next launch set, not only the current usage seen here.

Autonomous wait rules:
- If a later launch-gate probe is blocked and `fiveHourResetAt` is available, call the usage gate in `wait` mode with the same threshold and let it wait until the gate opens.
- If a later launch-gate probe is unavailable or has no usable reset time, sleep for 5 hours, then run `probe` again.
- If the post-fallback probe is still unavailable, stop and report that the autonomous gate state could not be determined after the 5-hour fallback.
- If the post-fallback probe is still blocked but now provides a usable reset time, switch to the normal `wait` path.
- Do not create an unbounded 5-hour sleep loop.

User-facing reporting:
- tell the user when TLA pauses because of the 5h budget
- include the current `fiveHourUtilization`
- include `fiveHourResetAt` when available
- say whether TLA is using gate-script `wait` or the conservative 5-hour fallback
- when it resumes, report how long it waited and the final utilization that allowed launch
- when a launch set is blocked by projected cost, also report:
  - number of pipes about to start
  - estimated wave cost (`5% * pipeCount`)
  - projected usage after this launch set

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
- any `manual_debug_needed` tasks
- all pending-merge tasks
- the newly added tasks
- recent planner feedback from the queue snapshot
- nearby documentation markdown files relevant to the affected modules

## 8. Gate And Start Ready Pipes

Before any launch attempt, if the latest queue snapshot reports `queueStall.status == "stalled"`, do one automatic stall-recovery cycle:
1. call the `scheduler-agent` again on the latest snapshot
2. `apply-plan`
3. `snapshot-queue` again
4. only continue if the new snapshot is no longer stalled

If the same `queueStall.signature` is still stalled after that single recovery cycle, stop and report the stalled queue state instead of looping.

Before starting any task in `startableTaskIds`, run a fresh launch-gate check for this exact launch set.

Launch-gate procedure:
1. Build `candidateTaskIds` from `startableTaskIds`, preserving order and excluding tasks already running.
2. If `candidateTaskIds` is empty, do not run the gate and do not start anything.
3. Run the usage gate again in `probe` mode with `-ThresholdPercent 90`.
4. If the gate result is fatal, stop.
5. If the gate result is unavailable:
   - do not ask the user
   - use the 5-hour fallback wait
   - then re-run `probe`
   - if the probe is still unavailable, stop and report that the autonomous gate state could not be determined
6. Let `currentUsage = fiveHourUtilization` from the fresh available probe result.
7. Compute the largest ordered prefix of `candidateTaskIds` that fits under the projected threshold using:
   - `estimatedWaveCost = pipeCount * 5`
   - `projectedUsage = currentUsage + estimatedWaveCost`
   - only prefixes with `projectedUsage < 90` fit
8. Interpret the fitting result:
   - if the full candidate set fits, launch it
   - if only a non-empty prefix fits, launch that fitting prefix and leave the remaining startable tasks queued
   - if no prefix fits, do not ask the user; wait, then re-probe, then recompute the fitting prefix
9. If `fiveHourResetAt` is available, use gate `wait` for the no-fit case. If it is not available, use the 5-hour fallback once and then re-probe.
10. After any wait completes, recompute the fitting prefix from the fresh probe result.
11. If no prefix fits even after the wait/re-probe cycle, stop and report that no task in the current launch set fits the projected 5h budget right now.
12. Never launch a queued wave based only on an old probe.

For each task in the allowed fitting launch set, launch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode run-task -SolutionPath "<solution>" -TaskId "<task id>"
```

The scheduler resolves worker PowerShell in this order:
- `AUTODEV_POWERSHELL_COMMAND`
- `pwsh` / `pwsh.exe`
- `powershell.exe`

These workers may run in parallel when their current wave allows it.

Immediately after launching the current wave, hand queue waiting back to the scheduler:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode wait-queue -SolutionPath "<solution>"
```

Interpret the wait result strictly:
- `status == "woke"` and `reason == "task_completed"`: snapshot the queue again and continue with section 9
- `status == "woke"` and `reason == "merge_ready"`: snapshot the queue again and continue with section 9
- `status == "woke"` and `reason == "breaker_opened"`: stop and report the breaker state plus the returned progress snapshot
- `status == "woke"` and `reason == "queue_changed"`: snapshot the queue again, report the changed progress state, and continue conservatively with section 9
- `status == "timeout"`: report the returned progress snapshot and stop cleanly without inventing your own shell sleep or re-entry loop

Do not replace scheduler waiting with `sleep`, `timeout`, or ad hoc polling commands.

Report to the user:
- which tasks started
- which startable tasks were deferred because they did not fit the projected 5h budget
- which tasks were queued
- which tasks are retry-scheduled
- which tasks are paused as `manual_debug_needed`
- whether the circuit breaker is open
- the projected queue cost from `usageProjection`
- the launch-gate numbers for this wave:
  - current 5h utilization
  - candidate pipe count
  - started pipe count
  - estimated wave cost for the started subset
  - projected usage for the started subset
- a compact progress snapshot from:
  - `queueProgressSummary`
  - `runningTaskProgress`
  - `queuedTaskProgress`
  - `recentQueueEvents`

If `circuitBreaker.status == "manual_override"`, report that the breaker is temporarily suppressed until `manualOverrideUntil`.

Do not reduce this to only "started" / "queued" lines when richer progress data is available.

## 9. Autonomous Merge Flow

Whenever `wait-queue` wakes or you re-enter while tasks may have progressed:
1. Snapshot the queue.
2. If `queueStall.status == "stalled"`, do one automatic stall-recovery cycle:
   - call the `scheduler-agent` on the latest snapshot
   - `apply-plan`
   - `snapshot-queue` again
   - if the same `queueStall.signature` is still stalled, report that the queue remains stalled and stop instead of looping
3. Before any merge handling, show a compact progress snapshot for the user from:
   - `queueProgressSummary`
   - `runningTaskProgress`
   - `queuedTaskProgress`
   - `mergeTaskProgress`
   - `recentQueueEvents`
4. If a merge is already prepared, inspect that task record and its `sourceCommand`.
5. If `nextMergeTaskId` is present, call `prepare-merge`, then inspect the returned task record and its `sourceCommand`.
6. If the prepared task has `sourceCommand = "TLA-develop"`, call `resolve-merge -Decision commit` immediately.
7. If the prepared task has `sourceCommand = "develop"`, stop and ask the user to test it before any merge commit.
8. After each merge, snapshot again and start any newly startable tasks only after running the same fresh launch-gate procedure from section 8.

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

If a task enters `manual_debug_needed`, do not treat it as an ordinary scheduled retry. Report that repeated inconclusive investigation produced no new evidence and that the task now waits for repo changes, replanning, or explicit requeue.

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
- `queueStall.status == "stalled"`

Do not continue using stale wave assignments after the queue changed.
Do not continue using stale usage information either. Every launch decision must use a fresh usage probe plus projected wave cost.

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
