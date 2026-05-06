function Resolve-CodexExecutablePath {
    param($RoleConfig)

    $candidateCommand = [string]$RoleConfig.command
    if ($env:AUTODEV_CODEX_COMMAND) {
        $candidateCommand = [string]$env:AUTODEV_CODEX_COMMAND
    }
    if (-not $candidateCommand) {
        $candidateCommand = "codex"
    }

    $resolved = Get-Command -Name $candidateCommand -ErrorAction SilentlyContinue
    if ($resolved) {
        return [string]$resolved.Source
    }

    if (Test-Path -LiteralPath $candidateCommand) {
        return [System.IO.Path]::GetFullPath($candidateCommand)
    }

    throw "Configured Codex command '$candidateCommand' for role '$($RoleConfig.roleName)' could not be resolved."
}

function Get-CodexPromptForRole {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)]$RoleConfig
    )

    $maxTurns = [int]$RoleConfig.maxTurns
    if ($maxTurns -le 0) {
        return $Prompt
    }

    $turnBudgetInstruction = "IMPORTANT: Treat $maxTurns turns as your hard conversation budget for this task. Plan briefly, execute directly, and stop once the task is complete or you cannot proceed safely within that budget."
    return ($Prompt.TrimEnd() + "`n`nAUTODEVELOP_TURN_BUDGET:`n$turnBudgetInstruction")
}

function Get-CodexSandboxModeForRole {
    param($RoleConfig)

    $capabilities = @($RoleConfig.capabilities | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ })
    if ($capabilities.Count -gt 0 -and @($capabilities | Where-Object { $_ -notin @("read", "search") }).Count -eq 0) {
        return "read-only"
    }

    return "workspace-write"
}

function Get-CodexInvocationForRole {
    param(
        $RoleConfig,
        [string]$LastMessageFile = ""
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    [void]$arguments.Add("exec")
    [void]$arguments.Add("--color")
    [void]$arguments.Add("never")

    if ($RoleConfig.model) {
        [void]$arguments.Add("--model")
        [void]$arguments.Add([string]$RoleConfig.model)
    }

    if ($RoleConfig.reasoningEffort) {
        [void]$arguments.Add("-c")
        [void]$arguments.Add(('model_reasoning_effort="' + [string]$RoleConfig.reasoningEffort + '"'))
    }

    if ($LastMessageFile) {
        [void]$arguments.Add("--output-last-message")
        [void]$arguments.Add($LastMessageFile)
    }

    if ($RoleConfig.dangerouslySkipPermissions) {
        [void]$arguments.Add("--dangerously-bypass-approvals-and-sandbox")
    } else {
        [void]$arguments.Add("--sandbox")
        [void]$arguments.Add((Get-CodexSandboxModeForRole -RoleConfig $RoleConfig))
    }

    foreach ($extraArg in @($RoleConfig.extraArgs)) {
        [void]$arguments.Add([string]$extraArg)
    }

    return [pscustomobject]@{
        executable = Resolve-CodexExecutablePath -RoleConfig $RoleConfig
        arguments = @($arguments.ToArray())
        promptInput = "stdin"
        output = "stdout"
        resultSource = if ($LastMessageFile) { "last-message-file" } else { "stdout" }
        env = [ordered]@{}
    }
}
