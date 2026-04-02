---
name: autodev-config
description: "Inspect and edit the repo-local AutoDevelop execution profile config in .claude/autodevelop.json."
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
- empty or `show`: show the effective configuration, the active session profile, the default execution profile, and all shipped CLI profiles
- `validate`: validate the file and report invalid execution profiles, role definitions, cliProfile references, provider/modelClass mismatches, option mismatches, and fallback problems
- `init-example`: create `.claude/autodevelop.json` only if it does not exist yet, using a full explicit example with multiple execution profiles
- `set ...`: update the repo config according to the user request

## Rules

Use `Read`, `Glob`, `Grep`, `Bash`.

You may edit `.claude/autodevelop.json` when the user asked to create or change it.

Keep the file explicit and easy to diff.

## Architecture

There are two different profile layers:
- shipped `cliProfile` values live in the plugin and are fixed/supported by the plugin build
- repo-local `executionProfiles` live in `.claude/autodevelop.json` and choose which `cliProfile`, `provider`, `modelClass`, and options each role should use

Do not invent unsupported CLI profiles or commands inside the repo config.

The active execution profile for the current session is selected separately through `/autodev-session` and is stored under `.claude-develop-logs/session.json`.

If no session profile is active, AutoDevelop uses `defaultExecutionProfile`.

## Config shape

```json
{
  "version": 4,
  "defaultExecutionProfile": "default",
  "executionProfiles": {
    "default": {
      "roles": {
        "scheduler": {
          "cliProfile": "claude-code-vanilla",
          "provider": "anthropic",
          "modelClass": "opus",
          "options": {
            "reasoningEffort": "medium"
          }
        },
        "implement": {
          "cliProfile": "claude-code-vanilla",
          "provider": "anthropic",
          "modelClass": "sonnet",
          "options": {
            "reasoningEffort": "low",
            "dangerouslySkipPermissions": true
          }
        }
      }
    },
    "openrouter-experiment": {
      "roles": {
        "implement": {
          "cliProfile": "claude-code-openrouter",
          "provider": "openrouter",
          "modelClass": "sonnet"
        }
      }
    }
  }
}
```

## Show output

When showing config, always surface:
- `defaultExecutionProfile`
- active session profile, if one is set
- all defined `executionProfiles`
- all shipped supported `cliProfile` ids
- effective role resolution for:
  - `discover`
  - `plan`
  - `fixPlan`
  - `directionCheck`
  - `investigate`
  - `reproduce`
  - `implement`
  - `reviewer`
  - `scheduler`

For each role, show:
- `cliProfile`
- `provider`
- `modelClass`
- effective model token if known
- `maxTurns`
- `timeoutSeconds`
- `capabilities`
- `options`
- usage support mode for the effective CLI/provider/modelClass combination

## Validation hints

Warn or fail when:
- `version` is missing or not `4`
- `defaultExecutionProfile` is missing or undefined
- an `executionProfile` is not an object
- a role is not an object
- `cliProfile` is unknown
- `provider` is unsupported by the selected `cliProfile`
- `modelClass` is unsupported by the selected `cliProfile`
- options are unsupported by the selected `cliProfile`
- required capabilities are unsupported by the selected `cliProfile`
- a referenced fallback cli profile is unknown
- session state points to a missing execution profile

Do not warn merely because a role omits `modelClass`. That can be intentional if the runtime should keep using the built-in role default or a runtime override.

Do not invent init state outside the repository.
