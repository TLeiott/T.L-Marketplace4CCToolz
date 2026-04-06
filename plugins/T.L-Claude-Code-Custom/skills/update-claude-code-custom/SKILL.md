---
name: update-claude-code-custom
description: Update proxy binary, launchers, and helpers after a plugin version bump. Preserves user config.
disable-model-invocation: true
---

# /update-claude-code-custom

Re-deploy the proxy binary, launcher scripts, and helper files after a plugin version bump. **Does not touch user config.** Requires a prior `/init-claude-code-custom`.

## Flow

Run these steps in order. Abort with a clear message if any step fails.

### Step 1: Detect OS

Determine the current OS:
- Windows: check for Windows-style paths or `$env:OS`
- Linux: `uname -s`

Set `osKind` to `windows` or `linux`.

### Step 2: Guard — is it installed?

Check if `~/.claude/claude-custom.json` exists. If it does **NOT** exist, abort with:

```
Not installed yet. Run /init-claude-code-custom first.
```

### Step 3: Read plugin version

Read `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` and extract the `version` field. This is the version being deployed.

### Step 4: Stop proxy if running

Read `~/.claude/claude-custom/proxy.lock`. If the file exists:

1. Extract `pid` from the lock file.
2. Check if the PID is alive:
   - Windows: `tasklist /FI "PID eq {pid}" /NH` — look for `OpenRouterProxy`
   - Linux: `ps -p {pid} -o comm=`
3. If alive, kill it:
   - Windows: `taskkill /PID {pid} /F`
   - Linux: `kill {pid}`
4. Delete the lock file.
5. Report: "Stopped proxy (PID {pid})."

If no lock file or PID is dead, skip silently.

### Step 5: Update proxy binary

1. Determine target dir:
   - Windows: `%USERPROFILE%\.claude\claude-custom\`
   - Linux: `~/.claude/claude-custom/`

2. Copy the correct binary (overwrite):
   - Windows: `${CLAUDE_PLUGIN_ROOT}/bin/win-x64/OpenRouterProxy.exe` → target dir
   - Linux: `${CLAUDE_PLUGIN_ROOT}/bin/linux-x64/OpenRouterProxy` → target dir, then `chmod +x`

3. Verify the binary exists after copy.

### Step 6: Update helper scripts

Copy `${CLAUDE_PLUGIN_ROOT}/scripts/launchers/resolve-config.ps1` → `~/.claude/claude-custom/resolve-config.ps1` (overwrite).

### Step 7: Update launcher scripts

Copy all launcher scripts to user bin dir (overwrite):

- Windows: copy `claude-custom-proxy.cmd` and `claude-custom.cmd` to `%USERPROFILE%\.local\bin\`
- Linux: copy `claude-custom-proxy` and `claude-custom` to `~/.local/bin/`, then `chmod +x` both

### Step 8: Report

Print:

```
Updated to v{VERSION}.
  - Proxy binary replaced
  - Launcher scripts replaced
  - Helper scripts replaced
  - Config preserved (not modified)
Proxy was stopped — it will restart automatically on next claude-custom-proxy use.
```

## Rules

Use `Read`, `Bash`, `Write`.

Do not modify `~/.claude/claude-custom.json` — that is the user's config.

Do not modify `proxy.log` — preserve existing logs.

Do not write the OpenRouter API key to any file.
