function Resolve-ClaudeCodeExecutablePath {
    param($RoleConfig)

    $candidateCommand = [string]$RoleConfig.command
    if ($env:AUTODEV_CLAUDE_COMMAND) {
        $candidateCommand = [string]$env:AUTODEV_CLAUDE_COMMAND
    }
    if (-not $candidateCommand) {
        $candidateCommand = "claude"
    }

    $resolved = Get-Command -Name $candidateCommand -ErrorAction SilentlyContinue
    if ($resolved) {
        return [string]$resolved.Source
    }

    if ($candidateCommand -eq "claude") {
        $fallback = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
        if (Test-Path -LiteralPath $fallback) {
            return $fallback
        }
    }

    if (Test-Path -LiteralPath $candidateCommand) {
        return [System.IO.Path]::GetFullPath($candidateCommand)
    }

    throw "Configured Claude command '$candidateCommand' for role '$($RoleConfig.roleName)' could not be resolved."
}

function Get-ClaudeCodeInvocationForRole {
    param($RoleConfig)

    $arguments = New-Object System.Collections.Generic.List[string]
    if ($RoleConfig.model) {
        [void]$arguments.Add("--model")
        [void]$arguments.Add([string]$RoleConfig.model)
    }

    if ($RoleConfig.reasoningEffort) {
        [void]$arguments.Add("--reasoning-effort")
        [void]$arguments.Add([string]$RoleConfig.reasoningEffort)
    }

    if ($RoleConfig.dangerouslySkipPermissions) {
        [void]$arguments.Add("--dangerously-skip-permissions")
    }

    if (@($RoleConfig.allowedTools).Count -gt 0) {
        [void]$arguments.Add("--allowedTools")
        [void]$arguments.Add((@($RoleConfig.allowedTools) -join ","))
    }

    if ([int]$RoleConfig.maxTurns -gt 0) {
        [void]$arguments.Add("--max-turns")
        [void]$arguments.Add(([int]$RoleConfig.maxTurns).ToString())
    }

    foreach ($extraArg in @($RoleConfig.extraArgs)) {
        [void]$arguments.Add([string]$extraArg)
    }

    return [pscustomobject]@{
        executable = Resolve-ClaudeCodeExecutablePath -RoleConfig $RoleConfig
        arguments = @($arguments.ToArray())
        promptInput = "stdin"
        output = "stdout"
        env = [ordered]@{}
    }
}
