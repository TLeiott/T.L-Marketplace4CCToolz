---
name: pipe-feedback
description: "Analyze a completed or in-progress AutoDevelop session and give honest, constructive feedback on friction points, failure patterns, inefficiencies, and improvement opportunities in the pipeline."
argument-hint: "[optional: path to run dir or task id to focus on]"
disable-model-invocation: true
---

# /pipe-feedback

Your job is to observe, analyze, and give honest feedback on the AutoDevelop pipeline based on what actually happened in this session. You are not here to summarize progress — you are here to find problems, rough edges, and improvement opportunities that the developer (who built this pipeline) would want to know about.

Be specific. Be direct. Praise what worked well too — balanced feedback is more useful than a list of complaints.

Allowed tools: `Read`, `Glob`, `Grep`, `Bash`.

Do not modify any files. Do not run the scheduler. Do not start tasks.

---

## 1. Locate Session Artifacts

Find the scheduler state and recent run artifacts:

```
<repo-root>/.claude-develop-logs/scheduler/
<repo-root>/.claude-develop-logs/runs/
```

If no run artifacts exist, report that there is no session data to analyze and stop.

Read:
- The latest scheduler state file (`state.json` or equivalent)
- The events file to reconstruct the session timeline
- Up to 5 of the most recent run directories (sorted by modification time, newest first)

For each recent run, read if present:
- `timeline.json` — phase transitions and milestones
- `scheduler-snapshot.json` — task state at the time of the run
- The worker result file referenced in the snapshot

---

## 2. Reconstruct What Happened

From the artifacts, build a factual picture of the session:

- How many tasks were submitted?
- How many completed successfully (reached `merged` or `completed_no_change`)?
- How many went to `retry_scheduled`, `manual_debug_needed`, or `completed_failed_terminal`?
- What phase did failures happen in (INVESTIGATE, FIX_PLAN, IMPLEMENT, VERIFY, MERGE)?
- Were there any queue stalls? What caused them?
- Were there any circuit breaker trips?
- How long did the session run? How long did individual tasks take?
- Did any wave assignments need to be corrected mid-session?

---

## 3. Identify Friction Points

Look specifically for:

**Retry patterns**
- Did multiple tasks fail at the same phase? That suggests a systemic issue in that phase, not a task-specific one.
- Did `FIX_PLAN_INSUFFICIENT` appear on tasks that seem straightforward? That may indicate an overly strict plan evaluator or missing codebase context.
- Did retries succeed where attempt 1 failed? If so, what changed?

**Stall patterns**
- Did the queue stall after retries lost their wave assignments? The scheduler should preserve wave assignments through retries automatically.
- Did stall recovery require an unnecessary replan pass that only reassigned tasks back to their original wave?

**Orchestration friction**
- Did the orchestrator (Claude) need to create temporary scripts (e.g., in `C:\Temp\`) to parse scheduler output? That indicates the scheduler output is too large or lacks a compact summary mode.
- Did any scheduler output files exceed readable size, requiring file I/O workarounds?
- Did task texts get modified (e.g., special characters stripped) between the user's input and the registered prompt? That is a data fidelity issue.
- Were there unnecessary sequential steps that could have been parallelized?

**Context quality**
- Did workers appear to lack codebase context (e.g., guessing file paths that don't exist)?
- Did the planner assign overly conservative wave dependencies that blocked parallelism without good reason?
- Did retry attempts receive any information about why attempt 1 failed?

---

## 4. Identify What Worked Well

Be equally specific about things that functioned smoothly:

- Did wave planning correctly separate conflicting files?
- Did the usage gate work without false positives?
- Did prepare-environment catch and clean real leftovers?
- Did any tasks complete cleanly on attempt 1?
- Was the stall detection prompt and accurate?

---

## 5. Deliver the Feedback Report

Structure the report as follows:

### Session Summary
One short paragraph: what ran, what succeeded, what failed, overall health.

### What Worked Well
Bullet list. Specific and honest — skip this section if nothing stood out positively.

### Friction Points & Issues
For each issue:
- **What happened** (fact)
- **Why it matters** (impact on reliability, speed, or developer experience)
- **Suggested fix** (concrete, actionable)

Prioritize by impact. Do not pad with minor nitpicks unless the serious issues list is short.

### Patterns Worth Watching
Things that didn't break this session but could break at scale or with more tasks. Flag them clearly as early warnings, not confirmed bugs.

### Overall Assessment
One or two sentences. Honest. If the session was rough, say so. If it went well despite a few bumps, say that too.

---

## Tone

- Direct and factual. No corporate hedging.
- Treat the reader as the developer who built this system — they want the unfiltered view.
- Short sentences. Skip "It's worth noting that..." style filler.
- If something is broken, say it's broken. If something is a minor nuisance, call it that.
