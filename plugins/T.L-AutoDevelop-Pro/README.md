# T.L-AutoDevelop-Pro

Autonomous queue-aware orchestration built on top of [T.L-AutoDevelop](../T.L-AutoDevelop/).

## Command

- `/TLA-develop [task text or path-to-task-file]`

## What V4 Changes

- uses the same shared scheduler queue as `/develop`
- accepts either a direct task text or a file containing multiple tasks
- uses the same read-only Scheduler-Agent wave planning model
- starts autonomous worker pipes in conservative parallel waves
- lets the shared scheduler wait for queue changes after launches instead of relying on external sleep-based polling
- prepares merges with normal merge semantics
- commits prepared merges automatically after validation succeeds

## Depends On

`T.L-AutoDevelop` provides the shared scripts and agents:
- `scheduler.ps1`
- `auto-develop.ps1`
- `scheduler-agent`
- `reviewer`
- usage gate and preflight helpers

## Requirements

- T.L-AutoDevelop installed
- Windows (PowerShell 5.1+)
- .NET SDK
- Git
- Claude CLI
