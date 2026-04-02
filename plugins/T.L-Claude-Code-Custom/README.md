# T.L-Claude-Code-Custom

Launch Claude Code with custom OpenRouter models and provider routing.

## What it does

This plugin installs a user-global `claude-custom` command that:

1. Starts a local proxy that speaks the Anthropic Messages API
2. Routes requests to OpenRouter's Anthropic-compatible endpoint
3. Injects OpenRouter provider routing (`provider.only`) into each request
4. Launches stock `claude` pointed at the local proxy

This enables the exact UX you want:

```bash
claude-custom --model minimax/minimax-m2.7 --provider minimax/fp8
```

## Why a proxy is needed

Claude Code supports custom gateways via `ANTHROPIC_BASE_URL`, but it has no built-in way to express OpenRouter provider-routing preferences like `minimax/fp8`. OpenRouter provider selection is a request-body concern (`provider.only`, `provider.order`), not a Claude CLI flag.

The bundled proxy bridges this gap:
- Claude Code talks Anthropic protocol to `127.0.0.1:<port>`
- The proxy forwards to `https://openrouter.ai/api`
- The proxy injects `provider.only: ["minimax/fp8"]` into each `/v1/messages` request body

## Setup

### Prerequisites

- Claude Code installed (`claude` on PATH)
- `OPENROUTER_API_KEY` environment variable set
- .NET 9 runtime (for running the proxy from source) or use the prebuilt binaries

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
3. Create `~/.claude/claude-custom.json` with defaults
4. Install the proxy binary to `~/.claude/claude-custom/`
5. Install the launcher to `~/.local/bin/claude-custom`
6. Verify PATH configuration

### Manual setup

**1. Set the API key** (add to your shell profile):

```bash
export OPENROUTER_API_KEY="sk-or-..."
```

**2. Create the config file** at `~/.claude/claude-custom.json`:

```json
{
  "version": 1,
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

**3. Install the proxy binary**:

- Windows: copy `bin/win-x64/OpenRouterProxy.exe` to `~/.claude/claude-custom/`
- Linux: copy `bin/linux-x64/OpenRouterProxy` to `~/.claude/claude-custom/` and `chmod +x`

**4. Install the launcher**:

- Windows: copy `scripts/launchers/claude-custom.cmd` to `~/.local/bin/`
- Linux: copy `scripts/launchers/claude-custom` to `~/.local/bin/` and `chmod +x`

**5. Ensure `~/.local/bin` is on PATH**.

## Usage

```bash
# Use default profile from config
claude-custom

# Explicit model and provider
claude-custom --model minimax/minimax-m2.7 --provider minimax/fp8

# Use a named profile
claude-custom --profile minimax-fast

# Override model on a named profile
claude-custom --profile minimax-fast --model minimax/minimax-m2.7

# Pass-through arguments to claude
claude-custom --model minimax/minimax-m2.7 --provider minimax/fp8 -- -p "summarize this repo"
```

## Config file

`~/.claude/claude-custom.json`

| Field | Description |
|-------|-------------|
| `version` | Config schema version (currently `1`) |
| `defaultProfile` | Profile name used when no `--profile` or `--model` is given |
| `profiles.<name>.model` | OpenRouter model slug (e.g. `minimax/minimax-m2.7`) |
| `profiles.<name>.provider` | OpenRouter provider slug (e.g. `minimax/fp8`) |
| `profiles.<name>.allowFallbacks` | Whether to allow other providers if the chosen one fails |

## Provider routing

The proxy injects this into every `/v1/messages` request body when a provider is configured:

```json
{
  "provider": {
    "only": ["minimax/fp8"],
    "allow_fallbacks": false
  }
}
```

This uses OpenRouter's documented `provider.only` field for strict single-provider selection. See [OpenRouter provider routing docs](https://openrouter.ai/docs/guides/routing/provider-selection).

## Security

- The OpenRouter API key is read from the `OPENROUTER_API_KEY` environment variable only
- It is never written to disk by this plugin
- The proxy only accepts connections on `127.0.0.1`
- The proxy binary is a self-contained .NET 9 application with no external dependencies

## Troubleshooting

**`OPENROUTER_API_KEY not set`**: Add it to your shell profile (`~/.bashrc`, `~/.zshrc`, or Windows environment variables).

**`claude` not found**: Install Claude Code first. See [Claude Code docs](https://code.claude.com/docs/en/overview).

**Proxy won't start**: Ensure the binary is executable. On Linux, run `chmod +x ~/.claude/claude-custom/OpenRouterProxy`.

**Model not found**: Verify the model slug is valid on [OpenRouter's model list](https://openrouter.ai/models).

**Provider not found**: Verify the provider slug matches OpenRouter's provider naming. See the provider list on any model page at openrouter.ai.
