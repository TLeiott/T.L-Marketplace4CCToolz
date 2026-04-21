# codex-usage-gate.ps1 -- Probe or wait on Codex session rate limits for batch launch gating
param(
    [ValidateSet('probe', 'wait')][string]$Mode = 'probe',
    [int]$ThresholdPercent = 90,
    [string]$CodexHome = '',
    [string]$UsageCachePath = '',
    [string]$StateDbPath = '',
    [string]$SessionPath = '',
    [string]$ThreadId = '',
    [int]$PollSeconds = 60,
    [int]$FastPollSeconds = 10,
    [int]$FastWindowSeconds = 60,
    [string]$MockStatusJson = '',
    [string]$MockErrorKind = '',
    [string]$MockStatusSequencePath = ''
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
    if (-not ($Errors -contains $Message)) {
        [void]$Errors.Add($Message)
    }
}

function Get-TrimmedString {
    param($Value)

    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
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

function Get-EffectiveCodexHome {
    if ($CodexHome) { return $CodexHome }
    if ($env:CODEX_HOME) { return [string]$env:CODEX_HOME }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Get-EffectiveUsageCachePath {
    param([string]$BaseCodexHome)

    if ($UsageCachePath) { return $UsageCachePath }
    return (Join-Path $BaseCodexHome 'tl-autodev-codex-usage-cache.json')
}

function Get-EffectiveStateDbPath {
    param([string]$BaseCodexHome)

    if ($StateDbPath) { return $StateDbPath }
    return (Join-Path $BaseCodexHome 'state_5.sqlite')
}

function Convert-ToDateTimeOffsetOrNull {
    param($Value)

    if ($null -eq $Value -or $Value -eq '') { return $null }

    if ($Value -is [DateTimeOffset]) {
        return $Value
    }

    if ($Value -is [DateTime]) {
        return [DateTimeOffset]$Value
    }

    if ($Value -is [long] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal]) {
        try {
            return [DateTimeOffset]::FromUnixTimeSeconds([long]$Value)
        } catch {
            return $null
        }
    }

    $text = [string]$Value
    if (-not $text) { return $null }

    try {
        return [DateTimeOffset]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        try {
            if ($text -match '^\d+$') {
                return [DateTimeOffset]::FromUnixTimeSeconds([long]$text)
            }
        } catch {
        }
    }

    return $null
}

function Convert-ToIsoStringOrNull {
    param($Value)

    $parsed = Convert-ToDateTimeOffsetOrNull -Value $Value
    if ($null -eq $parsed) { return $null }
    return $parsed.ToString('o')
}

function Get-UsageCacheState {
    param([string]$CachePath)

    $errors = New-OrderedList
    if (-not (Test-Path -LiteralPath $CachePath)) {
        return [ordered]@{
            exists = $false
            available = $false
            cachePath = $CachePath
            fetchedAt = $null
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            lastError = ''
            errors = @($errors)
        }
    }

    try {
        $cache = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
    } catch {
        Add-UniqueError -Errors $errors -Message "Codex usage cache could not be read: $($_.Exception.Message)"
        return [ordered]@{
            exists = $true
            available = $false
            cachePath = $CachePath
            fetchedAt = $null
            fiveHourUtilization = $null
            fiveHourResetAt = $null
            sevenDayUtilization = $null
            lastError = ''
            errors = @($errors)
        }
    }

    return [ordered]@{
        exists = $true
        available = ($null -ne $cache.fiveHourUtilization)
        cachePath = $CachePath
        fetchedAt = Convert-ToIsoStringOrNull -Value $cache.fetchedAt
        fiveHourUtilization = Normalize-Percent -Value $cache.fiveHourUtilization
        fiveHourResetAt = Convert-ToIsoStringOrNull -Value $cache.fiveHourResetAt
        sevenDayUtilization = Normalize-Percent -Value $cache.sevenDayUtilization
        lastError = if ($cache.lastError) { [string]$cache.lastError } else { '' }
        errors = @($errors)
    }
}

function Save-UsageCache {
    param(
        [string]$CachePath,
        $State
    )

    $parent = Split-Path -Path $CachePath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $cacheObject = [ordered]@{
        fetchedAt = $State.checkedAt
        source = 'session-log'
        fiveHourUtilization = $State.fiveHourUtilization
        fiveHourResetAt = $State.fiveHourResetAt
        sevenDayUtilization = $State.sevenDayUtilization
        thresholdPercent = $State.thresholdPercent
        shouldBlock = $State.shouldBlock
        lastError = ''
    }

    $cacheJson = $cacheObject | ConvertTo-Json -Depth 6
    $tempPath = "$CachePath.tmp-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$CachePath.bak-$([guid]::NewGuid().ToString('N'))"

    try {
        [System.IO.File]::WriteAllText($tempPath, $cacheJson, [System.Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $CachePath) {
            [System.IO.File]::Replace($tempPath, $CachePath, $backupPath, $false)
        } else {
            [System.IO.File]::Move($tempPath, $CachePath)
        }
    } finally {
        Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -ErrorAction SilentlyContinue
    }
}

function Get-ErrorCategory {
    param([string]$Kind)

    $normalizedKind = (Get-TrimmedString -Value $Kind).ToLowerInvariant()
    switch ($normalizedKind) {
        'timeout' { return 'unavailable_timeout' }
        'parse' { return 'unavailable_parse' }
        'session' { return 'unavailable_session' }
        default { return 'unavailable_parse' }
    }
}

function Resolve-AvailablePythonCommand {
    foreach ($candidate in @('python', 'py')) {
        $resolved = Get-Command -Name $candidate -ErrorAction SilentlyContinue
        if ($resolved) {
            return [string]$resolved.Source
        }
    }

    return ''
}

function Get-SqliteLookupSessionPath {
    param(
        [string]$DbPath,
        [string]$ThreadIdValue
    )

    if (-not $DbPath -or -not (Test-Path -LiteralPath $DbPath)) {
        return ''
    }

    $pythonCommand = Resolve-AvailablePythonCommand
    if (-not $pythonCommand) {
        return ''
    }

    $pythonCode = @'
import sqlite3
import sys

db_path = sys.argv[1]
thread_id = sys.argv[2]

conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT rollout_path FROM threads WHERE id = ? LIMIT 1", (thread_id,))
row = cur.fetchone()
if row and row[0]:
    sys.stdout.write(str(row[0]))
'@

    $pythonArguments = @('-c', $pythonCode, $DbPath, $ThreadIdValue)
    $pythonFileName = [System.IO.Path]::GetFileName($pythonCommand).ToLowerInvariant()
    if ($pythonFileName -eq 'py.exe' -or $pythonFileName -eq 'py') {
        $pythonArguments = @('-3') + $pythonArguments
    }

    try {
        $output = & $pythonCommand @pythonArguments 2>$null | Out-String
        return (Get-TrimmedString -Value $output)
    } catch {
        return ''
    }
}

function New-UnavailableState {
    param(
        [string]$Status,
        [int]$Threshold,
        $CachedState,
        [string[]]$Errors,
        [string]$ThreadIdValue,
        [string]$SessionPathValue,
        [string]$StateDbPathValue
    )

    return [ordered]@{
        ok = $false
        processStatus = $Status
        checkedAt = (Get-Date).ToString('o')
        thresholdPercent = $Threshold
        source = 'none'
        fresh = $false
        fiveHourUtilization = if ($CachedState) { $CachedState.fiveHourUtilization } else { $null }
        fiveHourResetAt = if ($CachedState) { $CachedState.fiveHourResetAt } else { $null }
        sevenDayUtilization = if ($CachedState) { $CachedState.sevenDayUtilization } else { $null }
        lastSuccessfulFetchAt = if ($CachedState) { $CachedState.fetchedAt } else { $null }
        shouldBlock = $false
        errors = @($Errors)
        threadId = $ThreadIdValue
        sessionPath = $SessionPathValue
        stateDbPath = $StateDbPathValue
    }
}

function Get-MockStatusFromSequence {
    param([string]$Path)

    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Mock Codex status sequence was not found: $Path" }

    $raw = Get-Content -LiteralPath $Path -Raw
    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        $items = @($parsed)
    } else {
        $items = @($parsed)
    }

    if ($items.Count -eq 0) {
        throw 'Mock Codex status sequence is empty.'
    }

    $current = $items[0]
    $remaining = if ($items.Count -gt 1) { @($items | Select-Object -Skip 1) } else { @($current) }
    [System.IO.File]::WriteAllText($Path, ($remaining | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
    return $current
}

function Resolve-EffectiveThreadId {
    if ($ThreadId) { return $ThreadId }
    if ($env:AUTODEV_CODEX_THREAD_ID) { return [string]$env:AUTODEV_CODEX_THREAD_ID }
    if ($env:CODEX_THREAD_ID) { return [string]$env:CODEX_THREAD_ID }
    return ''
}

function Resolve-EffectiveSessionPath {
    param(
        [string]$BaseCodexHome,
        [string]$ThreadIdValue,
        [string]$StateDbPathValue
    )

    if ($SessionPath) { return $SessionPath }
    if ($env:AUTODEV_CODEX_SESSION_PATH) { return [string]$env:AUTODEV_CODEX_SESSION_PATH }
    if (-not $ThreadIdValue) {
        throw 'SESSION: No Codex thread id is available for usage probing.'
    }

    $sessionPathFromStateDb = Get-SqliteLookupSessionPath -DbPath $StateDbPathValue -ThreadIdValue $ThreadIdValue
    if ($sessionPathFromStateDb) {
        return $sessionPathFromStateDb
    }

    $sessionsRoot = Join-Path $BaseCodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        throw "SESSION: Codex sessions directory was not found: $sessionsRoot"
    }

    $matches = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$ThreadIdValue*" } | Sort-Object LastWriteTimeUtc -Descending)
    if ($matches.Count -eq 0) {
        throw "SESSION: No Codex session log was found for thread '$ThreadIdValue'."
    }

    return [string]$matches[0].FullName
}

function Get-LatestTokenCountPayload {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "SESSION: Codex session log was not found: $Path"
    }

    $latest = $null
    foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line.IndexOf('"type":"token_count"') -lt 0 -and $line.IndexOf('"type": "token_count"') -lt 0) {
            continue
        }

        try {
            $parsed = $line | ConvertFrom-Json
        } catch {
            continue
        }

        if ($null -ne $parsed.payload -and [string]$parsed.payload.type -eq 'token_count') {
            $latest = $parsed.payload
        }
    }

    if ($null -eq $latest) {
        throw "No token_count payload was found in Codex session log '$Path'."
    }

    return $latest
}

function Convert-TokenCountPayloadToState {
    param(
        $Payload,
        [int]$Threshold,
        [string]$ThreadIdValue,
        [string]$SessionPathValue,
        [string]$StateDbPathValue
    )

    $rateLimits = $Payload.rate_limits
    if ($null -eq $rateLimits) {
        throw 'Codex token_count payload did not include rate_limits.'
    }

    $primaryUtilization = Normalize-Percent -Value $rateLimits.primary.used_percent
    $primaryResetAt = Convert-ToIsoStringOrNull -Value $rateLimits.primary.resets_at
    $secondaryUtilization = Normalize-Percent -Value $rateLimits.secondary.used_percent
    $planType = Get-TrimmedString -Value $rateLimits.plan_type
    $rateLimitReachedType = Get-TrimmedString -Value $rateLimits.rate_limit_reached_type
    $shouldBlock = (($null -ne $primaryUtilization) -and ($primaryUtilization -ge $Threshold)) -or [bool]$rateLimitReachedType
    $checkedAt = (Get-Date).ToString('o')

    return [ordered]@{
        ok = $true
        processStatus = if ($shouldBlock) { 'blocked' } else { 'ok' }
        checkedAt = $checkedAt
        thresholdPercent = $Threshold
        source = 'session-log'
        fresh = $true
        fiveHourUtilization = $primaryUtilization
        fiveHourResetAt = $primaryResetAt
        sevenDayUtilization = $secondaryUtilization
        shouldBlock = $shouldBlock
        lastSuccessfulFetchAt = $checkedAt
        planType = $planType
        rateLimitReachedType = $rateLimitReachedType
        errors = @()
        threadId = $ThreadIdValue
        sessionPath = $SessionPathValue
        stateDbPath = $StateDbPathValue
    }
}

function Invoke-CodexUsageProbe {
    param(
        [int]$Threshold,
        [string]$BaseCodexHome,
        [string]$CachePath,
        [string]$StateDbPathValue
    )

    $cachedState = Get-UsageCacheState -CachePath $CachePath
    $threadIdValue = Resolve-EffectiveThreadId
    $sessionPathValue = $null

    if ($MockErrorKind) {
        return (New-UnavailableState -Status (Get-ErrorCategory -Kind $MockErrorKind) -Threshold $Threshold -CachedState $cachedState -Errors @("Mock Codex probe error: $MockErrorKind") -ThreadIdValue $threadIdValue -SessionPathValue $SessionPath -StateDbPathValue $StateDbPathValue)
    }

    try {
        $payload = if ($MockStatusSequencePath) {
            Get-MockStatusFromSequence -Path $MockStatusSequencePath
        } elseif ($MockStatusJson) {
            $MockStatusJson | ConvertFrom-Json
        } else {
            $sessionPathValue = Resolve-EffectiveSessionPath -BaseCodexHome $BaseCodexHome -ThreadIdValue $threadIdValue -StateDbPathValue $StateDbPathValue
            Get-LatestTokenCountPayload -Path $sessionPathValue
        }

        if (-not $sessionPathValue) {
            $sessionPathValue = if ($SessionPath) { $SessionPath } elseif ($env:AUTODEV_CODEX_SESSION_PATH) { [string]$env:AUTODEV_CODEX_SESSION_PATH } else { '' }
        }

        $state = Convert-TokenCountPayloadToState -Payload $payload -Threshold $Threshold -ThreadIdValue $threadIdValue -SessionPathValue $sessionPathValue -StateDbPathValue $StateDbPathValue
        Save-UsageCache -CachePath $CachePath -State $state
        return $state
    } catch {
        $message = [string]$_.Exception.Message
        $kind = 'parse'
        if ($message -like 'SESSION:*') {
            $kind = 'session'
            $message = $message.Substring(8).Trim()
        }
        return (New-UnavailableState -Status (Get-ErrorCategory -Kind $kind) -Threshold $Threshold -CachedState $cachedState -Errors @($message) -ThreadIdValue $threadIdValue -SessionPathValue $sessionPathValue -StateDbPathValue $StateDbPathValue)
    }
}

$baseCodexHome = Get-EffectiveCodexHome
$cachePath = Get-EffectiveUsageCachePath -BaseCodexHome $baseCodexHome
$effectiveStateDbPath = Get-EffectiveStateDbPath -BaseCodexHome $baseCodexHome

if ($Mode -eq 'probe') {
    (Invoke-CodexUsageProbe -Threshold $ThresholdPercent -BaseCodexHome $baseCodexHome -CachePath $cachePath -StateDbPathValue $effectiveStateDbPath) | ConvertTo-Json -Depth 16
    exit 0
}

$history = New-OrderedList
$startedAt = Get-Date
while ($true) {
    $state = Invoke-CodexUsageProbe -Threshold $ThresholdPercent -BaseCodexHome $baseCodexHome -CachePath $cachePath -StateDbPathValue $effectiveStateDbPath
    [void]$history.Add([ordered]@{
        checkedAt = $state.checkedAt
        processStatus = $state.processStatus
        shouldBlock = $state.shouldBlock
        fiveHourUtilization = $state.fiveHourUtilization
    })

    if (-not $state.ok) {
        $state.waitedSeconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalSeconds)
        $state.history = @($history.ToArray())
        $state | ConvertTo-Json -Depth 16
        exit 0
    }

    if (-not $state.shouldBlock) {
        $state.waitedSeconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalSeconds)
        $state.history = @($history.ToArray())
        $state | ConvertTo-Json -Depth 16
        exit 0
    }

    if (-not $state.fiveHourResetAt) {
        $unavailable = New-UnavailableState -Status 'unavailable_parse' -Threshold $ThresholdPercent -CachedState $state -Errors @('Blocked Codex usage did not include a usable fiveHourResetAt value.') -ThreadIdValue $state.threadId -SessionPathValue $state.sessionPath -StateDbPathValue $state.stateDbPath
        $unavailable.waitedSeconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalSeconds)
        $unavailable.history = @($history.ToArray())
        $unavailable | ConvertTo-Json -Depth 16
        exit 0
    }

    $resetAt = Convert-ToDateTimeOffsetOrNull -Value $state.fiveHourResetAt
    if ($null -eq $resetAt) {
        $unavailable = New-UnavailableState -Status 'unavailable_parse' -Threshold $ThresholdPercent -CachedState $state -Errors @('Blocked Codex usage reset time could not be parsed.') -ThreadIdValue $state.threadId -SessionPathValue $state.sessionPath -StateDbPathValue $state.stateDbPath
        $unavailable.waitedSeconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalSeconds)
        $unavailable.history = @($history.ToArray())
        $unavailable | ConvertTo-Json -Depth 16
        exit 0
    }

    $now = [DateTimeOffset]::UtcNow
    $secondsUntilReset = [int][Math]::Ceiling(($resetAt - $now).TotalSeconds)
    if ($secondsUntilReset -lt 0) { $secondsUntilReset = 0 }
    $pollInterval = if ($secondsUntilReset -le $FastWindowSeconds -and $FastPollSeconds -gt 0) { $FastPollSeconds } else { $PollSeconds }
    if ($pollInterval -lt 1) { $pollInterval = 1 }
    Start-Sleep -Seconds $pollInterval
}
