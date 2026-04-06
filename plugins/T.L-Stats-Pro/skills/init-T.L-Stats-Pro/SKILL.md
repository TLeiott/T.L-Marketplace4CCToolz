---
name: init-T.L-Stats-Pro
description: Install CCMeter (Claude Code usage stats TUI) and register a custom launch alias. Pass the desired alias name as an argument.
argument-hint: <alias-name>
disable-model-invocation: true
---

# /init-T.L-Stats-Pro

Install [CCMeter](https://github.com/hmenzagh/CCMeter) — a terminal dashboard for Claude Code usage analytics — and create a launch command under the alias name provided by the user.

## Supported actions

Interpret `$ARGUMENTS` like this:
- **non-empty** (e.g. `ccstats`): use the argument as the alias/command name
- **empty**: abort with this message:

```
Usage: /init-T.L-Stats-Pro <alias-name>
Example: /init-T.L-Stats-Pro ccstats

Please provide the command name you want to use to launch CCMeter.
```

## Install flow

Run these steps in order. Abort with a clear message if any step fails.

### Step 1: Detect OS

Determine the current platform:
- Check the `OSTYPE` env var or run `uname -s` in Bash.
- If the output contains `msys`, `cygwin`, `mingw`, or `win32`, or the platform is `win32`, set `osKind` to `windows`.
- Otherwise set `osKind` to `linux`.

### Step 2: Guard — already installed?

Check if the CCMeter binary already exists:
- Windows: check if `$HOME/.cargo/bin/ccmeter.exe` exists
- Linux: check if `$HOME/.cargo/bin/ccmeter` exists

If it exists, check if the alias already exists too:
- Windows: check if `$HOME/.cargo/bin/<alias>.cmd` exists
- Linux: check if `$HOME/.cargo/bin/<alias>` exists

If **both** the binary and alias exist, print:

```
CCMeter is already installed and the alias '<alias>' is configured.
Run '<alias>' to launch the dashboard.
To reinstall, remove ~/.cargo/bin/ccmeter and ~/.cargo/bin/<alias> first.
```

Then **stop** — do not proceed.

If only the binary exists but the alias is missing, skip ahead to **Step 5** (create alias only).

### Step 3: Ensure Rust toolchain is available

Check if `cargo` is on PATH by running `cargo --version`.

If `cargo` is **not found**, install it:

- **Windows**: run `winget install Rustlang.Rustup --accept-package-agreements --accept-source-agreements`, then run `rustup default stable` with `$HOME/.cargo/bin` prepended to PATH.
- **Linux**: run `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y`, then source `$HOME/.cargo/env`.

After install, verify `cargo --version` succeeds. Abort if it still fails.

### Step 4: Build and install CCMeter

Run with a generous timeout (10 minutes):

```
cargo install --git https://github.com/hmenzagh/CCMeter
```

Make sure `$HOME/.cargo/bin` is on PATH before running this. Verify that the `ccmeter` binary exists after installation.

### Step 5: Create the alias command

Create the alias using the name from `$ARGUMENTS`.

**Windows** — create `$HOME/.cargo/bin/<alias>.cmd`:

```cmd
@echo off
ccmeter.exe %*
```

**Linux** — create `$HOME/.cargo/bin/<alias>`:

```bash
#!/bin/bash
exec ccmeter "$@"
```

Then run `chmod +x $HOME/.cargo/bin/<alias>`.

### Step 6: Verify PATH

Check whether `$HOME/.cargo/bin` is on PATH by running `which <alias>` or `command -v <alias>`.

If not found, print instructions:

- **Windows**: tell the user to add `%USERPROFILE%\.cargo\bin` to their system PATH via System Environment Variables, or add `export PATH="$HOME/.cargo/bin:$PATH"` to `~/.bashrc` if using Git Bash / MSYS2.
- **Linux**: tell the user to add `export PATH="$HOME/.cargo/bin:$PATH"` to their `~/.bashrc` or `~/.profile`, then `source` it.

### Step 7: Verify launch

Run `<alias> --help` (with PATH set) and confirm it outputs CCMeter's help text. If the binary does not support `--help`, just confirm the binary is callable (exit code is acceptable since CCMeter may return non-zero for `--help`).

### Step 8: Print success summary

```
CCMeter v1.x installed successfully.

  Launch command:  <alias>
  Binary:          ~/.cargo/bin/ccmeter
  Alias:           ~/.cargo/bin/<alias>.cmd   (Windows)
                   ~/.cargo/bin/<alias>       (Linux)
  Data source:     ~/.claude/projects/

Run '<alias>' to open the Claude Code usage dashboard.
```

Replace `<alias>` with the actual alias name the user provided.

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`, `Write`, `Edit`.

Do not modify any files outside of `~/.cargo/bin/` and the Rust toolchain directories.
