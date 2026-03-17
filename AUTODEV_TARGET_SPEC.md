# AutoDevelop Target Specification

Status: Draft target spec
Scope: Desired behavior for the next AutoDevelop scheduler/orchestrator revision
Audience: Plugin implementers for `T.L-AutoDevelop` and `T.L-AutoDevelop-Pro`

## 1. Intent

This specification defines the desired target behavior for AutoDevelop after the V3 drift.

The target system is not "a better single-task pipeline". It is:

- a persistent, repo-scoped task scheduler
- driven by a Main-Claude orchestrator
- assisted by a Scheduler-Agent subagent for conservative wave planning
- able to accept new tasks while other pipes are already running
- able to merge accepted work without squash merges
- able to retry failed tasks as scheduled work
- fully English in all internal prompts and agent instructions

## 2. Core Design Principles

The implementation SHALL follow these principles:

1. Main-Claude is the entrypoint and traffic controller.
2. Scheduler state MUST be persistent on disk. Conversational memory alone is insufficient.
3. Queue planning MUST consider all known tasks, not just the newest submission.
4. Parallelism MUST be conservative. If disjointness is unclear, tasks serialize.
5. A wave is the unit of parallel execution. Merge happens only after a full wave is complete.
6. Merges MUST use normal merge semantics. Squash merges are forbidden.
7. Internal prompts and agent instructions MUST be English.

## 3. Terms

`Main-Claude`
- The top-level orchestrator the user interacts with.

`Scheduler-Agent`
- A subagent started by Main-Claude when queue planning or replanning is required.
- It performs read-only analysis and returns an execution plan.

`Pipe`
- One full implementation pipeline for one task attempt, running in its own worktree and branch.

`Task`
- A schedulable unit of work derived either from direct text input or from one entry inside a task file.

`Task Attempt`
- One full pipeline run for a task on a fresh worktree branch.

`Wave`
- A conservative group of tasks that may run asynchronously in parallel.

`Interactive Task`
- A task created by `/develop`.
- Requires a user validation checkpoint before final merge commit.

`Autonomous Task`
- A task created by `/TLA-develop`.
- Does not require a user validation checkpoint before final merge commit.

## 4. Command Surface

The target command surface is:

- `/develop <taskTextOrTaskFile>`
- `/TLA-develop <taskTextOrTaskFile>`

The following commands are deprecated as user-facing concepts:

- `/develop-batch`
- `/TLA-develop-batch`

They MAY remain as compatibility aliases, but they MUST resolve into the same unified scheduling path.

## 5. Argument Resolution

For both `/develop` and `/TLA-develop`, Main-Claude SHALL resolve the single argument as follows:

1. If the argument resolves to an existing local file path, treat it as task-file mode.
2. Otherwise, treat it as direct task text.

Task-file mode rules:

- Supported formats are plain text and Markdown.
- Tasks are extracted from:
  - `- bullet`
  - `* bullet`
  - `1. numbered item`
- Blank lines and headings are ignored.
- If no task items can be extracted, Main-Claude MUST stop with a clear error.

Each extracted task becomes an independent scheduled task with:

- its own task id
- its own attempt budget
- the same command type as the parent invocation

## 6. Required English Prompt Policy

All internal prompts MUST be English, including:

- skill instructions
- subagent prompts
- phase prompts inside the implementation pipeline
- validation and repair prompts
- review prompts
- queue-planning prompts
- structured result marker instructions

User-facing status updates SHOULD also default to English.

Generated commit messages SHOULD default to English unless:

- the repository explicitly requires another language
- the user explicitly requests another language

Repository documentation may remain in any language. Agents MAY read non-English docs, but the prompts they generate from them MUST still be English.

## 7. Persistent Scheduler State

The system MUST maintain persistent repo-scoped scheduler state on disk.

Recommended location:

- `.claude-develop-logs/scheduler/state.json`

Recommended related locations:

- `.claude-develop-logs/scheduler/events.jsonl`
- `.claude-develop-logs/runs/<taskName>/...`
- `%TEMP%/claude-develop/...` only for transient debug/process artifacts

The scheduler state MUST contain enough information for Main-Claude to recover after interruption, including:

- queued tasks
- running tasks
- completed tasks not yet merged
- retry-scheduled tasks
- current wave assignments
- attempt counts
- branch/worktree metadata
- command type (`develop` vs `TLA-develop`)
- last known result status

## 8. Task Model

Each task record MUST include at least:

- `taskId`
- `taskText`
- `sourceCommand`
- `sourceInputType` = `text | file`
- `originalOrder`
- `attemptsUsed`
- `maxAttempts`
- `state`
- `branchName`
- `worktreePath`
- `resultFile`
- `likelyAreas`
- `likelyFiles`
- `searchPatterns`
- `conflictRisk`
- `confidence`
- `waveNumber`
- `blockedBy`
- `artifacts`

Recommended `maxAttempts`:

- `3`

## 9. Task States

The target scheduler SHOULD use states equivalent to:

- `queued`
- `planning`
- `ready`
- `running`
- `completed_success_pending_wave_merge`
- `completed_no_change`
- `completed_failed_retryable`
- `completed_failed_terminal`
- `waiting_user_test`
- `waiting_user_merge_decision`
- `merged`
- `discarded`
- `aborted`

Exact names may differ, but the semantics MUST remain equivalent.

## 10. Validation Before Accepting Work

Before any submission is accepted, Main-Claude MUST validate:

- current directory is inside a git worktree
- solution file exists and is discoverable
- scheduler state is readable

Main-Claude MUST also verify main-worktree cleanliness.

Allowed states:

- fully clean main worktree
- or a scheduler-managed interactive merge checkpoint created by this system

Unmanaged dirty state MUST block new scheduling and merge operations.

## 11. Solution and Project Discovery

Main-Claude MUST discover:

- `.sln`
- `.slnx`

Search scope:

- current directory
- parent directories up to a practical repo boundary

If multiple solutions exist:

- Main-Claude MUST ask the user to choose
- or reuse the already-selected solution recorded in scheduler state for the same repo

## 12. Usage Gate Policy

Main-Claude MUST check the Claude usage statusline before any operation that may start new pipes.

Minimum trigger points:

1. after each user submission
2. before starting any new pipe from a replanned queue
3. before launching the first tasks of a newly eligible wave
4. before starting retries

The key blocking metric is:

- `fiveHourUtilization`

`sevenDayUtilization` is informational only.

### 12.1 Threshold

Default threshold:

- `90%`

### 12.2 Overrun Prompt

If `fiveHourUtilization >= 90%`, Main-Claude MUST ask the user whether starting new pipes may proceed anyway.

If the user declines:

- tasks remain queued
- no new pipes start
- existing running pipes continue

If the user approves:

- approval applies only to the current scheduling cycle
- it MUST NOT become a permanent global bypass

### 12.3 Unavailable Statusline/Cache

If statusline or cache are unavailable, Main-Claude MAY ask for one explicit fallback approval to continue without usage verification.

## 13. Scheduler-Agent Responsibilities

Whenever queue planning or replanning is required, Main-Claude MUST start a Scheduler-Agent subagent.

Scheduler-Agent input MUST include:

- all queued tasks
- all retry-scheduled tasks
- all running tasks
- all completed-but-unmerged tasks
- command type per task
- current attempt counts
- solution path
- relevant repository documentation excerpts

Scheduler-Agent output MUST include:

- predicted affected files and areas for each task
- confidence per prediction
- conservative conflict/dependency edges
- wave assignments
- list of tasks that may start immediately
- rationale for each serialized task

Scheduler-Agent MUST be read-only.

## 14. Documentation Gathering for Planning

Scheduler-Agent MUST gather additional context from Markdown documentation near the likely project areas.

The minimum search order is:

1. nearest relevant `CLAUDE.md`
2. nearest relevant `AGENTS.md`
3. nearest relevant `README.md`
4. up to 3 additional nearby `*.md` files under a relevant `docs/` or project folder if clearly related

The planner MUST stay conservative and MUST NOT bulk-load unrelated documentation.

If no relevant local docs are found:

- fall back to root-level repo docs

## 15. Replanning Triggers

Main-Claude MUST re-run Scheduler-Agent planning when any of the following occurs:

- a new task is submitted
- a task file adds multiple new tasks
- a running pipe finishes
- a task becomes retry-scheduled
- a merge completes
- a merge is aborted or discarded
- an external managed pipe is detected

Planning is therefore continuous and queue-aware, not one-time at submission.

## 16. Wave Planning Rules

Scheduler-Agent MUST plan in conservative waves.

Tasks MAY share a wave only if there is no credible overlap across:

- likely files
- likely project files
- likely configuration files
- likely top-level module roots
- likely schema/contract/API surfaces

If certainty is low:

- tasks MUST be serialized

Running tasks remain part of the active wave even when a new task is submitted later.

Newly submitted tasks may be added to the currently active wave only if:

- they are predicted conflict-free with all running tasks
- and conflict-free with all completed-but-not-yet-merged tasks from that wave

## 17. Pipe Start Rules

Main-Claude starts new pipes only after all of the following are true:

- the task is marked startable by the latest execution plan
- usage gate allows a new launch
- the task is not blocked by current merge state
- the task has remaining attempts

Each started pipe MUST run in:

- its own worktree
- its own branch
- a clean attempt-specific context

## 18. Pipeline Contract

The implementation pipeline MAY keep the current phase structure, but its external contract MUST support queue orchestration.

Expected pipeline phases:

- Discover
- Investigate
- optional Reproduce
- Fix Plan
- Implement
- Verify Repro
- Preflight
- Review

The pipe MUST write structured result artifacts with enough information for scheduler decisions, including:

- final status
- final category
- summary
- changed files
- target hints
- attempt counters
- branch name
- run artifacts

## 19. Task Attempt Budget

Each task gets:

- `3` task attempts

A task attempt is consumed when a full pipe run reaches a retryable terminal state.

### 19.1 Retryable Outcomes

The following outcomes SHOULD be treated as retryable while attempts remain:

- pipeline failure
- unexpected pipeline error
- investigation inconclusive
- insufficient fix plan
- implementation no-change uncertain
- implementation blocked
- preflight failed
- review denied
- reproduction verification failed
- merge conflict against current HEAD
- post-merge build failure

### 19.2 Non-Retry Outcomes

The following outcomes SHOULD be treated as final:

- successful merge commit
- confirmed already-satisfied no-change
- explicit user discard
- attempts exhausted

### 19.3 Retry Scheduling

Retryable tasks MUST be put back into scheduler state as normal scheduled tasks.

They MUST:

- retain prior attempt history
- receive a new fresh worktree/branch for the next attempt
- be reconsidered by Scheduler-Agent during replanning

Retries MUST NOT bypass planning.

## 20. Wave Completion Boundary

Main-Claude MUST treat a wave as complete only when:

- every pipe started in that wave has reached a terminal result for its current attempt
- and no pipe from that wave is still alive according to process/state checks

Only after that boundary may merge processing begin for that wave.

## 21. Merge Policy

Squash merge is forbidden.

Main-Claude MUST use normal merge semantics.

Recommended merge flow:

1. `git merge --no-commit --no-ff <taskBranch>`
2. if merge conflict: abort merge and mark task retryable or terminal based on attempts
3. run deterministic build/validation
4. for interactive tasks, ask the user to test before final commit
5. if approved, create the merge commit
6. if rejected, abort merge or revert managed merge state and handle according to user decision

This approach preserves normal merge semantics while still allowing a user validation checkpoint before the merge commit is finalized.

## 22. Interactive vs Autonomous Merge Behavior

### 22.1 `/develop`

For interactive tasks:

- Main-Claude MUST merge one accepted task at a time after wave completion
- Main-Claude MUST ask the user to test the merged result before proceeding
- Main-Claude MUST wait for an explicit decision before continuing to the next accepted task

Allowed decisions SHOULD include:

- commit
- abort/discard
- optionally requeue

### 22.2 `/TLA-develop`

For autonomous tasks:

- Main-Claude MUST merge one accepted task at a time after wave completion
- no user test checkpoint is required
- commit proceeds automatically if merge and validation succeed

## 23. Merge Ordering

Accepted tasks MUST be merged in deterministic order:

1. wave number ascending
2. original submission order within the wave

If a later accepted task now conflicts with already merged results from the same wave:

- it MUST NOT be force-merged
- it MUST be reclassified as retryable or skipped
- it MUST be replanned against the new HEAD if attempts remain

## 24. User Testing Checkpoint

For `/develop`, the user validation checkpoint happens after:

- a clean non-squash merge has been prepared
- deterministic build/validation has passed

At that point Main-Claude asks the user to test.

If the user confirms:

- Main-Claude commits the merge
- branch/worktree cleanup proceeds

If the user rejects:

- Main-Claude MUST abort or cleanly unwind the prepared merge state
- the task MAY be discarded or requeued based on the user's decision

## 25. Commit Messages

Commit messages MUST be content-based.

Commit messages SHOULD:

- summarize the actual change
- default to English
- avoid generic filler such as only `auto-develop`

Whether a prefix is used is implementation-specific, but the message MUST remain understandable without hidden context.

## 26. Branch and Worktree Policy

Each task attempt MUST use:

- a fresh worktree
- a fresh branch

Branch names SHOULD encode:

- command type
- task id
- attempt number

Completed branches MUST be cleaned up after:

- successful merge
- explicit discard
- exhausted failure

## 27. Actual Overlap Recheck

Predicted overlap is conservative, but actual overlap MUST still be rechecked before merge.

At merge time, Main-Claude MUST compare:

- actual changed files from accepted tasks in the completed wave
- files already merged into current HEAD

If unexpected overlap exists:

- later tasks MUST not merge automatically
- they MUST be requeued or skipped conservatively

## 28. External Managed Work Detection

The scheduler MUST detect already running or pending managed work from:

- active scheduler state
- managed debug manifests
- managed task branches

Unknown unmanaged `auto/*` branches MUST block automatic scheduling until clarified.

## 29. Main-Claude Behavior Summary

Main-Claude SHALL:

1. accept new work at any time
2. resolve text vs task-file mode
3. validate solution and repo state
4. check usage gate before starting new pipes
5. start Scheduler-Agent whenever planning/replanning is needed
6. persist queue state
7. start only the currently allowed pipes
8. wait for full-wave completion before merge
9. merge one accepted task at a time without squash
10. requeue failures up to 3 attempts

## 30. Target Flow Example

The following is the intended canonical behavior:

1. User sends `/develop <task1>`.
2. Main-Claude validates repo and solution.
3. Main-Claude checks usage statusline.
4. If `5h >= 90%`, Main-Claude asks for explicit overrun approval.
5. Main-Claude starts Scheduler-Agent planning.
6. Scheduler-Agent returns a plan with `task1` in wave 1.
7. Main-Claude starts the first pipe for `task1`.
8. User sends `/develop <task2>`.
9. Main-Claude sees an existing running pipe.
10. Main-Claude checks usage statusline again.
11. Main-Claude starts Scheduler-Agent with all active tasks.
12. Scheduler-Agent predicts whether `task2` may join the active wave or must wait.
13. Main-Claude starts `task2` immediately only if the plan marks it safe.
14. User sends `/develop <pathToTaskFile>`.
15. Main-Claude extracts tasks from the file.
16. Main-Claude replans the full queue with Scheduler-Agent.
17. Main-Claude starts only the newly startable tasks.
18. A task fails.
19. Main-Claude records the failure and schedules a retry if attempts remain.
20. A full wave completes.
21. Main-Claude confirms no wave pipes are still running.
22. Main-Claude merges accepted tasks one by one using normal merge semantics.
23. Interactive tasks pause for user testing before final merge commit.
24. Autonomous tasks commit automatically.
25. Main-Claude checks usage gate again before starting the next eligible wave.
26. Main-Claude replans remaining queued and retryable tasks.

## 31. Source User Story Prompt

The following user story is preserved as the motivating source prompt for this target specification.

- User sends a `/develop <task1>`
- Main-Claude checks for the files needed (`.slnx` and related solution files)
- Main-Claude checks usage session limit via statusline and asks for permission to overrun if above 90%
- Main-Claude starts the pipe with the required context
- User sends another `/develop <task2>`
- Main-Claude knows that there is already a pipe running
- Main-Claude checks usage session limit via statusline and asks for permission to overrun if above 90%
- Main-Claude starts a subagent, forwarding the prompts for all tasks scheduled or running
- Scheduler-Agent checks all forwarded prompts and gathers additional information about already running projects via their documentation Markdown files
- Scheduler-Agent evaluates what files would be edited for which change and plans an execution plan in waves of pipe starts to enable multiple asynchronous pipes without likely merge problems; when uncertain, it stays conservative
- Scheduler-Agent returns the execution plan to Main-Claude
- Main-Claude checks whether the newly added task can run in parallel to the already running task and starts the pipe if it can
- User sends a `/develop <PathToAFileWithMultipleTasks>`; there is no separate batch command anymore
- Main-Claude extracts the individual tasks from the file
- Main-Claude knows that there are already pipes running
- Main-Claude checks usage session limit via statusline and asks for permission to overrun if above 90%
- Main-Claude starts a subagent, forwarding the prompts for all tasks scheduled or running
- Scheduler-Agent checks all forwarded prompts and gathers additional information about already running projects via their documentation Markdown files
- Scheduler-Agent evaluates what files would be edited for each task and plans an execution plan in waves of pipe starts to enable multiple asynchronous pipes without likely merge problems; when uncertain, it stays conservative
- Scheduler-Agent returns the execution plan to Main-Claude
- Main-Claude checks which newly added tasks can run in parallel to the already running tasks and starts their pipes
- `<task1>` finishes successfully
- Main-Claude waits
- `<task2>` finishes with fail
- Main-Claude remembers this and keeps it as a scheduled task; every task gets 3 tries
- `<task3>` finishes
- Main-Claude knows all pipes started in this wave are complete and checks for still running pipes just to be sure
- Main-Claude merges, not squash merges, each change one by one and, depending on whether a task was added with the `TLA-*` command, asks the user to test it before proceeding
- Main-Claude checks usage session limit via statusline and asks for permission to overrun if above 90%
- Main-Claude starts a subagent, forwarding the prompts for all scheduled tasks
- Scheduler-Agent checks all forwarded prompts, evaluates what files would be edited by each task, and plans the next execution waves
- Scheduler-Agent returns the execution plan to Main-Claude
- Main-Claude starts the next pipes based on the execution plan
- This cycle repeats until the queue is resolved

## 32. Required Deltas From Current Repo Behavior

The implementation needed to reach this target differs from current repo behavior in these mandatory ways:

1. `/develop` and `/TLA-develop` must absorb task-file mode; batch commands are no longer the primary UX.
2. Queue planning must become full-queue replanning, not only incremental single-task placement.
3. A Scheduler-Agent subagent must become the planning authority for wave generation.
4. Statusline policy must change from "wait until below threshold" to "ask for overrun approval when above threshold".
5. All internal prompts must be translated to English.
6. Merge strategy must change from squash merge to normal merge semantics.
7. Interactive tasks must gain an explicit user testing checkpoint before final merge commit.
8. Failed tasks must become retry-scheduled tasks with a 3-attempt budget.

## 33. Non-Goals

The target spec does not require:

- aggressive maximum parallelism
- guaranteed perfect overlap prediction
- replacing the existing pipeline phases if they already satisfy the contract
- user-visible batch-specific commands

## 34. Acceptance Criteria

The target behavior is reached only when all of the following are true:

- `/develop` accepts either direct task text or a task file
- `/TLA-develop` accepts either direct task text or a task file
- queue state survives interruptions
- Main-Claude replans with a Scheduler-Agent whenever the queue changes materially
- new tasks can join safely while other pipes are already running
- failed tasks are retried up to 3 times as scheduled work
- wave completion gates merge
- all merges are non-squash
- interactive tasks pause for user testing before final merge commit
- all internal prompts are English
