---
name: proxy-down
description: Stop the OpenRouter proxy daemon.
disable-model-invocation: true
---

# /proxy-down

Stop the shared OpenRouter proxy daemon.

## Behavior

### 1. Read the lock file

Read `~/.claude/claude-custom/proxy.lock`. If the file does not exist, print "Proxy is not running." and exit.

### 2. Kill the process

Extract `pid` from the lock file.

- Windows: `taskkill /PID {pid} /F`
- Linux: `kill {pid}`

### 3. Clean up

Delete the lock file.

### 4. Confirm

```
Proxy stopped. (PID {pid} on port {port})
```

If the process was already dead (stale lock file), still delete the lock file and print:

```
Proxy was not running (stale lock file cleaned up).
```

## Rules

Use `Bash`, `Read`.

Do not modify any files other than deleting the lock file.
