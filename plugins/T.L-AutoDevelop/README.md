# T.L-AutoDevelop

Interactive queue-aware .NET development orchestration for Claude Code, Codex, and OpenCode.

## Command

- `/develop [task text or path-to-task-file]`
- `/develop-prepare`
- `/pipe-feedback [optional: path-to-run-dir or task-id]`
- `/autodev-config [show|set|init-example|validate]`
- `/autodev-session [show|use <profile>|clear]`

## What V4 Does

- keeps a shared repo-scoped queue of running, queued, retryable, and pending-merge tasks
- adds a prepare pass that reconciles queue state and cleans safe AutoDevelop-owned leftovers before new sessions
- accepts either a direct task text or a file containing multiple tasks
- uses the config-driven `scheduler` role to plan conservative execution waves
- reads repo-local execution profile config from `.claude/autodevelop.json`
- resolves the active session execution profile from `.claude-develop-logs/session.json`, host-aware editor defaults, or the repo default
- resolves worker, reviewer, and scheduler runtime settings per role from shipped CLI profiles plus repo execution profiles
- aggregates usage checks across all active CLI/provider/model-class combinations
- supports hybrid execution profiles where different roles run through `claude-code`, `codex`, or `opencode`
- starts multiple worker pipes asynchronously when their likely edit scopes are disjoint
- lets `scheduler.ps1` wait for queue changes after launches instead of relying on external sleep-based polling
- leaves successful worker changes on normal branches for later merge preparation
- prepares merges with normal merge semantics instead of squash
- requires explicit user testing and confirmation before committing interactive merges

## Included Components

- `skills/develop/SKILL.md` — Main AutoDevelop interactive orchestrator
- `skills/develop-prepare/SKILL.md` — Explicit prepare and hygiene command
- `skills/pipe-feedback/SKILL.md` — Post-run pipeline feedback and friction analysis
- `skills/autodev-config/SKILL.md` — Repo-local AutoDevelop config inspector/editor
- `skills/autodev-session/SKILL.md` — Session-local execution profile selector
- `agents/scheduler-agent.md` — Scheduler prompt template body
- `agents/reviewer.md` — Reviewer prompt template body
- `scripts/scheduler.ps1` — Durable repo-local queue engine
- `scripts/auto-develop.ps1` — Worker pipeline engine
- `scripts/planner-runner.ps1` — Config-driven scheduler role runner
- `scripts/autodevelop-config.ps1` — Shared AutoDevelop config and role resolution helpers
- `scripts/autodevelop-role-runner.ps1` — Shared CLI-family role runner
- `scripts/autodevelop-session.ps1` — Session-local execution profile state helper
- `scripts/autodevelop-usage-gate.ps1` — Aggregated usage gate for all active CLI/profile/model combinations
- `scripts/cli-profiles/*.json` — Shipped supported CLI profile manifests
- `scripts/providers/*.ps1` — CLI-family adapters
- `scripts/claude-usage-gate.ps1` — 5h usage probe helper
- `scripts/preflight.ps1` — Deterministic validation checks

## Runtime Notes

- Scheduler state lives under `.claude-develop-logs/scheduler/`
- Worker run artifacts still live under `.claude-develop-logs/runs/<task>/`
- Each task gets up to 3 full attempts
- Queue replanning happens after submissions, completions, retries, and merge resolutions

## Requirements

- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude Code CLI and/or Codex CLI and/or OpenCode CLI, depending on the configured role profiles

## Testing AutoDevelop

- AutoDevelop tests should now be run in layers, not only as one expensive full pass.
- Goal: keep the same confidence, but pay real `dotnet restore` / `dotnet build` / `dotnet test` cost only where it proves something.

### Recommended Order

1. Run fast preflight-analysis tests during normal development.
2. Run targeted smoke tests when changing `preflight.ps1` behavior that depends on real SDK/build behavior.
3. Run the full scheduler regression script before release or after larger pipeline changes.

### Fast Analysis Mode

- `scripts/preflight.ps1` supports:
- `-SkipRun`
- `-SkipBuild`
- `-SkipTests`
- Use this for deterministic logic checks such as wiring analysis, JS interop validation, changed-file rules, and other static validation paths.
- This is the default choice for most `preflight` test cases in `scripts/test-scheduler.ps1`.

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugins\T.L-AutoDevelop\scripts\preflight.ps1 `
  -SolutionPath <path-to-sln-or-csproj> `
  -SkipRun -SkipBuild -SkipTests
```

### Smoke Tests

- Keep a small number of real end-to-end `preflight` smoke tests.
- These should still exercise actual restore/build behavior so that fast-mode tests do not hide SDK or tooling regressions.
- In the test harness, this means at least one `New-TestBlazorRepo` path should still run without `-SkipRestore` and without `-SkipBuild` / `-SkipTests`.

### Full Regression Run

- Full harness:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugins\T.L-AutoDevelop\scripts\test-scheduler.ps1
```

- Use this before shipping changes to:
- `scripts/scheduler.ps1`
- `scripts/auto-develop.ps1`
- `scripts/preflight.ps1`
- config resolution / provider / role-runner code

### Practical Rule

- If you are validating static preflight logic: use fast mode.
- If you are validating real CLI, PowerShell job boundaries, Git interaction, or SDK behavior: keep a real smoke/integration test.
- If you change distributed plugin content, bump the plugin version in both manifest locations.

## Repo Config

- AutoDevelop reads optional repo-local config from `.claude/autodevelop.json`
- missing config falls back to built-in defaults
- plugin updates do not overwrite repo config
- config version `4` defines repo-local `executionProfiles`
- config version `4` also supports `hostDefaults` for editor-aware default profile selection
- shipped `cliProfile` manifests define which CLIs, providers, model classes, options, and usage probes are supported by this plugin build
- an execution profile selects `cliProfile`, `provider`, `modelClass`, optional explicit `model`, and options per role
- built-in profiles include `default`, `claude-full`, and `codex-full`
- a session-local selection in `.claude-develop-logs/session.json` can activate a different execution profile for the current repository session
- if no session profile is active, AutoDevelop first checks `hostDefaults` for the detected editor host and then falls back to `defaultExecutionProfile`
- an explicit role `modelClass` pins that role to the configured model class
- an explicit role `model` pins that role to the configured full model token
- for `opencode` and `codex` roles, prefer explicit `model` values like `openai/gpt-5.4` instead of relying on `modelClass`
- if a role omits `modelClass`, the built-in default or runtime override can still decide the effective model token
- invalid config values fall back to built-in defaults with warnings instead of crashing the pipeline
- unsupported CLI profiles are rejected; only shipped supported profiles may be used
