---
name: init-add-claude-code-custom
description: Install a user-global `claude-custom` launcher that routes Claude Code through OpenRouter with explicit provider routing (e.g. `claude-custom --model minimax/minimax-m2.7 --provider minimax/fp8`). Cross-platform: Windows and Linux.
argument-hint: [install|show|validate|uninstall]
disable-model-invocation: true
---

# /init-add-claude-code-custom

Install, inspect, validate, or remove the user-global `claude-custom` launcher.

## Supported actions

Interpret `$ARGUMENTS` like this:
- empty or `install`: perform the full setup flow
- `show`: display the current config, launcher location, and proxy status
- `validate`: check the config file and launcher for correctness
- `uninstall`: remove the launcher, proxy, and config from the user's home

## Architecture

This plugin ships three things:

1. **A local proxy binary** (`OpenRouterProxy`) that speaks the Anthropic Messages API and forwards to OpenRouter, injecting `provider.only` into each request body.
2. **A launcher script** (`claude-custom`) that starts the proxy, then launches stock `claude` pointed at the proxy.
3. **A user config file** (`~/.claude/claude-custom.json`) that stores non-secret defaults like profiles.

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

### Step 3: Create the config file if missing

Target: `~/.claude/claude-custom.json`

If it does not exist, create it with this content:

```json
{
  "version": 1,
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

If it already exists, read it and report the current `defaultProfile` and defined profiles. Do not overwrite an existing config without explicit user confirmation.

### Step 4: Install the proxy binary

The plugin ships prebuilt proxy binaries under `${CLAUDE_PLUGIN_ROOT}/bin/`.

1. Determine the target install dir:
   - Windows: `%USERPROFILE%\.claude\claude-custom\`
   - Linux: `~/.claude/claude-custom/`
   Create it if missing.

2. Copy the correct binary:
   - Windows: `bin/win-x64/OpenRouterProxy.exe` and `scripts/launchers/resolve-config.ps1` → target dir
   - Linux: `bin/linux-x64/OpenRouterProxy` → target dir, then `chmod +x`

3. Verify the binary is executable by running it with `--help` or `--version` if supported.

### Step 5: Install the launcher

Target:
- Windows: `%USERPROFILE%\.local\bin\claude-custom.cmd`
- Linux: `~/.local/bin/claude-custom`

If a file already exists at the target path and it does not look like it was installed by this plugin, warn the user and ask for confirmation before overwriting.

Write the launcher content from the plugin's `scripts/launchers/` directory:
- Windows: copy `scripts/launchers/claude-custom.cmd` to `%USERPROFILE%\.local\bin\`
- Linux: copy `scripts/launchers/claude-custom` to `~/.local/bin/` and `chmod +x`

### Step 6: Verify PATH

Check whether the user bin dir is on PATH:
- Windows: `%USERPROFILE%\.local\bin`
- Linux: `~/.local/bin`

If not, print instructions for adding it to PATH. On most modern Linux distros, `~/.local/bin` is auto-added by `~/.profile` if it exists.

### Step 7: Print usage examples

After successful install, print:

```
claude-custom installed successfully.

Examples:
  claude-custom
  claude-custom --model minimax/minimax-m2.7 --provider minimax/fp8
  claude-custom --profile default
  claude-custom --model anthropic/claude-sonnet-4.6 --provider anthropic
  claude-custom --model minimax/minimax-m2.7 --provider minimax/fp8 -- -p "summarize this repo"

Config file: ~/.claude/claude-custom.json
Proxy dir:   ~/.claude/claude-custom/
Launcher:    ~/.local/bin/claude-custom

Required env: OPENROUTER_API_KEY
```

## Show output

When showing status, surface:
- OS and detected user bin dir
- Whether `claude` is on PATH
- Whether `OPENROUTER_API_KEY` is set
- Config file location and current `defaultProfile`
- Defined profiles and their model/provider
- Launcher file location
- Proxy binary location

## Validation checks

Run these checks:
1. Config file is valid JSON and has `version: 1`.
2. Each profile has `model` and `provider` fields.
3. Launcher file exists and is executable.
4. Proxy binary exists and is executable.
5. `claude` resolves on PATH.
6. `OPENROUTER_API_KEY` is set.

Report each check as pass/fail with a clear message.

## Uninstall flow

1. Remove the launcher file.
2. Remove the proxy install dir (`~/.claude/claude-custom/`).
3. Optionally remove the config file (ask the user).
4. Print a confirmation message.

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`, `Write`, `Edit`.

Do not write the OpenRouter API key to any file. It must come from the environment.

Do not overwrite an existing config file without explicit user confirmation.

Do not overwrite an existing launcher file that was not installed by this plugin without explicit user confirmation.
