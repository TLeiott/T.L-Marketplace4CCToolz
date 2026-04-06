---
name: init-claude-code-custom
description: Fresh-install `claude-custom` and `claude-custom-proxy` launchers, config, and proxy binary. Use `/update-claude-code-custom` to update after a plugin version bump.
argument-hint: [install|show|validate]
disable-model-invocation: true
---

# /init-claude-code-custom

Fresh-install both launchers, shared config, and proxy daemon binary. **Refuses to run if already installed** — use `/update-claude-code-custom` to update, or `/cleanup` then re-init for a fresh start.

## Supported actions

Interpret `$ARGUMENTS` like this:
- empty or `install`: perform the full setup flow
- `show`: display the current config, launcher locations, and proxy daemon status
- `validate`: check the config file, launchers, proxy binary, and daemon for correctness

## Architecture

This plugin provides two launcher commands that share the same config file (`~/.claude/claude-custom.json`):

1. **`claude-custom`** — connects directly to OpenRouter. No daemon, no proxy. The `OPENROUTER_API_KEY` env var is passed as `ANTHROPIC_API_KEY` directly to `claude`.
2. **`claude-custom-proxy`** — ensures the OpenRouterProxy daemon is running, then launches stock `claude` through the local proxy with provider routing encoded in the URL path.

The proxy daemon writes a lock file at `~/.claude/claude-custom/proxy.lock` containing its PID, port, and start time. The launcher reads this to reuse a running daemon or detect stale state.

The OpenRouter API key is read from the `OPENROUTER_API_KEY` environment variable. It is never written to disk by this plugin.

## Install flow

Run these steps in order. Abort with a clear message if any step fails.

### Step 1: Detect OS

Determine the current OS. Use `Bash` to run:
- Windows: `echo $env:OS` or check `$IsWindows` in PowerShell
- Linux: `uname -s`

Set a variable `osKind` to `windows` or `linux`.

### Step 2: Guard — already installed?

Check if `~/.claude/claude-custom.json` exists. If it does, **abort** with this message:

```
Already installed. Use /update-claude-code-custom to update after a plugin version bump, or /cleanup then /init-claude-code-custom for a fresh install.
```

Do NOT proceed with the install flow.

### Step 3: Verify prerequisites

Run these checks and abort with actionable messages if any fail:

1. **`claude` is installed**: try `claude --version`. If it fails, tell the user to install Claude Code first.
2. **`OPENROUTER_API_KEY` is set**: check the environment variable. If missing, tell the user to set it in their shell profile.
3. **User bin directory exists**:
   - Windows: `%USERPROFILE%\.local\bin`
   - Linux: `~/.local/bin`
   Create it if missing.

### Step 4: Create the config file

Target: `~/.claude/claude-custom.json`

Create it with this content:

```json
{
  "version": 2,
  "proxy": {
    "port": 18080
  },
  "defaultProfile": "default",
  "profiles": {
    "default": {
      "model": "anthropic/claude-sonnet-4.6",
      "provider": "anthropic",
      "allowFallbacks": false
    }
  }
}
```

### Step 5: Install the proxy binary and helpers

The plugin ships prebuilt proxy binaries under `${CLAUDE_PLUGIN_ROOT}/bin/`.

1. Determine the target install dir:
   - Windows: `%USERPROFILE%\.claude\claude-custom\`
   - Linux: `~/.claude/claude-custom/`
   Create it if missing.

2. Copy the correct binary and helper files:
   - Windows: `bin/win-x64/OpenRouterProxy.exe` and `scripts/launchers/resolve-config.ps1` → target dir
   - Linux: `bin/linux-x64/OpenRouterProxy` → target dir, then `chmod +x`

3. Verify the binary exists after copy.

### Step 6: Install both launchers

**`claude-custom-proxy` launcher:**
- Windows: copy `scripts/launchers/claude-custom-proxy.cmd` to `%USERPROFILE%\.local\bin\claude-custom-proxy.cmd`
- Linux: copy `scripts/launchers/claude-custom-proxy` to `~/.local/bin/claude-custom-proxy` and `chmod +x`

**`claude-custom` launcher:**
- Windows: copy `scripts/launchers/claude-custom.cmd` to `%USERPROFILE%\.local\bin\claude-custom.cmd`
- Linux: copy `scripts/launchers/claude-custom` to `~/.local/bin/claude-custom` and `chmod +x`

### Step 7: Verify PATH

Check whether the user bin dir is on PATH:
- Windows: `%USERPROFILE%\.local\bin`
- Linux: `~/.local/bin`

If not, print instructions for adding it to PATH. On most modern Linux distros, `~/.local/bin` is auto-added by `~/.profile` if it exists.

### Step 8: Print usage examples

After successful install, print:

```
claude-custom v{VERSION} installed successfully. Both launchers configured.

Proxy launcher (strict provider routing):
  claude-custom-proxy
  claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8
  claude-custom-proxy --profile default

Direct launcher (simple API routing):
  claude-custom
  claude-custom --model anthropic/claude-sonnet-4.6
  claude-custom --profile default

Proxy lifecycle:
  /proxy-up         Start the proxy daemon
  /proxy-down       Stop the proxy daemon
  claude-custom-proxy --stop-proxy   Stop from terminal

Config file: ~/.claude/claude-custom.json
Proxy dir:   ~/.claude/claude-custom/
Lock file:   ~/.claude/claude-custom/proxy.lock

Required env: OPENROUTER_API_KEY
```

## Show output

When showing status, surface:
- OS and detected user bin dir
- Whether `claude` is on PATH
- Whether `OPENROUTER_API_KEY` is set
- Config file location, version, and current `defaultProfile`
- Configured proxy port
- Defined profiles and their model/provider
- Both launcher file locations (proxy + direct)
- Proxy binary location
- **Proxy daemon status**: running/stopped, PID, port, uptime (read from lock file + health check)

## Validation checks

Run these checks:
1. Config file is valid JSON and has `version: 2`.
2. Each profile has `model` and `provider` fields.
3. Both launcher files exist and are executable.
4. Proxy binary exists.
5. `resolve-config.ps1` exists.
6. `claude` resolves on PATH.
7. `OPENROUTER_API_KEY` is set.
8. **Proxy health**: if running, `GET http://127.0.0.1:{port}/health` returns 200.
9. **Lock file**: if exists, PID matches a running process.

Report each check as pass/fail or N/A (if proxy not running) with a clear message.

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`, `Write`, `Edit`.

Do not write the OpenRouter API key to any file. It must come from the environment.
