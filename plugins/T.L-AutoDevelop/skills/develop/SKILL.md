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
- `git status --porcelain` is empty

If either check fails, stop and explain the problem.

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

Interpret the result strictly:
- `processStatus == "fatal"`: stop and show the error.
- `ok == true` and `fiveHourUtilization < 90`: continue.
- `ok == true` and `fiveHourUtilization >= 90`: ask the user whether this scheduling cycle may overrun the 5h budget.
- `ok == false` or the script is unavailable: ask whether the 5h limit should be ignored for this scheduling cycle.

Do not silently wait for the budget to drop. The user must explicitly approve a launch above the threshold.

If the user declines, stop after leaving the queue unchanged.

## 7. Snapshot the Existing Queue

Call:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode snapshot-queue -SolutionPath "<solution>"
```

Read the returned JSON and keep:
- the current task list
- `startableTaskIds`
- `nextMergeTaskId`
- `mergePreparedTaskId`
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
- pending-merge tasks
- the newly registered tasks

## 9. Plan Waves with `scheduler-agent`

Use the `scheduler-agent` as a read-only subagent.

Give it:
- the full queue snapshot after registration
- the new tasks added in this invocation
- the current running tasks
- the current pending-merge tasks
- recent planner feedback from `plannerFeedbackSummary`
- the nearest relevant `CLAUDE.md`, `AGENTS.md`, and `README.md`
- up to three additional nearby `*.md` files from relevant module or `docs/` directories

Ask it for a conservative whole-queue execution plan in JSON with:
- `summary`
- `tasks[]` containing `taskId`, `waveNumber`, `blockedBy`, `plannerMetadata`
- `startableTaskIds`
- optional wave rationale

Save that JSON to a plan file and apply it through the scheduler:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode apply-plan -SolutionPath "<solution>" -PlanFile "<plan.json>"
```

## 10. Start Ready Pipes

Snapshot the queue again after applying the plan.

For every task id in `startableTaskIds` that is not already running, launch a background worker:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode run-task -SolutionPath "<solution>" -TaskId "<task id>"
```

These workers may run in parallel when they are in the same conservative wave.

Tell the user:
- which tasks were started now
- which tasks were queued for later waves
- whether any tasks are currently retry-scheduled
- whether the circuit breaker is open
- the projected queue cost from `usageProjection`

If `circuitBreaker.status == "manual_override"`, report that the breaker is temporarily suppressed until `manualOverrideUntil`.

## 11. Handle Completions and Merge Turns

Whenever you are re-entered after one or more tasks completed, always do this in order:
1. Snapshot the queue.
2. If a merge is already prepared, keep focus on that task and inspect its queued task record from the latest snapshot.
3. If no merge is prepared and `nextMergeTaskId` is present, call `prepare-merge`, then inspect the returned task record and its `sourceCommand`.
4. Snapshot again after `prepare-merge`.
5. Start any newly startable tasks only after the merge situation is resolved.

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

Do not rely on stale wave assignments once the queue changes.

## 14. User-Facing Tone

Keep updates short and factual. Always report:
- what started now
- what is queued
- what needs user testing
- what failed and was requeued
- what exhausted its attempts
