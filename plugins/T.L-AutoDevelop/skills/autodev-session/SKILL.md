---
name: autodev-session
description: "Select or inspect the active AutoDevelop execution profile for the current repository session."
argument-hint: [show|use <profile>|clear]
disable-model-invocation: true
---

# /autodev-session

Your job is to inspect or change the active AutoDevelop execution profile for the current repository session.

Session state is stored in:
- `.claude-develop-logs/session.json`

This state is transient and must not be committed.

## Supported actions

Interpret `$ARGUMENTS` like this:
- empty or `show`: show the active execution profile, its source, the detected host, and the available execution profiles
- `use <profile>`: set the active session execution profile to the named profile
- `clear`: remove the session override so AutoDevelop falls back to the detected host default or `defaultExecutionProfile`

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`.

Do not edit `.claude/autodevelop.json` in this skill.

Resolve `autodevelop-session.ps1` from the installed plugin and use it instead of ad-hoc file edits.

Examples:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<autodevelop-session.ps1>" -Mode show -SolutionPath "<solution>"
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<autodevelop-session.ps1>" -Mode use -SolutionPath "<solution>" -ExecutionProfile "cheap-implementation"
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<autodevelop-session.ps1>" -Mode clear -SolutionPath "<solution>"
```

If the requested execution profile does not exist, stop and show the available profile names.
