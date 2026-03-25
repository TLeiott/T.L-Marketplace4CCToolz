---
name: develop-prepare
description: "Prepare AutoDevelop for a new session by reconciling scheduler state and cleaning safe AutoDevelop-owned leftovers."
disable-model-invocation: true
---

# /develop-prepare

CRITICAL: You are the Main-Claude orchestrator. You do not implement repository code changes yourself.

Your job is to:
- resolve the repository and solution context
- locate the shared AutoDevelop scheduler
- run the scheduler `prepare-environment` mode
- report whether AutoDevelop is ready, cleaned, warning, or blocked

Allowed tools: `Read`, `Glob`, `Grep`, `Bash`.

Do not edit repository files directly in this skill.
Do not register tasks.
Do not start workers.
Do not prepare or resolve merges.

## 1. Validate the Repository Context

Use one Bash call to verify:
- `git rev-parse --is-inside-work-tree` returns `true`

If it fails, stop and explain the problem.

## 2. Resolve the Solution

Find `*.sln` and `*.slnx` in the current directory and up to two parent directories.
- If none are found, stop.
- If more than one is found, ask the user which solution to use.

From this point on, always work with the absolute solution path.

## 3. Resolve the Scheduler Script

Find `scheduler.ps1` from the installed plugin.
- If it cannot be found, stop.

## 4. Run Prepare

Call:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scheduler.ps1>" -Mode prepare-environment -SolutionPath "<solution>"
```

Read the returned JSON and report:
- `status`
- `summary`
- whether AutoDevelop is ready to continue
- dirty repo state, if any
- unresolved git operation blockers, if any
- cleanup actions that were performed
- cleanup warnings that remain
- unknown AutoDevelop branches or worktrees that remain
- scheduler integrity warnings, if any
- the compact post-prepare queue snapshot:
  - `queueProgressSummary`
  - `queueStall`
  - `circuitBreaker`

When you need a queue snapshot outside of `prepare-environment`, prefer `snapshot-queue -View Compact` for routine reads and only use the full view for deep debugging.

Interpretation:
- `status == "ready"`: report that AutoDevelop is ready
- `status == "cleaned"`: report what was cleaned and that AutoDevelop is now ready
- `status == "warning"`: report the warnings, but explain that AutoDevelop can still continue
- `status == "blocked"`: stop and explain exactly what is blocking a safe session start

Do not continue into queue planning or worker launch from this command.
