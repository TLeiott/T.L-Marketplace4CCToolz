# AutoDevelop Pipeline Feedback Evaluation

Date: 2026-03-25
Branch evaluated: `DEV`
Scope: evaluation of external Claude session feedback against the current AutoDevelop implementation in this repository

## Source Context

An external Claude instance reported results from running roughly 20 tasks through the AutoDevelop pipeline. The feedback focused on repeated failures in cross-file features, especially where the worker needed to reuse existing code paths, wire multiple layers together, and react to prior review denials.

This document stores:

- the important feedback themes
- what was validated in the current code
- what is already partially addressed elsewhere
- the recommended change list as a checklist

## Executive Summary

The feedback is high-signal and broadly credible.

The current system appears strong in:

- scheduler rigor
- wave planning and merge sequencing
- deterministic preflight
- reviewer quality

The weak point is the worker on semantically coupled, cross-file tasks.

The biggest gaps are:

1. merge preparation does not restore before build
2. retries start too cold and do not receive prior denial context
3. worker prompts do not force a prior-art scan before planning or implementing reuse-heavy tasks
4. deterministic checks do not currently verify cross-file wiring such as `EventCallback` bindings or JS interop chains
5. remediation prompts are too thin for reliable self-correction on compile and wiring failures

## Follow-Up Status Update

Added after the original 2026-03-25 evaluation.

The following items from this document are now implemented on `DEV`:

- merge preparation restore before build: solved
- retry-context injection across attempts: solved
- retry-context hardening so only semantic blockers carry forward: solved

What this means in practice:

- merge verification now restores before the `--no-restore` build
- retries now receive structured retry context compiled from prior semantic failures
- prior review denials and other actionable blockers are injected into DISCOVER, INVESTIGATE, FIX_PLAN, IMPLEMENT, and remediation prompts
- infra/runtime noise is excluded from retry memory so future retries do not get polluted by non-semantic failures

Highest open item after these fixes:

- prior-art scan requirement for reuse-heavy and cross-file tasks

## High-Level Recommendation

Do not redesign the scheduler or weaken the reviewer.

The right move is to strengthen the worker pipeline for complex tasks while leaving the simple-task fast path largely intact.

In practical terms:

- fix merge restore immediately
- add retry memory across attempts
- require prior-art grounding for reuse and cross-file work
- add targeted semantic wiring checks
- improve remediation context for build and review failures

## Code-Verified Findings

### 1. Merge Preparation: Missing `dotnet restore`

Status: validated

Current merge preparation merges the task branch and then runs:

- `dotnet build <solution> --no-restore`

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/scheduler.ps1`
  - `Invoke-MergeBuildAttempt`
  - build call after merge

Why this matters:

- if a worker adds a new NuGet package, the worker worktree may restore it successfully
- merge verification runs in a different context
- `--no-restore` can fail even when the project diff is correct

Assessment:

- this is a concrete bug, not a preference
- this should be fixed first

### 2. Workers Do Not Reliably Reuse Existing Code

Status: validated structurally

The current worker prompt flow does not require a prior-art analysis before planning.

Observed prompt characteristics:

- DISCOVER is brief and routing-oriented
- INVESTIGATE asks for root cause and targets
- FIX_PLAN asks for a concrete plan
- IMPLEMENT asks for focused execution

What is missing:

- no mandatory "find existing implementation that already does this"
- no required summary of matching handlers, services, or call chains
- no required reference-code extraction for reuse-heavy tasks

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/auto-develop.ps1`
  - DISCOVER prompt block
  - INVESTIGATE prompt block
  - FIX_PLAN prompt block
  - IMPLEMENT prompt block

Assessment:

- the feedback about the worker inventing parallel logic instead of reusing named converters is exactly the kind of miss this prompt design allows
- this is likely the main cause of failures on end-to-end feature work

### 3. Unbound `EventCallback` Wiring Gaps

Status: validated as an uncovered deterministic gap

No deterministic check was found for:

- a new component `EventCallback` parameter that is never bound by a parent
- a parent-child callback chain that is incomplete

Current preflight focuses on:

- build success
- tests
- forbidden comments
- stub detection
- file-shape/style heuristics
- a few framework warnings

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/preflight.ps1`

Assessment:

- the reviewer can catch this
- the pipeline does not catch it early
- this is a good target for a low-cost semantic lint

### 4. Review Feedback Is Not Carried Into New Retries

Status: validated

Within a single worker run, feedback is tracked and reused.

However, across separate worker attempts, the next launch does not receive prior lessons in a structured way.

What is persisted today:

- final category
- summary
- feedback
- files changed
- investigation conclusion
- related run metadata

What is passed into a new worker launch today:

- planner metadata only, via `planner-context.json`

What is missing:

- retry context compiled from previous run denials
- explicit blocker carry-forward
- "do not repeat this" guidance

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/scheduler.ps1`
  - `Write-PlannerContextFile`
  - `Run-Task`
- `plugins/T.L-AutoDevelop/scripts/auto-develop.ps1`
  - intra-run `feedbackHistory` exists
  - no cross-run retry context input

Assessment:

- the feedback is correct
- the worker currently starts too cold on retry

### 5. `NO_CHANGE_UNCERTAIN` Should Fail Faster

Status: partially validated

The current worker already has some protection:

- it checks whether a no-change result contains actionable signal
- it can attempt one repair
- it terminates if two identical no-change outputs repeat without new information

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/auto-develop.ps1`
  - `Get-NoChangeAssessment`
  - `Test-HasActionableSignal`
  - `TERMINAL_NO_CHANGE_REPEAT`

What still remains weak:

- the expensive part is the long IMPLEMENT attempt before that logic triggers
- there is no early time-budget guard for low-progress implement runs
- a worker can still burn substantial time before producing a useless no-change result

Assessment:

- the complaint is directionally correct
- the pipeline has some protection, but too late

### 6. Worker Uses Outdated Package APIs

Status: validated as a structural risk

There is no package-aware API verification step after adding or changing a package.

Current behavior:

- worker is instructed to run `dotnet build --no-restore` after changes
- preflight later runs another build

What is missing:

- targeted restore/build immediately after package changes
- package-version-aware API verification
- a rule to confirm the actual attribute/type/member shape before the worker commits to it

Assessment:

- this explains failures like using removed SDK attributes
- this is not only a model problem; the pipeline should provide a better guardrail

### 7. Build Failures Not Reliably Self-Corrected

Status: partially validated

The remediation loops do exist.

Current strengths:

- preflight failures feed blocker text back into remediation
- review denials can trigger remediation
- build/test failures are not silently ignored

Current weakness:

- remediation prompts are often too thin
- they do not always include enough context to converge on compile failures
- they rely heavily on the worker inferring the right fix from a short blocker list

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/auto-develop.ps1`
  - preflight remediation prompt
  - review remediation prompt

Assessment:

- the pipeline attempts self-correction
- the current remediation payload is too weak for tricky compile and cross-file errors

### 8. Cross-File Features Need a Wiring Verification Step

Status: validated

No deterministic semantic check was found for chains like:

- JS `invokeMethodAsync` -> matching `[JSInvokable]`
- child component callback -> parent binding
- UI event -> parent -> service

The current implementation-scope check only compares changed files against planned targets. It does not verify semantic completeness.

Relevant code:

- `plugins/T.L-AutoDevelop/scripts/auto-develop.ps1`
  - implementation-scope check
- `plugins/T.L-AutoDevelop/scripts/preflight.ps1`
  - no wiring verification layer

Assessment:

- this is one of the best next deterministic additions
- it should be kept narrow to avoid false positives

### 9. What Already Looks Strong

Status: consistent with both the feedback and the codebase structure

The feedback positively highlighted:

- reviewer quality
- wave planning and merge sequencing
- retry scheduling
- preflight usefulness
- reliability on small and focused tasks

That aligns with the current design:

- queue and merge orchestration are mature
- review has clear blocker-focused rules
- deterministic checks already catch many cheap failures

Assessment:

- this is not a failing system overall
- it is a system that needs better worker guidance and better semantic guardrails on harder tasks

## Important Existing Context From Prior Internal Analysis

The repository already contains earlier analysis that predicted several of these gaps.

Key prior recommendations:

- inject discovery briefs into workers, not only the scheduler
- add retry context injection across attempts
- use lightweight hooks and pattern checks during implementation

Relevant report:

- `AUTODEV_VS_CITADEL_REPORT.md`

Important status note already recorded there:

- planner effort wiring: done
- discovery briefs to scheduler-agent: done
- direction check after fix-plan: done or pending in current 4.2.11 line
- retry context injection: done

Conclusion:

- the new external feedback mostly confirms existing strategic conclusions
- it gives sharper operational evidence about which missing pieces hurt most in practice

## Recommended Change Set

### Immediate

- done: `dotnet restore` before merge verification build
- done: keep `dotnet build --no-restore` afterward so the build still proves restore completeness

### Next Highest Value

- done: add retry-context injection for new attempts
- done: pass prior review denials and failed-attempt lessons into DISCOVER, INVESTIGATE, FIX_PLAN, and IMPLEMENT
- done: explicitly state prior blockers as must-fix constraints
- done: harden retry memory so infra/runtime failures do not pollute future retries

### Worker Grounding Improvements

- add a required prior-art scan step for reuse-heavy or cross-file tasks
- require the worker to cite existing implementation references before planning
- require plan output to mention what existing path is being reused and how

### Deterministic Semantic Checks

- add `EventCallback` parent-binding verification for newly introduced component parameters
- add JS interop verification for `invokeMethodAsync` and `[JSInvokable]`
- add narrow multi-layer wiring checks for known patterns instead of one generic "semantic correctness" check

### Better Remediation

- include task, validated plan, changed files, and exact blocker context in remediation prompts
- when build errors occur, feed the concrete compiler errors back with stronger fix instructions
- consider a targeted build immediately after package changes or other high-risk edits

### Faster Failure on Low-Progress Implement Attempts

- add an early fail-fast path for long implement attempts that produce no changes and no usable evidence
- optionally split implement into a shorter first probe plus full attempt only when the probe finds a concrete path

## What I Would Not Change

- do not weaken the reviewer
- do not remove wave conservatism
- do not replace deterministic preflight with a purely model-based check
- do not optimize for complex cross-file work by harming the simple-task success path

## Recommended Priority Order

1. Prior-art scan requirement
2. Wiring verification checks
3. Richer remediation prompts
4. Package-aware API verification
5. Faster no-change fail-fast behavior

## Tick-Off Checklist

### Merge Prep

- [x] Add `dotnet restore` to merge preparation before `dotnet build --no-restore`
- [ ] Add a scheduler test that reproduces a newly added package surviving worker build but failing merge prep without restore
- [ ] Record restore/build timing in merge-prep artifacts for later comparison

### Retry Memory

- [x] Extend worker result JSON with structured retry lessons derived from `feedbackHistory`
- [x] Persist lessons into scheduler run records
- [x] Generate a retry-context file from prior runs in `Run-Task`
- [x] Pass retry-context into the worker as a dedicated input file
- [x] Inject retry-context into DISCOVER
- [x] Inject retry-context into INVESTIGATE
- [x] Inject retry-context into FIX_PLAN
- [x] Inject retry-context into IMPLEMENT for attempt 1 of a retry
- [x] Add tests proving review denials are visible on the next retry
- [x] Exclude infra/runtime-only failures from retry memory
- [x] Persist stable run-level retry lesson metadata instead of ambiguous local attempt labels

### Prior-Art Scan

- [ ] Add a worker rule that tasks mentioning reuse, existing functionality, or named methods must perform a prior-art scan
- [ ] Require INVESTIGATE to output existing reference files or search hits when reuse is implied
- [ ] Require FIX_PLAN to include a "reuse/reference pattern" note
- [ ] Add a failure mode when the worker plans a reuse-heavy task without concrete reference paths

### Wiring Checks

- [ ] Add deterministic detection of new `EventCallback` parameters in changed `.razor` components
- [ ] Verify that each newly introduced callback name is bound in at least one parent `.razor` usage
- [ ] Add JS interop verification for `invokeMethodAsync` to `[JSInvokable]`
- [ ] Add targeted chain checks for known UI -> parent -> service patterns where feasible
- [ ] Keep checks narrow and opt for warnings first if false-positive risk is unclear

### Remediation Quality

- [ ] Enrich preflight remediation prompts with task, plan, changed files, and exact build/test errors
- [ ] Enrich review remediation prompts with task and validated plan, not only feedback text
- [ ] Add a compile-error-focused remediation mode for `CSxxxx` failures
- [ ] Add tests for remediation convergence on straightforward missing-using and wrong-symbol failures

### Package/API Safety

- [ ] Detect `.csproj` or `PackageReference` changes during implementation
- [ ] Trigger restore plus targeted build immediately after package changes
- [ ] Add prompt guidance to verify actual SDK/API shape before using new package types or attributes
- [ ] Capture package-change artifacts for debugging

### Fail-Fast No-Change Handling

- [ ] Add a shorter early implement probe for uncertain tasks
- [ ] Fail faster when implement returns no changes and no actionable evidence
- [ ] Add timing telemetry for no-change outcomes
- [ ] Add a policy threshold for maximum wasted implement time before forced failure

### Worker Brief Injection

- [ ] Pass `completedTaskBriefs` or a worker-focused subset into the worker, not only the scheduler-agent
- [ ] Inject those briefs into DISCOVER
- [ ] Inject those briefs into INVESTIGATE
- [ ] Evaluate whether failed-task briefs should be included separately from accepted-task briefs

## Closing Assessment

The external feedback should be treated as a useful confirmation, not as a contradiction of the system's strengths.

The system is already strong at orchestration, review, and focused tasks.

The next improvements should be narrow and surgical:

- restore at merge
- memory across retries
- stronger grounding before planning
- deterministic checks for wiring mistakes

That is the smallest change set most likely to improve the exact failure modes observed in the session feedback.
