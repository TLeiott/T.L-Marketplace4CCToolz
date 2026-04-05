---
name: init-add-claude-code-custom
description: Install a user-global `claude-custom-proxy` launcher that routes Claude Code through OpenRouter with explicit provider routing (e.g. `claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8`). Cross-platform: Windows and Linux.
argument-hint: [install|show|validate|uninstall]
disable-model-invocation: true
---

# /init-add-claude-code-custom

Install, inspect, validate, or remove the user-global `claude-custom-proxy` launcher.

## Supported actions

Interpret `$ARGUMENTS` like this:
- empty or `install`: perform the full setup flow
- `show`: display the current config, launcher location, and proxy daemon status
- `validate`: check the config file, launcher, and proxy daemon for correctness
- `uninstall`: remove the launcher, proxy, and config from the user's home

## Architecture (v2 — shared daemon model)

This plugin ships three things:

1. **A local proxy daemon** (`OpenRouterProxy`) that speaks the Anthropic Messages API and forwards to OpenRouter, injecting `provider.only` into each request body. One shared daemon serves all concurrent Claude Code sessions.
2. **A launcher script** (`claude-custom-proxy`) that ensures the daemon is running, then launches stock `claude` pointed at it with provider routing encoded in the URL path.
3. **A user config file** (`~/.claude/claude-custom.json`) that stores profiles and proxy settings.

The proxy daemon writes a lock file at `~/.claude/claude-custom/proxy.lock` containing its PID, port, and start time. The launcher reads this to reuse a running daemon or detect stale state.

Provider routing is per-request via the URL path: `http://127.0.0.1:{port}/route/{url-encoded-provider}/v1/messages`. This allows different sessions to use different providers through the same proxy.

The OpenRouter API key is read from the `OPENROUTER_API_KEY` environment variable. It is never written to disk by this plugin.

## Install flow

Run these steps in order. Abort with a clear message if any step fails.

### Step 1: Detect OS

Determine the current OS. Use `Bash` to run:
- Windows: `echo $env:OS` or check `$IsWindows` in PowerShell
- Linux: `uname -s`

Set a variable `osKind` to `windows` or `linux`.

### Step 2: Verify prerequisites

Run these checks and abort with actionable messages if any fail:

1. **`claude` is installed**: try `claude --version`. If it fails, tell the user to install Claude Code first.
2. **`OPENROUTER_API_KEY` is set**: check the environment variable. If missing, tell the user to set it in their shell profile.
3. **User bin directory exists**:
   - Windows: `%USERPROFILE%\.local\bin`
   - Linux: `~/.local/bin`
   Create it if missing.

### Step 3: Create or migrate the config file

Target: `~/.claude/claude-custom.json`

**If it does not exist**, create it with this content:

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

**If it exists with `version: 1`** (or no version field), migrate it:
1. Add the `proxy` section with default port `18080`.
2. Set `version` to `2`.
3. Preserve all existing profiles unchanged.
4. Report the migration to the user.

**If it exists with `version: 2`**, read it and report the current `defaultProfile` and defined profiles. Do not overwrite without explicit user confirmation.

### Step 3b: Kill orphan proxies (migration only)

If migrating from v1, kill any running `OpenRouterProxy` processes that were started by the old per-session model:
- Windows: `taskkill /IM OpenRouterProxy.exe /F`
- Linux: `pkill -f OpenRouterProxy`

Delete any stale lock files.

### Step 4: Install the proxy binary

The plugin ships prebuilt proxy binaries under `${CLAUDE_PLUGIN_ROOT}/bin/`.

1. Determine the target install dir:
   - Windows: `%USERPROFILE%\.claude\claude-custom\`
   - Linux: `~/.claude/claude-custom/`
   Create it if missing.

2. Copy the correct binary and helper files:
   - Windows: `bin/win-x64/OpenRouterProxy.exe` and `scripts/launchers/resolve-config.ps1` → target dir
   - Linux: `bin/linux-x64/OpenRouterProxy` → target dir, then `chmod +x`

3. Verify the binary is executable by running it with `--help` or `--version` if supported.

### Step 5: Install the launcher

Target:
- Windows: `%USERPROFILE%\.local\bin\claude-custom-proxy.cmd`
- Linux: `~/.local/bin/claude-custom-proxy`

If a file already exists at the target path and it does not look like it was installed by this plugin, warn the user and ask for confirmation before overwriting.

Write the launcher content from the plugin's `scripts/launchers/` directory:
- Windows: copy `scripts/launchers/claude-custom-proxy.cmd` to `%USERPROFILE%\.local\bin\`
- Linux: copy `scripts/launchers/claude-custom-proxy` to `~/.local/bin/` and `chmod +x`

The launcher invokes `claude --dangerously-skip-permissions` by default so that proxy-routed sessions run without interactive permission prompts.

#### Step 5b: Remove old launcher (rename migration)

The command was renamed from `claude-custom` to `claude-custom-proxy`. If the old launcher exists, delete it:

- Windows: delete `%USERPROFILE%\.local\bin\claude-custom.cmd` if it exists
- Linux: delete `~/.local/bin/claude-custom` if it exists

Report the removal to the user. If it does not exist, skip silently.

### Step 6: Verify PATH

Check whether the user bin dir is on PATH:
- Windows: `%USERPROFILE%\.local\bin`
- Linux: `~/.local/bin`

If not, print instructions for adding it to PATH. On most modern Linux distros, `~/.local/bin` is auto-added by `~/.profile` if it exists.

### Step 7: Print usage examples

After successful install, print:

```
claude-custom-proxy v2.0.1 installed successfully (shared daemon model).

Examples:
  claude-custom-proxy
  claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8
  claude-custom-proxy --profile default
  claude-custom-proxy --model anthropic/claude-sonnet-4.6 --provider anthropic
  claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8 -- -p "summarize this repo"
  claude-custom-proxy --stop-proxy

Proxy lifecycle:
  /proxy-up         Start the proxy daemon
  /proxy-down       Stop the proxy daemon
  claude-custom-proxy --stop-proxy   Stop from terminal

Config file: ~/.claude/claude-custom.json
Proxy dir:   ~/.claude/claude-custom/
Lock file:   ~/.claude/claude-custom/proxy.lock
Launcher:    ~/.local/bin/claude-custom-proxy

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
- Launcher file location
- Proxy binary location
- **Proxy daemon status**: running/stopped, PID, port, uptime (read from lock file + health check)

## Validation checks

Run these checks:
1. Config file is valid JSON and has `version: 2`.
2. Each profile has `model` and `provider` fields.
3. Launcher file exists and is executable.
4. Proxy binary exists and is executable.
5. `claude` resolves on PATH.
6. `OPENROUTER_API_KEY` is set.
7. **Proxy health**: `GET http://127.0.0.1:{port}/health` returns 200.
8. **Lock file**: exists, PID matches a running process.

Report each check as pass/fail with a clear message.

## Uninstall flow

1. Stop the proxy daemon (read lock file, kill PID, delete lock file).
2. Remove the launcher file.
3. Remove the proxy install dir (`~/.claude/claude-custom/`).
4. Optionally remove the config file (ask the user).
5. Print a confirmation message.

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`, `Write`, `Edit`.

Do not write the OpenRouter API key to any file. It must come from the environment.

Do not overwrite an existing config file without explicit user confirmation (except for v1→v2 migration which preserves profiles).

Do not overwrite an existing launcher file that was not installed by this plugin without explicit user confirmation.
