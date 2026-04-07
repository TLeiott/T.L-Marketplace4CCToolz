# T.L-Claude-Code-Custom

Launch Claude Code with custom OpenRouter models and provider routing.

## What it does

This plugin installs a user-global `claude-custom-proxy` command that:

1. Runs a **shared proxy daemon** that speaks the Anthropic Messages API
2. Routes requests to OpenRouter's Anthropic-compatible endpoint
3. Injects OpenRouter provider routing (`provider.only`) per-request via URL path
4. Launches stock `claude` pointed at the proxy

Multiple concurrent sessions share one daemon — 5 terminals, 1 proxy process.

```bash
claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8
```

## Why a proxy is needed

Claude Code supports custom gateways via `ANTHROPIC_BASE_URL`, but it has no built-in way to express OpenRouter provider-routing preferences like `minimax/fp8`. OpenRouter provider selection is a request-body concern (`provider.only`, `provider.order`), not a Claude CLI flag.

The bundled proxy bridges this gap:
- Claude Code talks Anthropic protocol to `127.0.0.1:{port}`
- The proxy injects `provider.only: ["minimax/fp8"]` into each `/v1/messages` request body
- Provider is encoded per-session in the URL path: `/route/minimax%2Ffp8/v1/messages`

## Architecture (v2 — shared daemon)

```
Terminal 1 (minimax)  ─── ANTHROPIC_BASE_URL=.../route/minimax%2Ffp8 ───┐
Terminal 2 (anthropic) ── ANTHROPIC_BASE_URL=.../route/anthropic ────────┤
Terminal 3 (no provider) ─ ANTHROPIC_BASE_URL=.../ ─────────────────────┤
                                                                        ▼
                                                          ┌─────────────────────┐
                                                          │  Shared Proxy :18080 │
                                                          │  /health → 200       │
                                                          │  /route/{prov}/...   │
                                                          │  /v1/... (passthru)  │
                                                          └──────────┬────────────┘
                                                                     ▼
                                                               OpenRouter API
```

The proxy writes a lock file at `~/.claude/claude-custom/proxy.lock` with PID, port, and start time. The launcher reads this to reuse a running daemon or detect stale state.

## Setup

### Prerequisites

- Claude Code installed (`claude` on PATH)
- `OPENROUTER_API_KEY` environment variable set
- .NET 9 runtime (for building from source) or use the prebuilt binaries

### Install via the plugin skill

```bash
claude --plugin-dir plugins/T.L-Claude-Code-Custom
```

Then run:

```
/init-add-claude-code-custom
```

The skill will:
1. Detect your OS
2. Verify prerequisites
3. Create `~/.claude/claude-custom.json` with defaults (or migrate v1 config)
4. Install the proxy binary to `~/.claude/claude-custom/`
5. Install the launcher to `~/.local/bin/claude-custom-proxy`
6. Verify PATH configuration

## Usage

```bash
# Use default profile from config
claude-custom-proxy

# Explicit model and provider
claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8

# Use a named profile
claude-custom-proxy --profile minimax-fast

# Override model on a named profile
claude-custom-proxy --profile minimax-fast --model minimax/minimax-m2.7

# Pass-through arguments to claude
claude-custom-proxy --model minimax/minimax-m2.7 --provider minimax/fp8 -- -p "summarize this repo"

# Stop the proxy daemon
claude-custom-proxy --stop-proxy
```

### Proxy lifecycle

The proxy daemon starts automatically on first `claude-custom-proxy` invocation. You can also manage it explicitly:

```
/proxy-up         Start the daemon (or check status if running)
/proxy-down       Stop the daemon
```

## Config file

`~/.claude/claude-custom.json`

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
    },
    "minimax-fast": {
      "model": "minimax/minimax-m2.7",
      "provider": "minimax/fp8",
      "allowFallbacks": false
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `version` | Config schema version (currently `2`) |
| `proxy.port` | Port for the shared daemon (default: `18080`) |
| `defaultProfile` | Profile name used when no `--profile` or `--model` is given |
| `profiles.<name>.model` | OpenRouter model slug (e.g. `minimax/minimax-m2.7`) |
| `profiles.<name>.provider` | OpenRouter provider slug (e.g. `minimax/fp8`) |
| `profiles.<name>.allowFallbacks` | Whether to allow other providers if the chosen one fails |

## Provider routing

The proxy injects this into every `/v1/messages` request body when a provider is in the URL path:

```json
{
  "provider": {
    "only": ["minimax/fp8"],
    "allow_fallbacks": false
  }
}
```

This uses OpenRouter's documented `provider.only` field for strict single-provider selection. See [OpenRouter provider routing docs](https://openrouter.ai/docs/guides/routing/provider-selection).

## Error handling

The proxy **fails loud** — it never silently forwards an unrouted request that was meant to be routed:

| Scenario | Behavior |
|---|---|
| Provider in URL, injection succeeds | Forward to OpenRouter |
| Provider in URL, injection fails | **502** with error JSON |
| Empty provider in URL | **502** with error JSON |
| No provider in URL | Pure passthrough |

## Permissions

The launcher passes `--dangerously-skip-permissions` to `claude` by default, so proxy-routed sessions run without interactive permission prompts. To override this, pass `-- --no-dangerously-skip-permissions` via the passthrough args.

## Security

- The OpenRouter API key is read from the `OPENROUTER_API_KEY` environment variable only
- It is never written to disk by this plugin
- The proxy only accepts connections on `127.0.0.1`
- The proxy binary is a self-contained .NET 9 application with no external dependencies

## Troubleshooting

**`OPENROUTER_API_KEY not set`**: Add it to your shell profile (`~/.bashrc`, `~/.zshrc`, or Windows environment variables).

**`claude` not found**: Install Claude Code first. See [Claude Code docs](https://code.claude.com/docs/en/overview).

**Proxy won't start**: Check if port 18080 is in use. Change the port in `~/.claude/claude-custom.json` under `proxy.port`, or set `PROXY_PORT=NNNN` environment variable.

**Stale lock file**: If the proxy crashed, the launcher auto-detects stale lock files and restarts. You can also manually run `claude-custom-proxy --stop-proxy` then retry.

**Model not found**: Verify the model slug is valid on [OpenRouter's model list](https://openrouter.ai/models).

**Provider not found**: Verify the provider slug matches OpenRouter's provider naming. See the provider list on any model page at openrouter.ai.
