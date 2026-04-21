param(
    [ValidateSet('probe', 'wait')][string]$Mode = 'probe',
    [string]$SolutionPath = '',
    [string]$RepoRoot = '',
    [int]$ThresholdPercent = 90,
    [int]$PollSeconds = 60,
    [int]$FastPollSeconds = 10,
    [int]$FastWindowSeconds = 60
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'autodevelop-config.ps1')

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory = '')

    $resolvedCommand = Resolve-AutoDevelopNativeCommandName -Command $Command
    $invocationCommand = $resolvedCommand
    $invocationArguments = @($Arguments)
    if ($resolvedCommand -and [System.IO.Path]::GetExtension([string]$resolvedCommand).ToLowerInvariant() -eq '.ps1') {
        $invocationCommand = 'powershell.exe'
        $invocationArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [string]$resolvedCommand) + @($Arguments)
    }
    $output = if ($WorkingDirectory) {
        & {
            $ErrorActionPreference = 'Continue'
            Push-Location $WorkingDirectory
            try {
                & $invocationCommand @invocationArguments 2>&1
            } finally {
                Pop-Location
            }
        }
    } else {
        & {
            $ErrorActionPreference = 'Continue'
            & $invocationCommand @invocationArguments 2>&1
        }
    }

    return [pscustomobject]@{
        output = ($output | Out-String).Trim()
        exitCode = $LASTEXITCODE
    }
}

function Get-CanonicalPath {
    param([string]$Path)

    if (-not $Path) { return '' }
    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    } catch {
        return [System.IO.Path]::GetFullPath($Path)
    }
}

function Resolve-RepoRoot {
    param([string]$ExplicitRepoRoot, [string]$ExplicitSolutionPath)

    if ($ExplicitRepoRoot) {
        return (Get-CanonicalPath -Path $ExplicitRepoRoot)
    }

    $anchor = if ($ExplicitSolutionPath) { Split-Path -Path (Get-CanonicalPath -Path $ExplicitSolutionPath) -Parent } else { (Get-Location).Path }
    $result = Invoke-NativeCommand -Command 'git' -Arguments @('rev-parse', '--show-toplevel') -WorkingDirectory $anchor
    if ($result.exitCode -ne 0 -or -not $result.output) {
        throw 'Could not resolve the repository root.'
    }
    return (Get-CanonicalPath -Path $result.output)
}

function Invoke-CommandUsageProbe {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $resolved = Get-Command -Name $Command -ErrorAction SilentlyContinue
    if (-not $resolved) {
        return [pscustomobject]@{
            ok = $false
            processStatus = 'fatal'
            shouldBlock = $false
            source = 'command'
            errors = @("Usage command '$Command' could not be resolved.")
        }
    }

    $raw = & $resolved.Source @Arguments 2>&1 | Out-String
    $text = $raw.Trim()
    if (-not $text) {
        return [pscustomobject]@{
            ok = $false
            processStatus = 'unavailable_parse'
            shouldBlock = $false
            source = 'command'
            errors = @('Usage command returned no JSON output.')
        }
    }

    try {
        return ($text | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            ok = $false
            processStatus = 'unavailable_parse'
            shouldBlock = $false
            source = 'command'
            errors = @("Usage command returned invalid JSON: $($_.Exception.Message)")
        }
    }
}

function Invoke-ComboUsageProbe {
    param(
        $Combo,
        [int]$Threshold,
        [int]$Poll,
        [int]$FastPoll,
        [int]$FastWindow
    )

    $usageSupport = Get-AutoDevelopCliProfileUsageSupport -CliProfileId ([string]$Combo.cliProfile) -Provider ([string]$Combo.provider) -ModelClass ([string]$Combo.modelClass)
    $modeName = [string](Get-AutoDevelopConfigPropertyValue -Object $usageSupport -Name 'mode')
    if (-not $modeName) { $modeName = 'none' }

    switch ($modeName) {
        'none' {
            return [pscustomobject]@{
                cliProfile = $Combo.cliProfile
                provider = $Combo.provider
                modelClass = $Combo.modelClass
                mode = 'none'
                ok = $true
                processStatus = 'usage_not_supported'
                shouldBlock = $false
                errors = @()
            }
        }
        'command' {
            $command = [string](Get-AutoDevelopConfigPropertyValue -Object $usageSupport -Name 'command')
            $arguments = @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $usageSupport -Name 'arguments'))
            $result = Invoke-CommandUsageProbe -Command $command -Arguments $arguments
            $result | Add-Member -NotePropertyName cliProfile -NotePropertyValue $Combo.cliProfile -Force
            $result | Add-Member -NotePropertyName provider -NotePropertyValue $Combo.provider -Force
            $result | Add-Member -NotePropertyName modelClass -NotePropertyValue $Combo.modelClass -Force
            $result | Add-Member -NotePropertyName mode -NotePropertyValue 'command' -Force
            return $result
        }
        'claude-oauth' {
            $gatePath = Join-Path $PSScriptRoot 'claude-usage-gate.ps1'
            $arguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $gatePath,
                '-Mode', $Mode,
                '-ThresholdPercent', $Threshold.ToString(),
                '-PollSeconds', $Poll.ToString(),
                '-FastPollSeconds', $FastPoll.ToString(),
                '-FastWindowSeconds', $FastWindow.ToString()
            )
            $raw = & powershell.exe @arguments
            $text = ($raw | Out-String).Trim()
            if (-not $text) {
                return [pscustomobject]@{
                    cliProfile = $Combo.cliProfile
                    provider = $Combo.provider
                    modelClass = $Combo.modelClass
                    mode = 'claude-oauth'
                    ok = $false
                    processStatus = 'fatal'
                    shouldBlock = $false
                    errors = @('Claude usage gate returned no JSON output.')
                }
            }

            $result = $text | ConvertFrom-Json
            $result | Add-Member -NotePropertyName cliProfile -NotePropertyValue $Combo.cliProfile -Force
            $result | Add-Member -NotePropertyName provider -NotePropertyValue $Combo.provider -Force
            $result | Add-Member -NotePropertyName modelClass -NotePropertyValue $Combo.modelClass -Force
            $result | Add-Member -NotePropertyName mode -NotePropertyValue 'claude-oauth' -Force
            return $result
        }
        'codex-session' {
            $gatePath = Join-Path $PSScriptRoot 'codex-usage-gate.ps1'
            $arguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $gatePath,
                '-Mode', $Mode,
                '-ThresholdPercent', $Threshold.ToString(),
                '-PollSeconds', $Poll.ToString(),
                '-FastPollSeconds', $FastPoll.ToString(),
                '-FastWindowSeconds', $FastWindow.ToString()
            )
            $raw = & powershell.exe @arguments
            $text = ($raw | Out-String).Trim()
            if (-not $text) {
                return [pscustomobject]@{
                    cliProfile = $Combo.cliProfile
                    provider = $Combo.provider
                    modelClass = $Combo.modelClass
                    mode = 'codex-session'
                    ok = $false
                    processStatus = 'fatal'
                    shouldBlock = $false
                    errors = @('Codex usage gate returned no JSON output.')
                }
            }

            $result = $text | ConvertFrom-Json
            $result | Add-Member -NotePropertyName cliProfile -NotePropertyValue $Combo.cliProfile -Force
            $result | Add-Member -NotePropertyName provider -NotePropertyValue $Combo.provider -Force
            $result | Add-Member -NotePropertyName modelClass -NotePropertyValue $Combo.modelClass -Force
            $result | Add-Member -NotePropertyName mode -NotePropertyValue 'codex-session' -Force
            return $result
        }
        default {
            return [pscustomobject]@{
                cliProfile = $Combo.cliProfile
                provider = $Combo.provider
                modelClass = $Combo.modelClass
                mode = $modeName
                ok = $false
                processStatus = 'fatal'
                shouldBlock = $false
                errors = @("Unsupported usage mode '$modeName'.")
            }
        }
    }
}

$resolvedRepoRoot = Resolve-RepoRoot -ExplicitRepoRoot $RepoRoot -ExplicitSolutionPath $SolutionPath
$configState = Get-AutoDevelopConfigState -RepoRoot $resolvedRepoRoot
$combos = @(Get-AutoDevelopRoleUsageCombos -ConfigState $configState)
$probeResults = @($combos | ForEach-Object { Invoke-ComboUsageProbe -Combo $_ -Threshold $ThresholdPercent -Poll $PollSeconds -FastPoll $FastPollSeconds -FastWindow $FastWindowSeconds })

$fatalCount = @($probeResults | Where-Object { [string]$_.processStatus -eq 'fatal' }).Count
$blockedCount = @($probeResults | Where-Object { $_.shouldBlock -eq $true }).Count
$unavailableCount = @($probeResults | Where-Object { $_.ok -ne $true -and [string]$_.processStatus -ne 'fatal' }).Count
$usageUnsupportedCount = @($probeResults | Where-Object { [string]$_.processStatus -eq 'usage_not_supported' }).Count

$processStatus = if ($fatalCount -gt 0) {
    'fatal'
} elseif ($blockedCount -gt 0) {
    'blocked'
} elseif ($unavailableCount -gt 0) {
    'unavailable'
} else {
    'ok'
}

[pscustomobject]@{
    ok = ($fatalCount -eq 0 -and $unavailableCount -eq 0)
    processStatus = $processStatus
    checkedAt = (Get-Date).ToString('o')
    thresholdPercent = $ThresholdPercent
    repoRoot = $resolvedRepoRoot
    activeExecutionProfile = $configState.activeExecutionProfile
    activeExecutionProfileSource = $configState.activeExecutionProfileSource
    combos = $probeResults
    usageUnsupportedCount = $usageUnsupportedCount
    blockingCount = $blockedCount
    unavailableCount = $unavailableCount
    fatalCount = $fatalCount
    shouldBlock = ($blockedCount -gt 0)
    warnings = @($configState.warnings)
} | ConvertTo-Json -Depth 32
