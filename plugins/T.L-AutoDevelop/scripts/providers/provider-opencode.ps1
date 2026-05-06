function Get-OpenCodeCapabilityPermissions {
    param([string[]]$Capabilities)

    $capabilityToolMap = @{
        "read"   = @("read", "list")
        "search" = @("glob", "grep")
        "edit"   = @("edit")
        "write"  = @("edit")
        "shell"  = @("bash")
    }

    $allowedTools = New-Object System.Collections.Generic.List[string]
    foreach ($capability in @($Capabilities)) {
        $tools = $capabilityToolMap[$capability]
        if ($tools) {
            foreach ($tool in $tools) {
                if (-not $allowedTools.Contains($tool)) {
                    [void]$allowedTools.Add($tool)
                }
            }
        }
    }

    $permissions = [ordered]@{}
    foreach ($tool in @("read", "edit", "glob", "grep", "list", "bash")) {
        if ($allowedTools.Contains($tool)) {
            $permissions[$tool] = "allow"
        } else {
            $permissions[$tool] = "deny"
        }
    }
    $permissions["question"] = "deny"
    $permissions["webfetch"] = "deny"
    $permissions["websearch"] = "deny"
    $permissions["codesearch"] = "deny"
    $permissions["external_directory"] = "deny"
    $permissions["doom_loop"] = "deny"

    return $permissions
}

function Get-OpenCodeInvocationConfigJson {
    param(
        [Parameter(Mandatory)][string[]]$Capabilities,
        [string]$Model = "",
        [int]$MaxTurns = 0,
        [string]$ReasoningEffort = ""
    )

    $permissions = Get-OpenCodeCapabilityPermissions -Capabilities $Capabilities

    $agentConfig = [ordered]@{}
    $agentConfig["description"] = "AutoDevelop agent"
    $agentConfig["mode"] = "primary"
    if ($Model) { $agentConfig["model"] = $Model }
    if ($MaxTurns -gt 0) { $agentConfig["steps"] = $MaxTurns }

    $permissionObj = [ordered]@{}
    foreach ($key in $permissions.Keys) {
        $permissionObj[$key] = $permissions[$key]
    }
    $agentConfig["permission"] = $permissionObj

    if ($ReasoningEffort) {
        $agentConfig["reasoningEffort"] = $ReasoningEffort
    }

    $config = [ordered]@{}
    $config['$schema'] = "https://opencode.ai/config.json"
    $config["agent"] = @{ "autodev-role" = $agentConfig }
    $config["default_agent"] = "autodev-role"

    return ($config | ConvertTo-Json -Depth 8 -Compress)
}

function Resolve-OpenCodeExecutablePath {
    param($RoleConfig)

    $command = [string](Get-AutoDevelopConfigPropertyValue -Object $RoleConfig -Name "command")
    if ($env:AUTODEV_OPENCODE_COMMAND) {
        $command = [string]$env:AUTODEV_OPENCODE_COMMAND
    }
    if (-not $command) { $command = "opencode" }

    $resolved = Get-Command $command -ErrorAction SilentlyContinue
    if ($resolved) {
        return [string]$resolved.Source
    }

    if (Test-Path -LiteralPath $command) {
        return [System.IO.Path]::GetFullPath($command)
    }

    throw "Configured OpenCode command '$command' for role '$($RoleConfig.roleName)' could not be resolved."
}

function Get-OpenCodeInvocationForRole {
    param($RoleConfig)

    $executable = Resolve-OpenCodeExecutablePath -RoleConfig $RoleConfig

    $model = [string]$RoleConfig.model
    $maxTurns = [int]$RoleConfig.maxTurns
    $reasoningEffort = [string]$RoleConfig.reasoningEffort
    $capabilities = @($RoleConfig.capabilities)

    $arguments = New-Object System.Collections.Generic.List[string]
    [void]$arguments.Add("run")

    if ($model) {
        [void]$arguments.Add("--model")
        [void]$arguments.Add($model)
    }

    [void]$arguments.Add("--agent")
    [void]$arguments.Add("autodev-role")

    $extraArgs = @($RoleConfig.extraArgs)
    foreach ($arg in $extraArgs) {
        [void]$arguments.Add($arg)
    }

    $configJson = Get-OpenCodeInvocationConfigJson -Capabilities $capabilities -Model $model -MaxTurns $maxTurns -ReasoningEffort $reasoningEffort
    $envOverrides = [ordered]@{
        "OPENCODE_CONFIG_CONTENT" = $configJson
    }

    return [pscustomobject]@{
        executable = $executable
        arguments = @($arguments.ToArray())
        promptInput = "argument"
        output = "stdout"
        env = $envOverrides
        configJson = $configJson
    }
}
