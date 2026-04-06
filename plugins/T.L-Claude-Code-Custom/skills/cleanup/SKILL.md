---
name: cleanup
description: Full uninstall — remove all installed files (binary, launchers, config, proxy dir). After cleanup, /init-claude-code-custom can do a fresh install.
disable-model-invocation: true
---

# /cleanup

Fully remove everything installed by `/init-claude-code-custom`. After cleanup, the system is as if the init was never run.

## Flow

Run these steps in order.

### Step 1: Detect OS

Determine the current OS:
- Windows: check for Windows-style paths or `$env:OS`
- Linux: `uname -s`

Set `osKind` to `windows` or `linux`.

### Step 2: Stop proxy daemon

Read `~/.claude/claude-custom/proxy.lock`. If it exists:

1. Extract `pid`.
2. Kill the process:
   - Windows: `taskkill /PID {pid} /F`
   - Linux: `kill {pid}`
3. Report: "Stopped proxy (PID {pid})."

Also kill any orphan `OpenRouterProxy` processes:
- Windows: `taskkill /IM OpenRouterProxy.exe /F`
- Linux: `pkill -f OpenRouterProxy`

### Step 3: Remove launcher scripts

Remove these files from the user bin dir. Report each removal. Skip silently if a file doesn't exist.

- Windows (`%USERPROFILE%\.local\bin\`):
  - `claude-custom-proxy.cmd`
  - `claude-custom.cmd`
- Linux (`~/.local/bin/`):
  - `claude-custom-proxy`
  - `claude-custom`

### Step 4: Remove proxy directory

Remove the entire directory and all its contents:
- Windows: `%USERPROFILE%\.claude\claude-custom\`
- Linux: `~/.claude/claude-custom/`

This removes: `OpenRouterProxy.exe` (or `OpenRouterProxy`), `resolve-config.ps1`, `proxy.lock`, `proxy.log`, `web.config`, `.pdb`, and any other files.

Report: "Removed proxy directory."

### Step 5: Remove config file

Remove `~/.claude/claude-custom.json`.

Report: "Removed config file."

### Step 6: Report summary

Print:

```
Cleanup complete — full uninstall.
  Proxy stopped: {yes/no}
  Launchers removed: {list}
  Proxy directory removed: {yes/no}
  Config file removed: {yes/no}

Run /init-claude-code-custom to reinstall.
```

## What is NOT removed

- `~/.claude/` directory (shared by Claude Code)
- `~/.local/bin/` directory (may contain other tools)
- Any other Claude Code settings or data

## Rules

Use `Bash`, `Read`.

Do not remove anything outside of the directories listed above.
