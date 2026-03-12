# Ollama + Claude Code Local Provider Integration

Researched on: March 12, 2026

## Executive Summary

Ollama does not patch Claude Code to add a new provider. The feature works by launching the normal `claude` CLI with environment variables that point Claude Code at Ollama's local Anthropic-compatible API, then translating Anthropic-format requests into Ollama's native chat pipeline on the server side.

In other words, the integration is mostly a gateway and compatibility-layer design:

- Claude Code already supports custom Anthropic-compatible gateways.
- Ollama exposes `POST /v1/messages` and converts that traffic into its own `/api/chat` flow.
- `ollama launch claude` automates the environment setup, model selection, alias routing, and process launch.

This means the feature is not a hidden fork of Claude Code or a private plugin API. It is an orchestration layer around the stock `claude` binary plus an Anthropic-compatible server surface inside Ollama.

## Timeline

- January 16, 2026: Ollama announced Anthropic API compatibility for Claude Code and other Anthropic-style clients.
- January 23, 2026: Ollama announced `ollama launch`, which automates launching tools like Claude Code against Ollama models.
- February 16, 2026: Ollama announced Claude Code subagents and web search support through the same compatibility layer.

The sequence matters. Anthropic compatibility came first, then the convenience launcher, then deeper agent features.

## High-Level Architecture

The end-to-end request path looks like this:

1. The user runs `ollama launch claude`.
2. Ollama selects or reuses a configured model and stores integration state in `~/.ollama/config.json`.
3. Ollama locates the `claude` executable and launches it as a child process.
4. Ollama injects Anthropic gateway environment variables into that process.
5. Claude Code sends Anthropic-format requests to the Ollama host instead of Anthropic.
6. Ollama receives those requests at `/v1/messages`.
7. Ollama middleware converts the request into its native chat request format and forwards it into the normal chat handler.
8. Ollama converts native responses back into Anthropic response objects or Anthropic-style SSE stream events.
9. Claude Code behaves as though it is talking to an Anthropic-compatible provider, but the actual model can be local.

## What `ollama launch claude` Actually Does

### It launches the stock `claude` binary

In Ollama source, the Claude integration looks up `claude` on `PATH`, then falls back to `~/.claude/local/claude` or `claude.exe` on Windows if needed.

This is important because it shows Ollama is not embedding Claude Code. It is invoking the existing CLI.

### It does not rewrite Claude Code config files

For the Claude integration, Ollama implements a runner and alias configuration layer, but not an editor that mutates Claude configuration files.

Practically, this means:

- Ollama persists its own integration state in `~/.ollama/config.json`.
- Claude-specific behavior is applied at launch time via process environment and server-side aliases.
- The "no env vars or config files needed" marketing message means the user does not have to set them manually. Under the hood, environment variables are still the mechanism.

### It injects gateway environment variables

Ollama launches `claude` with these key environment variables:

- `ANTHROPIC_BASE_URL=<ollama host>`
- `ANTHROPIC_API_KEY=`
- `ANTHROPIC_AUTH_TOKEN=ollama`
- `ANTHROPIC_DEFAULT_OPUS_MODEL=<primary model>`
- `ANTHROPIC_DEFAULT_SONNET_MODEL=<primary model>`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL=<fast model or primary model>`
- `CLAUDE_CODE_SUBAGENT_MODEL=<primary model>`

It also passes `--model <model>` directly to the `claude` CLI.

Anthropic's Claude Code documentation explicitly supports LLM gateways via `ANTHROPIC_BASE_URL`, and its model configuration docs state that `--model` and these model environment values are passed to the provider as-is. That is why provider-specific model IDs like `qwen3-coder` can work without Claude Code needing to understand Ollama model naming.

### It forwards extra CLI arguments

Ollama's `launch` command allows extra arguments after `--`, and those are forwarded to the child integration process. For Claude Code, that means the launcher preserves normal CLI usage patterns while only changing the backend connection details.

## Why This Works With a "Local Provider"

Claude Code is already designed to talk to Anthropic-compatible gateways. Ollama takes advantage of that existing mechanism.

The core compatibility contract is:

- Claude Code speaks Anthropic Messages API semantics.
- Ollama offers an Anthropic-compatible `/v1/messages` endpoint.
- Model selection is passed through to the provider.
- Therefore, a local Ollama-hosted model can satisfy Claude Code requests as long as Ollama can map the request and response shapes correctly.

This is the central architectural insight: Ollama does not teach Claude Code a brand new local provider API. It presents itself as an Anthropic-compatible gateway that Claude Code already knows how to use.

## Ollama's Server-Side Translation Layer

### Request handling

Ollama registers `POST /v1/messages` and runs Anthropic middleware before the normal chat handler.

The middleware converts Anthropic requests into Ollama chat requests. The conversion includes:

- `model` passed through directly
- `max_tokens` mapped to Ollama's `num_predict`
- Anthropic `system` content flattened into system messages
- Anthropic message blocks converted into Ollama messages
- tool definitions converted into Ollama tools
- `thinking` translated into Ollama's think flag
- streaming preserved through a dedicated stream converter

The message conversion logic supports text, tool use, tool results, thinking blocks, and base64 image input. URL image sources are explicitly not supported in the current conversion code.

### Response handling

Ollama converts native chat responses back into Anthropic responses.

That includes:

- standard message responses
- Anthropic-style stop reasons such as `tool_use`, `end_turn`, and `max_tokens`
- SSE stream events like `message_start`, `content_block_delta`, `message_delta`, and `message_stop`

This translation layer is what makes Claude Code believe it is speaking to an Anthropic-compatible provider even when the actual model is a local Ollama model.

## Alias Routing and Claude Family Mapping

Ollama adds a second layer beyond basic gateway env vars: server-side aliases.

For Claude Code, Ollama configures:

- a primary model alias
- an optional fast model alias
- prefix-matching aliases for `claude-sonnet-*`
- prefix-matching aliases for `claude-haiku-*`

This matters because Claude Code may request model families or internal/background variants that still look Anthropic-flavored. Ollama resolves those requests back to the selected Ollama model.

In the current implementation:

- Opus and Sonnet defaults are routed via the primary model environment variables.
- Haiku uses the fast alias when available, otherwise the primary model.
- `CLAUDE_CODE_SUBAGENT_MODEL` is set to the primary model.

For local models, Ollama intentionally removes stale fast aliases so old cloud mappings do not persist accidentally.

## Local Models Versus Cloud Models

This feature can start Claude Code against both local models and Ollama cloud models, but they are routed differently.

- If the chosen model does not end in `:cloud`, inference stays local and flows through Ollama's local chat path.
- If the chosen model ends in `:cloud`, Ollama still receives the Anthropic-compatible request, but the actual inference is proxied to Ollama Cloud.

That distinction matters if the goal is strictly local inference. Choosing `glm-5:cloud` or similar uses the same launcher mechanism, but it is not a purely local backend.

## Subagents and Web Search

On February 16, 2026, Ollama extended the Claude Code integration to cover subagents and web search.

The implementation is not superficial. The middleware includes logic to detect Anthropic web-search tool usage, execute the search through Ollama, then feed results back into the conversation as Anthropic-style `server_tool_use` and `web_search_tool_result` blocks. Streaming is handled as well, including follow-up response assembly.

This shows Ollama is doing more than a naive JSON pass-through. It has built provider-specific orchestration in the Anthropic compatibility layer so Claude Code features can continue to work when backed by Ollama.

## Reproducing the Launch Manually

The launcher is mostly automating a manual flow that already existed once Anthropic compatibility landed.

A rough equivalent manual launch looks like this:

```bash
ANTHROPIC_BASE_URL=http://localhost:11434 \
ANTHROPIC_AUTH_TOKEN=ollama \
ANTHROPIC_API_KEY="" \
ANTHROPIC_DEFAULT_OPUS_MODEL=qwen3-coder \
ANTHROPIC_DEFAULT_SONNET_MODEL=qwen3-coder \
ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3-coder \
CLAUDE_CODE_SUBAGENT_MODEL=qwen3-coder \
claude --model qwen3-coder
```

The launcher adds convenience around model selection, alias syncing, process discovery, and saved integration state, but the essential transport mechanism is the same.

## Current Compatibility Gaps

Ollama's current Anthropic compatibility docs still list several unsupported features:

- `/v1/messages/count_tokens`
- forcing `tool_choice`
- request `metadata`
- prompt caching
- Batches API
- citations
- PDF document blocks
- server-sent error events during streaming

The docs also note that token counts are approximate rather than exact.

One notable nuance is that Ollama source includes token counting request and response types internally, but the public route remains unsupported in current docs and routes. That suggests Ollama has partial internal scaffolding without full public endpoint support.

Inference: this strongly suggests Ollama is implementing the Claude Code-compatible surface it needs first, rather than the full Anthropic gateway contract all at once.

## Operational Implications

- This integration is viable because Claude Code already supports gateways.
- The model name can be an Ollama-native identifier because Claude Code passes provider model values through as-is.
- "No manual environment variables" is a usability statement, not an implementation statement.
- The feature is safest to think of as a launch wrapper plus API translation layer.
- If strict locality matters, choose a non-cloud model name.
- If maximum Claude feature parity matters, current Anthropic compatibility gaps still matter.

## Key Conclusions

1. Ollama launches the normal Claude Code CLI, not a modified fork.
2. The provider switch happens through injected Anthropic gateway environment variables.
3. Ollama's server implements an Anthropic-compatible `/v1/messages` surface and translates requests to its native chat system.
4. Additional alias routing is required so Claude-family model names and subagent behavior still resolve correctly.
5. Web search and subagents are implemented in the middleware layer, not by simply forwarding requests unchanged.
6. The same launcher can target local or cloud-backed Ollama models, so the chosen model name determines whether the backend is actually local.

## Inferences Versus Direct Evidence

The following points are direct evidence from docs and source:

- Ollama launches `claude` as a child process.
- Ollama sets Anthropic gateway and model environment variables.
- Ollama exposes `POST /v1/messages`.
- Ollama translates Anthropic requests and responses in middleware.
- Ollama sets prefix aliases for Claude family model routing.
- Ollama distinguishes local models from `:cloud` models.

The following points are informed inferences from those sources:

- `ANTHROPIC_API_KEY=""` is likely set to neutralize any inherited real Anthropic API key before launch.
- Ollama is prioritizing the Claude Code-critical subset of Anthropic compatibility before full endpoint parity.

## Primary Sources

### Official product and documentation sources

- Ollama blog, Claude Code with Anthropic API compatibility: <https://ollama.com/blog/claude>
- Ollama blog, `ollama launch`: <https://ollama.com/blog/launch>
- Ollama blog, subagents and web search in Claude Code: <https://ollama.com/blog/web-search-subagents-claude-code>
- Ollama docs, Anthropic compatibility: <https://docs.ollama.com/api/anthropic-compatibility>
- Ollama docs, Claude Code integration: <https://docs.ollama.com/integrations/claude-code>
- Anthropic docs, Claude Code LLM gateway: <https://docs.anthropic.com/en/docs/claude-code/llm-gateway>
- Anthropic docs, Claude Code settings and model configuration: <https://docs.anthropic.com/en/docs/claude-code/settings#model-configuration>

### Official Ollama source code

- Claude launcher implementation: <https://github.com/ollama/ollama/blob/8f45236d09332949aa91774dc9eb46caf2abbbc1/cmd/config/claude.go>
- Integration registry and launch command: <https://github.com/ollama/ollama/blob/8f45236d09332949aa91774dc9eb46caf2abbbc1/cmd/config/integrations.go>
- Anthropic middleware: <https://github.com/ollama/ollama/blob/8f45236d09332949aa91774dc9eb46caf2abbbc1/middleware/anthropic.go>
- Anthropic request and response conversion: <https://github.com/ollama/ollama/blob/8f45236d09332949aa91774dc9eb46caf2abbbc1/anthropic/anthropic.go>
- Server route registration and cloud routing behavior: <https://github.com/ollama/ollama/blob/8f45236d09332949aa91774dc9eb46caf2abbbc1/server/routes.go>
