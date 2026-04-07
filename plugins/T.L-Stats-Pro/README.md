# T.L-Stats-Pro

Install and launch [CCMeter](https://github.com/hmenzagh/CCMeter) — a terminal-based dashboard for Claude Code usage analytics.

## What it does

CCMeter reads Claude Code's local JSONL session files and renders an interactive TUI dashboard showing:

- Per-model USD cost tracking (Opus, Sonnet, Haiku)
- Token analytics (input, output, cache reads, cache creation)
- Code metrics (lines added, deleted, acceptance rate)
- Efficiency scores and GitHub-style heatmaps
- Auto-discovered project grouping by git repository

## Skills

| Skill | Description |
|---|---|
| `/init-T.L-Stats-Pro <alias>` | Install CCMeter + Rust toolchain and create a launch alias |

## Usage

```
/init-T.L-Stats-Pro ccstats
```

This installs everything needed (Rust, CCMeter) and creates the `ccstats` command. Works on both Windows and Linux.

Then just run:

```
ccstats
```

## Requirements

- Internet connection (for Rust + CCMeter download)
- `winget` (Windows) or `curl` (Linux) for Rust installation
- A terminal with enough size for the TUI dashboard
