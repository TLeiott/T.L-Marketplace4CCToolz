---
name: cleanup
description: Remove stale artifacts — old launchers, orphan proxy processes, dead lock files.
disable-model-invocation: true
---

# /cleanup

Remove stale artifacts left by previous versions or unclean shutdowns.

## Behavior

### Step 1: Detect OS

Determine the current OS:
- Windows: check `$env:OS` or `$IsWindows`
- Linux: `uname -s`

Set `osKind` to `windows` or `linux`.

### Step 2: Remove old launchers (rename migration)

The command was renamed from `claude-custom` to `claude-custom-proxy`. Delete the old launcher if it exists:

- Windows: `%USERPROFILE%\.local\bin\claude-custom.cmd`
- Linux: `~/.local/bin/claude-custom`

If the file exists and is deleted, report it. If it does not exist, skip silently.

### Step 3: Clean stale lock file

Read `~/.claude/claude-custom/proxy.lock`. If the file exists:

1. Extract `pid` from the lock file.
2. Check if the PID is alive and belongs to `OpenRouterProxy`:
   - Windows: `tasklist /FI "PID eq {pid}" /NH` — look for `OpenRouterProxy`
   - Linux: `ps -p {pid} -o comm=` — check output contains `OpenRouterProxy`
3. If the PID is **dead** or not an `OpenRouterProxy` process, delete the lock file and report it.
4. If the PID is **alive** and matches, leave it alone (healthy daemon).

### Step 4: Kill orphan proxy processes

Find all `OpenRouterProxy` processes not tracked by a valid lock file:

- Windows: `tasklist /FI "IMAGENAME eq OpenRouterProxy.exe" /FO CSV /NH` — parse each PID
- Linux: `pgrep -f OpenRouterProxy` — list all PIDs

For each discovered PID:
1. If a valid lock file exists (survived Step 3) and its `pid` matches, skip it (active daemon).
2. Otherwise, kill the process:
   - Windows: `taskkill /PID {pid} /F`
   - Linux: `kill {pid}`
3. Report each killed orphan with its PID.

### Step 5: Report summary

Print a summary:

```
Cleanup complete.
  Old launchers removed: {n}
  Stale lock files removed: {n}
  Orphan processes killed: {n}
```

If nothing was found, print:

```
Nothing to clean up. Environment is clean.
```

## Rules

Use `Bash`, `Read`.

Do not stop a proxy process that is tracked by a valid (live-PID) lock file.

Do not modify config files, the proxy binary, or the current launcher.
