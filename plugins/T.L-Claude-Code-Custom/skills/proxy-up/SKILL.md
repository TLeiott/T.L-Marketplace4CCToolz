---
name: proxy-up
description: Start the OpenRouter proxy daemon, or report its status if already running.
argument-hint: [--port N]
disable-model-invocation: true
---

# /proxy-up

Start the shared OpenRouter proxy daemon or check its status.

## Behavior

### 1. Check if proxy is already running

Read `~/.claude/claude-custom/proxy.lock`. If the file exists:

1. Extract `pid` and `port` from the lock file (format: `key=value` per line).
2. Check if the PID is alive:
   - Windows: `tasklist /FI "PID eq {pid}"` and look for `OpenRouterProxy`
   - Linux: `kill -0 {pid}`
3. Check health endpoint: `GET http://127.0.0.1:{port}/health`
4. If both pass: print status and exit.

```
Proxy is running.
  PID:     12345
  Port:    18080
  Started: 2026-04-05T14:30:00Z
  Health:  ok
```

If the lock file exists but the process is dead or health check fails, delete the stale lock file and proceed to start.

### 2. Determine port

- If `$ARGUMENTS` contains `--port N`, use that port.
- Otherwise read `proxy.port` from `~/.claude/claude-custom.json` (default: `18080`).

### 3. Start the proxy

- Windows: `start /b "" "%USERPROFILE%\.claude\claude-custom\OpenRouterProxy.exe" --port {port}`
- Linux: `~/.claude/claude-custom/OpenRouterProxy --port {port} &` then `disown`

### 4. Wait for health

Poll `GET http://127.0.0.1:{port}/health` every 200ms, up to 10 seconds. If it never responds, print an error with the port number and suggest checking for conflicts.

### 5. Confirm

```
Proxy started.
  PID:  {pid from lock file}
  Port: {port}
  URL:  http://127.0.0.1:{port}
```

## Rules

Use `Bash`, `Read`, `Glob`, `Grep`.

Do not modify any files. This skill only starts a process and reads status.
