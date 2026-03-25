# claude-usage-gate.ps1 -- Probe or wait on Claude usage state for batch launch gating
param(
    [ValidateSet('probe', 'wait')][string]$Mode = 'probe',
    [int]$ThresholdPercent = 90,
    [string]$ClaudeHome = '',
    [string]$UsageCachePath = '',
    [int]$PollSeconds = 60,
    [int]$FastPollSeconds = 10,
    [int]$FastWindowSeconds = 60,
    [int]$RequestTimeoutSeconds = 15,
    [string]$CredentialsPath = '',
    [string]$UsageEndpoint = 'https://api.anthropic.com/api/oauth/usage',
    [string]$MockUsageJson = '',
    [string]$MockErrorKind = '',
    [string]$MockUsageSequencePath = ''
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

function Get-EffectiveClaudeHome {
    if ($ClaudeHome) { return $ClaudeHome }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-EffectiveUsageCachePath {
    param([string]$BaseClaudeHome)
    if ($UsageCachePath) { return $UsageCachePath }
    return (Join-Path $BaseClaudeHome 'tl-autodev-usage-cache.json')
}

function Get-EffectiveCredentialsPath {
    param([string]$BaseClaudeHome)
    if ($CredentialsPath) { return $CredentialsPath }
    return (Join-Path $BaseClaudeHome '.credentials.json')
}

function Convert-ToIsoStringOrNull {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToString('o')
    }

    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToString('o')
    }

    try {
        return ([DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('o')
    } catch {
        return $null
    }
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
        Add-UniqueError -Errors $errors -Message "Usage cache could not be read: $($_.Exception.Message)"
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

    $fetchedAt = Convert-ToIsoStringOrNull -Value $cache.fetchedAt
    $fiveHourResetAt = Convert-ToIsoStringOrNull -Value $cache.fiveHourResetAt
    $lastError = if ($cache.lastError) { [string]$cache.lastError } else { '' }

    return [ordered]@{
        exists = $true
        available = ($null -ne $cache.fiveHourUtilization)
        cachePath = $CachePath
        fetchedAt = $fetchedAt
        fiveHourUtilization = Normalize-Percent -Value $cache.fiveHourUtilization
        fiveHourResetAt = $fiveHourResetAt
        sevenDayUtilization = Normalize-Percent -Value $cache.sevenDayUtilization
        lastError = $lastError
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
        source = 'oauth'
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

function Get-MockUsageFromSequence {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Mock usage sequence was not found: $Path" }

    $raw = Get-Content -LiteralPath $Path -Raw
    $parsed = $raw | ConvertFrom-Json
    if ($parsed -is [System.Array]) {
        $items = @($parsed)
    } else {
        $items = @($parsed)
    }

    if ($items.Count -eq 0) {
        throw 'Mock usage sequence is empty.'
    }

    $current = $items[0]
    $remaining = if ($items.Count -gt 1) { @($items | Select-Object -Skip 1) } else { @($current) }
    [System.IO.File]::WriteAllText($Path, ($remaining | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)
    return $current
}

function Get-ErrorCategory {
    param($Exception)

    if ($null -eq $Exception) { return 'unavailable_timeout' }

    $message = [string]$Exception.Message
    if ($message -match '(?i)timed?\s*out|timeout|operationtimedout|taskcanceled|request canceled') {
        return 'unavailable_timeout'
    }

    if ($Exception.PSObject.Properties.Name -contains 'Response') {
        $response = $Exception.Response
        if ($response -and $response.StatusCode) {
            $statusCode = [int]$response.StatusCode
            if ($statusCode -eq 401 -or $statusCode -eq 403) { return 'unavailable_auth' }
            if ($statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500) { return 'unavailable_timeout' }
            return 'unavailable_parse'
        }
    }

    if ($message -match '(?i)401|403|unauthorized|forbidden|authentication|access token|bearer') {
        return 'unavailable_auth'
    }

    return 'unavailable_parse'
}

function New-UnavailableState {
    param(
        [string]$Status,
        [int]$Threshold,
        [string]$CachePath,
        $LastSuccessfulFetchAt,
        [string]$Message,
        [object[]]$AdditionalErrors = @(),
        $CachedState = $null
    )

    $errors = New-OrderedList
    foreach ($errorText in @($AdditionalErrors)) {
        Add-UniqueError -Errors $errors -Message ([string]$errorText)
    }
    if ($Message) {
        Add-UniqueError -Errors $errors -Message $Message
    }

    return [ordered]@{
        ok = $false
        processStatus = $Status
        checkedAt = (Get-Date).ToString('o')
        thresholdPercent = $Threshold
        fiveHourUtilization = if ($CachedState) { $CachedState.fiveHourUtilization } else { $null }
        fiveHourResetAt = if ($CachedState) { $CachedState.fiveHourResetAt } else { $null }
        sevenDayUtilization = if ($CachedState) { $CachedState.sevenDayUtilization } else { $null }
        shouldBlock = $false
        source = 'none'
        fresh = $false
        cachePath = $CachePath
        lastSuccessfulFetchAt = $LastSuccessfulFetchAt
        errors = @($errors)
    }
}

function Get-UsageResponse {
    param(
        [string]$BaseClaudeHome,
        [string]$CachePath
    )

    $cachedState = Get-UsageCacheState -CachePath $CachePath
    $lastSuccessfulFetchAt = if ($cachedState.available) { $cachedState.fetchedAt } else { $null }

    if ($MockErrorKind) {
        $status = switch ($MockErrorKind.ToLowerInvariant()) {
            'timeout' { 'unavailable_timeout' }
            'auth' { 'unavailable_auth' }
            'parse' { 'unavailable_parse' }
            default { 'fatal' }
        }
        return (New-UnavailableState -Status $status -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message "Mock error requested: $MockErrorKind" -AdditionalErrors $cachedState.errors -CachedState $cachedState)
    }

    if ($MockUsageSequencePath) {
        try {
            $usage = Get-MockUsageFromSequence -Path $MockUsageSequencePath
        } catch {
            return (New-UnavailableState -Status 'unavailable_parse' -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message $_.Exception.Message -AdditionalErrors $cachedState.errors -CachedState $cachedState)
        }
    } elseif ($MockUsageJson) {
        try {
            $usage = $MockUsageJson | ConvertFrom-Json
        } catch {
            return (New-UnavailableState -Status 'unavailable_parse' -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message "Mock usage JSON could not be parsed: $($_.Exception.Message)" -AdditionalErrors $cachedState.errors -CachedState $cachedState)
        }
    } else {
        $effectiveCredentialsPath = Get-EffectiveCredentialsPath -BaseClaudeHome $BaseClaudeHome
        if (-not (Test-Path -LiteralPath $effectiveCredentialsPath)) {
            return (New-UnavailableState -Status 'unavailable_auth' -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message "Claude credentials were not found: $effectiveCredentialsPath" -AdditionalErrors $cachedState.errors -CachedState $cachedState)
        }

        try {
            $credentials = Get-Content -LiteralPath $effectiveCredentialsPath -Raw | ConvertFrom-Json
        } catch {
            return (New-UnavailableState -Status 'unavailable_parse' -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message "Claude credentials could not be read: $($_.Exception.Message)" -AdditionalErrors $cachedState.errors -CachedState $cachedState)
        }

        $token = ''
        if ($credentials.claudeAiOauth -and $credentials.claudeAiOauth.accessToken) {
            $token = [string]$credentials.claudeAiOauth.accessToken
        }
        if (-not $token) {
            return (New-UnavailableState -Status 'unavailable_auth' -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message 'Claude OAuth access token is missing.' -AdditionalErrors $cachedState.errors -CachedState $cachedState)
        }

        $headers = @{
            Authorization = "Bearer $token"
            Accept = 'application/json'
            'anthropic-beta' = 'oauth-2025-04-20'
        }

        try {
            $usage = Invoke-RestMethod -Uri $UsageEndpoint -Headers $headers -Method Get -TimeoutSec $RequestTimeoutSeconds
        } catch {
            $status = Get-ErrorCategory -Exception $_.Exception
            return (New-UnavailableState -Status $status -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message "Usage request failed: $($_.Exception.Message)" -AdditionalErrors $cachedState.errors -CachedState $cachedState)
        }
    }

    $fiveHourUtilization = Normalize-Percent -Value $usage.five_hour.utilization
    $fiveHourResetAt = Convert-ToIsoStringOrNull -Value $usage.five_hour.resets_at
    $sevenDayUtilization = Normalize-Percent -Value $usage.seven_day.utilization

    if ($null -eq $fiveHourUtilization) {
        return (New-UnavailableState -Status 'unavailable_parse' -Threshold $ThresholdPercent -CachePath $CachePath -LastSuccessfulFetchAt $lastSuccessfulFetchAt -Message 'Usage response did not include a valid five_hour.utilization value.' -AdditionalErrors $cachedState.errors -CachedState $cachedState)
    }

    $checkedAt = (Get-Date).ToString('o')
    $shouldBlock = ($fiveHourUtilization -ge $ThresholdPercent)
    $processStatus = if ($shouldBlock) { 'blocked' } else { 'ok' }

    $state = [ordered]@{
        ok = $true
        processStatus = $processStatus
        checkedAt = $checkedAt
        thresholdPercent = $ThresholdPercent
        fiveHourUtilization = $fiveHourUtilization
        fiveHourResetAt = $fiveHourResetAt
        sevenDayUtilization = $sevenDayUtilization
        shouldBlock = $shouldBlock
        source = 'oauth'
        fresh = $true
        cachePath = $CachePath
        lastSuccessfulFetchAt = $checkedAt
        errors = @()
    }

    Save-UsageCache -CachePath $CachePath -State $state
    return $state
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

    $coarseSleep = $remaining - $FastWindowSeconds
    $maxSleepSeconds = 2147483
    if ($coarseSleep -gt $maxSleepSeconds) { return $maxSleepSeconds }
    return [Math]::Max(1, [int]$coarseSleep)
}

function Write-JsonResult {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Output $json
}

try {
    $baseClaudeHome = Get-EffectiveClaudeHome
    $effectiveCachePath = Get-EffectiveUsageCachePath -BaseClaudeHome $baseClaudeHome

    if ($Mode -eq 'probe') {
        $probeResult = Get-UsageResponse -BaseClaudeHome $baseClaudeHome -CachePath $effectiveCachePath
        Write-JsonResult -Object $probeResult
        exit 0
    }

    $history = New-OrderedList
    $waitedSeconds = 0
    while ($true) {
        $state = Get-UsageResponse -BaseClaudeHome $baseClaudeHome -CachePath $effectiveCachePath
        [void]$history.Add([ordered]@{
            checkedAt = $state.checkedAt
            processStatus = $state.processStatus
            fiveHourUtilization = $state.fiveHourUtilization
            fiveHourResetAt = $state.fiveHourResetAt
            shouldBlock = $state.shouldBlock
            fresh = $state.fresh
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

        if (-not $state.fiveHourResetAt) {
            $state.ok = $false
            $state.processStatus = 'unavailable_parse'
            $state.fresh = $false
            $state.source = 'none'
            $state.lastSuccessfulFetchAt = $state.checkedAt
            $state.errors = @('Blocked usage did not include a usable fiveHourResetAt value.')
            $state.mode = $Mode
            $state.waitedSeconds = $waitedSeconds
            $state.history = @($history)
            Write-JsonResult -Object $state
            exit 0
        }

        $resetAt = Convert-ToDateTimeOffsetOrNull -Value $state.fiveHourResetAt
        if ($null -eq $resetAt) {
            $state.ok = $false
            $state.processStatus = 'unavailable_parse'
            $state.fresh = $false
            $state.source = 'none'
            $state.lastSuccessfulFetchAt = $state.checkedAt
            $state.errors = @('Blocked usage reset time could not be parsed.')
            $state.mode = $Mode
            $state.waitedSeconds = $waitedSeconds
            $state.history = @($history)
            Write-JsonResult -Object $state
            exit 0
        }

        $sleepSeconds = Get-WaitSeconds -ResetAt $resetAt
        Start-Sleep -Seconds $sleepSeconds
        $waitedSeconds += $sleepSeconds
    }
} catch {
    $fatalResult = [ordered]@{
        ok = $false
        processStatus = 'fatal'
        checkedAt = (Get-Date).ToString('o')
        thresholdPercent = $ThresholdPercent
        fiveHourUtilization = $null
        fiveHourResetAt = $null
        sevenDayUtilization = $null
        shouldBlock = $false
        source = 'none'
        fresh = $false
        cachePath = Get-EffectiveUsageCachePath -BaseClaudeHome (Get-EffectiveClaudeHome)
        lastSuccessfulFetchAt = $null
        errors = @($_.Exception.Message)
        mode = $Mode
        waitedSeconds = 0
        history = @()
    }
    Write-JsonResult -Object $fatalResult
    exit 0
}
