---
name: autodev-config
description: "Inspect and edit the repo-local AutoDevelop role config in .claude/autodevelop.json."
argument-hint: [show|set|init-example|validate]
disable-model-invocation: true
---

# /autodev-config

Your job is to inspect or update the repository-local AutoDevelop configuration.

The source of truth is:
- `.claude/autodevelop.json`

Do not touch plugin installation files for user configuration.

## Supported actions

Interpret `$ARGUMENTS` like this:
- empty or `show`: show the effective configuration and explain which values are explicitly set in `.claude/autodevelop.json`
- `validate`: validate the file and report missing or suspicious role settings
- `init-example`: create `.claude/autodevelop.json` only if it does not exist yet, using a full explicit example
- `set ...`: update the repo config according to the user request

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`.

You may edit `.claude/autodevelop.json` when the user asked to create or change it.

Keep the file explicit and easy to diff.

Semantics:
- an explicit role `model` pins that role to the configured model
- omitting `model` keeps runtime model heuristics active for that role
- invalid values should be corrected because AutoDevelop will warn and fall back to defaults

When showing config, always include these roles if present:
- `discover`
- `plan`
- `fixPlan`
- `directionCheck`
- `investigate`
- `reproduce`
- `implement`
- `reviewer`
- `scheduler`

For each role, surface:
- `model`
- `reasoningEffort`
- `maxTurns`
- `allowedTools`
- optional `command`
- optional `extraArgs`

## Example shape

```json
{
  "version": 1,
  "providerDefaults": {
    "provider": "claude-code",
    "command": "claude"
  },
  "roles": {
    "implement": {
      "model": "claude-sonnet-4-6",
      "reasoningEffort": "low",
      "maxTurns": 24,
      "allowedTools": ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
      "dangerouslySkipPermissions": true
    },
    "reviewer": {
      "model": "claude-opus-4-6",
      "reasoningEffort": "medium",
      "maxTurns": 12,
      "allowedTools": ["Read", "Glob", "Grep"]
    },
    "scheduler": {
      "model": "claude-opus-4-6",
      "reasoningEffort": "medium",
      "maxTurns": 18,
      "allowedTools": ["Read", "Glob", "Grep", "Bash"]
    }
  }
}
```

## Validation hints

Warn when:
- `version` is missing or not `1`
- `providerDefaults.provider` is not `claude-code`
- `reasoningEffort` is not empty, `low`, `medium`, or `high`
- `maxTurns` is not positive
- `allowedTools` is empty for an active role

Do not warn merely because a role omits `model`. That can be intentional to keep runtime heuristics active.

Do not invent init state outside the repository.
