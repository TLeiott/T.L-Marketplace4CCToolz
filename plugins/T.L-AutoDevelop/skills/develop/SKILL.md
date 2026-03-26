---
name: develop
description: "Queue-aware interactive .NET development pipeline. Accepts a task text or a task file and orchestrates scheduler waves."
argument-hint: [task text or path to a task file]
disable-model-invocation: true
---

# /develop

CRITICAL: You are the Main-Claude orchestrator. You do not implement the requested code changes yourself.

Your job is to:
- validate the repository and solution context
- run the shared prepare check before queue orchestration
- resolve the argument as a direct task or a task file
- maintain the shared scheduler queue
- invoke the read-only `scheduler-agent` for conservative wave planning
- start background task pipes when the current wave allows them
- prepare normal merges one by one
- ask the user to test interactive tasks before the final merge commit

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

From this point on, always work with the absolute solution path.

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
- `status == "blocked"`: stop and explain the blocker before registering or planning anything
- `status == "ready"` or `status == "cleaned"`: continue
- `status == "warning"`: continue, but tell the user what warnings remain

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
- If it is an existing local file path, switch to task-file mode.
- Otherwise treat it as a single task text.

Task-file mode rules:
- Read the file.
- Extract individual tasks from bullet items, numbered items, or plain non-empty lines.
- Preserve source order.
- Ignore headings and blank lines.
- Support optional inline annotations:
  - `[after: <task id or earlier task number>]`
  - `[priority: high|normal|low]`
  - `[serial]`

Semantics:
- `[after: ...]` is a hard execution dependency, not just a planning hint.
- Tasks declared with `[after: ...]` must run in a later wave and must not start in parallel with their dependency target.

Each extracted task needs:
- `taskText`
- `sourceCommand = "develop"`
- `sourceInputType = "file"` or `"inline"`
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
Write prompt markdown and registration JSON with explicit UTF-8 encoding.
Do not rely on PowerShell here-strings for JSON escaping; prefer object -> `ConvertTo-Json` -> UTF-8 file writes so arbitrary Unicode task text survives intact.
Do not inline multiline PowerShell prompt-writing logic inside bash-quoted `-Command "..."` strings. Write files with direct UTF-8 file writes instead.
After writing each prompt file, verify it is non-empty and still contains a readable task line before calling `register-tasks`.

Each task prompt file must contain:

```md
## Task
<task text>

## Solution
<absolute solution path>
```

The registration JSON for each task should include:
- `taskText`
- `sourceCommand`
- `sourceInputType`
- `promptFile`
- `resultFile`
- `solutionPath`
- `allowNuget = false`

## 6. Probe the Usage Gate

Run the usage gate in `probe` mode with `-ThresholdPercent 90`.

Use this initial probe only to:
- detect fatal gate errors
- show the current 5h status to the user
- confirm whether a fresh usage state can be retrieved

Interpret the initial probe strictly:
- `processStatus == "fatal"`: stop and show the error.
- `ok == true`: continue to queue planning.
- `ok == false` or the script is unavailable: continue to queue planning, but do not treat the gate as launchable until a later fresh probe succeeds.

Important:
- Do not treat this initial probe as sufficient for the rest of the session.
- Before every actual worker launch set, you must run a fresh usage probe again.
- The real launch decision is based on the projected cost of the next launch set, not only the current usage seen here.

## 7. Snapshot the Existing Queue

Call:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode snapshot-queue -View Compact -SolutionPath "<solution>"
```

Read the returned JSON and keep:
- the current task list
- `startableTaskIds`
- `nextMergeTaskId`
- `mergePreparedTaskId`
- `queueStall`
- `plannerFeedbackSummary`
- `usageProjection`
- `circuitBreaker`
- `unknownAutoBranches`

If unknown `auto/*` branches are reported, tell the user before proceeding.

## 8. Register the New Tasks

Write the new task list to a JSON file and register it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode register-tasks -SolutionPath "<solution>" -TasksFile "<tasks.json>"
```

Then snapshot the queue again so the full active queue now includes:
- running tasks
- queued tasks
- retry-scheduled tasks
- any `manual_debug_needed` tasks
- pending-merge tasks
- the newly registered tasks

Use compact snapshots for routine orchestration reads. Only fall back to the full snapshot view when you need detailed run history or deep debug data.

## 9. Plan Waves with `scheduler-agent`

Use the `scheduler-agent` as a read-only subagent.

Give it:
- the full queue snapshot after registration
- the new tasks added in this invocation
- the current running tasks
- the current pending-merge tasks
- recent completed task discovery briefs from the latest queue snapshot
- recent planner feedback from `plannerFeedbackSummary`
- the nearest relevant `CLAUDE.md`, `AGENTS.md`, and `README.md`
- up to three additional nearby `*.md` files from relevant module or `docs/` directories

Use `completedTaskBriefs` only as advisory planning context for recently touched files, shared modules, and conflict risk. Do not treat them as hard dependency evidence when they are vague or failure-only.

Ask it for a conservative whole-queue execution plan in JSON with:
- `summary`
- `tasks[]` containing `taskId`, `waveNumber`, `blockedBy`, `plannerMetadata`
- `startableTaskIds`
- optional wave rationale

Save that JSON to a plan file and apply it through the scheduler:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode apply-plan -SolutionPath "<solution>" -PlanFile "<plan.json>"
```

## 10. Gate And Start Ready Pipes

Snapshot the queue again after applying the plan.

If that snapshot reports `queueStall.status == "stalled"`, do one automatic stall-recovery cycle before any launch attempt:
1. call the `scheduler-agent` again on the latest snapshot
2. `apply-plan`
3. `snapshot-queue` again
4. only continue if the new snapshot is no longer stalled

If the same `queueStall.signature` is still stalled after that single recovery cycle, stop and report the stalled queue state instead of looping or silently doing nothing.

Before starting any task in `startableTaskIds`, run a fresh launch-gate check for this exact launch set.

Launch-gate procedure:
1. Build the candidate launch set from `startableTaskIds`, preserving order and excluding tasks already running.
2. Let `pipeCount = count(candidate launch set)`.
3. If `pipeCount == 0`, do not run the gate and do not start anything.
3. Run the usage gate again in `probe` mode with `-ThresholdPercent 90`.
4. Compute:
   - `currentUsage = fiveHourUtilization`
   - `estimatedWaveCost = pipeCount * 5`
   - `projectedUsage = currentUsage + estimatedWaveCost`
5. Interpret the result:
   - fatal gate error -> stop
   - unavailable gate -> stop and report that the 5h budget could not be verified for this launch set
   - available gate and `projectedUsage < 90` -> launch
   - available gate and `projectedUsage >= 90` -> ask the user whether this launch set may overrun the 5h budget
6. If the user declines, leave the tasks queued and do not start them.

The question must be about the current launch set only, not about the whole session.
Always mention:
- current 5h utilization
- number of pipes about to start
- estimated wave cost (`5% * pipeCount`)
- projected usage after this launch set

For every task id in the candidate launch set, launch a background worker:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode run-task -SolutionPath "<solution>" -TaskId "<task id>"
```

The scheduler resolves worker PowerShell in this order:
- `AUTODEV_POWERSHELL_COMMAND`
- `pwsh` / `pwsh.exe`
- `powershell.exe`

These workers may run in parallel when they are in the same conservative wave.

Immediately after launching the current wave, hand queue waiting back to the scheduler:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode wait-queue -SolutionPath "<solution>"
```

Interpret the wait result strictly:
- `status == "woke"` and `reason == "task_completed"`: snapshot the queue again and continue with section 11
- `status == "woke"` and `reason == "merge_ready"`: snapshot the queue again and continue with section 11
- `status == "woke"` and `reason == "breaker_opened"`: stop and report the breaker state plus the returned progress snapshot
- `status == "woke"` and `reason == "queue_changed"`: snapshot the queue again, report the changed progress state, and continue conservatively with section 11
- `status == "timeout"`: report the returned progress snapshot and stop cleanly without inventing your own shell sleep or re-entry loop

Do not replace scheduler waiting with `sleep`, `timeout`, or ad hoc polling commands.

Tell the user:
- which tasks were started now
- which tasks were queued for later waves
- whether any tasks are currently retry-scheduled
- whether any tasks are paused as `manual_debug_needed`
- whether the circuit breaker is open
- the projected queue cost from `usageProjection`
- the launch-gate numbers for this wave:
  - current 5h utilization
  - number of pipes started
  - estimated wave cost
  - projected usage
- a compact progress snapshot from:
  - `queueProgressSummary`
  - `runningTaskProgress`
  - `queuedTaskProgress`
  - `recentQueueEvents`

If `circuitBreaker.status == "manual_override"`, report that the breaker is temporarily suppressed until `manualOverrideUntil`.

Do not reduce this to only "started" / "queued" lines when richer progress data is available.

## 11. Handle Scheduler Wake-Ups and Merge Turns

Whenever `wait-queue` wakes or you are re-entered while tasks may have progressed, always do this in order:
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
4. If a merge is already prepared, keep focus on that task and inspect its queued task record from the latest snapshot.
5. If no merge is prepared and `nextMergeTaskId` is present, call `prepare-merge`, then inspect the returned task record and its `sourceCommand`.
6. Snapshot again after `prepare-merge`.
7. Start any newly startable tasks only after the merge situation is resolved.
8. Before starting them, run the same fresh launch-gate procedure from section 10.

`nextMergeTaskId` may stay empty even when `pendingMergeTaskIds` is non-empty. This is expected while other tasks in the same wave are still `queued` or `running`. Detached worker retries no longer block merge turns for already finished wave work.

Per-task merge flow:
- If the prepared task has `sourceCommand = "develop"`, it should be in `waiting_user_test`.
- Use the merge preview from the scheduler result or `mergePreparedPreview` in the snapshot.
- Summarize the task, changed files, diff stat, review verdict, preflight status, and repro status before asking the user to test it now.
- Ask for one of: `commit`, `abort`, `discard`, `requeue`.
- If the prepared task has `sourceCommand = "TLA-develop"`, resolve it with `commit` immediately instead of pausing for manual testing.

Resolve it with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode resolve-merge -SolutionPath "<solution>" -TaskId "<task id>" -Decision <decision> -CommitMessage "<message when committing>"
```

Commit rules:
- Use a normal commit message in English that describes the actual change.
- Do not use squash wording.
- Do not reuse generic `auto-develop` text if you can describe the change concretely.

Decision rules:
- `commit`: finalize the prepared merge
- `abort`: keep the task pending for another merge attempt later
- `discard`: drop the task permanently
- `requeue`: reschedule the task as another attempt if the retry budget allows it

## 12. Retry Policy

The scheduler owns retries.

Treat these task states as retryable scheduled work:
- pipeline failures
- unexpected errors
- inconclusive outcomes
- merge conflicts
- build failures during merge preparation

If a task enters `manual_debug_needed`, do not treat it as an ordinary scheduled retry. Report that repeated inconclusive investigation produced no new evidence and that the task now waits for repo changes, replanning, or explicit requeue.

Each task gets at most 3 full attempts.

If a task is reported as `retry_scheduled`, do not treat it as done. It must stay in the queue and go back through planning.

If merge preparation fails after a worker already produced an accepted branch, the scheduler may preserve that branch and reschedule merge preparation separately instead of rerunning the whole worker immediately.

## 13. Replanning Rule

Run the scheduler-agent planning pass whenever the queue materially changes:
- new task submission
- task-file expansion
- task completion
- retry scheduling
- merge resolution
- circuit-breaker clear
- `queueStall.status == "stalled"`

Do not rely on stale wave assignments once the queue changes.
Do not rely on stale usage information either. Every launch decision must use a fresh usage probe plus projected wave cost.

## 14. User-Facing Tone

Keep updates short and factual. Always report:
- what started now
- what is currently running and in which phase
- what is queued
- what is blocked and why
- what changed since the last queue update
- what needs user testing
- what failed and was requeued
- what exhausted its attempts

When progress fields are present, prefer structured status lines over generic text like "No output available."
