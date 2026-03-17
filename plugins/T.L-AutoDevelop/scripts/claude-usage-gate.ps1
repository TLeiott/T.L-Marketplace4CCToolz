# claude-usage-gate.ps1 -- Probe or wait on local Claude 5h usage state for batch launch gating
param(
    [ValidateSet('probe', 'wait')][string]$Mode = 'probe',
    [int]$ThresholdPercent = 90,
    [string]$ClaudeHome = '',
    [string]$SettingsPath = '',
    [string]$UsageCachePath = '',
    [string]$StatusLineCommandOverride = '',
    [switch]$SkipStatusLineCommand,
    [int]$PollSeconds = 60,
    [int]$FastPollSeconds = 10,
    [int]$FastWindowSeconds = 60
)

$ErrorActionPreference = 'Stop'

function New-OrderedList {
    return ,([System.Collections.ArrayList]::new())
}

function Add-UniqueError {
    param(
        [System.Collections.ArrayList]$Errors,
        [string]$Message
    )
    if ($null -eq $Errors -or -not $Message) { return }
    if (-not ($Errors -contains $Message)) { [void]$Errors.Add($Message) }
}

function Normalize-Percent {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    try {
        return [Math]::Round([double]$Value, 2)
    } catch {
        return $null
    }
}

function Get-ResolvedPathOrEmpty {
    param([string]$Path)
    if (-not $Path) { return '' }
    try {
        return (Resolve-Path -LiteralPath $Path).Path
    } catch {
        return ''
    }
}

function Get-EffectiveClaudeHome {
    if ($ClaudeHome) { return $ClaudeHome }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-EffectiveSettingsPath {
    param([string]$BaseClaudeHome)
    if ($SettingsPath) { return $SettingsPath }
    return (Join-Path $BaseClaudeHome 'settings.json')
}

function Get-EffectiveUsageCachePath {
    param([string]$BaseClaudeHome)
    if ($UsageCachePath) { return $UsageCachePath }
    return (Join-Path $BaseClaudeHome '.usage-cache.json')
}

function Strip-AnsiText {
    param([string]$Text)
    if (-not $Text) { return '' }
    $clean = [regex]::Replace($Text, "\x1B\[[0-?]*[ -/]*[@-~]", '')
    $clean = $clean -replace "`r", ''
    return $clean.Trim()
}

function Convert-TtlToResetAt {
    param([string]$Ttl)
    if (-not $Ttl) { return $null }
    if ($Ttl -notmatch '^(?<value>\d+)(?<unit>[mhd])$') { return $null }
    $value = [int]$Matches['value']
    $unit = $Matches['unit']
    $base = Get-Date
    switch ($unit) {
        'm' { return $base.AddMinutes($value) }
        'h' { return $base.AddHours($value) }
        'd' { return $base.AddDays($value) }
    }
    return $null
}

function Invoke-CommandText {
    param(
        [string]$CommandText,
        [string]$InputText
    )
    if (-not $CommandText) {
        return [ordered]@{
            success = $false
            exitCode = -1
            output = ''
            error = 'No command was provided.'
        }
    }

    try {
        $output = $InputText | & cmd.exe /d /s /c $CommandText 2>&1 | Out-String
        return [ordered]@{
            success = ($LASTEXITCODE -eq 0)
            exitCode = $LASTEXITCODE
            output = $output.TrimEnd()
            error = ''
        }
    } catch {
        return [ordered]@{
            success = $false
            exitCode = -1
            output = ''
            error = $_.Exception.Message
        }
    }
}

function Get-PathCandidatesFromCommandText {
    param([string]$CommandText)
    $paths = New-OrderedList
    if (-not $CommandText) { return @($paths) }

    $matches = [regex]::Matches($CommandText, '(?i)(?<path>[A-Z]:\\[^"\r\n]+)')
    foreach ($match in $matches) {
        $candidate = $match.Groups['path'].Value.Trim()
        if (-not $candidate) { continue }
        $candidate = $candidate.Trim('"')
        if ($paths -notcontains $candidate) {
            [void]$paths.Add($candidate)
        }
    }

    return @($paths)
}

function Expand-CommandText {
    param([string]$CommandText)
    if (-not $CommandText) { return '' }

    $expanded = [Environment]::ExpandEnvironmentVariables($CommandText)
    $homeValue = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    if ($homeValue) {
        $expanded = $expanded.Replace('$HOME', $homeValue)
        $expanded = $expanded.Replace('${HOME}', $homeValue)
        $expanded = $expanded.Replace('$env:HOME', $homeValue)
        $expanded = $expanded.Replace('$Env:HOME', $homeValue)
    }
    if ($env:USERPROFILE) {
        $expanded = $expanded.Replace('$env:USERPROFILE', $env:USERPROFILE)
        $expanded = $expanded.Replace('$Env:USERPROFILE', $env:USERPROFILE)
        $expanded = $expanded.Replace('${env:USERPROFILE}', $env:USERPROFILE)
        $expanded = $expanded.Replace('${Env:USERPROFILE}', $env:USERPROFILE)
    }

    return $expanded
}

function Get-StatusLineCommandInfo {
    param([string]$BaseClaudeHome)

    $errors = New-OrderedList
    $effectiveSettingsPath = Get-EffectiveSettingsPath -BaseClaudeHome $BaseClaudeHome
    $resolvedClaudeHome = Get-ResolvedPathOrEmpty -Path $BaseClaudeHome
    $defaultStatusLinePath = Join-Path $BaseClaudeHome 'statusline.ps1'
    $resolvedDefaultStatusLinePath = Get-ResolvedPathOrEmpty -Path $defaultStatusLinePath

    function New-CommandInfoResult {
        param(
            [string]$Command = '',
            [string]$ResolvedPath = '',
            [string]$CommandSource = ''
        )
        return [ordered]@{
            command = $Command
            resolvedPath = $ResolvedPath
            commandSource = $CommandSource
            errors = @($errors)
        }
    }

    function Get-DefaultCommandText {
        param([string]$StatusLinePath)
        if (-not $StatusLinePath) { return '' }
        return "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$StatusLinePath`""
    }

    function Try-BuildTrustedCommand {
        param(
            [string]$CommandText,
            [string]$CommandSource
        )

        if (-not $CommandText) { return $null }
        $expandedCommandText = Expand-CommandText -CommandText $CommandText
        $insideClaudeHome = $false
        $resolvedTargetPath = ''

        foreach ($candidate in (Get-PathCandidatesFromCommandText -CommandText $expandedCommandText)) {
            $resolvedCandidate = Get-ResolvedPathOrEmpty -Path $candidate
            if (-not $resolvedCandidate) { continue }
            if ($resolvedClaudeHome -and $resolvedCandidate.StartsWith($resolvedClaudeHome, [System.StringComparison]::OrdinalIgnoreCase)) {
                $insideClaudeHome = $true
                $resolvedTargetPath = $resolvedCandidate
                break
            }
        }

        if (-not $insideClaudeHome) { return $null }
        return [ordered]@{
            command = $expandedCommandText
            resolvedPath = $resolvedTargetPath
            commandSource = $CommandSource
        }
    }

    if ($StatusLineCommandOverride) {
        $overrideResult = Try-BuildTrustedCommand -CommandText $StatusLineCommandOverride -CommandSource 'override'
        if ($overrideResult) {
            return New-CommandInfoResult -Command $overrideResult.command -ResolvedPath $overrideResult.resolvedPath -CommandSource $overrideResult.commandSource
        }
        Add-UniqueError -Errors $errors -Message 'StatusLineCommandOverride does not safely resolve into the main Claude directory.'
        return New-CommandInfoResult
    }

    if (-not (Test-Path -LiteralPath $effectiveSettingsPath)) {
        Add-UniqueError -Errors $errors -Message "settings.json was not found: $effectiveSettingsPath"
        if ($resolvedDefaultStatusLinePath) {
            return New-CommandInfoResult -Command (Get-DefaultCommandText -StatusLinePath $resolvedDefaultStatusLinePath) -ResolvedPath $resolvedDefaultStatusLinePath -CommandSource 'default-script'
        }
        return New-CommandInfoResult
    }

    try {
        $settings = Get-Content -LiteralPath $effectiveSettingsPath -Raw | ConvertFrom-Json
    } catch {
        Add-UniqueError -Errors $errors -Message "settings.json could not be read: $($_.Exception.Message)"
        if ($resolvedDefaultStatusLinePath) {
            return New-CommandInfoResult -Command (Get-DefaultCommandText -StatusLinePath $resolvedDefaultStatusLinePath) -ResolvedPath $resolvedDefaultStatusLinePath -CommandSource 'default-script'
        }
        return New-CommandInfoResult
    }

    if ($settings.statusLine.type -ne 'command') {
        Add-UniqueError -Errors $errors -Message 'statusLine.type is not "command".'
        if ($resolvedDefaultStatusLinePath) {
            return New-CommandInfoResult -Command (Get-DefaultCommandText -StatusLinePath $resolvedDefaultStatusLinePath) -ResolvedPath $resolvedDefaultStatusLinePath -CommandSource 'default-script'
        }
        return New-CommandInfoResult
    }

    $commandText = [string]$settings.statusLine.command
    if (-not $commandText) {
        Add-UniqueError -Errors $errors -Message 'statusLine.command ist leer.'
        if ($resolvedDefaultStatusLinePath) {
            return New-CommandInfoResult -Command (Get-DefaultCommandText -StatusLinePath $resolvedDefaultStatusLinePath) -ResolvedPath $resolvedDefaultStatusLinePath -CommandSource 'default-script'
        }
        return New-CommandInfoResult
    }

    $trustedCommand = Try-BuildTrustedCommand -CommandText $commandText -CommandSource 'settings'
    if ($trustedCommand) {
        return New-CommandInfoResult -Command $trustedCommand.command -ResolvedPath $trustedCommand.resolvedPath -CommandSource $trustedCommand.commandSource
    }

    Add-UniqueError -Errors $errors -Message 'statusLine.command does not safely resolve to a file inside the main Claude directory.'
    if ($resolvedDefaultStatusLinePath) {
        return New-CommandInfoResult -Command (Get-DefaultCommandText -StatusLinePath $resolvedDefaultStatusLinePath) -ResolvedPath $resolvedDefaultStatusLinePath -CommandSource 'default-script'
    }
    return New-CommandInfoResult
}

function Get-MockStatusLinePayload {
    $cwd = (Get-Location).Path
    return ([ordered]@{
        model = [ordered]@{
            display_name = 'Batch Scheduler'
            id = 'claude-sonnet-4-6'
        }
        context_window = [ordered]@{
            used_percentage = 0
            remaining_percentage = 100
            context_window_size = 1000000
            exceeds_200k_tokens = $false
            current_usage = 0
        }
        cost = [ordered]@{
            total_cost_usd = 0
            total_lines_added = 0
            total_lines_removed = 0
            total_duration_ms = 0
        }
        workspace = [ordered]@{
            current_dir = $cwd
            original_cwd = $cwd
            added_dirs = @()
        }
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-UsageCacheState {
    param([string]$BaseClaudeHome)

    $errors = New-OrderedList
    $effectiveCachePath = Get-EffectiveUsageCachePath -BaseClaudeHome $BaseClaudeHome
    if (-not (Test-Path -LiteralPath $effectiveCachePath)) {
        Add-UniqueError -Errors $errors -Message "Usage cache was not found: $effectiveCachePath"
        return [ordered]@{
            available = $false
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            errors = @($errors)
        }
    }

    try {
        $cache = Get-Content -LiteralPath $effectiveCachePath -Raw | ConvertFrom-Json
    } catch {
        Add-UniqueError -Errors $errors -Message "Usage cache could not be read: $($_.Exception.Message)"
        return [ordered]@{
            available = $false
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            errors = @($errors)
        }
    }

    $fiveHourResetAt = $null
    if ($cache.five_hour.resets_at) {
        try {
            $fiveHourResetAt = [DateTimeOffset]::Parse([string]$cache.five_hour.resets_at)
        } catch {
            Add-UniqueError -Errors $errors -Message 'five_hour.resets_at could not be parsed.'
        }
    }

    return [ordered]@{
        available = ($null -ne $cache.five_hour)
        fiveHourUtilization = Normalize-Percent -Value $cache.five_hour.utilization
        fiveHourResetAt = $fiveHourResetAt
        sevenDayUtilization = Normalize-Percent -Value $cache.seven_day.utilization
        errors = @($errors)
    }
}

function Get-StatusLineState {
    param(
        [string]$BaseClaudeHome,
        $CacheState
    )

    $errors = New-OrderedList
    if ($SkipStatusLineCommand) {
        Add-UniqueError -Errors $errors -Message 'The statusline command was skipped via parameter.'
        return [ordered]@{
            available = $false
            rawStatusline = ''
            cleanStatusline = ''
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            command = ''
            resolvedPath = ''
            commandSource = ''
            errors = @($errors)
        }
    }

    $commandInfo = Get-StatusLineCommandInfo -BaseClaudeHome $BaseClaudeHome
    foreach ($errorText in $commandInfo.errors) {
        Add-UniqueError -Errors $errors -Message $errorText
    }

    if (-not $commandInfo.command) {
        return [ordered]@{
            available = $false
            rawStatusline = ''
            cleanStatusline = ''
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            command = ''
            resolvedPath = ''
            commandSource = ''
            errors = @($errors)
        }
    }

    $invokeResult = Invoke-CommandText -CommandText $commandInfo.command -InputText (Get-MockStatusLinePayload)
    if (-not $invokeResult.success) {
        $errorText = if ($invokeResult.error) { $invokeResult.error } else { "ExitCode=$($invokeResult.exitCode)" }
        Add-UniqueError -Errors $errors -Message "Statusline command failed: $errorText"
        return [ordered]@{
            available = $false
            rawStatusline = $invokeResult.output
            cleanStatusline = (Strip-AnsiText -Text $invokeResult.output)
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            command = $commandInfo.command
            resolvedPath = $commandInfo.resolvedPath
            commandSource = $commandInfo.commandSource
            errors = @($errors)
        }
    }

    $cleanText = Strip-AnsiText -Text $invokeResult.output
    $segmentMatch = [regex]::Match($cleanText, '(?is)\b5h\b(?<segment>.*?)(?:\|\s*7d\b|$)')
    if (-not $segmentMatch.Success) {
        Add-UniqueError -Errors $errors -Message 'The 5h segment was not found in the statusline output.'
        return [ordered]@{
            available = $false
            rawStatusline = $invokeResult.output
            cleanStatusline = $cleanText
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            command = $commandInfo.command
            resolvedPath = $commandInfo.resolvedPath
            commandSource = $commandInfo.commandSource
            errors = @($errors)
        }
    }

    $segmentText = $segmentMatch.Groups['segment'].Value
    $percentMatch = [regex]::Match($segmentText, '(?is)(?<percent>\d{1,3}(?:[.,]\d+)?)%')
    if (-not $percentMatch.Success) {
        Add-UniqueError -Errors $errors -Message 'The 5h percentage value was not found in the statusline output.'
        return [ordered]@{
            available = $false
            rawStatusline = $invokeResult.output
            cleanStatusline = $cleanText
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            command = $commandInfo.command
            resolvedPath = $commandInfo.resolvedPath
            commandSource = $commandInfo.commandSource
            errors = @($errors)
        }
    }

    $fiveHourPercent = Normalize-Percent -Value ($percentMatch.Groups['percent'].Value -replace ',', '.')
    $ttlMatch = [regex]::Match($segmentText, '(?is)%\s*(?<ttl>\d+[mhd])\b')
    $ttlResetAt = if ($ttlMatch.Success) { Convert-TtlToResetAt -Ttl $ttlMatch.Groups['ttl'].Value } else { $null }
    $effectiveResetAt = if ($CacheState.available -and $CacheState.fiveHourResetAt) { $CacheState.fiveHourResetAt } else { $ttlResetAt }
    $effectiveSevenDay = if ($CacheState.available) { $CacheState.sevenDayUtilization } else { $null }

    return [ordered]@{
        available = ($null -ne $fiveHourPercent)
        rawStatusline = $invokeResult.output
        cleanStatusline = $cleanText
        fiveHourUtilization = $fiveHourPercent
        fiveHourResetAt = $effectiveResetAt
        sevenDayUtilization = $effectiveSevenDay
        command = $commandInfo.command
        resolvedPath = $commandInfo.resolvedPath
        commandSource = $commandInfo.commandSource
        errors = @($errors)
    }
}

function Get-WaitSeconds {
    param($ResetAt)
    if ($null -eq $ResetAt) { return [Math]::Max(1, $PollSeconds) }

    try {
        $remaining = [Math]::Ceiling(($ResetAt - [DateTimeOffset]::Now).TotalSeconds)
    } catch {
        return [Math]::Max(1, $PollSeconds)
    }

    if ($remaining -le 0) { return [Math]::Max(1, $FastPollSeconds) }
    if ($remaining -le $FastWindowSeconds) { return [Math]::Max(1, [Math]::Min($FastPollSeconds, $remaining)) }
    return [Math]::Max(1, [Math]::Min($PollSeconds, $remaining))
}

function Get-GateState {
    param([string]$BaseClaudeHome)

    $errors = New-OrderedList
    $cacheState = Get-UsageCacheState -BaseClaudeHome $BaseClaudeHome
    foreach ($errorText in $cacheState.errors) {
        Add-UniqueError -Errors $errors -Message $errorText
    }

    $statusState = Get-StatusLineState -BaseClaudeHome $BaseClaudeHome -CacheState $cacheState
    foreach ($errorText in $statusState.errors) {
        Add-UniqueError -Errors $errors -Message $errorText
    }

    $source = 'none'
    $fiveHourUtilization = $null
    $fiveHourResetAt = $null
    $sevenDayUtilization = $null
    $rawStatusline = ''
    $statuslineCommand = ''
    $statuslineResolvedPath = ''
    $statuslineCommandSource = ''

    if ($statusState.available) {
        $source = 'statusline'
        $fiveHourUtilization = $statusState.fiveHourUtilization
        $fiveHourResetAt = $statusState.fiveHourResetAt
        $sevenDayUtilization = $statusState.sevenDayUtilization
        $rawStatusline = $statusState.cleanStatusline
        $statuslineCommand = $statusState.command
        $statuslineResolvedPath = $statusState.resolvedPath
        $statuslineCommandSource = $statusState.commandSource
    } elseif ($cacheState.available -and $null -ne $cacheState.fiveHourUtilization) {
        $source = 'cache'
        $fiveHourUtilization = $cacheState.fiveHourUtilization
        $fiveHourResetAt = $cacheState.fiveHourResetAt
        $sevenDayUtilization = $cacheState.sevenDayUtilization
        $rawStatusline = ''
        $statuslineCommand = $statusState.command
        $statuslineResolvedPath = $statusState.resolvedPath
        $statuslineCommandSource = $statusState.commandSource
    }

    return [ordered]@{
        ok = ($source -ne 'none' -and $null -ne $fiveHourUtilization)
        processStatus = if ($source -ne 'none' -and $null -ne $fiveHourUtilization) { 'ok' } else { 'unavailable' }
        checkedAt = (Get-Date).ToString('o')
        source = $source
        thresholdPercent = $ThresholdPercent
        fiveHourUtilization = $fiveHourUtilization
        fiveHourResetAt = if ($fiveHourResetAt) { $fiveHourResetAt.ToString('o') } else { $null }
        sevenDayUtilization = $sevenDayUtilization
        shouldBlock = ($source -ne 'none' -and $null -ne $fiveHourUtilization -and $fiveHourUtilization -ge $ThresholdPercent)
        rawStatusline = $rawStatusline
        statuslineCommand = $statuslineCommand
        statuslineResolvedPath = $statuslineResolvedPath
        statuslineCommandSource = $statuslineCommandSource
        statuslineErrors = @($statusState.errors)
        cacheErrors = @($cacheState.errors)
        errors = @($errors)
    }
}

function Write-JsonResult {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Output $json
}

try {
    $baseClaudeHome = Get-EffectiveClaudeHome
    if ($Mode -eq 'probe') {
        $probeResult = Get-GateState -BaseClaudeHome $baseClaudeHome
        Write-JsonResult -Object $probeResult
        exit 0
    }

    $history = New-OrderedList
    $waitedSeconds = 0
    while ($true) {
        $state = Get-GateState -BaseClaudeHome $baseClaudeHome
        [void]$history.Add([ordered]@{
            checkedAt = $state.checkedAt
            source = $state.source
            fiveHourUtilization = $state.fiveHourUtilization
            fiveHourResetAt = $state.fiveHourResetAt
            shouldBlock = $state.shouldBlock
            processStatus = $state.processStatus
            errors = @($state.errors)
        })

        if (-not $state.ok) {
            $state.mode = $Mode
            $state.waitedSeconds = $waitedSeconds
            $state.history = @($history)
            Write-JsonResult -Object $state
            exit 0
        }

        if (-not $state.shouldBlock) {
            $state.mode = $Mode
            $state.waitedSeconds = $waitedSeconds
            $state.history = @($history)
            Write-JsonResult -Object $state
            exit 0
        }

        $resetAt = $null
        if ($state.fiveHourResetAt) {
            try {
                $resetAt = [DateTimeOffset]::Parse([string]$state.fiveHourResetAt)
            } catch {
                $resetAt = $null
            }
        }

        $sleepSeconds = Get-WaitSeconds -ResetAt $resetAt
        Start-Sleep -Seconds $sleepSeconds
        $waitedSeconds += $sleepSeconds
    }
} catch {
    $fatalErrors = @($_.Exception.Message)
    $fatalResult = [ordered]@{
        ok = $false
        processStatus = 'fatal'
        checkedAt = (Get-Date).ToString('o')
        source = 'none'
        thresholdPercent = $ThresholdPercent
        fiveHourUtilization = $null
        fiveHourResetAt = $null
        sevenDayUtilization = $null
        shouldBlock = $false
        rawStatusline = ''
        statuslineCommand = ''
        statuslineResolvedPath = ''
        statuslineCommandSource = ''
        statuslineErrors = @()
        cacheErrors = @()
        errors = $fatalErrors
        mode = $Mode
        waitedSeconds = 0
        history = @()
    }
    Write-JsonResult -Object $fatalResult
    exit 0
}
