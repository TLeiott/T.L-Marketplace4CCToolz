# scheduler.ps1 -- Repo-scoped queue scheduler for AutoDevelop v4
param(
    [Parameter(Mandatory)][ValidateSet("snapshot-queue", "register-tasks", "apply-plan", "run-task", "wait-queue", "prepare-merge", "resolve-merge", "admin-edit-task", "admin-clear-breaker", "prepare-environment")][string]$Mode,
    [string]$SolutionPath = "",
    [string]$TasksFile = "",
    [string]$PlanFile = "",
    [string]$EditFile = "",
    [string]$TaskId = "",
    [string]$Decision = "",
    [string]$CommitMessage = "",
    [int]$WaitTimeoutSeconds = 7200,
    [int]$IdlePollSeconds = 2,
    [bool]$WakeOnAnyCompletion = $true,
    [bool]$WakeOnMergeReady = $true,
    [bool]$WakeOnBreakerOpen = $true
)

$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    $resolvedCommand = Resolve-NativeCommandName -Command $Command

    $output = if ($WorkingDirectory) {
        & {
            $ErrorActionPreference = "Continue"
            Push-Location $WorkingDirectory
            try {
                & $resolvedCommand @Arguments 2>&1
            } finally {
                Pop-Location
            }
        }
    } else {
        & {
            $ErrorActionPreference = "Continue"
            & $resolvedCommand @Arguments 2>&1
        }
    }

    return [pscustomobject]@{
        output = ($output | Out-String).Trim()
        exitCode = $LASTEXITCODE
    }
}

function Resolve-NativeCommandName {
    param([string]$Command)

    switch ($Command.ToLowerInvariant()) {
        "git" {
            if ($env:AUTODEV_GIT_COMMAND) { return $env:AUTODEV_GIT_COMMAND }
            break
        }
        "dotnet" {
            if ($env:AUTODEV_DOTNET_COMMAND) { return $env:AUTODEV_DOTNET_COMMAND }
            break
        }
        "taskkill" {
            if ($env:AUTODEV_TASKKILL_COMMAND) { return $env:AUTODEV_TASKKILL_COMMAND }
            break
        }
    }

    return $Command
}

function Write-JsonOutput {
    param($Object)
    $Object | ConvertTo-Json -Depth 32
}

function Ensure-Directory {
    param([string]$Path)
    if ($Path -and -not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-ParentDirectory {
    param([string]$Path)
    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        Ensure-Directory -Path $parent
    }
}

function Get-CanonicalPath {
    param([string]$Path)
    if (-not $Path) { return "" }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    } catch {
        $fullPath = $Path
    }

    try {
        return (Get-Item -LiteralPath $fullPath -ErrorAction Stop).FullName
    } catch {
        return $fullPath
    }
}

function Get-CanonicalRepoRoot {
    param([string]$ResolvedSolutionPath)
    if (-not $ResolvedSolutionPath) {
        throw "A solution path is required to resolve the repository root."
    }

    $solutionDir = Split-Path -Path $ResolvedSolutionPath -Parent
    $result = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "--show-toplevel") -WorkingDirectory $solutionDir
    if ($result.exitCode -ne 0 -or -not $result.output) {
        throw "Could not resolve the git repository root for solution '$ResolvedSolutionPath'."
    }

    return (Get-CanonicalPath -Path $result.output)
}

function Get-GitDirPath {
    param([string]$RepoRoot)

    $result = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "--git-dir") -WorkingDirectory $RepoRoot
    if ($result.exitCode -ne 0 -or -not $result.output) {
        throw "Could not resolve the git directory for '$RepoRoot'."
    }

    $gitDir = [string]$result.output
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
        $gitDir = Join-Path $RepoRoot $gitDir
    }

    return (Get-CanonicalPath -Path $gitDir)
}

function Get-StatePaths {
    param([string]$RepoRoot)
    $baseDir = Join-Path $RepoRoot ".claude-develop-logs\scheduler"
    return [pscustomobject]@{
        baseDir = $baseDir
        stateFile = Join-Path $baseDir "state.json"
        eventsFile = Join-Path $baseDir "events.jsonl"
        lockFile = Join-Path $baseDir "state.lock"
        tasksDir = Join-Path $baseDir "tasks"
        resultsDir = Join-Path $baseDir "results"
    }
}

function Get-AutoDevelopWorktreeBase {
    return (Join-Path $env:TEMP "claude-worktrees")
}

function New-EmptyState {
    param([string]$RepoRoot)
    return [pscustomobject]@{
        version = 4
        repoRoot = $RepoRoot
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
        lastPlanAppliedAt = ""
        circuitBreaker = (New-CircuitBreakerRecord)
        tasks = @()
    }
}

function Load-State {
    param(
        [string]$StateFile,
        [string]$RepoRoot
    )

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return (New-EmptyState -RepoRoot $RepoRoot)
    }

    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if (-not $state.tasks) {
        $state | Add-Member -NotePropertyName tasks -NotePropertyValue @() -Force
    }
    if (-not $state.repoRoot) {
        $state | Add-Member -NotePropertyName repoRoot -NotePropertyValue $RepoRoot -Force
    }
    if (-not $state.version) {
        $state | Add-Member -NotePropertyName version -NotePropertyValue 4 -Force
    }
    if (-not $state.lastPlanAppliedAt) {
        $state | Add-Member -NotePropertyName lastPlanAppliedAt -NotePropertyValue "" -Force
    }
    if (-not $state.circuitBreaker) {
        $state | Add-Member -NotePropertyName circuitBreaker -NotePropertyValue (New-CircuitBreakerRecord) -Force
    } else {
        $breaker = New-CircuitBreakerRecord
        foreach ($property in @("status", "openedAt", "closedAt", "scopeWave", "reasonCategory", "reasonSummary", "affectedTaskIds", "manualOverrideUntil")) {
            if ($null -ne $state.circuitBreaker.$property) {
                Set-ObjectProperty -Object $breaker -Name $property -Value $state.circuitBreaker.$property
            }
        }
        Set-ObjectProperty -Object $breaker -Name "affectedTaskIds" -Value @(Normalize-StringArray -Value $breaker.affectedTaskIds)
        $state | Add-Member -NotePropertyName circuitBreaker -NotePropertyValue $breaker -Force
    }
    foreach ($task in @(Get-Tasks -State $state)) {
        Ensure-TaskShape -Task $task -RepoRoot $state.repoRoot
    }
    return $state
}

function Save-State {
    param(
        [string]$StateFile,
        $State
    )

    $State.updatedAt = (Get-Date).ToString("o")
    Ensure-ParentDirectory -Path $StateFile
    [System.IO.File]::WriteAllText($StateFile, ($State | ConvertTo-Json -Depth 32), [System.Text.Encoding]::UTF8)
}

function Append-StateEvent {
    param(
        [string]$EventsFile,
        [string]$TaskId,
        [string]$Kind,
        [string]$Message,
        $Data
    )

    Ensure-ParentDirectory -Path $EventsFile
    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        taskId = $TaskId
        kind = $Kind
        message = $Message
        data = $Data
    } | ConvertTo-Json -Depth 20 -Compress
    Add-Content -LiteralPath $EventsFile -Value $entry -Encoding UTF8
}

function Acquire-Lock {
    param(
        [string]$LockFile,
        [int]$TimeoutSeconds = 120
    )

    Ensure-ParentDirectory -Path $LockFile
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return [System.IO.File]::Open($LockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }

    throw "Could not acquire the scheduler lock."
}

function Release-Lock {
    param($LockHandle)
    if ($LockHandle) {
        $LockHandle.Dispose()
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw
    if (-not $content.Trim()) {
        return $null
    }
    return ($content | ConvertFrom-Json)
}

function Read-JsonFileBestEffort {
    param(
        [string]$Path,
        [int]$RetryCount = 2,
        [int]$RetryDelayMilliseconds = 100
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if (-not $content.Trim()) {
                return $null
            }
            return ($content | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            if ($attempt -ge $RetryCount) {
                return $null
            }
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }

    return $null
}

function Read-JsonLinesFile {
    param(
        [string]$Path,
        [int]$MaxEntries = 0
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $lines = @(
        Get-Content -LiteralPath $Path |
            Where-Object { $_ -and $_.Trim() }
    )
    if ($MaxEntries -gt 0 -and $lines.Count -gt $MaxEntries) {
        $lines = @($lines | Select-Object -Last $MaxEntries)
    }

    $items = [System.Collections.ArrayList]::new()
    foreach ($line in $lines) {
        try {
            [void]$items.Add(($line | ConvertFrom-Json))
        } catch {
        }
    }

    return @($items)
}

function Set-ObjectProperty {
    param(
        $Object,
        [string]$Name,
        $Value
    )

    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-TaskById {
    param(
        $State,
        [string]$TaskId
    )

    return @($State.tasks | Where-Object { $_.taskId -eq $TaskId } | Select-Object -First 1)[0]
}

function Get-Tasks {
    param($State)
    return @($State.tasks | Where-Object { $_ })
}

function Get-TaskMode {
    param([string]$SourceCommand)
    if ($SourceCommand -eq "TLA-develop") { return "autonomous" }
    return "interactive"
}

function Get-TaskPrefix {
    param([string]$SourceCommand)
    if ($SourceCommand -eq "TLA-develop") { return "tla" }
    return "develop"
}

function Get-ShortTaskLabel {
    param([string]$TaskId)
    if (-not $TaskId) { return "task" }
    $clean = ($TaskId -replace "[^A-Za-z0-9]", "").ToLowerInvariant()
    if (-not $clean) { return "task" }
    if ($clean.Length -gt 6) { return $clean.Substring(0, 6) }
    return $clean
}

function Get-TaskIdentityToken {
    param([string]$TaskId)

    $label = Get-ShortTaskLabel -TaskId $TaskId
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$TaskId)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hashText = [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant().Substring(0, 10)
    return "$label-$hashText"
}

function Get-AttemptTaskName {
    param(
        [string]$TaskId,
        [string]$SourceCommand,
        [int]$LaunchSequence
    )

    $prefix = Get-TaskPrefix -SourceCommand $SourceCommand
    return "$prefix-$(Get-TaskIdentityToken -TaskId $TaskId)-a$LaunchSequence"
}

function Is-TerminalState {
    param([string]$State)
    return $State -in @(
        "merged",
        "completed_no_change",
        "completed_failed_terminal",
        "discarded"
    )
}

function Is-QueueState {
    param([string]$State)
    return $State -in @("queued", "retry_scheduled")
}

function Is-ManualDebugState {
    param([string]$State)
    return $State -eq "manual_debug_needed"
}

function Is-MergeRetryState {
    param([string]$State)
    return $State -eq "merge_retry_scheduled"
}

function Is-RunningState {
    param([string]$State)
    return $State -eq "running"
}

function Is-PendingMergeState {
    param([string]$State)
    return $State -in @("pending_merge", "merge_prepared", "waiting_user_test")
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    if (-not $ProcessId -or $ProcessId -le 0) { return $false }
    try {
        Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-DefaultTaskResultPath {
    param(
        [string]$RepoRoot,
        [string]$TaskId
    )

    $paths = Get-StatePaths -RepoRoot $RepoRoot
    Ensure-Directory -Path $paths.resultsDir
    return (Join-Path $paths.resultsDir "$TaskId.json")
}

function New-LatestRunRecord {
    param(
        [int]$AttemptNumber = 0,
        [int]$LaunchSequence = 0,
        [string]$TaskName = "",
        [string]$ResultFile = "",
        [int]$ProcessId = 0,
        [string]$StartedAt = "",
        [string]$CompletedAt = ""
    )

    return [pscustomobject]@{
        attemptNumber = $AttemptNumber
        launchSequence = $LaunchSequence
        taskName = $TaskName
        resultFile = $ResultFile
        processId = $ProcessId
        startedAt = $StartedAt
        completedAt = $CompletedAt
        finalStatus = ""
        finalCategory = ""
        summary = ""
        feedback = ""
        noChangeReason = ""
        investigationConclusion = ""
        reproductionConfirmed = $false
        actualFiles = @()
        branchName = ""
        artifacts = $null
        runDir = ""
        schedulerSnapshotPath = ""
        timelinePath = ""
        workerStdoutPath = ""
        workerStderrPath = ""
    }
}

function Get-EnvironmentFailureCategories {
    return @(
        "WORKTREE_ERROR",
        "WORKTREE_INVALID",
        "SOLUTION_PATH_MISSING",
        "WORKTREE_ENVIRONMENT_ERROR",
        "WORKER_START_FAILED",
        "WORKER_EXITED_WITHOUT_RESULT"
    )
}

function Is-EnvironmentFailureCategory {
    param([string]$Category)
    return (Get-EnvironmentFailureCategories) -contains ([string]$Category)
}

function New-MergeRecord {
    return [pscustomobject]@{
        state = ""
        preparedAt = ""
        commitMessage = ""
        commitSha = ""
        reason = ""
        branchName = ""
    }
}

function New-CircuitBreakerRecord {
    return [pscustomobject]@{
        status = "closed"
        openedAt = ""
        closedAt = ""
        scopeWave = 0
        reasonCategory = ""
        reasonSummary = ""
        affectedTaskIds = @()
        manualOverrideUntil = ""
    }
}

$script:CircuitBreakerRecentWindowMinutes = 30

function Normalize-Priority {
    param([string]$Priority)

    switch (($Priority | ForEach-Object { [string]$_ }).Trim().ToLowerInvariant()) {
        "high" { return "high" }
        "low" { return "low" }
        default { return "normal" }
    }
}

function Normalize-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = if ($Value -is [string]) {
        @($Value)
    } elseif ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [pscustomobject])) {
        @($Value)
    } else {
        @($Value)
    }

    return @(
        $items |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Normalize-LatestRun {
    param(
        $LatestRun,
        [string]$ResultFile = ""
    )

    $normalized = New-LatestRunRecord -ResultFile $ResultFile
    if ($LatestRun) {
        foreach ($property in @(
            "attemptNumber",
            "launchSequence",
            "taskName",
            "resultFile",
            "processId",
            "startedAt",
            "completedAt",
            "finalStatus",
            "finalCategory",
            "summary",
            "feedback",
            "noChangeReason",
            "investigationConclusion",
            "reproductionConfirmed",
            "branchName",
            "artifacts",
            "runDir",
            "schedulerSnapshotPath",
            "timelinePath",
            "workerStdoutPath",
            "workerStderrPath"
        )) {
            if ($null -ne $LatestRun.$property) {
                Set-ObjectProperty -Object $normalized -Name $property -Value $LatestRun.$property
            }
        }
        Set-ObjectProperty -Object $normalized -Name "actualFiles" -Value (Normalize-StringArray -Value $LatestRun.actualFiles)
    }
    if ($ResultFile -and -not $normalized.resultFile) {
        Set-ObjectProperty -Object $normalized -Name "resultFile" -Value $ResultFile
    }
    return $normalized
}

function Normalize-RunRecords {
    param($Runs)

    $normalizedRuns = @()
    foreach ($run in @($Runs)) {
        if (-not $run) { continue }
        $normalizedRuns += [pscustomobject]@{
            attemptNumber = if ($null -ne $run.attemptNumber) { [int]$run.attemptNumber } else { 0 }
            launchSequence = if ($null -ne $run.launchSequence) { [int]$run.launchSequence } else { 0 }
            taskName = [string]$run.taskName
            finalStatus = [string]$run.finalStatus
            finalCategory = [string]$run.finalCategory
            summary = [string]$run.summary
            feedback = [string]$run.feedback
            noChangeReason = [string]$run.noChangeReason
            investigationConclusion = [string]$run.investigationConclusion
            reproductionConfirmed = [bool]$run.reproductionConfirmed
            actualFiles = @(Normalize-StringArray -Value $run.actualFiles)
            branchName = [string]$run.branchName
            resultFile = [string]$run.resultFile
            completedAt = [string]$run.completedAt
            artifacts = $run.artifacts
        }
    }
    return @($normalizedRuns)
}

function Normalize-TaskRecord {
    param(
        $Task,
        [string]$RepoRoot
    )

    if (-not $Task) { return }

    if (-not $Task.resultFile) {
        Set-ObjectProperty -Object $Task -Name "resultFile" -Value (Get-DefaultTaskResultPath -RepoRoot $RepoRoot -TaskId $Task.taskId)
    }
    if (-not $Task.taskToken) {
        Set-ObjectProperty -Object $Task -Name "taskToken" -Value (Get-TaskIdentityToken -TaskId ([string]$Task.taskId))
    }
    Set-ObjectProperty -Object $Task -Name "promptFile" -Value ([string]$Task.promptFile).Trim()
    Set-ObjectProperty -Object $Task -Name "taskText" -Value ([string]$Task.taskText).Trim()

    Set-ObjectProperty -Object $Task -Name "blockedBy" -Value @(Normalize-StringArray -Value $Task.blockedBy)
    Set-ObjectProperty -Object $Task -Name "runs" -Value @(Normalize-RunRecords -Runs $Task.runs)
    if (-not $Task.plannerMetadata) {
        Set-ObjectProperty -Object $Task -Name "plannerMetadata" -Value ([pscustomobject]@{})
    }
    if (-not $Task.plannerFeedback) {
        Set-ObjectProperty -Object $Task -Name "plannerFeedback" -Value ([pscustomobject]@{})
    }
    Set-ObjectProperty -Object $Task -Name "declaredDependencies" -Value @(Normalize-StringArray -Value $Task.declaredDependencies)
    Set-ObjectProperty -Object $Task -Name "declaredPriority" -Value (Normalize-Priority -Priority ([string]$Task.declaredPriority))
    if ($null -eq $Task.serialOnly) {
        Set-ObjectProperty -Object $Task -Name "serialOnly" -Value $false
    }
    if ($null -eq $Task.usageCostClass) {
        Set-ObjectProperty -Object $Task -Name "usageCostClass" -Value "MEDIUM"
    }
    if ($null -eq $Task.usageEstimateMinutes) {
        Set-ObjectProperty -Object $Task -Name "usageEstimateMinutes" -Value 20
    }
    if ($null -eq $Task.usageEstimateSource) {
        Set-ObjectProperty -Object $Task -Name "usageEstimateSource" -Value "heuristic"
    }
    if ($null -eq $Task.maxMergeAttempts) {
        Set-ObjectProperty -Object $Task -Name "maxMergeAttempts" -Value 3
    }
    if ($null -eq $Task.workerLaunchSequence) {
        Set-ObjectProperty -Object $Task -Name "workerLaunchSequence" -Value 0
    }
    if ($null -eq $Task.maxEnvironmentRepairAttempts) {
        Set-ObjectProperty -Object $Task -Name "maxEnvironmentRepairAttempts" -Value 2
    }
    if ($null -eq $Task.mergeAttemptsUsed) {
        Set-ObjectProperty -Object $Task -Name "mergeAttemptsUsed" -Value 0
    }
    if ($null -eq $Task.environmentRepairAttemptsUsed) {
        Set-ObjectProperty -Object $Task -Name "environmentRepairAttemptsUsed" -Value 0
    }
    if ($null -eq $Task.mergeAttemptsRemaining) {
        Set-ObjectProperty -Object $Task -Name "mergeAttemptsRemaining" -Value ([Math]::Max(0, [int]$Task.maxMergeAttempts - [int]$Task.mergeAttemptsUsed))
    }
    if ($null -eq $Task.environmentRepairAttemptsRemaining) {
        Set-ObjectProperty -Object $Task -Name "environmentRepairAttemptsRemaining" -Value ([Math]::Max(0, [int]$Task.maxEnvironmentRepairAttempts - [int]$Task.environmentRepairAttemptsUsed))
    }
    if ($null -eq $Task.lastEnvironmentFailureCategory) {
        Set-ObjectProperty -Object $Task -Name "lastEnvironmentFailureCategory" -Value ""
    }
    if ($null -eq $Task.manualDebugReason) {
        Set-ObjectProperty -Object $Task -Name "manualDebugReason" -Value ""
    }
    Set-ObjectProperty -Object $Task -Name "latestRun" -Value (Normalize-LatestRun -LatestRun $Task.latestRun -ResultFile ([string]$Task.resultFile))
    if (-not $Task.merge) {
        Set-ObjectProperty -Object $Task -Name "merge" -Value (New-MergeRecord)
    } else {
        $merge = New-MergeRecord
        foreach ($property in @("state", "preparedAt", "commitMessage", "commitSha", "reason", "branchName")) {
            if ($null -ne $Task.merge.$property) {
                Set-ObjectProperty -Object $merge -Name $property -Value $Task.merge.$property
            }
        }
        Set-ObjectProperty -Object $Task -Name "merge" -Value $merge
    }
}

function Ensure-TaskShape {
    param(
        $Task,
        [string]$RepoRoot
    )

    if (-not $Task.maxAttempts) { $Task | Add-Member -NotePropertyName maxAttempts -NotePropertyValue 3 -Force }
    if ($null -eq $Task.attemptsUsed) { $Task | Add-Member -NotePropertyName attemptsUsed -NotePropertyValue 0 -Force }
    if ($null -eq $Task.attemptsRemaining) { $Task | Add-Member -NotePropertyName attemptsRemaining -NotePropertyValue ([Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)) -Force }
    if ($null -eq $Task.retryScheduled) { $Task | Add-Member -NotePropertyName retryScheduled -NotePropertyValue $false -Force }
    if ($null -eq $Task.waitingUserTest) { $Task | Add-Member -NotePropertyName waitingUserTest -NotePropertyValue $false -Force }
    if ($null -eq $Task.maxMergeAttempts) { $Task | Add-Member -NotePropertyName maxMergeAttempts -NotePropertyValue 3 -Force }
    if ($null -eq $Task.workerLaunchSequence) { $Task | Add-Member -NotePropertyName workerLaunchSequence -NotePropertyValue 0 -Force }
    if ($null -eq $Task.maxEnvironmentRepairAttempts) { $Task | Add-Member -NotePropertyName maxEnvironmentRepairAttempts -NotePropertyValue 2 -Force }
    if ($null -eq $Task.mergeAttemptsUsed) { $Task | Add-Member -NotePropertyName mergeAttemptsUsed -NotePropertyValue 0 -Force }
    if ($null -eq $Task.environmentRepairAttemptsUsed) { $Task | Add-Member -NotePropertyName environmentRepairAttemptsUsed -NotePropertyValue 0 -Force }
    if ($null -eq $Task.mergeAttemptsRemaining) { $Task | Add-Member -NotePropertyName mergeAttemptsRemaining -NotePropertyValue 3 -Force }
    if ($null -eq $Task.environmentRepairAttemptsRemaining) { $Task | Add-Member -NotePropertyName environmentRepairAttemptsRemaining -NotePropertyValue 2 -Force }
    if ($null -eq $Task.lastEnvironmentFailureCategory) { $Task | Add-Member -NotePropertyName lastEnvironmentFailureCategory -NotePropertyValue "" -Force }
    if ($null -eq $Task.manualDebugReason) { $Task | Add-Member -NotePropertyName manualDebugReason -NotePropertyValue "" -Force }
    if ($null -eq $Task.blockedBy) { $Task | Add-Member -NotePropertyName blockedBy -NotePropertyValue @() -Force }
    if ($null -eq $Task.declaredDependencies) { $Task | Add-Member -NotePropertyName declaredDependencies -NotePropertyValue @() -Force }
    if ($null -eq $Task.declaredPriority) { $Task | Add-Member -NotePropertyName declaredPriority -NotePropertyValue "normal" -Force }
    if ($null -eq $Task.serialOnly) { $Task | Add-Member -NotePropertyName serialOnly -NotePropertyValue $false -Force }
    if ($null -eq $Task.usageCostClass) { $Task | Add-Member -NotePropertyName usageCostClass -NotePropertyValue "MEDIUM" -Force }
    if ($null -eq $Task.usageEstimateMinutes) { $Task | Add-Member -NotePropertyName usageEstimateMinutes -NotePropertyValue 20 -Force }
    if ($null -eq $Task.usageEstimateSource) { $Task | Add-Member -NotePropertyName usageEstimateSource -NotePropertyValue "heuristic" -Force }
    if ($null -eq $Task.runs) { $Task | Add-Member -NotePropertyName runs -NotePropertyValue @() -Force }
    if (-not $Task.plannerMetadata) { $Task | Add-Member -NotePropertyName plannerMetadata -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $Task.plannerFeedback) { $Task | Add-Member -NotePropertyName plannerFeedback -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $Task.taskToken) { $Task | Add-Member -NotePropertyName taskToken -NotePropertyValue (Get-TaskIdentityToken -TaskId ([string]$Task.taskId)) -Force }
    if ($null -eq $Task.latestRun) { $Task | Add-Member -NotePropertyName latestRun -NotePropertyValue (New-LatestRunRecord) -Force }
    if (-not $Task.merge) {
        $Task | Add-Member -NotePropertyName merge -NotePropertyValue (New-MergeRecord) -Force
    }
    if (-not $Task.resultFile) {
        $Task | Add-Member -NotePropertyName resultFile -NotePropertyValue (Get-DefaultTaskResultPath -RepoRoot $RepoRoot -TaskId $Task.taskId) -Force
    }
    if (-not $Task.state) {
        $Task | Add-Member -NotePropertyName state -NotePropertyValue "queued" -Force
    }
    if (-not $Task.mergeState) {
        $Task | Add-Member -NotePropertyName mergeState -NotePropertyValue "" -Force
    }
    Normalize-TaskRecord -Task $Task -RepoRoot $RepoRoot
}

function Get-TaskSummaryText {
    param($Task)
    if ($Task.latestRun.summary) { return [string]$Task.latestRun.summary }
    if ($Task.taskText) { return [string]$Task.taskText }
    return ""
}

function Get-TaskArtifactPointers {
    param(
        [string]$RepoRoot,
        $Task
    )

    $taskName = [string]$Task.latestRun.taskName
    $runDir = if ($Task.latestRun.runDir) {
        [string]$Task.latestRun.runDir
    } elseif ($RepoRoot -and $taskName) {
        Join-Path (Join-Path $RepoRoot ".claude-develop-logs\runs") $taskName
    } else {
        ""
    }

    $schedulerSnapshotPath = if ($Task.latestRun.schedulerSnapshotPath) {
        [string]$Task.latestRun.schedulerSnapshotPath
    } elseif ($runDir) {
        Join-Path $runDir "scheduler-snapshot.json"
    } else {
        ""
    }

    $timelinePath = if ($Task.latestRun.timelinePath) {
        [string]$Task.latestRun.timelinePath
    } elseif ($runDir) {
        Join-Path $runDir "timeline.json"
    } else {
        ""
    }

    $workerStdoutPath = if ($Task.latestRun.workerStdoutPath) {
        [string]$Task.latestRun.workerStdoutPath
    } elseif ($Task.latestRun.artifacts -and $Task.latestRun.artifacts.workerStdout) {
        [string]$Task.latestRun.artifacts.workerStdout
    } else {
        ""
    }

    $workerStderrPath = if ($Task.latestRun.workerStderrPath) {
        [string]$Task.latestRun.workerStderrPath
    } elseif ($Task.latestRun.artifacts -and $Task.latestRun.artifacts.workerStderr) {
        [string]$Task.latestRun.artifacts.workerStderr
    } else {
        ""
    }

    return [pscustomobject]@{
        runDir = $runDir
        schedulerSnapshotPath = $schedulerSnapshotPath
        timelinePath = $timelinePath
        resultFile = [string]$Task.latestRun.resultFile
        workerStdoutPath = $workerStdoutPath
        workerStderrPath = $workerStderrPath
    }
}

function Get-TaskEnvironmentFailureDetail {
    param(
        $Task,
        $RecentTimelineEvent = $null
    )

    $summary = [string]$Task.latestRun.summary
    $feedback = [string]$Task.latestRun.feedback
    $category = [string]$Task.lastEnvironmentFailureCategory

    if ($summary) {
        $detail = $summary.Trim()
        if ($category) {
            return "$detail (Environment failure: $category.)"
        }
        return $detail
    }

    if ($feedback) {
        $firstLine = @($feedback -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)[0]
        if ($firstLine) {
            if ($category) {
                return "$firstLine (Environment failure: $category.)"
            }
            return $firstLine
        }
    }

    if ($RecentTimelineEvent -and $RecentTimelineEvent.message) {
        $timelineDetail = ConvertTo-DisplayText -Text ([string]$RecentTimelineEvent.message)
        if ($timelineDetail) {
            if ($category) {
                return "$timelineDetail (Environment failure: $category.)"
            }
            return $timelineDetail
        }
    }

    if ($category) {
        return "Last environment failure: $category."
    }

    return ""
}

function Get-RecentTimelineEvent {
    param([string]$TimelinePath)

    $timeline = Read-JsonFileBestEffort -Path $TimelinePath
    if (-not $timeline) { return $null }
    $items = @($timeline)
    if ($items.Count -eq 0) { return $null }
    return $items[-1]
}

function ConvertTo-DisplayText {
    param([string]$Text)
    if (-not $Text) { return "" }

    $value = $Text.Trim()
    $replacements = [ordered]@{
        "Prompt eingelesen und Task klassifiziert." = "Task prompt loaded and classified."
        "Codebase-Kontext erfasst." = "Codebase context captured."
        "Testprojekt-Inventar erfasst." = "Test project inventory captured."
        "Discover routing determined." = "Discovery routing finished."
        "Investigation was salvaged from actionable evidence." = "Investigation recovered from actionable evidence."
        "Bug reproduction confirmed through tests." = "Bug reproduction confirmed through tests."
        "No reliable test reproduction was confirmed." = "No reliable automated reproduction was confirmed."
        "Fix-Plan akzeptiert." = "Fix plan accepted."
        "Fix-Plan wurde verworfen." = "Fix plan rejected."
        "Fix-Plan nach Repair akzeptiert." = "Fix plan accepted after repair."
        "Fix-Plan via Salvage fortgesetzt." = "Fix plan continued from salvage."
        "No files were changed." = "No files were changed."
        "Repair implementation changed files." = "Repair implementation changed files."
        "Preflight failed." = "Preflight failed."
        "Review infrastructure failure during invocation." = "Review infrastructure failed during invocation."
        "Review infrastructure failure in the response." = "Review infrastructure failed in the response."
        "Task pipeline started." = "Task pipeline started."
        "Task pipeline finished." = "Task pipeline finished."
        "Merge prepared successfully." = "Merge prepared successfully."
        "Merge preparation failed." = "Merge preparation failed."
    }
    foreach ($entry in $replacements.GetEnumerator()) {
        if ($value -eq $entry.Key) {
            return [string]$entry.Value
        }
    }

    $prefixPatterns = @(
        @{ Pattern = '^(DISCOVER|PLAN|FIX_PLAN|INVESTIGATE|IMPLEMENT|REPRODUCE|REVIEW)\s+nutzt\s+'; Replacement = '$1 uses ' }
    )
    foreach ($pattern in $prefixPatterns) {
        if ($value -match $pattern.Pattern) {
            $value = [regex]::Replace($value, $pattern.Pattern, $pattern.Replacement)
            break
        }
    }

    $value = $value -replace '^Review verdict:\s*', 'Review verdict: '
    $value = $value -replace '^Erstelle\s+', 'Create '
    $value = $value -replace '^Sammle\s+', 'Collect '
    return $value
}

function Format-ElapsedLabel {
    param(
        [string]$StartedAt,
        [string]$CompletedAt = ""
    )

    if (-not $StartedAt) { return "" }
    try {
        $start = [datetime]$StartedAt
    } catch {
        return ""
    }

    $end = if ($CompletedAt) {
        try { [datetime]$CompletedAt } catch { Get-Date }
    } else {
        Get-Date
    }

    $span = $end - $start
    if ($span.TotalHours -ge 1) {
        return ("{0}h {1}m" -f [int]$span.TotalHours, $span.Minutes)
    }
    if ($span.TotalMinutes -ge 1) {
        return ("{0}m" -f [int][Math]::Max(1, [Math]::Round($span.TotalMinutes)))
    }
    return ("{0}s" -f [int][Math]::Max(1, [Math]::Round($span.TotalSeconds)))
}

function Get-PhaseDisplayLabel {
    param(
        [string]$TaskState,
        [string]$Phase
    )

    $normalized = ([string]$Phase).Trim().ToUpperInvariant()
    switch ($normalized) {
        "VALIDATE" { return "Validate" }
        "WORKTREE" { return "Create worktree" }
        "CONTEXT_SNAPSHOT" { return "Load context" }
        "DISCOVER" { return "Discover" }
        "INVESTIGATE" { return "Investigate" }
        "REPRODUCE" { return "Reproduce" }
        "FIX_PLAN" { return "Fix plan" }
        "FIX_PLAN_VALIDATE" { return "Validate fix plan" }
        "IMPLEMENT" { return "Implement" }
        "CHANGE_VALIDATE" { return "Validate change" }
        "VERIFY_REPRO" { return "Verify reproduction" }
        "PREFLIGHT" { return "Preflight" }
        "REVIEW" { return "Review" }
        "FINALIZE" { return "Finalize" }
        "MERGE_PREP" { return "Prepare merge" }
    }

    switch ([string]$TaskState) {
        "queued" { return "Queued" }
        "running" { return "Running" }
        "retry_scheduled" { return "Retry scheduled" }
        "environment_retry_scheduled" { return "Environment repair scheduled" }
        "manual_debug_needed" { return "Manual debug needed" }
        "merge_retry_scheduled" { return "Merge retry scheduled" }
        "pending_merge" { return "Pending merge" }
        "merge_prepared" { return "Merge prepared" }
        "waiting_user_test" { return "Waiting for user test" }
        "merged" { return "Merged" }
        "completed_no_change" { return "No change needed" }
        "completed_failed_terminal" { return "Failed" }
        default { return "Task" }
    }
}

function Get-TaskProgress {
    param(
        [string]$RepoRoot,
        $Task,
        [object[]]$RecentEvents = @()
    )

    $artifactPointers = Get-TaskArtifactPointers -RepoRoot $RepoRoot -Task $Task
    $liveSnapshot = Read-JsonFileBestEffort -Path $artifactPointers.schedulerSnapshotPath
    $recentTimelineEvent = Get-RecentTimelineEvent -TimelinePath $artifactPointers.timelinePath

    $phase = if ($liveSnapshot -and $liveSnapshot.currentPhase) {
        [string]$liveSnapshot.currentPhase
    } elseif ([string]$Task.state -in @("merge_prepared", "waiting_user_test", "pending_merge", "merge_retry_scheduled")) {
        "MERGE_PREP"
    } else {
        ""
    }

    $phaseLabel = Get-PhaseDisplayLabel -TaskState ([string]$Task.state) -Phase $phase
    $attemptLabel = if ([int]$Task.attemptsUsed -gt 0) {
        "Attempt $([int]$Task.attemptsUsed) of $([int]$Task.maxAttempts)"
    } else {
        ""
    }

    $latestMilestone = if ($recentTimelineEvent -and $recentTimelineEvent.message) {
        ConvertTo-DisplayText -Text ([string]$recentTimelineEvent.message)
    } elseif ($Task.latestRun.summary) {
        [string]$Task.latestRun.summary
    } else {
        ""
    }

    $changedFiles = if ($liveSnapshot -and $liveSnapshot.changedFiles) {
        @(Get-NormalizedPathSet -RepoRoot $RepoRoot -Paths $liveSnapshot.changedFiles)
    } else {
        @(Get-NormalizedPathSet -RepoRoot $RepoRoot -Paths $Task.latestRun.actualFiles)
    }

    $blockerSummary = switch ([string]$Task.state) {
        "queued" {
            if (@($Task.blockedBy).Count -gt 0) {
                "Waiting for task(s): $((@($Task.blockedBy) -join ', '))."
            } else {
                "Waiting for wave $([int]$Task.waveNumber) to open."
            }
        }
        "retry_scheduled" { "Waiting for replanning before a new worker attempt." }
        "environment_retry_scheduled" { "Waiting for environment replan before rerunning the worker." }
        "manual_debug_needed" { "Waiting for repo changes, replanning, or explicit requeue before another worker attempt." }
        "merge_retry_scheduled" { "Waiting for another merge preparation attempt." }
        "pending_merge" { "Waiting for merge turn after the current wave finishes." }
        "waiting_user_test" { "Waiting for user testing before the merge commit." }
        default { "" }
    }

    $nextExpectedAction = switch ([string]$Task.state) {
        "queued" { "Start when this task becomes startable." }
        "running" { "Continue the current worker phase." }
        "retry_scheduled" { "Replan and rerun the worker." }
        "environment_retry_scheduled" { "Replan the task and then rerun the worker in a fresh environment." }
        "manual_debug_needed" { "Resume only after new evidence, repo changes, or an explicit requeue." }
        "merge_retry_scheduled" { "Retry merge preparation with the preserved branch." }
        "pending_merge" { "Prepare the merge when the scheduler surfaces this task." }
        "merge_prepared" { "Resolve the prepared merge." }
        "waiting_user_test" { "User tests, then choose commit, abort, discard, or requeue." }
        "merged" { "No action needed." }
        "completed_no_change" { "No implementation work was needed." }
        "completed_failed_terminal" { "Retry budget exhausted or task was discarded." }
        default { "" }
    }

    $statusTone = switch ([string]$Task.state) {
        "running" { "info" }
        "queued" { "info" }
        "retry_scheduled" { "warning" }
        "environment_retry_scheduled" { "warning" }
        "manual_debug_needed" { "blocked" }
        "merge_retry_scheduled" { "warning" }
        "pending_merge" { "info" }
        "merge_prepared" { "success" }
        "waiting_user_test" { "warning" }
        "merged" { "success" }
        "completed_no_change" { "success" }
        "completed_failed_terminal" { "error" }
        default { "info" }
    }

    $headline = switch ([string]$Task.state) {
        "running" { "${phaseLabel}: $([string]$Task.taskText)" }
        "queued" { "Queued for wave $([int]$Task.waveNumber): $([string]$Task.taskText)" }
        "retry_scheduled" { "Worker retry scheduled: $([string]$Task.taskText)" }
        "environment_retry_scheduled" { "Environment repair scheduled: $([string]$Task.taskText)" }
        "manual_debug_needed" { "Manual debug needed: $([string]$Task.taskText)" }
        "merge_retry_scheduled" { "Merge retry scheduled: $([string]$Task.taskText)" }
        "pending_merge" { "Pending merge: $([string]$Task.taskText)" }
        "merge_prepared" { "Merge prepared: $([string]$Task.taskText)" }
        "waiting_user_test" { "Ready for user test: $([string]$Task.taskText)" }
        "merged" { "Merged: $([string]$Task.taskText)" }
        "completed_no_change" { "No change needed: $([string]$Task.taskText)" }
        "completed_failed_terminal" { "Failed: $([string]$Task.taskText)" }
        default { "${phaseLabel}: $([string]$Task.taskText)" }
    }

    $detail = switch ([string]$Task.state) {
        "running" {
            if ($latestMilestone) { $latestMilestone } else { "Worker is still running." }
        }
        "queued" { $blockerSummary }
        "retry_scheduled" { if ($Task.merge.reason) { [string]$Task.merge.reason } elseif ($Task.latestRun.feedback) { [string]$Task.latestRun.feedback } else { $blockerSummary } }
        "environment_retry_scheduled" {
            $environmentDetail = Get-TaskEnvironmentFailureDetail -Task $Task -RecentTimelineEvent $recentTimelineEvent
            if ($environmentDetail) { $environmentDetail } else { $blockerSummary }
        }
        "manual_debug_needed" { if ($Task.manualDebugReason) { [string]$Task.manualDebugReason } elseif ($Task.latestRun.feedback) { [string]$Task.latestRun.feedback } else { $blockerSummary } }
        "merge_retry_scheduled" { if ($Task.merge.reason) { [string]$Task.merge.reason } else { $blockerSummary } }
        "pending_merge" { $blockerSummary }
        "merge_prepared" { "Merge is prepared and ready for resolution." }
        "waiting_user_test" { "Merge is prepared and waiting for user testing." }
        "merged" { if ($Task.merge.reason) { [string]$Task.merge.reason } else { "Merge completed successfully." } }
        "completed_no_change" { if ($Task.latestRun.noChangeReason) { [string]$Task.latestRun.noChangeReason } else { [string]$Task.latestRun.summary } }
        "completed_failed_terminal" { if ($Task.latestRun.feedback) { [string]$Task.latestRun.feedback } else { [string]$Task.latestRun.summary } }
        default { [string]$Task.latestRun.summary }
    }

    return [pscustomobject]@{
        headline = $headline
        detail = $detail
        phase = $phase
        phaseLabel = $phaseLabel
        attemptLabel = $attemptLabel
        elapsedLabel = Format-ElapsedLabel -StartedAt ([string]$Task.latestRun.startedAt) -CompletedAt ([string]$Task.latestRun.completedAt)
        latestMilestone = $latestMilestone
        statusTone = $statusTone
        changedFilesPreview = @($changedFiles | Select-Object -First 5)
        blockerSummary = $blockerSummary
        nextExpectedAction = $nextExpectedAction
        artifactPointers = $artifactPointers
    }
}

function Get-RecentQueueEvents {
    param([string]$EventsFile)

    $allowedKinds = @(
        "started",
        "completed",
        "merge_prepared",
        "merge_failed",
        "merge_resolved",
        "circuit_breaker_opened",
        "circuit_breaker_closed",
        "circuit_breaker_cleared",
        "external_merge_detected",
        "environment_failure_detected",
        "environment_retry_scheduled",
        "manual_debug_needed"
    )
    $events = @(Read-JsonLinesFile -Path $EventsFile -MaxEntries 40 | Where-Object { $allowedKinds -contains [string]$_.kind } | Select-Object -Last 8)
    return @($events | ForEach-Object {
        [pscustomobject]@{
            timestamp = [string]$_.timestamp
            taskId = [string]$_.taskId
            kind = [string]$_.kind
            message = ConvertTo-DisplayText -Text ([string]$_.message)
        }
    })
}

function Get-QueueProgressSummary {
    param($State)

    $tasks = @(Get-Tasks -State $State)
    $currentWave = Get-CurrentExecutionWave -State $State
    return [pscustomobject]@{
        currentWave = $currentWave
        runningCount = @($tasks | Where-Object { $_.state -eq "running" }).Count
        queuedCount = @($tasks | Where-Object { $_.state -eq "queued" }).Count
        retryCount = @($tasks | Where-Object { $_.state -eq "retry_scheduled" }).Count
        environmentRetryCount = @($tasks | Where-Object { $_.state -eq "environment_retry_scheduled" }).Count
        manualDebugCount = @($tasks | Where-Object { $_.state -eq "manual_debug_needed" }).Count
        mergeRetryCount = @($tasks | Where-Object { $_.state -eq "merge_retry_scheduled" }).Count
        pendingMergeCount = @($tasks | Where-Object { $_.state -eq "pending_merge" }).Count
        waitingUserTestCount = @($tasks | Where-Object { $_.state -eq "waiting_user_test" }).Count
        mergedCount = @($tasks | Where-Object { $_.state -eq "merged" }).Count
        failedCount = @($tasks | Where-Object { $_.state -eq "completed_failed_terminal" }).Count
    }
}

function Get-QueueStallSummary {
    param(
        $State,
        [object[]]$StartableTaskIds = @(),
        $NextMergeTask = $null,
        $MergePreparedTask = $null,
        $CircuitBreaker = $null,
        [object[]]$ReconcileErrors = @()
    )

    $tasks = @(Get-Tasks -State $State)
    $runningTasks = @($tasks | Where-Object { $_.state -eq "running" })
    $waitingMergeTasks = @($tasks | Where-Object { $_.state -in @("merge_prepared", "waiting_user_test") })
    $queueRelevantTasks = @($tasks | Where-Object { $_.state -in @("queued", "retry_scheduled", "environment_retry_scheduled", "manual_debug_needed", "pending_merge", "merge_retry_scheduled") })
    $manualDebugTaskIds = @($tasks | Where-Object { $_.state -eq "manual_debug_needed" } | ForEach-Object { [string]$_.taskId })
    $environmentRetryTaskIds = @($tasks | Where-Object { $_.state -eq "environment_retry_scheduled" } | ForEach-Object { [string]$_.taskId })
    $retryTaskIds = @($tasks | Where-Object { $_.state -eq "retry_scheduled" } | ForEach-Object { [string]$_.taskId })
    $pendingMergeBlocked = @($tasks | Where-Object { $_.state -in @("pending_merge", "merge_retry_scheduled") } | ForEach-Object { [string]$_.taskId })
    $queuedLikeTaskIds = @($queueRelevantTasks | ForEach-Object { [string]$_.taskId })
    $currentWave = Get-CurrentExecutionWave -State $State
    $nextMergeTaskId = if ($NextMergeTask) { [string]$NextMergeTask.taskId } else { "" }
    $mergePreparedTaskId = if ($MergePreparedTask) { [string]$MergePreparedTask.taskId } else { "" }
    $signatureParts = @(
        "wave=$currentWave"
        "startable=$((@($StartableTaskIds) | ForEach-Object { [string]$_ }) -join ',')"
        "queue=$($queuedLikeTaskIds -join ',')"
        "running=$((@($runningTasks | ForEach-Object { [string]$_.taskId })) -join ',')"
        "merge=$nextMergeTaskId"
        "prepared=$mergePreparedTaskId"
    )

    if ($waitingMergeTasks.Count -gt 0) {
        return [pscustomobject]@{
            status = "blocked"
            reason = "A merge is waiting for explicit resolution before queue progress can continue."
            recommendedAction = "wait_for_user_merge_decision"
            currentWave = $currentWave
            candidateTaskIds = @($waitingMergeTasks | ForEach-Object { [string]$_.taskId })
            queuedLikeTaskIds = @($queuedLikeTaskIds)
            blockingTaskIds = @($waitingMergeTasks | ForEach-Object { [string]$_.taskId })
            mergePendingButBlocked = @($pendingMergeBlocked).Count -gt 0
            manualDebugTaskIds = @($manualDebugTaskIds)
            environmentRetryTaskIds = @($environmentRetryTaskIds)
            retryTaskIds = @($retryTaskIds)
            signature = ($signatureParts -join "|")
            details = [pscustomobject]@{
                runningCount = $runningTasks.Count
                startableCount = @($StartableTaskIds).Count
                reconcileErrorCount = @($ReconcileErrors).Count
            }
        }
    }

    if ($CircuitBreaker -and $CircuitBreaker.status -notin @("closed", "manual_override")) {
        return [pscustomobject]@{
            status = "blocked"
            reason = "The circuit breaker is open, so no new work may start right now."
            recommendedAction = "wait_for_breaker_clear"
            currentWave = $currentWave
            candidateTaskIds = @()
            queuedLikeTaskIds = @($queuedLikeTaskIds)
            blockingTaskIds = @($queuedLikeTaskIds)
            mergePendingButBlocked = @($pendingMergeBlocked).Count -gt 0
            manualDebugTaskIds = @($manualDebugTaskIds)
            environmentRetryTaskIds = @($environmentRetryTaskIds)
            retryTaskIds = @($retryTaskIds)
            signature = ($signatureParts -join "|")
            details = [pscustomobject]@{
                runningCount = $runningTasks.Count
                startableCount = @($StartableTaskIds).Count
                reconcileErrorCount = @($ReconcileErrors).Count
                breakerStatus = [string]$CircuitBreaker.status
            }
        }
    }

    if (@($ReconcileErrors).Count -gt 0) {
        return [pscustomobject]@{
            status = "blocked"
            reason = "Scheduler reconciliation errors must be resolved before autonomous progress can continue safely."
            recommendedAction = "investigate_reconcile_errors"
            currentWave = $currentWave
            candidateTaskIds = @()
            queuedLikeTaskIds = @($queuedLikeTaskIds)
            blockingTaskIds = @(@($ReconcileErrors | ForEach-Object { [string]$_.taskId } | Where-Object { $_ } | Select-Object -Unique))
            mergePendingButBlocked = @($pendingMergeBlocked).Count -gt 0
            manualDebugTaskIds = @($manualDebugTaskIds)
            environmentRetryTaskIds = @($environmentRetryTaskIds)
            retryTaskIds = @($retryTaskIds)
            signature = ($signatureParts -join "|")
            details = [pscustomobject]@{
                runningCount = $runningTasks.Count
                startableCount = @($StartableTaskIds).Count
                reconcileErrorCount = @($ReconcileErrors).Count
            }
        }
    }

    if ($runningTasks.Count -gt 0 -or @($StartableTaskIds).Count -gt 0 -or $NextMergeTask -or $queuedLikeTaskIds.Count -eq 0) {
        return [pscustomobject]@{
            status = "none"
            reason = ""
            recommendedAction = ""
            currentWave = $currentWave
            candidateTaskIds = @()
            queuedLikeTaskIds = @($queuedLikeTaskIds)
            blockingTaskIds = @()
            mergePendingButBlocked = @($pendingMergeBlocked).Count -gt 0
            manualDebugTaskIds = @($manualDebugTaskIds)
            environmentRetryTaskIds = @($environmentRetryTaskIds)
            retryTaskIds = @($retryTaskIds)
            signature = ($signatureParts -join "|")
            details = [pscustomobject]@{
                runningCount = $runningTasks.Count
                startableCount = @($StartableTaskIds).Count
                reconcileErrorCount = @($ReconcileErrors).Count
            }
        }
    }

    return [pscustomobject]@{
        status = "stalled"
        reason = "No running tasks, no startable tasks, and no merge candidate are available even though queued work remains."
        recommendedAction = "replan"
        currentWave = $currentWave
        candidateTaskIds = @($queuedLikeTaskIds)
        queuedLikeTaskIds = @($queuedLikeTaskIds)
        blockingTaskIds = @($queuedLikeTaskIds)
        mergePendingButBlocked = @($pendingMergeBlocked).Count -gt 0
        manualDebugTaskIds = @($manualDebugTaskIds)
        environmentRetryTaskIds = @($environmentRetryTaskIds)
        retryTaskIds = @($retryTaskIds)
        signature = ($signatureParts -join "|")
        details = [pscustomobject]@{
            runningCount = $runningTasks.Count
            startableCount = @($StartableTaskIds).Count
            reconcileErrorCount = @($ReconcileErrors).Count
        }
    }
}

function Get-UsageEstimateForTask {
    param(
        $State,
        $Task
    )

    $historyMinutes = @(
        (Get-Tasks -State $State) |
            Where-Object {
                $_.taskId -ne $Task.taskId -and
                $_.latestRun.startedAt -and
                $_.latestRun.completedAt
            } |
            ForEach-Object {
                try {
                    $start = [datetime]$_.latestRun.startedAt
                    $end = [datetime]$_.latestRun.completedAt
                    [int][Math]::Ceiling(($end - $start).TotalMinutes)
                } catch {
                }
            } |
            Where-Object { $_ -gt 0 }
    )

    $text = [string]$Task.taskText
    $estimate = 20
    $source = "heuristic"
    if ($historyMinutes.Count -gt 0) {
        $estimate = [int][Math]::Max(5, [Math]::Round((($historyMinutes | Measure-Object -Average).Average), 0))
        $source = "historical"
    } elseif ($text) {
        $estimate = 15
        if ($text.Length -gt 140) { $estimate = 25 }
        if ($text -match '(?i)\b(refactor|migration|schema|review|investigate|reproduce|preflight|test)\b') { $estimate += 10 }
        if ($text -match '(?i)\b(simple|tiny|small|minor|rename|text)\b') { $estimate = [Math]::Max(5, $estimate - 5) }
    }

    $costClass = if ($estimate -ge 35) { "HIGH" } elseif ($estimate -ge 18) { "MEDIUM" } else { "LOW" }

    return [pscustomobject]@{
        usageEstimateMinutes = [int]$estimate
        usageEstimateSource = [string]$source
        usageCostClass = [string]$costClass
    }
}

function Update-TaskUsageEstimate {
    param(
        $State,
        $Task
    )

    $estimate = Get-UsageEstimateForTask -State $State -Task $Task
    $Task.usageEstimateMinutes = [int]$estimate.usageEstimateMinutes
    $Task.usageEstimateSource = [string]$estimate.usageEstimateSource
    $Task.usageCostClass = [string]$estimate.usageCostClass
}

function Evaluate-PlannerPrediction {
    param(
        [string]$RepoRoot,
        $Task
    )

    $predictedFiles = @(Get-NormalizedPathSet -RepoRoot $RepoRoot -Paths $Task.plannerMetadata.likelyFiles)
    $actualFiles = @(Get-NormalizedPathSet -RepoRoot $RepoRoot -Paths $Task.latestRun.actualFiles)
    if ($predictedFiles.Count -eq 0 -and $actualFiles.Count -eq 0) {
        return [pscustomobject]@{
            predictionEvaluated = $false
            predictionHitRate = 0
            predictionNotes = "No predicted or actual files were available."
            falsePositives = @()
            falseNegatives = @()
            overlap = @()
            classification = "unknown"
        }
    }

    $matchResult = Match-PlannerPredictionPaths -PredictedPaths $predictedFiles -ActualPaths $actualFiles
    $overlap = @($matchResult.overlap)
    $falsePositives = @($matchResult.falsePositives)
    $falseNegatives = @($matchResult.falseNegatives)
    $denominator = [Math]::Max(1, [Math]::Max($predictedFiles.Count, $actualFiles.Count))
    $hitRate = [Math]::Round(($overlap.Count / $denominator), 2)
    $classification = if ($matchResult.matchKinds.directory -gt 0 -and $matchResult.matchKinds.exact -eq 0) {
        "broad"
    } elseif ($hitRate -ge 0.8 -and $falseNegatives.Count -eq 0 -and $matchResult.matchKinds.suffix -eq 0 -and $matchResult.matchKinds.directory -eq 0) {
        "tight"
    } elseif ($hitRate -ge 0.5) {
        "acceptable"
    } elseif ($overlap.Count -gt 0) {
        "broad"
    } else {
        "missed"
    }

    $matchKindSummary = @()
    if ($matchResult.matchKinds.exact -gt 0) { $matchKindSummary += "$($matchResult.matchKinds.exact) exact" }
    if ($matchResult.matchKinds.suffix -gt 0) { $matchKindSummary += "$($matchResult.matchKinds.suffix) suffix" }
    if ($matchResult.matchKinds.directory -gt 0) { $matchKindSummary += "$($matchResult.matchKinds.directory) directory" }
    $notes = "Predicted $($predictedFiles.Count) file(s), actual $($actualFiles.Count) file(s), overlap $($overlap.Count)."
    if ($matchKindSummary.Count -gt 0) {
        $notes += " Match kinds: $($matchKindSummary -join ', ')."
    }

    return [pscustomobject]@{
        predictionEvaluated = $true
        predictionHitRate = $hitRate
        predictionNotes = $notes
        falsePositives = @($falsePositives)
        falseNegatives = @($falseNegatives)
        overlap = @($overlap)
        classification = $classification
        matchKindsSummary = [pscustomobject]@{
            exact = [int]$matchResult.matchKinds.exact
            suffix = [int]$matchResult.matchKinds.suffix
            directory = [int]$matchResult.matchKinds.directory
        }
        matchedPredictions = @($matchResult.matchedPredictions)
        matchedActualFiles = @($matchResult.matchedActualFiles)
    }
}

function ConvertTo-TaskSnapshot {
    param(
        $Task,
        [string]$RepoRoot = $script:CurrentSnapshotRepoRoot
    )

    $progress = Get-TaskProgress -RepoRoot $RepoRoot -Task $Task
    $artifactPointers = Get-TaskArtifactPointers -RepoRoot $RepoRoot -Task $Task
    $integrityWarnings = @(Get-TaskIntegrityWarnings -Task $Task)
    $processId = 0
    [void][int]::TryParse(([string]$Task.latestRun.processId), [ref]$processId)

    return [pscustomobject]@{
        taskId = [string]$Task.taskId
        taskToken = [string]$Task.taskToken
        sourceCommand = [string]$Task.sourceCommand
        sourceInputType = [string]$Task.sourceInputType
        taskText = [string]$Task.taskText
        state = [string]$Task.state
        waveNumber = [int]$Task.waveNumber
        submissionOrder = [int]$Task.submissionOrder
        blockedBy = @($Task.blockedBy)
        declaredDependencies = @($Task.declaredDependencies)
        declaredPriority = [string]$Task.declaredPriority
        serialOnly = [bool]$Task.serialOnly
        attemptsUsed = [int]$Task.attemptsUsed
        attemptsRemaining = [int]$Task.attemptsRemaining
        workerLaunchSequence = [int]$Task.workerLaunchSequence
        latestRunLaunchSequence = [int]$Task.latestRun.launchSequence
        maxEnvironmentRepairAttempts = [int]$Task.maxEnvironmentRepairAttempts
        environmentRepairAttemptsUsed = [int]$Task.environmentRepairAttemptsUsed
        environmentRepairAttemptsRemaining = [int]$Task.environmentRepairAttemptsRemaining
        lastEnvironmentFailureCategory = [string]$Task.lastEnvironmentFailureCategory
        manualDebugReason = [string]$Task.manualDebugReason
        retryScheduled = [bool]$Task.retryScheduled
        usageCostClass = [string]$Task.usageCostClass
        usageEstimateMinutes = [int]$Task.usageEstimateMinutes
        usageEstimateSource = [string]$Task.usageEstimateSource
        maxMergeAttempts = [int]$Task.maxMergeAttempts
        mergeAttemptsUsed = [int]$Task.mergeAttemptsUsed
        mergeAttemptsRemaining = [int]$Task.mergeAttemptsRemaining
        waitingUserTest = [bool]$Task.waitingUserTest
        mergeState = [string]$Task.mergeState
        processId = $processId
        completedAt = [string]$Task.latestRun.completedAt
        branchName = [string]$Task.latestRun.branchName
        summary = Get-TaskSummaryText -Task $Task
        finalStatus = [string]$Task.latestRun.finalStatus
        finalCategory = [string]$Task.latestRun.finalCategory
        noChangeReason = [string]$Task.latestRun.noChangeReason
        actualFiles = @($Task.latestRun.actualFiles)
        plannerMetadata = $Task.plannerMetadata
        plannerFeedback = $Task.plannerFeedback
        runs = @($Task.runs)
        integrityWarnings = @($integrityWarnings)
        merge = $Task.merge
        resultFile = [string]$Task.resultFile
        progress = $progress
        progressArtifacts = $artifactPointers
    }
}

function Write-TaskResultFile {
    param($Task)
    Ensure-ParentDirectory -Path $Task.resultFile
    [System.IO.File]::WriteAllText($Task.resultFile, ((ConvertTo-TaskSnapshot -Task $Task -RepoRoot $script:CurrentSnapshotRepoRoot) | ConvertTo-Json -Depth 24), [System.Text.Encoding]::UTF8)
}

function Write-PlannerContextFile {
    param(
        [string]$Path,
        $Task
    )

    Ensure-ParentDirectory -Path $Path
    $payload = [ordered]@{
        taskId = [string]$Task.taskId
        waveNumber = [int]$Task.waveNumber
        plannerMetadata = if ($Task.plannerMetadata) { $Task.plannerMetadata } else { [pscustomobject]@{} }
    } | ConvertTo-Json -Depth 16
    [System.IO.File]::WriteAllText($Path, $payload, [System.Text.Encoding]::UTF8)
}

function Normalize-RepoRelativePath {
    param(
        [string]$RepoRoot,
        [string]$Path
    )

    if (-not $Path) { return "" }
    $value = $Path.Trim().Replace("/", "\")
    if (-not $value) { return "" }

    try {
        if ([System.IO.Path]::IsPathRooted($value)) {
            $fullPath = [System.IO.Path]::GetFullPath($value)
            $fullRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
            if ($fullPath.StartsWith($fullRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = $fullPath.Substring($fullRepoRoot.Length).TrimStart('\')
            } else {
                $value = $fullPath
            }
        }
    } catch {
    }

    while ($value.StartsWith(".\")) {
        $value = $value.Substring(2)
    }
    return $value.TrimStart('\')
}

function Get-NormalizedPathSet {
    param(
        [string]$RepoRoot,
        [string[]]$Paths
    )

    return @(
        @($Paths | ForEach-Object {
            $normalized = Normalize-RepoRelativePath -RepoRoot $RepoRoot -Path ([string]$_)
            if ($normalized) { $normalized }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-CanonicalComparisonPath {
    param([string]$Path)
    if (-not $Path) { return "" }
    return (([string]$Path).Trim().Replace("/", "\").TrimStart('\')).ToLowerInvariant()
}

function Get-PathComparisonProfile {
    param([string]$Path)

    $canonical = Get-CanonicalComparisonPath -Path $Path
    if (-not $canonical) {
        return [pscustomobject]@{
            original = [string]$Path
            canonical = ""
            baseName = ""
            isFileLike = $false
            segments = @()
        }
    }

    $segments = @($canonical -split '[\\/]')
    $baseName = if ($segments.Count -gt 0) { [string]$segments[-1] } else { "" }
    $isFileLike = ($baseName -match '\.') -and ($segments.Count -gt 0)
    return [pscustomobject]@{
        original = [string]$Path
        canonical = $canonical
        baseName = $baseName
        isFileLike = $isFileLike
        segments = @($segments)
    }
}

function Get-PlannerPredictionMatch {
    param(
        [string]$PredictedPath,
        [string[]]$ActualPaths
    )

    $predicted = Get-PathComparisonProfile -Path $PredictedPath
    $actualProfiles = @($ActualPaths | ForEach-Object { Get-PathComparisonProfile -Path ([string]$_) } | Where-Object { $_.canonical })
    if (-not $predicted.canonical -or $actualProfiles.Count -eq 0) {
        return [pscustomobject]@{ kind = "none"; actual = "" }
    }

    $exactMatch = @($actualProfiles | Where-Object { $_.canonical -eq $predicted.canonical } | Select-Object -First 1)
    if ($exactMatch.Count -gt 0) {
        return [pscustomobject]@{ kind = "exact"; actual = [string]$exactMatch[0].original }
    }

    if ($predicted.isFileLike) {
        $suffixCandidates = @($actualProfiles | Where-Object { $_.baseName -eq $predicted.baseName })
        if ($suffixCandidates.Count -eq 1) {
            return [pscustomobject]@{ kind = "suffix"; actual = [string]$suffixCandidates[0].original }
        }

        $suffixByEnding = @($actualProfiles | Where-Object { $_.canonical.EndsWith("\" + $predicted.canonical) })
        if ($suffixByEnding.Count -eq 1) {
            return [pscustomobject]@{ kind = "suffix"; actual = [string]$suffixByEnding[0].original }
        }
    }

    if (-not $predicted.isFileLike -and $predicted.segments.Count -gt 0) {
        $directoryPrefix = $predicted.canonical.TrimEnd('\')
        $directoryCandidates = @($actualProfiles | Where-Object { $_.canonical.StartsWith($directoryPrefix + "\") -or $_.canonical -eq $directoryPrefix })
        if ($directoryCandidates.Count -gt 0) {
            return [pscustomobject]@{ kind = "directory"; actual = [string]$directoryCandidates[0].original }
        }
    }

    return [pscustomobject]@{ kind = "none"; actual = "" }
}

function Match-PlannerPredictionPaths {
    param(
        [string[]]$PredictedPaths,
        [string[]]$ActualPaths
    )

    $matchedPredictions = [System.Collections.ArrayList]::new()
    $matchedActualFiles = [System.Collections.ArrayList]::new()
    $overlap = [System.Collections.ArrayList]::new()
    $usedActuals = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $matchKinds = [ordered]@{ exact = 0; suffix = 0; directory = 0 }
    $falsePositives = [System.Collections.ArrayList]::new()

    foreach ($predicted in @($PredictedPaths | Where-Object { $_ } | Select-Object -Unique)) {
        $match = Get-PlannerPredictionMatch -PredictedPath ([string]$predicted) -ActualPaths $ActualPaths
        if ($match.kind -eq "none" -or -not $match.actual) {
            [void]$falsePositives.Add([string]$predicted)
            continue
        }

        [void]$matchedPredictions.Add([string]$predicted)
        [void]$matchedActualFiles.Add([string]$match.actual)
        [void]$overlap.Add([string]$predicted)
        [void]$usedActuals.Add(([string]$match.actual))
        if ($matchKinds.Contains($match.kind)) {
            $matchKinds[$match.kind] = [int]$matchKinds[$match.kind] + 1
        }
    }

    $falseNegatives = @(
        @($ActualPaths | Where-Object { $_ -and -not $usedActuals.Contains([string]$_) } | Select-Object -Unique)
    )

    return [pscustomobject]@{
        overlap = @($overlap | Select-Object -Unique)
        falsePositives = @($falsePositives | Select-Object -Unique)
        falseNegatives = @($falseNegatives)
        matchedPredictions = @($matchedPredictions | Select-Object -Unique)
        matchedActualFiles = @($matchedActualFiles | Select-Object -Unique)
        matchKinds = [pscustomobject]$matchKinds
    }
}

function Get-SubmissionOrder {
    param($State)
    $tasks = Get-Tasks -State $State
    if ($tasks.Count -eq 0) { return 1 }
    return ((@($tasks | ForEach-Object { [int]$_.submissionOrder } | Measure-Object -Maximum).Maximum) + 1)
}

function Get-TaskFailureCategory {
    param($Task)

    $text = (([string]$Task.latestRun.finalCategory) + " " + ([string]$Task.merge.reason) + " " + ([string]$Task.latestRun.feedback)).ToLowerInvariant()
    if (-not $text.Trim()) { return "" }
    if ($text -match 'worktree_invalid|solution_path_missing|worktree_environment_error|worker_start_failed|worker_exited_without_result') { return "environment_state" }
    if ($text -match 'nuget|restore|package') { return "restore_infra" }
    if ($text -match 'msb3021|msb3027|lock|locked|access to the path|used by another process') { return "locked_environment" }
    if ($text -match 'build failed|compile|cs\d{4}|msbuild') { return "build_infra" }
    if ($text -match 'test|xunit|nunit|mstest') { return "test_infra" }
    if ($text -match 'merge conflict') { return "merge_conflict" }
    if ($text -match 'dirty_worktree|repository worktree is not clean|git') { return "repo_state" }
    if ($text -match 'reconcile|scheduler|planner') { return "scheduler_state" }
    if ($text -match 'review_denied') { return "review_denied" }
    return "unknown"
}

function Get-TaskCompletionTimestamp {
    param($Task)

    $value = if ($Task.latestRun.completedAt) { [string]$Task.latestRun.completedAt } else { "" }
    if (-not $value) { return $null }
    try {
        return [datetime]$value
    } catch {
        return $null
    }
}

function Get-TaskSuccessTimestamp {
    param($Task)

    if ($Task.state -notin @("pending_merge", "merge_prepared", "waiting_user_test", "merged", "completed_no_change")) {
        return $null
    }
    return (Get-TaskCompletionTimestamp -Task $Task)
}

function Get-RecentFailureCandidates {
    param($State)

    $cutoff = (Get-Date).AddMinutes(-$script:CircuitBreakerRecentWindowMinutes)
    return @(
        (Get-Tasks -State $State) |
            Where-Object { $_.state -in @("retry_scheduled", "merge_retry_scheduled", "completed_failed_terminal") } |
            ForEach-Object {
                $completedAt = Get-TaskCompletionTimestamp -Task $_
                if ($null -eq $completedAt -or $completedAt -lt $cutoff) { return }
                $category = Get-TaskFailureCategory -Task $_
                if (-not $category -or $category -eq "review_denied") { return }
                [pscustomobject]@{
                    taskId = [string]$_.taskId
                    waveNumber = [int]$_.waveNumber
                    category = $category
                    completedAt = $completedAt
                }
            } |
            Where-Object { $_ }
    )
}

function Get-CircuitBreakerSummary {
    param($State)

    if (-not $State.circuitBreaker) {
        $State | Add-Member -NotePropertyName circuitBreaker -NotePropertyValue (New-CircuitBreakerRecord) -Force
    }

    $overrideUntil = [datetime]::MinValue
    if ($State.circuitBreaker.manualOverrideUntil) {
        try { $overrideUntil = [datetime]$State.circuitBreaker.manualOverrideUntil } catch { }
    }
    if ($overrideUntil -gt (Get-Date)) {
        return [pscustomobject]@{
            status = "manual_override"
            openedAt = [string]$State.circuitBreaker.openedAt
            closedAt = if ($State.circuitBreaker.closedAt) { [string]$State.circuitBreaker.closedAt } else { (Get-Date).ToString("o") }
            scopeWave = 0
            reasonCategory = if ($State.circuitBreaker.reasonCategory) { [string]$State.circuitBreaker.reasonCategory } else { "manual_override" }
            reasonSummary = "Manual circuit-breaker override is active."
            affectedTaskIds = if ($State.circuitBreaker.affectedTaskIds) { @(Normalize-StringArray -Value $State.circuitBreaker.affectedTaskIds) } else { @() }
            manualOverrideUntil = [string]$State.circuitBreaker.manualOverrideUntil
        }
    }

    $retryCandidates = @(Get-RecentFailureCandidates -State $State)

    $waveGroups = @(
        $retryCandidates |
            Group-Object waveNumber, category |
            Where-Object { $_.Count -ge 3 -and [int]$_.Group[0].waveNumber -gt 0 }
    )
    if ($waveGroups.Count -gt 0) {
        foreach ($waveGroup in $waveGroups) {
            $group = @($waveGroup.Group | Sort-Object completedAt)
            $earliestFailure = $group[0].completedAt
            $waveSuccessAfterFailure = @(
                (Get-Tasks -State $State) |
                    Where-Object { [int]$_.waveNumber -eq [int]$group[0].waveNumber } |
                    ForEach-Object { Get-TaskSuccessTimestamp -Task $_ } |
                    Where-Object { $null -ne $_ -and $_ -gt $earliestFailure }
            )
            if ($waveSuccessAfterFailure.Count -gt 0) { continue }
            return [pscustomobject]@{
                status = "wave_open"
                openedAt = if ($State.circuitBreaker.openedAt -and $State.circuitBreaker.status -eq "wave_open") { [string]$State.circuitBreaker.openedAt } else { (Get-Date).ToString("o") }
                closedAt = ""
                scopeWave = [int]$group[0].waveNumber
                reasonCategory = [string]$group[0].category
                reasonSummary = "Recent correlated failures opened the wave breaker."
                affectedTaskIds = @($group | ForEach-Object { [string]$_.taskId })
                manualOverrideUntil = ""
            }
        }
    }

    $sessionGroups = @(
        $retryCandidates |
            Group-Object category |
            Where-Object { $_.Count -ge 4 }
    )
    if ($sessionGroups.Count -gt 0) {
        foreach ($sessionGroup in $sessionGroups) {
            $group = @($sessionGroup.Group | Sort-Object completedAt)
            $earliestFailure = $group[0].completedAt
            $successAfterFailure = @(
                (Get-Tasks -State $State) |
                    ForEach-Object { Get-TaskSuccessTimestamp -Task $_ } |
                    Where-Object { $null -ne $_ -and $_ -gt $earliestFailure }
            )
            if ($successAfterFailure.Count -gt 0) { continue }
            return [pscustomobject]@{
                status = "session_open"
                openedAt = if ($State.circuitBreaker.openedAt -and $State.circuitBreaker.status -eq "session_open") { [string]$State.circuitBreaker.openedAt } else { (Get-Date).ToString("o") }
                closedAt = ""
                scopeWave = 0
                reasonCategory = [string]$group[0].category
                reasonSummary = "Recent correlated failures opened the session breaker."
                affectedTaskIds = @($group | ForEach-Object { [string]$_.taskId })
                manualOverrideUntil = ""
            }
        }
    }

    $closed = New-CircuitBreakerRecord
    $closed.closedAt = (Get-Date).ToString("o")
    return $closed
}

function Update-CircuitBreakerState {
    param(
        $State,
        [string]$EventsFile = ""
    )

    $previousStatus = if ($State.circuitBreaker) { [string]$State.circuitBreaker.status } else { "closed" }
    $summary = Get-CircuitBreakerSummary -State $State
    $State.circuitBreaker = $summary

    if ($EventsFile -and $summary.status -ne $previousStatus) {
        $kind = if ($summary.status -eq "closed") { "circuit_breaker_closed" } else { "circuit_breaker_opened" }
        Append-StateEvent -EventsFile $EventsFile -TaskId "" -Kind $kind -Message $summary.reasonSummary -Data $summary
    }

    return $summary
}

function Get-CurrentExecutionWave {
    param($State)
    $active = @((Get-Tasks -State $State) | Where-Object {
        -not (Is-TerminalState -State $_.state) -and [int]$_.waveNumber -gt 0
    })
    if ($active.Count -eq 0) { return 0 }
    return (@($active | ForEach-Object { [int]$_.waveNumber } | Measure-Object -Minimum).Minimum)
}

function Get-TasksInWave {
    param(
        $State,
        [int]$WaveNumber
    )

    if ($WaveNumber -le 0) { return @() }
    return @(
        @((Get-Tasks -State $State) | Where-Object {
            [int]$_.waveNumber -eq $WaveNumber
        } | Sort-Object submissionOrder)
    )
}

function Get-StartableTaskIds {
    param($State)
    $breaker = Get-CircuitBreakerSummary -State $State
    if ($breaker.status -notin @("closed", "manual_override")) { return @() }

    $waveNumber = Get-CurrentExecutionWave -State $State
    if ($waveNumber -le 0) { return @() }

    $waveTasks = @(Get-TasksInWave -State $State -WaveNumber $waveNumber)
    if ($waveTasks.Count -eq 0) { return @() }

    $mergeGateStates = @("pending_merge", "merge_retry_scheduled", "merge_prepared", "waiting_user_test")
    if (@($waveTasks | Where-Object { $mergeGateStates -contains $_.state }).Count -gt 0) {
        return @()
    }

    $taskIndex = @{}
    foreach ($candidate in @(Get-Tasks -State $State)) {
        $taskIndex[[string]$candidate.taskId] = $candidate
    }

    return @(
        @($waveTasks | Where-Object {
            if ([int]$_.waveNumber -ne $waveNumber -or -not (Is-QueueState -State $_.state)) { return $false }
            foreach ($dependencyId in @($_.blockedBy)) {
                $dependencyTask = $taskIndex[[string]$dependencyId]
                if ($null -eq $dependencyTask) { return $false }
                if ($dependencyTask.state -notin @("merged", "completed_no_change")) { return $false }
            }
            return $true
        } | Sort-Object @{ Expression = {
                switch ([string]$_.declaredPriority) {
                    "high" { 0 }
                    "normal" { 1 }
                    "low" { 2 }
                    default { 1 }
                }
            }
        }, submissionOrder | ForEach-Object { [string]$_.taskId })
    )
}

function Get-NextMergeTask {
    param($State)
    return @(
        @((Get-Tasks -State $State) | Where-Object {
            $_.state -eq "pending_merge"
        } | Sort-Object waveNumber, submissionOrder)
    )[0]
}

function Get-MergePreparedTask {
    param($State)
    return @(
        @((Get-Tasks -State $State) | Where-Object {
            $_.state -in @("merge_prepared", "waiting_user_test")
        } | Sort-Object waveNumber, submissionOrder)
    )[0]
}

function Get-KnownBranches {
    param($State)
    return @(
        @((Get-Tasks -State $State) | ForEach-Object {
            if ($_.latestRun.branchName) { [string]$_.latestRun.branchName }
            foreach ($run in @($_.runs)) {
                if ($run.branchName) { [string]$run.branchName }
            }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-KnownTaskNames {
    param($State)

    return @(
        @((Get-Tasks -State $State) | ForEach-Object {
            if ($_.latestRun.taskName) { [string]$_.latestRun.taskName }
            foreach ($run in @($_.runs)) {
                if ($run.taskName) { [string]$run.taskName }
            }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Is-PrepareProtectedBranchState {
    param([string]$State)

    return $State -in @(
        "running",
        "pending_merge",
        "merge_retry_scheduled",
        "merge_prepared",
        "waiting_user_test"
    )
}

function Is-PrepareProtectedLaunchArtifactState {
    param([string]$State)

    return $State -eq "running"
}

function Get-PrepareProtectedBranchReferences {
    param($State)

    return @(
        @((Get-Tasks -State $State) | Where-Object {
            Is-PrepareProtectedBranchState -State ([string]$_.state)
        } | ForEach-Object {
            if ($_.merge.branchName) { [string]$_.merge.branchName }
            elseif ($_.latestRun.branchName) { [string]$_.latestRun.branchName }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-PrepareProtectedLaunchArtifactReferences {
    param($State)

    $protectedTaskNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($task in @(Get-Tasks -State $State)) {
        $taskName = [string]$task.latestRun.taskName
        if (-not $taskName) { continue }
        if ((Is-PrepareProtectedLaunchArtifactState -State ([string]$task.state)) -or (Test-ProcessAlive -ProcessId ([int]$task.latestRun.processId))) {
            [void]$protectedTaskNames.Add($taskName)
        }
    }

    return @(
        @($protectedTaskNames | Select-Object -Unique)
    )
}

function Get-UnknownAutoBranches {
    param(
        [string]$RepoRoot,
        [string[]]$KnownBranches
    )

    $result = Invoke-NativeCommand -Command "git" -Arguments @("branch", "--format", "%(refname:short)", "--list", "auto/*") -WorkingDirectory $RepoRoot
    if ($result.exitCode -ne 0 -or -not $result.output) { return @() }

    return @(
        @($result.output -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object {
            $_ -and ($KnownBranches -notcontains $_)
        })
    )
}

function Get-CurrentBranchName {
    param([string]$RepoRoot)

    $result = Invoke-NativeCommand -Command "git" -Arguments @("branch", "--show-current") -WorkingDirectory $RepoRoot
    if ($result.exitCode -ne 0) { return "" }
    return ([string]$result.output).Trim()
}

function Get-GitWorktreeEntries {
    param([string]$RepoRoot)

    $result = Invoke-NativeCommand -Command "git" -Arguments @("worktree", "list", "--porcelain") -WorkingDirectory $RepoRoot
    if ($result.exitCode -ne 0 -or -not $result.output) {
        return @()
    }

    $entries = [System.Collections.ArrayList]::new()
    $current = $null
    foreach ($line in @($result.output -split "\r?\n")) {
        $trimmed = [string]$line
        if (-not $trimmed) {
            if ($current) {
                [void]$entries.Add([pscustomobject]$current)
                $current = $null
            }
            continue
        }

        if ($trimmed.StartsWith("worktree ")) {
            if ($current) {
                [void]$entries.Add([pscustomobject]$current)
            }
            $current = [ordered]@{
                path = Get-CanonicalPath -Path ($trimmed.Substring(9).Trim())
                branch = ""
                head = ""
                bare = $false
                detached = $false
            }
            continue
        }

        if (-not $current) { continue }
        if ($trimmed.StartsWith("branch ")) {
            $current.branch = ($trimmed.Substring(7).Trim() -replace '^refs/heads/', '')
        } elseif ($trimmed.StartsWith("HEAD ")) {
            $current.head = $trimmed.Substring(5).Trim()
        } elseif ($trimmed -eq "bare") {
            $current.bare = $true
        } elseif ($trimmed -eq "detached") {
            $current.detached = $true
        }
    }

    if ($current) {
        [void]$entries.Add([pscustomobject]$current)
    }

    return @($entries)
}

function Get-UnknownAutoWorktrees {
    param(
        [string]$RepoRoot,
        [string[]]$KnownTaskNames,
        [object[]]$GitWorktreeEntries
    )

    $worktreeBase = Get-AutoDevelopWorktreeBase
    if (-not (Test-Path -LiteralPath $worktreeBase)) {
        return @()
    }

    $registeredPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($GitWorktreeEntries)) {
        if ($entry.path) {
            [void]$registeredPaths.Add((Get-CanonicalPath -Path ([string]$entry.path)))
        }
    }

    $gitDir = Get-GitDirPath -RepoRoot $RepoRoot
    $worktreesMarker = (Join-Path $gitDir "worktrees").Replace("/", "\")

    return @(
        @(Get-ChildItem -LiteralPath $worktreeBase -Directory -ErrorAction SilentlyContinue | Where-Object {
            $name = [string]$_.Name
            $fullPath = Get-CanonicalPath -Path $_.FullName
            $gitPointerPath = Join-Path $_.FullName ".git"
            $gitPointerContent = if (Test-Path -LiteralPath $gitPointerPath) {
                try { [System.IO.File]::ReadAllText($gitPointerPath) } catch { "" }
            } else {
                ""
            }
            $isRepoOwned = $gitPointerContent -and (($gitPointerContent.Replace("/", "\")).IndexOf($worktreesMarker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            $isRepoOwned -and ($KnownTaskNames -notcontains $name) -and (-not $registeredPaths.Contains($fullPath))
        } | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.Name
                path = [string]$_.FullName
            }
        })
    )
}

function Get-OrphanedRunArtifacts {
    param(
        [string]$RepoRoot,
        [string[]]$KnownTaskNames
    )

    $runsRoot = Join-Path $RepoRoot ".claude-develop-logs\runs"
    if (-not (Test-Path -LiteralPath $runsRoot)) {
        return @()
    }

    return @(
        @(Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
            $KnownTaskNames -notcontains ([string]$_.Name)
        } | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.Name
                path = [string]$_.FullName
            }
        })
    )
}

function Invoke-GitCleanCheck {
    param([string]$RepoRoot)
    $status = Invoke-NativeCommand -Command "git" -Arguments @("status", "--porcelain") -WorkingDirectory $RepoRoot
    return (-not $status.output)
}

function Get-GitStatusLines {
    param([string]$RepoRoot)

    $status = Invoke-NativeCommand -Command "git" -Arguments @("status", "--porcelain") -WorkingDirectory $RepoRoot
    if ($status.exitCode -ne 0 -or -not $status.output) {
        return @()
    }

    return @($status.output -split "\r?\n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
}

function Get-RepoOperationBlockers {
    param([string]$RepoRoot)

    $gitDir = Get-GitDirPath -RepoRoot $RepoRoot
    $checks = @(
        @{ name = "merge"; path = Join-Path $gitDir "MERGE_HEAD"; message = "Repository has an unresolved merge in progress." }
        @{ name = "rebase"; path = Join-Path $gitDir "REBASE_HEAD"; message = "Repository has an unresolved rebase in progress." }
        @{ name = "rebase"; path = Join-Path $gitDir "rebase-merge"; message = "Repository has an unresolved rebase in progress." }
        @{ name = "rebase"; path = Join-Path $gitDir "rebase-apply"; message = "Repository has an unresolved rebase in progress." }
        @{ name = "cherry-pick"; path = Join-Path $gitDir "CHERRY_PICK_HEAD"; message = "Repository has an unresolved cherry-pick in progress." }
        @{ name = "revert"; path = Join-Path $gitDir "REVERT_HEAD"; message = "Repository has an unresolved revert in progress." }
        @{ name = "bisect"; path = Join-Path $gitDir "BISECT_LOG"; message = "Repository is in the middle of a git bisect." }
    )

    return @(
        @($checks | Where-Object { Test-Path -LiteralPath $_.path } | ForEach-Object {
            [pscustomobject]@{
                kind = [string]$_.name
                path = [string]$_.path
                message = [string]$_.message
            }
        })
    )
}

function Test-BranchMergedIntoHead {
    param(
        [string]$RepoRoot,
        [string]$BranchName
    )

    if (-not $BranchName) { return $false }

    $verifyBranch = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "--verify", $BranchName) -WorkingDirectory $RepoRoot
    if ($verifyBranch.exitCode -ne 0 -or -not $verifyBranch.output) {
        return $false
    }

    $sha = [string]$verifyBranch.output
    $ancestor = Invoke-NativeCommand -Command "git" -Arguments @("merge-base", "--is-ancestor", $sha, "HEAD") -WorkingDirectory $RepoRoot
    return ($ancestor.exitCode -eq 0)
}

function Undo-MergeAttempt {
    param([string]$RepoRoot)
    $abortResult = Invoke-NativeCommand -Command "git" -Arguments @("merge", "--abort") -WorkingDirectory $RepoRoot
    if ($abortResult.exitCode -eq 0) {
        return
    }
    $resetResult = Invoke-NativeCommand -Command "git" -Arguments @("reset", "--merge") -WorkingDirectory $RepoRoot
    if ($resetResult.exitCode -ne 0) {
        throw "Failed to abort the merge attempt: $($abortResult.output) $($resetResult.output)"
    }
}

function Remove-TaskBranch {
    param(
        [string]$RepoRoot,
        [string]$BranchName
    )

    if (-not $BranchName) { return }
    Invoke-NativeCommand -Command "git" -Arguments @("branch", "-D", $BranchName) -WorkingDirectory $RepoRoot | Out-Null
}

function Get-NormalizedComparisonText {
    param([string]$Text)

    if (-not $Text) { return "" }
    return (([string]$Text).ToLowerInvariant() -replace '\s+', ' ').Trim()
}

function Get-TaskIntegrityWarnings {
    param($Task)

    $warnings = [System.Collections.ArrayList]::new()
    $runs = @($Task.runs)
    $launchSequences = @($runs | Where-Object { [int]$_.launchSequence -gt 0 } | ForEach-Object { [int]$_.launchSequence })
    $taskNames = @($runs | ForEach-Object { [string]$_.taskName } | Where-Object { $_ })
    $resultFiles = @($runs | ForEach-Object { [string]$_.resultFile } | Where-Object { $_ })
    $maxLaunchSequence = if ($launchSequences.Count -gt 0) { (@($launchSequences | Measure-Object -Maximum).Maximum) } else { 0 }

    if ([int]$Task.attemptsUsed -gt [int]$Task.maxAttempts) {
        [void]$warnings.Add("attemptsUsed exceeds maxAttempts.")
    }
    if ([int]$Task.attemptsRemaining -ne [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)) {
        [void]$warnings.Add("attemptsRemaining does not match attemptsUsed.")
    }
    if ([int]$Task.mergeAttemptsUsed -gt [int]$Task.maxMergeAttempts) {
        [void]$warnings.Add("mergeAttemptsUsed exceeds maxMergeAttempts.")
    }
    if ([int]$Task.mergeAttemptsRemaining -ne [Math]::Max(0, [int]$Task.maxMergeAttempts - [int]$Task.mergeAttemptsUsed)) {
        [void]$warnings.Add("mergeAttemptsRemaining does not match mergeAttemptsUsed.")
    }
    if ([int]$Task.environmentRepairAttemptsUsed -gt [int]$Task.maxEnvironmentRepairAttempts) {
        [void]$warnings.Add("environmentRepairAttemptsUsed exceeds maxEnvironmentRepairAttempts.")
    }
    if ([int]$Task.environmentRepairAttemptsRemaining -ne [Math]::Max(0, [int]$Task.maxEnvironmentRepairAttempts - [int]$Task.environmentRepairAttemptsUsed)) {
        [void]$warnings.Add("environmentRepairAttemptsRemaining does not match environmentRepairAttemptsUsed.")
    }
    if ($launchSequences.Count -ne @($launchSequences | Select-Object -Unique).Count) {
        [void]$warnings.Add("runs contain duplicate launchSequence values.")
    }
    if ($taskNames.Count -ne @($taskNames | Select-Object -Unique).Count) {
        [void]$warnings.Add("runs contain duplicate taskName values.")
    }
    if ($resultFiles.Count -ne @($resultFiles | Select-Object -Unique).Count) {
        [void]$warnings.Add("runs contain duplicate resultFile values.")
    }
    if ([int]$Task.workerLaunchSequence -lt [int]$maxLaunchSequence) {
        [void]$warnings.Add("workerLaunchSequence is lower than recorded run launchSequence history.")
    }
    if (-not [string]$Task.taskText) {
        [void]$warnings.Add("taskText is missing.")
    }
    if (([string]$Task.state -in @("queued", "retry_scheduled", "environment_retry_scheduled", "running", "pending_merge", "merge_retry_scheduled", "merge_prepared", "waiting_user_test")) -and -not [string]$Task.promptFile) {
        [void]$warnings.Add("promptFile is missing for a runnable task.")
    }
    if ([string]$Task.promptFile -and -not (Test-Path -LiteralPath ([string]$Task.promptFile))) {
        [void]$warnings.Add("promptFile path does not exist.")
    }

    $latestRun = $Task.latestRun
    if ($latestRun) {
        if ([int]$latestRun.launchSequence -gt 0 -and [int]$Task.workerLaunchSequence -gt 0 -and [int]$latestRun.launchSequence -gt [int]$Task.workerLaunchSequence) {
            [void]$warnings.Add("latestRun.launchSequence exceeds workerLaunchSequence.")
        }
        if ($runs.Count -gt 0) {
            $latestRecordedRun = @($runs | Sort-Object launchSequence, completedAt | Select-Object -Last 1)[0]
            if ($latestRecordedRun) {
                if ([int]$latestRun.launchSequence -gt 0 -and [int]$latestRecordedRun.launchSequence -gt 0 -and [int]$latestRun.launchSequence -lt [int]$latestRecordedRun.launchSequence) {
                    [void]$warnings.Add("latestRun.launchSequence is older than the latest recorded run.")
                }
                if ($latestRun.taskName -and $latestRecordedRun.taskName -and [string]$latestRun.taskName -ne [string]$latestRecordedRun.taskName -and [int]$latestRun.launchSequence -eq [int]$latestRecordedRun.launchSequence) {
                    [void]$warnings.Add("latestRun.taskName conflicts with latest recorded run for the same launchSequence.")
                }
                if ($latestRun.resultFile -and $latestRecordedRun.resultFile -and [string]$latestRun.resultFile -ne [string]$latestRecordedRun.resultFile -and [int]$latestRun.launchSequence -eq [int]$latestRecordedRun.launchSequence) {
                    [void]$warnings.Add("latestRun.resultFile conflicts with latest recorded run for the same launchSequence.")
                }
                if ($latestRun.branchName -and $latestRecordedRun.branchName -and [string]$latestRun.branchName -ne [string]$latestRecordedRun.branchName -and [int]$latestRun.launchSequence -eq [int]$latestRecordedRun.launchSequence) {
                    [void]$warnings.Add("latestRun.branchName conflicts with latest recorded run for the same launchSequence.")
                }
            }
        }
    }

    return @($warnings | Select-Object -Unique)
}

function Get-StateIntegritySummary {
    param($State)

    $taskWarnings = @(
        (Get-Tasks -State $State) | ForEach-Object {
            $warnings = @(Get-TaskIntegrityWarnings -Task $_)
            if ($warnings.Count -gt 0) {
                [pscustomobject]@{
                    taskId = [string]$_.taskId
                    warnings = @($warnings)
                }
            }
        } | Where-Object { $_ }
    )

    $warningCount = if ($taskWarnings.Count -gt 0) {
        [int](@($taskWarnings | ForEach-Object { @($_.warnings).Count } | Measure-Object -Sum).Sum)
    } else {
        0
    }

    return [pscustomobject]@{
        status = if ($taskWarnings.Count -gt 0) { "warning" } else { "clean" }
        warningCount = $warningCount
        taskWarnings = @($taskWarnings)
        summary = if ($taskWarnings.Count -gt 0) { "$($taskWarnings.Count) task(s) have run bookkeeping warnings." } else { "No run bookkeeping warnings detected." }
    }
}

function Get-InvestigationEvidenceSignature {
    param($RunRecord)

    if (-not $RunRecord) { return "" }

    $reproMarker = if ([bool]$RunRecord.reproductionConfirmed) { "repro-confirmed" } else { "repro-unconfirmed" }

    $parts = @(
        (Get-NormalizedComparisonText -Text ([string]$RunRecord.finalCategory)),
        (Get-NormalizedComparisonText -Text ([string]$RunRecord.investigationConclusion)),
        $reproMarker,
        (Get-NormalizedComparisonText -Text ([string]$RunRecord.summary)),
        (Get-NormalizedComparisonText -Text ([string]$RunRecord.feedback)),
        ((Normalize-StringArray -Value $RunRecord.actualFiles) -join "|")
    )
    $payload = ($parts -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Test-InvestigationRetryHasNewEvidence {
    param(
        $PreviousRun,
        $CurrentRun
    )

    if (-not $PreviousRun -or -not $CurrentRun) { return $true }
    if ([string]$PreviousRun.finalCategory -ne "INVESTIGATION_INCONCLUSIVE") { return $true }
    if ([string]$CurrentRun.finalCategory -ne "INVESTIGATION_INCONCLUSIVE") { return $true }

    $previousSignature = Get-InvestigationEvidenceSignature -RunRecord $PreviousRun
    $currentSignature = Get-InvestigationEvidenceSignature -RunRecord $CurrentRun
    return ($previousSignature -ne $currentSignature)
}

function Get-ManualDebugReason {
    param($Task)

    $latestSummary = Get-NormalizedComparisonText -Text ([string]$Task.latestRun.summary)
    $latestFeedback = Get-NormalizedComparisonText -Text ([string]$Task.latestRun.feedback)
    if ($latestFeedback -match 'reached max turns') {
        return "Repeated inconclusive investigation hit the same max-turn limit without new evidence."
    }
    if ($latestSummary -match 'reliable change path') {
        return "Repeated inconclusive investigation could not identify a reliable change path."
    }
    return "Repeated inconclusive investigation produced no new evidence, so another cold retry would likely be blind."
}

function Get-RetryableResult {
    param(
        $Task,
        [string]$Reason
    )

    $hasBudget = ([int]$Task.attemptsUsed -lt [int]$Task.maxAttempts)
    if ($hasBudget) {
        $Task.state = "retry_scheduled"
        $Task.retryScheduled = $true
        $Task.waitingUserTest = $false
        $Task.waveNumber = 0
        $Task.blockedBy = @()
        $Task.mergeState = ""
        $Task.merge.state = ""
        $Task.merge.reason = $Reason
        $Task.manualDebugReason = ""
    } else {
        $Task.state = "completed_failed_terminal"
        $Task.retryScheduled = $false
        $Task.waitingUserTest = $false
        $Task.mergeState = "failed_terminal"
        $Task.merge.state = "failed_terminal"
        $Task.merge.reason = $Reason
        $Task.manualDebugReason = ""
    }
    $Task.attemptsRemaining = [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)
}

function Get-ManualDebugResult {
    param(
        $Task,
        [string]$Reason
    )

    $Task.state = "manual_debug_needed"
    $Task.retryScheduled = $false
    $Task.waitingUserTest = $false
    $Task.waveNumber = 0
    $Task.blockedBy = @()
    $Task.mergeState = ""
    $Task.merge.state = ""
    $Task.merge.reason = ""
    $Task.merge.branchName = ""
    $Task.manualDebugReason = if ($Reason) { [string]$Reason } else { "Repeated inconclusive investigation produced no new evidence." }
    $Task.attemptsRemaining = [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)
}

function Get-EnvironmentRetryableResult {
    param(
        $Task,
        [string]$Reason
    )

    if ([int]$Task.attemptsUsed -gt 0) {
        $Task.attemptsUsed = [int]$Task.attemptsUsed - 1
    }
    $Task.attemptsRemaining = [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)
    $Task.environmentRepairAttemptsUsed = [int]$Task.environmentRepairAttemptsUsed + 1
    $Task.environmentRepairAttemptsRemaining = [Math]::Max(0, [int]$Task.maxEnvironmentRepairAttempts - [int]$Task.environmentRepairAttemptsUsed)
    $Task.lastEnvironmentFailureCategory = [string]$Reason
    $Task.retryScheduled = $true
    $Task.waitingUserTest = $false
    $Task.waveNumber = 0
    $Task.blockedBy = @()
    $Task.mergeState = ""
    $Task.merge.state = ""
    $Task.merge.reason = [string]$Reason
    $Task.merge.branchName = ""
    $Task.manualDebugReason = ""

    if ([int]$Task.environmentRepairAttemptsUsed -lt [int]$Task.maxEnvironmentRepairAttempts) {
        $Task.state = "environment_retry_scheduled"
        return
    }

    Get-RetryableResult -Task $Task -Reason ([string]$Reason)
}

function Get-MergeRetryableResult {
    param(
        $Task,
        [string]$Reason
    )

    $Task.mergeAttemptsUsed = [int]$Task.mergeAttemptsUsed + 1
    $Task.mergeAttemptsRemaining = [Math]::Max(0, [int]$Task.maxMergeAttempts - [int]$Task.mergeAttemptsUsed)

    if ([int]$Task.mergeAttemptsUsed -lt [int]$Task.maxMergeAttempts) {
        $Task.state = "merge_retry_scheduled"
        $Task.retryScheduled = $false
        $Task.waitingUserTest = $false
        $Task.mergeState = "retry_scheduled"
        $Task.merge.state = "retry_scheduled"
        $Task.merge.reason = $Reason
        $Task.manualDebugReason = ""
        return $true
    }

    return $false
}

function Get-LockFailureInfo {
    param([string]$BuildOutput)

    $text = [string]$BuildOutput
    $pids = [System.Collections.ArrayList]::new()
    foreach ($match in [regex]::Matches($text, '(?i)\bPID\s*(\d+)\b|\((?:PID|pid)\s*(\d+)\)')) {
        $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        if ($value) {
            $pidValue = 0
            if ([int]::TryParse($value, [ref]$pidValue) -and $pids -notcontains $pidValue) {
                [void]$pids.Add($pidValue)
            }
        }
    }

    $paths = [System.Collections.ArrayList]::new()
    foreach ($match in [regex]::Matches($text, '([A-Za-z]:\\[^"\r\n]+?\.(?:dll|exe|pdb))')) {
        $pathValue = [string]$match.Groups[1].Value
        if ($pathValue -and $paths -notcontains $pathValue) {
            [void]$paths.Add($pathValue)
        }
    }

    $processHints = [System.Collections.ArrayList]::new()
    if ($text -match '(?i)Visual Studio|devenv(?:\.exe)?') { [void]$processHints.Add("devenv") }
    if ($text -match '(?i)IIS Express|iisexpress(?:\.exe)?') { [void]$processHints.Add("iisexpress") }
    if ($text -match '(?i)\bdotnet(?:\.exe)?\b') { [void]$processHints.Add("dotnet") }

    $isLockFailure =
        ($text -match '(?i)\bMSB3027\b') -or
        ($text -match '(?i)\bMSB3021\b') -or
        ($text -match '(?i)because it is being used by another process') -or
        ($text -match '(?i)unable to copy file') -or
        ($text -match '(?i)access to the path') -or
        ($text -match '(?i)file is locked')

    return [pscustomobject]@{
        isLockFailure = [bool]$isLockFailure
        processIds = @($pids)
        processHints = @($processHints | Select-Object -Unique)
        lockedPaths = @($paths)
        output = $text
    }
}

function Get-LockCandidateProcesses {
    param(
        [string]$RepoRoot,
        [string]$SolutionPath,
        $LockInfo
    )

    if ($env:AUTODEV_TEST_PROCESS_CANDIDATES) {
        try {
            $payload = $env:AUTODEV_TEST_PROCESS_CANDIDATES | ConvertFrom-Json
            return @($payload)
        } catch {
        }
    }

    $allowedNames = @("devenv", "iisexpress")
    if (@($LockInfo.processHints) -contains "dotnet") {
        $allowedNames += "dotnet"
    }

    $candidates = [System.Collections.ArrayList]::new()
    if (@($LockInfo.processIds).Count -gt 0) {
        foreach ($pid in @($LockInfo.processIds)) {
            try {
                $process = Get-Process -Id ([int]$pid) -ErrorAction Stop
                $name = [string]$process.ProcessName
                if ($allowedNames -contains $name.ToLowerInvariant()) {
                    [void]$candidates.Add([pscustomobject]@{
                        id = [int]$process.Id
                        processName = $name
                    })
                }
            } catch {
            }
        }
    }

    if ($candidates.Count -gt 0) {
        return @($candidates | Sort-Object processName, id)
    }

    foreach ($name in $allowedNames | Select-Object -Unique) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            [void]$candidates.Add([pscustomobject]@{
                id = [int]$process.Id
                processName = [string]$process.ProcessName
            })
        }
    }

    return @($candidates | Sort-Object processName, id -Unique)
}

function Invoke-TlaLockRemediation {
    param(
        [string]$RepoRoot,
        [string]$SolutionPath,
        $LockInfo
    )

    $candidates = @(Get-LockCandidateProcesses -RepoRoot $RepoRoot -SolutionPath $SolutionPath -LockInfo $LockInfo)
    $killedProcesses = [System.Collections.ArrayList]::new()

    foreach ($candidate in $candidates) {
        $killResult = Invoke-NativeCommand -Command "taskkill" -Arguments @("/PID", ([string]$candidate.id), "/T", "/F")
        [void]$killedProcesses.Add([pscustomobject]@{
            id = [int]$candidate.id
            processName = [string]$candidate.processName
            exitCode = [int]$killResult.exitCode
            output = [string]$killResult.output
        })
    }

    return [pscustomobject]@{
        attempted = ($candidates.Count -gt 0)
        candidates = @($candidates)
        killedProcesses = @($killedProcesses)
    }
}

function Invoke-MergeBuildAttempt {
    param(
        [string]$RepoRoot,
        [string]$SolutionPath,
        [string]$BranchName
    )

    $mergeCommand = Invoke-NativeCommand -Command "git" -Arguments @("merge", "--no-commit", "--no-ff", $BranchName) -WorkingDirectory $RepoRoot
    if ($mergeCommand.exitCode -ne 0) {
        Undo-MergeAttempt -RepoRoot $RepoRoot
        return [pscustomobject]@{
            success = $false
            phase = "merge"
            output = [string]$mergeCommand.output
            reason = if ($mergeCommand.output) { [string]$mergeCommand.output } else { "Merge conflict." }
        }
    }

    $restoreCommand = Invoke-NativeCommand -Command "dotnet" -Arguments @("restore", $SolutionPath) -WorkingDirectory $RepoRoot
    if ($restoreCommand.exitCode -ne 0) {
        Undo-MergeAttempt -RepoRoot $RepoRoot
        return [pscustomobject]@{
            success = $false
            phase = "restore"
            output = [string]$restoreCommand.output
            reason = if ($restoreCommand.output) { [string]$restoreCommand.output } else { "Restore failed after merge preparation." }
            lockInfo = (Get-LockFailureInfo -BuildOutput "")
        }
    }

    $buildCommand = Invoke-NativeCommand -Command "dotnet" -Arguments @("build", $SolutionPath, "--no-restore") -WorkingDirectory $RepoRoot
    if ($buildCommand.exitCode -ne 0) {
        $lockInfo = Get-LockFailureInfo -BuildOutput ([string]$buildCommand.output)
        Undo-MergeAttempt -RepoRoot $RepoRoot
        return [pscustomobject]@{
            success = $false
            phase = "build"
            output = [string]$buildCommand.output
            reason = if ($buildCommand.output) { [string]$buildCommand.output } else { "Build failed after merge preparation." }
            lockInfo = $lockInfo
        }
    }

    return [pscustomobject]@{
        success = $true
        phase = "build"
        output = [string]$buildCommand.output
        reason = "Merge prepared successfully."
        lockInfo = (Get-LockFailureInfo -BuildOutput "")
    }
}

function Apply-PipelineResultToTask {
    param(
        $Task,
        $PipelineResult,
        [string]$RepoRoot = ""
    )

    Set-ObjectProperty -Object $Task -Name "latestRun" -Value (Normalize-LatestRun -LatestRun $Task.latestRun -ResultFile ([string]$Task.resultFile))
    Set-ObjectProperty -Object $Task.latestRun -Name "finalStatus" -Value ([string]$PipelineResult.status)
    Set-ObjectProperty -Object $Task.latestRun -Name "finalCategory" -Value ([string]$PipelineResult.finalCategory)
    Set-ObjectProperty -Object $Task.latestRun -Name "summary" -Value ([string]$PipelineResult.summary)
    Set-ObjectProperty -Object $Task.latestRun -Name "feedback" -Value ([string]$PipelineResult.feedback)
    Set-ObjectProperty -Object $Task.latestRun -Name "noChangeReason" -Value ([string]$PipelineResult.noChangeReason)
    Set-ObjectProperty -Object $Task.latestRun -Name "investigationConclusion" -Value ([string]$PipelineResult.investigationConclusion)
    Set-ObjectProperty -Object $Task.latestRun -Name "reproductionConfirmed" -Value ([bool]$PipelineResult.reproductionConfirmed)
    Set-ObjectProperty -Object $Task.latestRun -Name "actualFiles" -Value @(Normalize-StringArray -Value $PipelineResult.files)
    Set-ObjectProperty -Object $Task.latestRun -Name "branchName" -Value ([string]$PipelineResult.branch)
    Set-ObjectProperty -Object $Task.latestRun -Name "artifacts" -Value $PipelineResult.artifacts
    Set-ObjectProperty -Object $Task.latestRun -Name "completedAt" -Value ((Get-Date).ToString("o"))
    Set-ObjectProperty -Object $Task.latestRun -Name "launchSequence" -Value ([int]$Task.workerLaunchSequence)

    $runRecord = [pscustomobject]@{
        attemptNumber = [int]$Task.attemptsUsed
        launchSequence = [int]$Task.workerLaunchSequence
        taskName = [string]$Task.latestRun.taskName
        finalStatus = [string]$PipelineResult.status
        finalCategory = [string]$PipelineResult.finalCategory
        summary = [string]$PipelineResult.summary
        feedback = [string]$PipelineResult.feedback
        noChangeReason = [string]$PipelineResult.noChangeReason
        investigationConclusion = [string]$PipelineResult.investigationConclusion
        reproductionConfirmed = [bool]$PipelineResult.reproductionConfirmed
        actualFiles = @($PipelineResult.files)
        branchName = [string]$PipelineResult.branch
        resultFile = [string]$Task.latestRun.resultFile
        completedAt = $Task.latestRun.completedAt
        artifacts = $PipelineResult.artifacts
    }
    $Task.runs = @($Task.runs) + @($runRecord)
    if ($RepoRoot) {
        Set-ObjectProperty -Object $Task -Name "plannerFeedback" -Value (Evaluate-PlannerPrediction -RepoRoot $RepoRoot -Task $Task)
    }

    if (Is-EnvironmentFailureCategory -Category ([string]$PipelineResult.finalCategory)) {
        Get-EnvironmentRetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
        $Task.latestRun.branchName = ""
        return
    }

    switch ([string]$PipelineResult.status) {
        "ACCEPTED" {
            $Task.state = "pending_merge"
            $Task.retryScheduled = $false
            $Task.waitingUserTest = $false
            $Task.lastEnvironmentFailureCategory = ""
            $Task.mergeState = "pending"
            $Task.merge.state = "pending"
            $Task.merge.branchName = [string]$PipelineResult.branch
            $Task.merge.reason = ""
            $Task.manualDebugReason = ""
        }
        "NO_CHANGE" {
            if ([string]$PipelineResult.finalCategory -eq "NO_CHANGE_ALREADY_SATISFIED") {
                $Task.state = "completed_no_change"
                $Task.retryScheduled = $false
                $Task.waitingUserTest = $false
                $Task.lastEnvironmentFailureCategory = ""
                $Task.mergeState = "no_change"
                $Task.merge.state = "no_change"
                $Task.merge.reason = ""
                $Task.merge.branchName = ""
                $Task.manualDebugReason = ""
            } else {
                Get-RetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
            }
        }
        "FAILED" {
            if ([string]$PipelineResult.finalCategory -eq "INVESTIGATION_INCONCLUSIVE" -and $Task.runs.Count -ge 2) {
                $currentRun = @($Task.runs)[-1]
                $previousRun = @($Task.runs)[-2]
                if ([string]$previousRun.finalCategory -eq "INVESTIGATION_INCONCLUSIVE" -and -not (Test-InvestigationRetryHasNewEvidence -PreviousRun $previousRun -CurrentRun $currentRun)) {
                    Get-ManualDebugResult -Task $Task -Reason (Get-ManualDebugReason -Task $Task)
                    break
                }
            }
            Get-RetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
        }
        default {
            Get-RetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
        }
    }

    $Task.attemptsRemaining = [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)
}

function Reconcile-TaskState {
    param(
        $Task,
        [string]$RepoRoot = ""
    )

    if ([string]$Task.state -eq "environment_retry_scheduled") {
        $latePipelineResult = Read-JsonFileBestEffort -Path $Task.latestRun.resultFile
        $lateStatus = [string]$latePipelineResult.status
        $lateCategory = [string]$latePipelineResult.finalCategory
        $canRecoverFromLateResult =
            $latePipelineResult -and (
                $lateStatus -eq "ACCEPTED" -or
                ($lateStatus -eq "NO_CHANGE" -and $lateCategory -eq "NO_CHANGE_ALREADY_SATISFIED")
            )
        if ($canRecoverFromLateResult) {
            Apply-PipelineResultToTask -Task $Task -PipelineResult $latePipelineResult -RepoRoot $RepoRoot
            return
        }
    }

    if ($RepoRoot -and $Task.state -in @("pending_merge", "merge_retry_scheduled", "merge_prepared", "waiting_user_test")) {
        $branchName = [string]$Task.latestRun.branchName
        if ($branchName -and (Invoke-GitCleanCheck -RepoRoot $RepoRoot) -and (Test-BranchMergedIntoHead -RepoRoot $RepoRoot -BranchName $branchName)) {
            $headSha = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "HEAD") -WorkingDirectory $RepoRoot
            $Task.state = "merged"
            $Task.retryScheduled = $false
            $Task.waitingUserTest = $false
            $Task.mergeState = "merged"
            $Task.merge.state = "merged"
            $Task.merge.commitSha = if ($headSha.exitCode -eq 0) { [string]$headSha.output } else { [string]$Task.merge.commitSha }
            if (-not $Task.merge.reason) {
                $Task.merge.reason = "Merged externally and reconciled from git state."
            }
            return
        }
    }

    if (-not (Is-RunningState -State $Task.state)) {
        return
    }

    $alive = Test-ProcessAlive -ProcessId ([int]$Task.latestRun.processId)
    if ($alive) {
        return
    }

    $pipelineResult = Read-JsonFileBestEffort -Path $Task.latestRun.resultFile
    if ($pipelineResult) {
        Apply-PipelineResultToTask -Task $Task -PipelineResult $pipelineResult -RepoRoot $RepoRoot
        return
    }

    Get-EnvironmentRetryableResult -Task $Task -Reason "WORKER_EXITED_WITHOUT_RESULT"
}

function Reconcile-State {
    param(
        $State,
        [string]$EventsFile = ""
    )

    $errors = @()
    foreach ($task in @(Get-Tasks -State $State)) {
        try {
            $previousState = [string]$task.state
            Ensure-TaskShape -Task $task -RepoRoot $State.repoRoot
            Reconcile-TaskState -Task $task -RepoRoot $State.repoRoot
            Ensure-TaskShape -Task $task -RepoRoot $State.repoRoot
            if ($EventsFile -and $previousState -in @("pending_merge", "merge_retry_scheduled", "merge_prepared", "waiting_user_test") -and [string]$task.state -eq "merged") {
                Append-StateEvent -EventsFile $EventsFile -TaskId ([string]$task.taskId) -Kind "external_merge_detected" -Message "Task was marked merged because its branch is already reachable from HEAD." -Data @{
                    branchName = [string]$task.latestRun.branchName
                    previousState = $previousState
                }
            }
            Write-TaskResultFile -Task $task
        } catch {
            $errorRecord = [pscustomobject]@{
                taskId = [string]$task.taskId
                phase = "reconcile"
                message = $_.Exception.Message
            }
            $errors += $errorRecord
            if ($EventsFile) {
                Append-StateEvent -EventsFile $EventsFile -TaskId ([string]$task.taskId) -Kind "reconcile_error" -Message "Task reconciliation failed." -Data $errorRecord
            }
        }
    }
    return @($errors)
}

function Test-ActiveTaskState {
    param([string]$State)
    return $State -in @("queued", "retry_scheduled", "environment_retry_scheduled", "running", "pending_merge", "merge_retry_scheduled", "merge_prepared", "waiting_user_test")
}

function Assert-TaskRecordValid {
    param(
        $Task,
        [string]$Operation
    )

    $taskId = [string]$Task.taskId
    if (-not [string]$Task.taskText) {
        throw "$Operation rejected task '$taskId' because taskText is missing."
    }
    if (-not [string]$Task.solutionPath) {
        throw "$Operation rejected task '$taskId' because solutionPath is missing."
    }
    if (-not (Test-Path -LiteralPath ([string]$Task.solutionPath))) {
        throw "$Operation rejected task '$taskId' because solutionPath does not exist: $([string]$Task.solutionPath)"
    }
    if ((Test-ActiveTaskState -State ([string]$Task.state)) -and -not [string]$Task.promptFile) {
        throw "$Operation rejected task '$taskId' because promptFile is missing."
    }
    if ([string]$Task.promptFile -and -not (Test-Path -LiteralPath ([string]$Task.promptFile))) {
        throw "$Operation rejected task '$taskId' because promptFile does not exist: $([string]$Task.promptFile)"
    }
}

function Assert-TaskIdentityUnique {
    param(
        $State,
        $Task
    )

    $matches = @((Get-Tasks -State $State) | Where-Object {
        $_.taskId -ne $Task.taskId -and
        [string]$_.taskToken -eq [string]$Task.taskToken
    })
    if ($matches.Count -gt 0) {
        throw "Task id '$([string]$Task.taskId)' collides with existing task identity token '$([string]$Task.taskToken)'."
    }
}

function New-TaskRecord {
    param(
        [string]$RepoRoot,
        [string]$DefaultSolutionPath,
        $InputTask,
        [int]$SubmissionOrder
    )

    $taskId = if ($InputTask.taskId) { [string]$InputTask.taskId } else { ([guid]::NewGuid().ToString("N")) }
    $resolvedSolutionPath = if ($InputTask.solutionPath) { Get-CanonicalPath -Path ([string]$InputTask.solutionPath) } else { $DefaultSolutionPath }
    $resolvedPromptFile = if ($InputTask.promptFile) { Get-CanonicalPath -Path ([string]$InputTask.promptFile) } else { "" }
    $resolvedPlanFile = if ($InputTask.planFile) { Get-CanonicalPath -Path ([string]$InputTask.planFile) } else { "" }
    $resultFile = if ($InputTask.resultFile) { Get-CanonicalPath -Path ([string]$InputTask.resultFile) } else { Get-DefaultTaskResultPath -RepoRoot $RepoRoot -TaskId $taskId }
    $declaredPriority = Normalize-Priority -Priority ([string]$InputTask.declaredPriority)
    $declaredDependencies = @(Normalize-StringArray -Value $InputTask.declaredDependencies)
    $serialOnly = [bool]$InputTask.serialOnly

    return [pscustomobject]@{
        taskId = $taskId
        taskToken = (Get-TaskIdentityToken -TaskId $taskId)
        sourceCommand = if ($InputTask.sourceCommand) { [string]$InputTask.sourceCommand } else { "develop" }
        sourceInputType = if ($InputTask.sourceInputType) { [string]$InputTask.sourceInputType } else { "inline" }
        taskText = [string]$InputTask.taskText
        promptFile = $resolvedPromptFile
        planFile = $resolvedPlanFile
        solutionPath = $resolvedSolutionPath
        resultFile = $resultFile
        allowNuget = [bool]$InputTask.allowNuget
        submissionOrder = $SubmissionOrder
        waveNumber = if ($InputTask.waveNumber) { [int]$InputTask.waveNumber } else { 0 }
        blockedBy = @()
        declaredDependencies = @($declaredDependencies)
        declaredPriority = $declaredPriority
        serialOnly = $serialOnly
        usageCostClass = "MEDIUM"
        usageEstimateMinutes = 20
        usageEstimateSource = "heuristic"
        maxAttempts = 3
        attemptsUsed = 0
        attemptsRemaining = 3
        workerLaunchSequence = 0
        maxEnvironmentRepairAttempts = 2
        environmentRepairAttemptsUsed = 0
        environmentRepairAttemptsRemaining = 2
        lastEnvironmentFailureCategory = ""
        manualDebugReason = ""
        maxMergeAttempts = 3
        mergeAttemptsUsed = 0
        mergeAttemptsRemaining = 3
        retryScheduled = $false
        waitingUserTest = $false
        mergeState = ""
        state = "queued"
        plannerMetadata = if ($InputTask.plannerMetadata) { $InputTask.plannerMetadata } else { [pscustomobject]@{} }
        plannerFeedback = [pscustomobject]@{}
        latestRun = (New-LatestRunRecord -ResultFile $resultFile)
        runs = @()
        merge = (New-MergeRecord)
    }
}

function Read-TaskRegistrationPayload {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if (-not $payload) {
        throw "Task registration file not found or empty: $Path"
    }

    if ($payload -is [System.Array]) {
        return @($payload)
    }
    if ($payload.tasks) {
        return @($payload.tasks)
    }
    return @($payload)
}

function Read-PlanPayload {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if (-not $payload) {
        throw "Plan file not found or empty: $Path"
    }
    return $payload
}

function Read-AdminEditPayload {
    param([string]$Path)

    $payload = Read-JsonFile -Path $Path
    if (-not $payload) {
        throw "Admin edit file not found or empty: $Path"
    }
    return $payload
}

function Is-MergeResolvedState {
    param([string]$State)
    return $State -in @("merged", "completed_no_change", "completed_failed_terminal", "discarded")
}

function Get-NextMergeCandidate {
    param($State)

    foreach ($waveNumber in @((Get-Tasks -State $State) | ForEach-Object { [int]$_.waveNumber } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)) {
        $waveTasks = @(Get-TasksInWave -State $State -WaveNumber $waveNumber)
        if ($waveTasks.Count -eq 0) {
            continue
        }

        $hasPreparedMerge = @($waveTasks | Where-Object { $_.state -in @("merge_prepared", "waiting_user_test") }).Count -gt 0
        if ($hasPreparedMerge) {
            return $null
        }

        $hasUnfinishedPipes = @($waveTasks | Where-Object { $_.state -in @("queued", "running") }).Count -gt 0
        if ($hasUnfinishedPipes) {
            return $null
        }

        $pendingMergeTask = @($waveTasks | Where-Object { $_.state -in @("pending_merge", "merge_retry_scheduled") } | Select-Object -First 1)[0]
        if ($pendingMergeTask) {
            return $pendingMergeTask
        }
    }

    return $null
}

function Get-DefaultMergeCommitMessage {
    param($Task)

    $taskText = [string]$Task.taskText
    if (-not $taskText) {
        return "Implement scheduled task"
    }

    $singleLine = (($taskText -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join " ").Trim()
    if (-not $singleLine) {
        return "Implement scheduled task"
    }
    if ($singleLine.Length -gt 72) {
        $singleLine = $singleLine.Substring(0, 72).TrimEnd()
    }
    return $singleLine
}

function Get-SchedulerContext {
    param([string]$ResolvedSolutionPath)

    $repoRoot = Get-CanonicalRepoRoot -ResolvedSolutionPath $ResolvedSolutionPath
    $paths = Get-StatePaths -RepoRoot $repoRoot
    Ensure-Directory -Path $paths.baseDir
    Ensure-Directory -Path $paths.tasksDir
    Ensure-Directory -Path $paths.resultsDir
    return [pscustomobject]@{
        repoRoot = $repoRoot
        paths = $paths
    }
}

function Get-AutoDevelopScriptPath {
    return (Join-Path (Split-Path -Path $PSCommandPath -Parent) "auto-develop.ps1")
}

function Get-WorkerPowerShellLauncher {
    $explicit = ([string]$env:AUTODEV_POWERSHELL_COMMAND).Trim()
    if ($explicit) {
        $resolvedExplicit = Get-Command -Name $explicit -ErrorAction SilentlyContinue
        if (-not $resolvedExplicit) {
            throw "Configured AUTODEV_POWERSHELL_COMMAND '$explicit' could not be resolved."
        }
        return [pscustomobject]@{
            command = [string]$resolvedExplicit.Source
            source = "AUTODEV_POWERSHELL_COMMAND"
        }
    }

    foreach ($candidate in @("pwsh", "pwsh.exe", "powershell.exe")) {
        $resolved = Get-Command -Name $candidate -ErrorAction SilentlyContinue
        if ($resolved) {
            return [pscustomobject]@{
                command = [string]$resolved.Source
                source = if ($candidate -like "pwsh*") { "pwsh_auto" } else { "powershell_fallback" }
            }
        }
    }

    throw "No supported PowerShell launcher was found. Set AUTODEV_POWERSHELL_COMMAND or install pwsh/powershell.exe."
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string]$Value)

    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-EncodedWorkerLaunchCommand {
    param(
        [string]$ScriptPath,
        [string]$PromptFile,
        [string]$SolutionPath,
        [string]$ResultFile,
        [string]$PlannerContextFile,
        [string]$TaskName,
        [string]$SchedulerTaskId,
        [string]$CommandType,
        [bool]$AllowNuget
    )

    $scriptLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $ScriptPath
    $promptLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $PromptFile
    $solutionLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $SolutionPath
    $resultLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $ResultFile
    $plannerContextLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $PlannerContextFile
    $taskNameLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $TaskName
    $taskIdLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $SchedulerTaskId
    $commandTypeLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Value $CommandType
    $allowNugetFragment = if ($AllowNuget) { " -AllowNuget" } else { "" }

    $commandText = @"
`$ErrorActionPreference = 'Stop'
& $scriptLiteral -PromptFile $promptLiteral -SolutionPath $solutionLiteral -ResultFile $resultLiteral -PlannerContextFile $plannerContextLiteral -TaskName $taskNameLiteral -SchedulerTaskId $taskIdLiteral -CommandType $commandTypeLiteral$allowNugetFragment
exit `$LASTEXITCODE
"@

    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
}

function Get-UsageProjection {
    param($State)

    $currentWave = Get-CurrentExecutionWave -State $State
    $nextWaveTasks = if ($currentWave -gt 0) {
        @((Get-Tasks -State $State) | Where-Object {
            [int]$_.waveNumber -eq $currentWave -and $_.state -in @("queued", "retry_scheduled", "environment_retry_scheduled")
        })
    } else {
        @()
    }
    $queueTasks = @((Get-Tasks -State $State) | Where-Object { $_.state -in @("queued", "retry_scheduled", "environment_retry_scheduled") })
    $runningTasks = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "running" })

    $sumMinutes = {
        param($Tasks)
        return [int](@($Tasks | ForEach-Object { [int]$_.usageEstimateMinutes } | Measure-Object -Sum).Sum)
    }

    $nextWaveMinutes = & $sumMinutes $nextWaveTasks
    $fullQueueMinutes = & $sumMinutes $queueTasks
    $runningMinutes = & $sumMinutes $runningTasks
    $risk = if ($fullQueueMinutes -ge 120) { "HIGH" } elseif ($fullQueueMinutes -ge 45) { "MEDIUM" } else { "LOW" }

    return [pscustomobject]@{
        currentWave = $currentWave
        runningEstimatedMinutes = $runningMinutes
        nextWaveEstimatedMinutes = $nextWaveMinutes
        fullQueueEstimatedMinutes = $fullQueueMinutes
        projectedRisk = $risk
        recommendedApprovalScope = if ($risk -eq "HIGH") { "next_wave_only" } else { "current_plan" }
    }
}

function Get-PlannerFeedbackSummary {
    param($State)

    $evaluated = @(
        (Get-Tasks -State $State) |
            Where-Object { $_.plannerFeedback -and $_.plannerFeedback.predictionEvaluated } |
            Sort-Object submissionOrder |
            Select-Object -Last 20
    )
    $hitRates = @($evaluated | ForEach-Object { [double]$_.plannerFeedback.predictionHitRate })
    return [pscustomobject]@{
        evaluatedTasks = $evaluated.Count
        averageHitRate = if ($hitRates.Count -gt 0) { [Math]::Round((($hitRates | Measure-Object -Average).Average), 2) } else { 0 }
        tightCount = @($evaluated | Where-Object { $_.plannerFeedback.classification -eq "tight" }).Count
        acceptableCount = @($evaluated | Where-Object { $_.plannerFeedback.classification -eq "acceptable" }).Count
        broadCount = @($evaluated | Where-Object { $_.plannerFeedback.classification -eq "broad" }).Count
        missedCount = @($evaluated | Where-Object { $_.plannerFeedback.classification -eq "missed" }).Count
        recent = @($evaluated | ForEach-Object {
            [pscustomobject]@{
                taskId = [string]$_.taskId
                hitRate = [double]$_.plannerFeedback.predictionHitRate
                classification = [string]$_.plannerFeedback.classification
                notes = [string]$_.plannerFeedback.predictionNotes
            }
        })
    }
}

function Clip-DiscoveryBriefText {
    param(
        [string]$Text,
        [int]$MaxLength = 180
    )

    if (-not $Text) { return "" }
    $value = ([string]$Text -replace '\s+', ' ').Trim()
    if (-not $value) { return "" }
    if ($value.Length -le $MaxLength) { return $value }
    return ($value.Substring(0, [Math]::Max(0, $MaxLength - 3)).TrimEnd() + "...")
}

function Get-DiscoveryBriefConflictHint {
    param($Task)

    $classification = [string]$Task.plannerFeedback.classification
    $likelyAreas = @(Normalize-StringArray -Value $Task.plannerMetadata.likelyAreas)
    $likelyFiles = @(Normalize-StringArray -Value $Task.plannerMetadata.likelyFiles)
    $actualFiles = @(Normalize-StringArray -Value $Task.latestRun.actualFiles)

    if ($actualFiles.Count -gt 0 -and $likelyAreas.Count -gt 0) {
        return (Clip-DiscoveryBriefText -Text ("Touches " + ($actualFiles.Count) + " changed file(s) in area(s): " + (($likelyAreas | Select-Object -First 2) -join ", ") + ".") -MaxLength 160)
    }
    if ($classification -eq "broad" -and $likelyFiles.Count -gt 0) {
        return (Clip-DiscoveryBriefText -Text ("Prior scope prediction was broad around: " + (($likelyFiles | Select-Object -First 2) -join ", ") + ".") -MaxLength 160)
    }
    if ($classification -eq "missed" -and $actualFiles.Count -gt 0) {
        return (Clip-DiscoveryBriefText -Text ("Actual files diverged from the original prediction; changed: " + (($actualFiles | Select-Object -First 2) -join ", ") + ".") -MaxLength 160)
    }
    return ""
}

function Get-TaskDiscoveryBrief {
    param($Task)

    if (-not $Task) { return $null }
    $state = [string]$Task.state
    if ($state -notin @("merged", "pending_merge", "completed_no_change", "completed_failed_terminal")) {
        return $null
    }

    $taskSummary = Clip-DiscoveryBriefText -Text ([string]$Task.taskText) -MaxLength 180
    $whatWasBuilt = Clip-DiscoveryBriefText -Text ([string]$Task.latestRun.summary) -MaxLength 220
    $investigationConclusion = Clip-DiscoveryBriefText -Text ([string]$Task.latestRun.investigationConclusion) -MaxLength 180
    $failureText = Clip-DiscoveryBriefText -Text ([string]$Task.latestRun.feedback) -MaxLength 180
    $filesChanged = @((Normalize-StringArray -Value $Task.latestRun.actualFiles) | Select-Object -First 6)
    $discoveries = [System.Collections.ArrayList]::new()

    if ($investigationConclusion) {
        [void]$discoveries.Add($investigationConclusion)
    }
    if ($whatWasBuilt -and $whatWasBuilt -ne $taskSummary -and $whatWasBuilt -ne $investigationConclusion) {
        [void]$discoveries.Add((Clip-DiscoveryBriefText -Text $whatWasBuilt -MaxLength 180))
    }
    $discoveries = @($discoveries | Select-Object -Unique | Select-Object -First 2)

    $failures = @()
    if ($state -eq "completed_failed_terminal" -and $failureText) {
        $failures = @($failureText)
    }

    $conflictHint = Get-DiscoveryBriefConflictHint -Task $Task
    $hasSignal = $taskSummary -or $whatWasBuilt -or $discoveries.Count -gt 0 -or $failures.Count -gt 0 -or $filesChanged.Count -gt 0
    if (-not $hasSignal) { return $null }

    return [pscustomobject]@{
        taskId = [string]$Task.taskId
        waveNumber = [int]$Task.waveNumber
        status = [string]$Task.latestRun.finalStatus
        finalCategory = [string]$Task.latestRun.finalCategory
        taskSummary = $taskSummary
        whatWasBuilt = $whatWasBuilt
        discoveries = @($discoveries)
        failures = @($failures)
        filesChanged = @($filesChanged)
        conflictHints = $conflictHint
    }
}

function Get-DiscoveryBriefPriority {
    param($Task)

    switch ([string]$Task.state) {
        "merged" { return 4 }
        "pending_merge" { return 3 }
        "completed_no_change" { return 2 }
        "completed_failed_terminal" { return 1 }
        default { return 0 }
    }
}

function Get-CompletedTaskBriefs {
    param($State)

    $tasks = @((Get-Tasks -State $State) | Where-Object {
        $_ -and [string]$_.state -in @("merged", "pending_merge", "completed_no_change", "completed_failed_terminal")
    })

    $ordered = @($tasks | Sort-Object @{
        Expression = { Get-DiscoveryBriefPriority -Task $_ }
        Descending = $true
    }, @{
        Expression = {
            $completedAt = [string]$_.latestRun.completedAt
            if ($completedAt) {
                try { return [datetime]$completedAt } catch { }
            }
            return [datetime]::MinValue
        }
        Descending = $true
    }, @{
        Expression = { [int]$_.submissionOrder }
        Descending = $true
    })

    return @(
        $ordered |
            ForEach-Object { Get-TaskDiscoveryBrief -Task $_ } |
            Where-Object { $_ } |
            Select-Object -First 8
    )
}

function Get-TaskMergePreview {
    param(
        [string]$RepoRoot,
        $Task
    )

    $result = Read-JsonFile -Path ([string]$Task.latestRun.resultFile)
    $branchName = [string]$Task.latestRun.branchName
    $diffStat = ""
    if ($branchName) {
        $diffResult = Invoke-NativeCommand -Command "git" -Arguments @("diff", "--stat", "HEAD..$branchName") -WorkingDirectory $RepoRoot
        if ($diffResult.exitCode -eq 0) {
            $diffStat = [string]$diffResult.output
        }
    }

    return [pscustomobject]@{
        taskSummary = Get-TaskSummaryText -Task $Task
        actualFiles = @($Task.latestRun.actualFiles | Select-Object -First 10)
        diffStat = $diffStat
        reviewVerdict = if ($Task.latestRun.finalStatus -eq "ACCEPTED") { "APPROVED" } elseif ($Task.latestRun.finalStatus) { [string]$Task.latestRun.finalStatus } else { "" }
        reviewSeverity = if ($result -and $result.severity) { [string]$result.severity } else { "" }
        reviewSummary = [string]$Task.latestRun.summary
        preflightPassed = [bool]($Task.latestRun.finalStatus -eq "ACCEPTED")
        preflightBlockerCount = 0
        preflightWarningCount = 0
        reproVerified = [bool]($result -and $result.reproductionConfirmed)
        artifactsAvailable = [bool]($Task.latestRun.artifacts)
    }
}

function Get-SnapshotPayload {
    param(
        $State,
        [string]$EventsFile = "",
        [object[]]$ReconcileErrors = @()
    )

    $script:CurrentSnapshotRepoRoot = [string]$State.repoRoot
    $knownBranches = Get-KnownBranches -State $State
    $unknownBranches = Get-UnknownAutoBranches -RepoRoot $State.repoRoot -KnownBranches $knownBranches
    $nextMergeTask = Get-NextMergeCandidate -State $State
    $mergePreparedTask = Get-MergePreparedTask -State $State
    $breaker = Update-CircuitBreakerState -State $State
    $usageProjection = Get-UsageProjection -State $State
    $plannerFeedbackSummary = Get-PlannerFeedbackSummary -State $State
    $completedTaskBriefs = Get-CompletedTaskBriefs -State $State
    $recentEvents = Get-RecentQueueEvents -EventsFile $EventsFile
    $tasks = @((Get-Tasks -State $State) | Sort-Object waveNumber, submissionOrder)
    $stateIntegrity = Get-StateIntegritySummary -State $State
    $taskSnapshots = @($tasks | ForEach-Object { ConvertTo-TaskSnapshot -Task $_ -RepoRoot $State.repoRoot })
    $startableTaskIds = @(Get-StartableTaskIds -State $State)
    $runningTaskProgress = @($taskSnapshots | Where-Object { $_.state -eq "running" } | ForEach-Object {
        [pscustomobject]@{
            taskId = [string]$_.taskId
            taskText = [string]$_.taskText
            waveNumber = [int]$_.waveNumber
            progress = $_.progress
        }
    })
    $queuedTaskProgress = @($taskSnapshots | Where-Object { $_.state -in @("queued", "retry_scheduled", "environment_retry_scheduled", "manual_debug_needed", "merge_retry_scheduled") } | ForEach-Object {
        [pscustomobject]@{
            taskId = [string]$_.taskId
            taskText = [string]$_.taskText
            waveNumber = [int]$_.waveNumber
            progress = $_.progress
        }
    })
    $mergeTaskProgress = if ($mergePreparedTask) {
        [pscustomobject]@{
            taskId = [string]$mergePreparedTask.taskId
            taskText = [string]$mergePreparedTask.taskText
            progress = (ConvertTo-TaskSnapshot -Task $mergePreparedTask -RepoRoot $State.repoRoot).progress
        }
    } elseif ($nextMergeTask) {
        [pscustomobject]@{
            taskId = [string]$nextMergeTask.taskId
            taskText = [string]$nextMergeTask.taskText
            progress = (ConvertTo-TaskSnapshot -Task $nextMergeTask -RepoRoot $State.repoRoot).progress
        }
    } else {
        $null
    }
    $queueStall = Get-QueueStallSummary -State $State -StartableTaskIds $startableTaskIds -NextMergeTask $nextMergeTask -MergePreparedTask $mergePreparedTask -CircuitBreaker $breaker -ReconcileErrors $ReconcileErrors

    return [pscustomobject]@{
        repoRoot = $State.repoRoot
        updatedAt = [string]$State.updatedAt
        lastPlanAppliedAt = [string]$State.lastPlanAppliedAt
        tasks = $taskSnapshots
        runningTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "running" } | ForEach-Object { [string]$_.taskId })
        queuedTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "queued" } | ForEach-Object { [string]$_.taskId })
        retryTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "retry_scheduled" } | ForEach-Object { [string]$_.taskId })
        environmentRetryTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "environment_retry_scheduled" } | ForEach-Object { [string]$_.taskId })
        manualDebugTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "manual_debug_needed" } | ForEach-Object { [string]$_.taskId })
        mergeRetryTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "merge_retry_scheduled" } | ForEach-Object { [string]$_.taskId })
        pendingMergeTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "pending_merge" } | ForEach-Object { [string]$_.taskId })
        startableTaskIds = @($startableTaskIds)
        nextMergeTaskId = if ($nextMergeTask) { [string]$nextMergeTask.taskId } else { "" }
        mergePreparedTaskId = if ($mergePreparedTask) { [string]$mergePreparedTask.taskId } else { "" }
        mergePreparedPreview = if ($mergePreparedTask) { Get-TaskMergePreview -RepoRoot $State.repoRoot -Task $mergePreparedTask } else { $null }
        unknownAutoBranches = @($unknownBranches)
        plannerFeedbackSummary = $plannerFeedbackSummary
        completedTaskBriefs = @($completedTaskBriefs)
        usageProjection = $usageProjection
        stateIntegrity = $stateIntegrity
        hasIntegrityWarnings = [bool]($stateIntegrity.status -eq "warning")
        circuitBreaker = $breaker
        queueStall = $queueStall
        needsReplan = [bool]($queueStall.status -eq "stalled")
        queueProgressSummary = Get-QueueProgressSummary -State $State
        runningTaskProgress = $runningTaskProgress
        queuedTaskProgress = $queuedTaskProgress
        mergeTaskProgress = $mergeTaskProgress
        recentQueueEvents = $recentEvents
        schedulerHealthy = (@($ReconcileErrors).Count -eq 0)
        reconcileErrors = @($ReconcileErrors)
    }
}

function Snapshot-Queue {
    param([string]$ResolvedSolutionPath)

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $reconcileErrors = @(Reconcile-State -State $state -EventsFile $context.paths.eventsFile)
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state
        return (Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile -ReconcileErrors $reconcileErrors)
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Get-WaitQueueSignature {
    param($Snapshot)

    $tasks = @($Snapshot.tasks | Sort-Object waveNumber, submissionOrder, taskId | ForEach-Object {
        [pscustomobject]@{
            taskId = [string]$_.taskId
            state = [string]$_.state
            processId = [int]$_.processId
            completedAt = [string]$_.completedAt
            finalStatus = [string]$_.finalStatus
            finalCategory = [string]$_.finalCategory
            mergeState = [string]$_.mergeState
            waitingUserTest = [bool]$_.waitingUserTest
        }
    })

    $signaturePayload = [pscustomobject]@{
        tasks = $tasks
        circuitBreakerStatus = [string]$Snapshot.circuitBreaker.status
        mergePreparedTaskId = [string]$Snapshot.mergePreparedTaskId
        nextMergeTaskId = [string]$Snapshot.nextMergeTaskId
    }

    return ($signaturePayload | ConvertTo-Json -Depth 16 -Compress)
}

function Get-WaitQueueSnapshotState {
    param([string]$ResolvedSolutionPath)

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $preReconcileRunningTaskIds = @((Get-Tasks -State $state) | Where-Object { [string]$_.state -eq "running" } | ForEach-Object { [string]$_.taskId })
        $beforeStateJson = ($state | ConvertTo-Json -Depth 32 -Compress)
        $reconcileErrors = @(Reconcile-State -State $state -EventsFile $context.paths.eventsFile)
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        $afterStateJson = ($state | ConvertTo-Json -Depth 32 -Compress)
        if ($afterStateJson -ne $beforeStateJson) {
            Save-State -StateFile $context.paths.stateFile -State $state
        }

        $snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile -ReconcileErrors $reconcileErrors
        return [pscustomobject]@{
            preReconcileRunningTaskIds = @($preReconcileRunningTaskIds)
            snapshot = $snapshot
            signature = Get-WaitQueueSignature -Snapshot $snapshot
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function New-WaitQueueResponse {
    param(
        [string]$Status,
        [string]$Reason,
        [datetime]$WaitStartedAt,
        [string[]]$CompletedTaskIds,
        $SnapshotState
    )

    $waitEndedAt = Get-Date
    $snapshot = $SnapshotState.snapshot
    return [pscustomobject]@{
        status = $Status
        reason = $Reason
        waitStartedAt = $WaitStartedAt.ToString("o")
        waitEndedAt = $waitEndedAt.ToString("o")
        elapsedSeconds = [int][Math]::Floor(($waitEndedAt - $WaitStartedAt).TotalSeconds)
        completedTaskIds = @($CompletedTaskIds)
        mergePreparedTaskId = [string]$snapshot.mergePreparedTaskId
        waitingUserTestTaskIds = @($snapshot.tasks | Where-Object { [string]$_.state -eq "waiting_user_test" } | ForEach-Object { [string]$_.taskId })
        runningTaskIds = @($snapshot.runningTaskIds)
        queueProgressSummary = $snapshot.queueProgressSummary
        runningTaskProgress = $snapshot.runningTaskProgress
        queuedTaskProgress = $snapshot.queuedTaskProgress
        mergeTaskProgress = $snapshot.mergeTaskProgress
        recentQueueEvents = $snapshot.recentQueueEvents
        snapshot = $snapshot
    }
}

function Wait-Queue {
    param(
        [string]$ResolvedSolutionPath,
        [int]$WaitTimeoutSeconds = 7200,
        [int]$IdlePollSeconds = 2,
        [bool]$WakeOnAnyCompletion = $true,
        [bool]$WakeOnMergeReady = $true,
        [bool]$WakeOnBreakerOpen = $true
    )

    $effectiveTimeoutSeconds = [Math]::Max(0, $WaitTimeoutSeconds)
    $effectivePollSeconds = [Math]::Max(1, $IdlePollSeconds)
    $waitStartedAt = Get-Date
    $deadline = $waitStartedAt.AddSeconds($effectiveTimeoutSeconds)

    $baselineState = Get-WaitQueueSnapshotState -ResolvedSolutionPath $ResolvedSolutionPath
    $baselineSnapshot = $baselineState.snapshot
    $baselineSignature = [string]$baselineState.signature
    $baselineRunningTaskIds = @(@($baselineState.preReconcileRunningTaskIds) + @($baselineSnapshot.runningTaskIds) | Where-Object { $_ } | Select-Object -Unique)

    while ($true) {
        $currentState = if ($baselineState) {
            $baselineState
        } else {
            Get-WaitQueueSnapshotState -ResolvedSolutionPath $ResolvedSolutionPath
        }
        $baselineState = $null
        $currentSnapshot = $currentState.snapshot
        $currentSignature = [string]$currentState.signature
        $completedTaskIds = @($baselineRunningTaskIds | Where-Object { $currentSnapshot.runningTaskIds -notcontains $_ })

        if ($WakeOnBreakerOpen -and [string]$currentSnapshot.circuitBreaker.status -notin @("closed", "manual_override")) {
            return (New-WaitQueueResponse -Status "woke" -Reason "breaker_opened" -WaitStartedAt $waitStartedAt -CompletedTaskIds $completedTaskIds -SnapshotState $currentState)
        }

        $hasMergeReady = ([string]$currentSnapshot.mergePreparedTaskId) -or @($currentSnapshot.tasks | Where-Object { [string]$_.state -eq "waiting_user_test" }).Count -gt 0
        if ($WakeOnMergeReady -and $hasMergeReady) {
            return (New-WaitQueueResponse -Status "woke" -Reason "merge_ready" -WaitStartedAt $waitStartedAt -CompletedTaskIds $completedTaskIds -SnapshotState $currentState)
        }

        if ($WakeOnAnyCompletion -and $completedTaskIds.Count -gt 0) {
            return (New-WaitQueueResponse -Status "woke" -Reason "task_completed" -WaitStartedAt $waitStartedAt -CompletedTaskIds $completedTaskIds -SnapshotState $currentState)
        }

        if ($currentSignature -ne $baselineSignature) {
            return (New-WaitQueueResponse -Status "woke" -Reason "queue_changed" -WaitStartedAt $waitStartedAt -CompletedTaskIds $completedTaskIds -SnapshotState $currentState)
        }

        if ((Get-Date) -ge $deadline) {
            return (New-WaitQueueResponse -Status "timeout" -Reason "timeout" -WaitStartedAt $waitStartedAt -CompletedTaskIds $completedTaskIds -SnapshotState $currentState)
        }

        Start-Sleep -Seconds $effectivePollSeconds
    }
}

function Prepare-Environment {
    param([string]$ResolvedSolutionPath)

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $reconcileErrors = @(Reconcile-State -State $state -EventsFile $context.paths.eventsFile)
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile

        $dirtyFiles = @(Get-GitStatusLines -RepoRoot $context.repoRoot)
        $repoBlockers = @(Get-RepoOperationBlockers -RepoRoot $context.repoRoot)
        $protectedBranchReferences = @(Get-PrepareProtectedBranchReferences -State $state)
        $protectedLaunchArtifactReferences = @(Get-PrepareProtectedLaunchArtifactReferences -State $state)
        $gitWorktreeEntries = @(Get-GitWorktreeEntries -RepoRoot $context.repoRoot)
        $unknownAutoBranches = @(Get-UnknownAutoBranches -RepoRoot $context.repoRoot -KnownBranches $protectedBranchReferences)
        $unknownAutoWorktrees = @(Get-UnknownAutoWorktrees -RepoRoot $context.repoRoot -KnownTaskNames $protectedLaunchArtifactReferences -GitWorktreeEntries $gitWorktreeEntries)
        $orphanedRunArtifacts = @(Get-OrphanedRunArtifacts -RepoRoot $context.repoRoot -KnownTaskNames $protectedLaunchArtifactReferences)
        $cleanupActions = [System.Collections.ArrayList]::new()
        $cleanupWarnings = [System.Collections.ArrayList]::new()

        $repoState = [pscustomobject]@{
            repoRoot = $context.repoRoot
            dirty = ($dirtyFiles.Count -gt 0)
            dirtyFiles = @($dirtyFiles)
            operationBlockers = @($repoBlockers)
            gitWorktreeCount = @($gitWorktreeEntries).Count
        }

        $blocked = ($dirtyFiles.Count -gt 0) -or ($repoBlockers.Count -gt 0) -or ($reconcileErrors.Count -gt 0)
        if (-not $blocked) {
            $currentBranch = Get-CurrentBranchName -RepoRoot $context.repoRoot
            $attachedWorktreeBranches = @($gitWorktreeEntries | ForEach-Object { [string]$_.branch } | Where-Object { $_ } | Select-Object -Unique)

            Invoke-NativeCommand -Command "git" -Arguments @("worktree", "prune") -WorkingDirectory $context.repoRoot | Out-Null

            foreach ($branchName in $unknownAutoBranches) {
                if ($branchName -eq $currentBranch -or $attachedWorktreeBranches -contains $branchName) {
                    [void]$cleanupWarnings.Add("AutoDevelop branch '$branchName' was left in place because it is currently checked out or attached to a worktree.")
                    continue
                }

                if (-not (Test-BranchMergedIntoHead -RepoRoot $context.repoRoot -BranchName $branchName)) {
                    [void]$cleanupWarnings.Add("AutoDevelop branch '$branchName' was left in place because it is not merged into HEAD.")
                    continue
                }

                Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName $branchName
                [void]$cleanupActions.Add([pscustomobject]@{
                    kind = "remove_auto_branch"
                    target = [string]$branchName
                    detail = "Removed stale merged AutoDevelop branch."
                })
                Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId "" -Kind "prepare_cleanup" -Message "Removed stale AutoDevelop branch." -Data @{ branchName = [string]$branchName }
            }

            foreach ($worktree in $unknownAutoWorktrees) {
                try {
                    Remove-Item -LiteralPath ([string]$worktree.path) -Recurse -Force -ErrorAction Stop
                    [void]$cleanupActions.Add([pscustomobject]@{
                        kind = "remove_auto_worktree"
                        target = [string]$worktree.path
                        detail = "Removed stale AutoDevelop worktree directory."
                    })
                    Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId "" -Kind "prepare_cleanup" -Message "Removed stale AutoDevelop worktree directory." -Data @{ path = [string]$worktree.path }
                } catch {
                    [void]$cleanupWarnings.Add("Failed to remove stale AutoDevelop worktree '$([string]$worktree.path)': $($_.Exception.Message)")
                }
            }

            foreach ($artifact in $orphanedRunArtifacts) {
                try {
                    Remove-Item -LiteralPath ([string]$artifact.path) -Recurse -Force -ErrorAction Stop
                    [void]$cleanupActions.Add([pscustomobject]@{
                        kind = "remove_run_artifact"
                        target = [string]$artifact.path
                        detail = "Removed orphaned AutoDevelop run artifact directory."
                    })
                    Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId "" -Kind "prepare_cleanup" -Message "Removed orphaned AutoDevelop run artifact directory." -Data @{ path = [string]$artifact.path }
                } catch {
                    [void]$cleanupWarnings.Add("Failed to remove orphaned run artifact '$([string]$artifact.path)': $($_.Exception.Message)")
                }
            }
        }

        Save-State -StateFile $context.paths.stateFile -State $state

        $postProtectedBranchReferences = @(Get-PrepareProtectedBranchReferences -State $state)
        $postProtectedLaunchArtifactReferences = @(Get-PrepareProtectedLaunchArtifactReferences -State $state)
        $postGitWorktreeEntries = @(Get-GitWorktreeEntries -RepoRoot $context.repoRoot)
        $postUnknownAutoBranches = @(Get-UnknownAutoBranches -RepoRoot $context.repoRoot -KnownBranches $postProtectedBranchReferences)
        $postUnknownAutoWorktrees = @(Get-UnknownAutoWorktrees -RepoRoot $context.repoRoot -KnownTaskNames $postProtectedLaunchArtifactReferences -GitWorktreeEntries $postGitWorktreeEntries)
        $snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile -ReconcileErrors $reconcileErrors
        $status = if ($blocked) {
            "blocked"
        } elseif ($cleanupActions.Count -gt 0) {
            "cleaned"
        } elseif ($cleanupWarnings.Count -gt 0 -or $postUnknownAutoBranches.Count -gt 0 -or $postUnknownAutoWorktrees.Count -gt 0 -or [string]$snapshot.stateIntegrity.status -eq "warning") {
            "warning"
        } else {
            "ready"
        }

        $summary = switch ($status) {
            "blocked" { "Prepare blocked because the repository or scheduler state is not safe for AutoDevelop startup." }
            "cleaned" { "Prepare cleaned stale AutoDevelop-owned leftovers and reconciled the scheduler state." }
            "warning" { "Prepare completed with warnings; AutoDevelop can continue, but some leftovers or integrity warnings remain." }
            default { "Prepare confirmed that the repository and scheduler state are ready." }
        }

        return [pscustomobject]@{
            ready = [bool]($status -ne "blocked")
            status = $status
            summary = $summary
            repoState = $repoState
            schedulerState = [pscustomobject]@{
                healthy = [bool]($reconcileErrors.Count -eq 0)
                reconcileErrors = @($reconcileErrors)
                queueStall = $snapshot.queueStall
                circuitBreaker = $snapshot.circuitBreaker
            }
            cleanupActions = @($cleanupActions)
            cleanupWarnings = @($cleanupWarnings)
            unknownAutoBranches = @($postUnknownAutoBranches)
            unknownAutoWorktrees = @($postUnknownAutoWorktrees)
            dirtyFiles = @($dirtyFiles)
            integrityWarnings = @($snapshot.stateIntegrity.taskWarnings)
            snapshot = $snapshot
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Register-Tasks {
    param(
        [string]$ResolvedSolutionPath,
        [string]$ResolvedTasksFile
    )

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $registrationTasks = @(Read-TaskRegistrationPayload -Path $ResolvedTasksFile)

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $null = Reconcile-State -State $state -EventsFile $context.paths.eventsFile

        $submissionOrder = Get-SubmissionOrder -State $state
        $registered = [System.Collections.ArrayList]::new()

        foreach ($inputTask in $registrationTasks) {
            $task = New-TaskRecord -RepoRoot $context.repoRoot -DefaultSolutionPath $ResolvedSolutionPath -InputTask $inputTask -SubmissionOrder $submissionOrder
            Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
            Assert-TaskRecordValid -Task $task -Operation "register-tasks"
            Update-TaskUsageEstimate -State $state -Task $task
            if (Get-TaskById -State $state -TaskId $task.taskId) {
                throw "Task id '$($task.taskId)' is already registered."
            }
            Assert-TaskIdentityUnique -State $state -Task $task
            $state.tasks = @($state.tasks) + @($task)
            Write-TaskResultFile -Task $task
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "registered" -Message "Task registered." -Data @{ sourceCommand = $task.sourceCommand; sourceInputType = $task.sourceInputType }
            [void]$registered.Add((ConvertTo-TaskSnapshot -Task $task -RepoRoot $context.repoRoot))
            $submissionOrder += 1
        }

        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state

        return [pscustomobject]@{
            registered = @($registered)
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Apply-Plan {
    param(
        [string]$ResolvedSolutionPath,
        [string]$ResolvedPlanFile
    )

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $planPayload = Read-PlanPayload -Path $ResolvedPlanFile
    $assignments = if ($planPayload.tasks) { @($planPayload.tasks) } elseif ($planPayload.assignments) { @($planPayload.assignments) } else { @() }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $null = Reconcile-State -State $state -EventsFile $context.paths.eventsFile

        foreach ($assignment in $assignments) {
            if (-not $assignment.taskId) { continue }
            $task = Get-TaskById -State $state -TaskId ([string]$assignment.taskId)
            if (-not $task) { continue }
            if (Is-TerminalState -State $task.state) { continue }

            if ($assignment.waveNumber) { $task.waveNumber = [int]$assignment.waveNumber }
            Set-ObjectProperty -Object $task -Name "blockedBy" -Value ([object[]](Normalize-StringArray -Value $assignment.blockedBy))
            if ($assignment.plannerMetadata) {
                $task.plannerMetadata = $assignment.plannerMetadata
            }
            if ($assignment.plannedState -and ([string]$task.state -in @("queued", "retry_scheduled", "environment_retry_scheduled", "manual_debug_needed"))) {
                $task.state = [string]$assignment.plannedState
            }
            if ([string]$task.state -eq "manual_debug_needed" -and [int]$task.waveNumber -gt 0 -and -not $assignment.plannedState) {
                $task.state = "queued"
                $task.retryScheduled = $false
            }
            Update-TaskUsageEstimate -State $state -Task $task
            Write-TaskResultFile -Task $task
        }

        foreach ($task in @(Get-Tasks -State $state | Where-Object { -not (Is-TerminalState -State $_.state) })) {
            foreach ($dependencyId in @($task.declaredDependencies)) {
                $dependencyTask = Get-TaskById -State $state -TaskId ([string]$dependencyId)
                if (-not $dependencyTask) {
                    throw "Plan rejected because task '$($task.taskId)' declares unknown dependency '$dependencyId'."
                }
                if ([int]$task.waveNumber -le [int]$dependencyTask.waveNumber) {
                    throw "Plan rejected because task '$($task.taskId)' does not respect declared dependency '$dependencyId'."
                }
                if (@($task.blockedBy) -notcontains [string]$dependencyTask.taskId) {
                    Set-ObjectProperty -Object $task -Name "blockedBy" -Value (@(@($task.blockedBy) + @([string]$dependencyTask.taskId) | Select-Object -Unique))
                }
            }
            if ([bool]$task.serialOnly) {
                $sameWave = @((Get-Tasks -State $state) | Where-Object {
                    $_.taskId -ne $task.taskId -and
                    -not (Is-TerminalState -State $_.state) -and
                    [int]$_.waveNumber -eq [int]$task.waveNumber
                })
                if ($sameWave.Count -gt 0) {
                    throw "Plan rejected because serial-only task '$($task.taskId)' shares wave $($task.waveNumber)."
                }
            }
        }

        $state.lastPlanAppliedAt = (Get-Date).ToString("o")
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId "" -Kind "plan_applied" -Message "Planner output applied." -Data @{
            summary = [string]$planPayload.summary
            startableTaskIds = @(Get-StartableTaskIds -State $state)
        }

        return [pscustomobject]@{
            summary = [string]$planPayload.summary
            startableTaskIds = @(Get-StartableTaskIds -State $state)
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Run-Task {
    param(
        [string]$ResolvedSolutionPath,
        [string]$TaskId
    )

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $autoDevelopScript = Get-AutoDevelopScriptPath
    if (-not (Test-Path -LiteralPath $autoDevelopScript)) {
        throw "auto-develop.ps1 was not found."
    }
    $workerLauncher = Get-WorkerPowerShellLauncher

    $task = $null
    $pipelineResultPath = ""
    $attemptNumber = 0
    $launchSequence = 0
    $artifactPointers = $null
    $workerOutputFile = ""
    $workerErrorFile = ""

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $null = Reconcile-State -State $state -EventsFile $context.paths.eventsFile
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) {
            throw "Task '$TaskId' was not found."
        }
        if (-not (Is-QueueState -State $task.state)) {
            throw "Task '$TaskId' is not in a startable state."
        }
        if ((Get-StartableTaskIds -State $state) -notcontains $TaskId) {
            throw "Task '$TaskId' is not startable in the current wave."
        }
        Assert-TaskRecordValid -Task $task -Operation "run-task"

        $task.state = "running"
        $task.retryScheduled = $false
        $task.waitingUserTest = $false
        $task.manualDebugReason = ""
        $task.mergeState = ""
        $task.mergeAttemptsUsed = 0
        $task.mergeAttemptsRemaining = [int]$task.maxMergeAttempts
        $task.attemptsUsed = [int]$task.attemptsUsed + 1
        $task.attemptsRemaining = [Math]::Max(0, [int]$task.maxAttempts - [int]$task.attemptsUsed)
        $task.workerLaunchSequence = [int]$task.workerLaunchSequence + 1
        $attemptNumber = [int]$task.attemptsUsed
        $launchSequence = [int]$task.workerLaunchSequence
        $pipelineResultPath = Join-Path $context.paths.tasksDir "$TaskId-launch-$launchSequence-result.json"
        $plannerContextPath = Join-Path $context.paths.tasksDir "$TaskId-launch-$launchSequence-planner-context.json"
        $taskName = Get-AttemptTaskName -TaskId $TaskId -SourceCommand $task.sourceCommand -LaunchSequence $launchSequence
        $runDir = Join-Path (Join-Path $context.repoRoot ".claude-develop-logs\runs") $taskName
        $artifactPointers = [pscustomobject]@{
            runDir = $runDir
            schedulerSnapshotPath = Join-Path $runDir "scheduler-snapshot.json"
            timelinePath = Join-Path $runDir "timeline.json"
            resultFile = $pipelineResultPath
            plannerContextFile = $plannerContextPath
        }
        $task.latestRun = New-LatestRunRecord `
            -AttemptNumber $attemptNumber `
            -LaunchSequence $launchSequence `
            -TaskName $taskName `
            -ResultFile $pipelineResultPath `
            -ProcessId 0 `
            -StartedAt ((Get-Date).ToString("o"))
        $task.latestRun.runDir = $artifactPointers.runDir
        $task.latestRun.schedulerSnapshotPath = $artifactPointers.schedulerSnapshotPath
        $task.latestRun.timelinePath = $artifactPointers.timelinePath
        $task.latestRun.artifacts = [pscustomobject]@{
            runDir = $artifactPointers.runDir
            timeline = $artifactPointers.timelinePath
            schedulerSnapshot = $artifactPointers.schedulerSnapshotPath
            plannerContext = $artifactPointers.plannerContextFile
            workerLauncher = $workerLauncher.command
            workerStdout = ""
            workerStderr = ""
        }
        Write-PlannerContextFile -Path $plannerContextPath -Task $task
        Write-TaskResultFile -Task $task
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "started" -Message "Task pipeline started." -Data @{ attempt = $attemptNumber; launchSequence = $launchSequence; waveNumber = $task.waveNumber; workerLauncher = $workerLauncher.command; workerLauncherSource = $workerLauncher.source }
    } finally {
        Release-Lock -LockHandle $lock
    }

    $encodedCommand = Get-EncodedWorkerLaunchCommand `
        -ScriptPath $autoDevelopScript `
        -PromptFile ([string]$task.promptFile) `
        -SolutionPath ([string]$task.solutionPath) `
        -ResultFile $pipelineResultPath `
        -PlannerContextFile $plannerContextPath `
        -TaskName ([string]$task.latestRun.taskName) `
        -SchedulerTaskId ([string]$task.taskId) `
        -CommandType ([string]$task.sourceCommand) `
        -AllowNuget ([bool]$task.allowNuget)

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-EncodedCommand", $encodedCommand
    )

    $workerOutputFile = Join-Path $context.paths.tasksDir "$TaskId-launch-$launchSequence-stdout.log"
    $workerErrorFile = Join-Path $context.paths.tasksDir "$TaskId-launch-$launchSequence-stderr.log"
    Remove-Item -LiteralPath $workerOutputFile, $workerErrorFile -ErrorAction SilentlyContinue

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $task = Get-TaskById -State $state -TaskId $TaskId
        if ($task) {
            Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
            $task.latestRun.workerStdoutPath = $workerOutputFile
            $task.latestRun.workerStderrPath = $workerErrorFile
            if (-not $task.latestRun.artifacts) {
                $task.latestRun.artifacts = [pscustomobject]@{}
            }
            $task.latestRun.artifacts.workerStdout = $workerOutputFile
            $task.latestRun.artifacts.workerStderr = $workerErrorFile
            Write-TaskResultFile -Task $task
            Save-State -StateFile $context.paths.stateFile -State $state
        }
    } finally {
        Release-Lock -LockHandle $lock
    }

    [Console]::Error.WriteLine(("[START] {0}" -f ([string](Get-TaskProgress -RepoRoot $context.repoRoot -Task $task).headline)))

    try {
        $process = Start-Process -FilePath $workerLauncher.command `
            -ArgumentList $arguments `
            -WorkingDirectory $context.repoRoot `
            -RedirectStandardOutput $workerOutputFile `
            -RedirectStandardError $workerErrorFile `
            -NoNewWindow `
            -PassThru
    } catch {
        $startError = $_.Exception.Message
        $lock = Acquire-Lock -LockFile $context.paths.lockFile
        try {
            $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
            $task = Get-TaskById -State $state -TaskId $TaskId
            if ($task) {
                Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
                Get-EnvironmentRetryableResult -Task $task -Reason "WORKER_START_FAILED"
                $task.latestRun.processId = 0
                $task.latestRun.finalStatus = "ERROR"
                $task.latestRun.finalCategory = "WORKER_START_FAILED"
                $task.latestRun.feedback = [string]$startError
                $task.latestRun.completedAt = (Get-Date).ToString("o")
                Write-TaskResultFile -Task $task
                Save-State -StateFile $context.paths.stateFile -State $state
                Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "completed" -Message "Task pipeline failed to start." -Data @{
                    attempt = $attemptNumber
                    finalStatus = "ERROR"
                    finalCategory = "WORKER_START_FAILED"
                    state = [string]$task.state
                }
            }
        } finally {
            Release-Lock -LockHandle $lock
        }
        throw
    }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) {
            throw "Task '$TaskId' disappeared after the worker process started."
        }
        Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
        $task.latestRun.processId = [int]$process.Id
        Write-TaskResultFile -Task $task
        Save-State -StateFile $context.paths.stateFile -State $state
    } finally {
        Release-Lock -LockHandle $lock
    }

    $lastProgressKey = ""
    while (-not $process.HasExited) {
        Start-Sleep -Seconds 2
        $stateForProgress = $null
        $progressTask = $null
        $progressLock = Acquire-Lock -LockFile $context.paths.lockFile
        try {
            $stateForProgress = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
            $progressTask = Get-TaskById -State $stateForProgress -TaskId $TaskId
            if ($progressTask) {
                Ensure-TaskShape -Task $progressTask -RepoRoot $context.repoRoot
            }
        } finally {
            Release-Lock -LockHandle $progressLock
        }

        if ($progressTask) {
            $progress = Get-TaskProgress -RepoRoot $context.repoRoot -Task $progressTask
            $progressKey = "{0}|{1}|{2}" -f $progress.phaseLabel, $progress.latestMilestone, $progress.detail
            if ($progressKey -ne $lastProgressKey) {
                $elapsedPart = if ($progress.elapsedLabel) { " | elapsed $($progress.elapsedLabel)" } else { "" }
                $attemptPart = if ($progress.attemptLabel) { " | $($progress.attemptLabel)" } else { "" }
                $detailPart = if ($progress.detail) { " | $($progress.detail)" } else { "" }
                [Console]::Error.WriteLine(("[PROGRESS] {0}{1}{2}{3}" -f $progress.phaseLabel, $attemptPart, $elapsedPart, $detailPart))
                $lastProgressKey = $progressKey
            }
        }
    }

    $stdoutText = if (Test-Path -LiteralPath $workerOutputFile) { (Get-Content -LiteralPath $workerOutputFile -Raw) } else { "" }
    $stderrText = if (Test-Path -LiteralPath $workerErrorFile) { (Get-Content -LiteralPath $workerErrorFile -Raw) } else { "" }
    $workerResult = [pscustomobject]@{
        output = ((@($stdoutText, $stderrText) | Where-Object { $_ }) -join [Environment]::NewLine).Trim()
        exitCode = [int]$process.ExitCode
    }
    $pipelineResult = Read-JsonFileBestEffort -Path $pipelineResultPath
    if (-not $pipelineResult) {
        $pipelineResult = [pscustomobject]@{
            status = "ERROR"
            finalCategory = "WORKER_EXITED_WITHOUT_RESULT"
            summary = if ($workerResult.output) { $workerResult.output } else { "Pipeline completed without a result file." }
            feedback = [string]$workerResult.output
            noChangeReason = ""
            files = @()
            branch = ""
            artifacts = $null
        }
    }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) {
            throw "Task '$TaskId' disappeared during execution."
        }
        Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
        Apply-PipelineResultToTask -Task $task -PipelineResult $pipelineResult -RepoRoot $context.repoRoot
        Update-TaskUsageEstimate -State $state -Task $task
        Write-TaskResultFile -Task $task
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "completed" -Message "Task pipeline finished." -Data @{
            attempt = $attemptNumber
            finalStatus = [string]$task.latestRun.finalStatus
            finalCategory = [string]$task.latestRun.finalCategory
            state = [string]$task.state
        }
        if ([string]$task.state -eq "environment_retry_scheduled") {
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "environment_failure_detected" -Message "Environment failure detected; scheduling environment repair." -Data @{
                finalCategory = [string]$task.latestRun.finalCategory
                environmentRepairAttemptsUsed = [int]$task.environmentRepairAttemptsUsed
                environmentRepairAttemptsRemaining = [int]$task.environmentRepairAttemptsRemaining
            }
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "environment_retry_scheduled" -Message "Task will retry after recreating the execution environment." -Data @{
                finalCategory = [string]$task.latestRun.finalCategory
                state = [string]$task.state
            }
        }
        if ([string]$task.state -eq "manual_debug_needed") {
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "manual_debug_needed" -Message "Task paused because repeated inconclusive investigation produced no new evidence." -Data @{
                finalCategory = [string]$task.latestRun.finalCategory
                manualDebugReason = [string]$task.manualDebugReason
                attemptsUsed = [int]$task.attemptsUsed
            }
        }
        if ($task.plannerFeedback.predictionEvaluated) {
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "planner_feedback" -Message "Planner prediction compared against actual files." -Data $task.plannerFeedback
        }

        $finalProgress = Get-TaskProgress -RepoRoot $context.repoRoot -Task $task
        [Console]::Error.WriteLine(("[DONE] {0}" -f $finalProgress.headline))
        if ($finalProgress.detail) {
            [Console]::Error.WriteLine(("[DETAIL] {0}" -f $finalProgress.detail))
        }

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $task -RepoRoot $context.repoRoot
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Prepare-Merge {
    param(
        [string]$ResolvedSolutionPath,
        [string]$TaskId
    )

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $selectedTask = $null
    $mergeResult = $null
    $lockRemediationAttempted = $false
    $killedProcesses = @()
    $lockFailureDetected = $false

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $null = Reconcile-State -State $state -EventsFile $context.paths.eventsFile

        $alreadyPrepared = Get-MergePreparedTask -State $state
        if ($alreadyPrepared -and ((-not $TaskId) -or [string]$alreadyPrepared.taskId -ne $TaskId)) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $alreadyPrepared -RepoRoot $context.repoRoot
                blocked = $true
                reason = "Another task already has a prepared merge."
                snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
            }
        }

        $selectedTask = if ($TaskId) { Get-TaskById -State $state -TaskId $TaskId } else { Get-NextMergeCandidate -State $state }
        if (-not $selectedTask) {
            return [pscustomobject]@{
                task = $null
                blocked = $false
                reason = "No task is ready for merge preparation."
                snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
            }
        }
        if ($selectedTask.state -notin @("pending_merge", "merge_retry_scheduled")) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask -RepoRoot $context.repoRoot
                blocked = $true
                reason = "The selected task is not pending merge."
                snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
            }
        }

        $unknownBranches = Get-UnknownAutoBranches -RepoRoot $context.repoRoot -KnownBranches (Get-KnownBranches -State $state)
        if ($unknownBranches.Count -gt 0) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask -RepoRoot $context.repoRoot
                blocked = $true
                reason = "Untracked auto/* branches are blocking merge preparation."
                unknownAutoBranches = @($unknownBranches)
                snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
            }
        }

        if (-not (Invoke-GitCleanCheck -RepoRoot $context.repoRoot)) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask -RepoRoot $context.repoRoot
                blocked = $true
                reason = "The repository worktree is not clean."
                snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
            }
        }

    } finally {
        Release-Lock -LockHandle $lock
    }

    $branchName = [string]$selectedTask.latestRun.branchName
    $mergeAttempt = Invoke-MergeBuildAttempt -RepoRoot $context.repoRoot -SolutionPath $selectedTask.solutionPath -BranchName $branchName
    $lockFailureDetected = [bool]($mergeAttempt.lockInfo -and $mergeAttempt.lockInfo.isLockFailure)

    if (
        (-not $mergeAttempt.success) -and
        $mergeAttempt.phase -eq "build" -and
        $lockFailureDetected -and
        $selectedTask.sourceCommand -eq "TLA-develop"
    ) {
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $selectedTask.taskId -Kind "merge_lock_detected" -Message "Lock-style build failure detected during autonomous merge preparation." -Data @{
            processIds = @($mergeAttempt.lockInfo.processIds)
            processHints = @($mergeAttempt.lockInfo.processHints)
            lockedPaths = @($mergeAttempt.lockInfo.lockedPaths)
        }

        $remediation = Invoke-TlaLockRemediation -RepoRoot $context.repoRoot -SolutionPath $selectedTask.solutionPath -LockInfo $mergeAttempt.lockInfo
        $lockRemediationAttempted = [bool]$remediation.attempted
        $killedProcesses = @($remediation.killedProcesses)

        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $selectedTask.taskId -Kind "merge_lock_remediation" -Message "Autonomous merge lock remediation attempted." -Data @{
            attempted = $lockRemediationAttempted
            candidates = @($remediation.candidates)
            killedProcesses = @($killedProcesses)
        }

        if ($lockRemediationAttempted) {
            $mergeAttempt = Invoke-MergeBuildAttempt -RepoRoot $context.repoRoot -SolutionPath $selectedTask.solutionPath -BranchName $branchName
            $lockFailureDetected = [bool]($mergeAttempt.lockInfo -and $mergeAttempt.lockInfo.isLockFailure)
        }
    }

    $mergeResult = [pscustomobject]@{
        success = [bool]$mergeAttempt.success
        reason = [string]$mergeAttempt.reason
        lockFailureDetected = $lockFailureDetected
        lockRemediationAttempted = $lockRemediationAttempted
        killedProcesses = @($killedProcesses)
    }

    if ((-not $mergeResult.success) -and $lockRemediationAttempted) {
        $postRemediationReason = switch ([string]$mergeAttempt.phase) {
            "restore" { "Restore failed after autonomous lock remediation." }
            "build" { "Build failed after autonomous lock remediation." }
            default { "Merge preparation failed after autonomous lock remediation." }
        }
        $mergeResult.reason = "$postRemediationReason $([string]$mergeAttempt.reason)".Trim()
    }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $selectedTask = Get-TaskById -State $state -TaskId $selectedTask.taskId
        if (-not $selectedTask) {
            throw "Task '$TaskId' disappeared during merge preparation."
        }

        if ($mergeResult.success) {
            $selectedTask.mergeAttemptsUsed = 0
            $selectedTask.mergeAttemptsRemaining = [int]$selectedTask.maxMergeAttempts
            $selectedTask.merge.preparedAt = (Get-Date).ToString("o")
            $selectedTask.merge.reason = ""
            $selectedTask.merge.state = "prepared"
            $selectedTask.mergeState = "prepared"
            if ($selectedTask.sourceCommand -eq "TLA-develop") {
                $selectedTask.state = "merge_prepared"
                $selectedTask.waitingUserTest = $false
            } else {
                $selectedTask.state = "waiting_user_test"
                $selectedTask.waitingUserTest = $true
            }
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $selectedTask.taskId -Kind "merge_prepared" -Message "Merge prepared successfully." -Data @{ waitingUserTest = [bool]$selectedTask.waitingUserTest }
        } else {
            $requiresWorkerRetry = ($mergeAttempt.phase -eq "merge")
            if ($requiresWorkerRetry) {
                Get-RetryableResult -Task $selectedTask -Reason ([string]$mergeResult.reason)
                Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName ([string]$selectedTask.latestRun.branchName)
            } else {
                $scheduled = Get-MergeRetryableResult -Task $selectedTask -Reason ([string]$mergeResult.reason)
                if (-not $scheduled) {
                    Get-RetryableResult -Task $selectedTask -Reason ([string]$mergeResult.reason)
                    Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName ([string]$selectedTask.latestRun.branchName)
                }
            }
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $selectedTask.taskId -Kind "merge_failed" -Message "Merge preparation failed." -Data @{ reason = [string]$mergeResult.reason }
        }

        Write-TaskResultFile -Task $selectedTask
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $selectedTask -RepoRoot $context.repoRoot
            prepared = [bool]$mergeResult.success
            reason = [string]$mergeResult.reason
            lockFailureDetected = [bool]$mergeResult.lockFailureDetected
            lockRemediationAttempted = [bool]$mergeResult.lockRemediationAttempted
            killedProcesses = @($mergeResult.killedProcesses)
            mergePreview = if ($mergeResult.success) { Get-TaskMergePreview -RepoRoot $context.repoRoot -Task $selectedTask } else { $null }
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Admin-Edit-Task {
    param(
        [string]$ResolvedSolutionPath,
        [string]$ResolvedEditFile
    )

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $payload = Read-AdminEditPayload -Path $ResolvedEditFile
    $taskId = [string]$payload.taskId
    if (-not $taskId) {
        throw "Admin edit payload must include taskId."
    }
    $updates = if ($payload.updates) { $payload.updates } else { $payload }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $task = Get-TaskById -State $state -TaskId $taskId
        if (-not $task) {
            throw "Task '$taskId' was not found."
        }

        foreach ($field in @("state", "waveNumber", "retryScheduled", "waitingUserTest", "mergeState", "attemptsUsed", "attemptsRemaining", "mergeAttemptsUsed", "mergeAttemptsRemaining", "manualDebugReason")) {
            if ($null -ne $updates.$field) {
                Set-ObjectProperty -Object $task -Name $field -Value $updates.$field
            }
        }
        if ($null -ne $updates.blockedBy) {
            Set-ObjectProperty -Object $task -Name "blockedBy" -Value ([object[]](Normalize-StringArray -Value $updates.blockedBy))
        }
        if ($updates.merge) {
            foreach ($field in @("state", "preparedAt", "commitMessage", "commitSha", "reason", "branchName")) {
                if ($null -ne $updates.merge.$field) {
                    Set-ObjectProperty -Object $task.merge -Name $field -Value $updates.merge.$field
                }
            }
        }
        if ($updates.latestRun) {
            foreach ($field in @("branchName", "finalStatus", "finalCategory", "summary", "feedback", "noChangeReason", "completedAt", "startedAt", "taskName", "resultFile", "processId", "artifacts")) {
                if ($null -ne $updates.latestRun.$field) {
                    Set-ObjectProperty -Object $task.latestRun -Name $field -Value $updates.latestRun.$field
                }
            }
            if ($null -ne $updates.latestRun.actualFiles) {
                Set-ObjectProperty -Object $task.latestRun -Name "actualFiles" -Value ([object[]](Normalize-StringArray -Value $updates.latestRun.actualFiles))
            }
        }

        Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
        $integrityWarnings = @(Get-TaskIntegrityWarnings -Task $task)
        Write-TaskResultFile -Task $task
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "admin_edit" -Message "Task edited by admin command." -Data @{
            updates = $updates
            integrityWarnings = @($integrityWarnings)
        }

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $task -RepoRoot $context.repoRoot
            integrityWarnings = @($integrityWarnings)
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Resolve-Merge {
    param(
        [string]$ResolvedSolutionPath,
        [string]$TaskId,
        [string]$Decision,
        [string]$CommitMessage
    )

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $null = Reconcile-State -State $state -EventsFile $context.paths.eventsFile
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) {
            throw "Task '$TaskId' was not found."
        }
        if ($task.state -notin @("merge_prepared", "waiting_user_test")) {
            throw "Task '$TaskId' is not waiting for merge resolution."
        }
    } finally {
        Release-Lock -LockHandle $lock
    }

    $operation = $null
    switch ($Decision) {
        "commit" {
            $message = if ($CommitMessage) { $CommitMessage } else { Get-DefaultMergeCommitMessage -Task $task }
            $commitResult = Invoke-NativeCommand -Command "git" -Arguments @("commit", "-m", $message) -WorkingDirectory $context.repoRoot
            if ($commitResult.exitCode -ne 0) {
                throw "Failed to commit the prepared merge: $($commitResult.output)"
            }
            $shaResult = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "HEAD") -WorkingDirectory $context.repoRoot
            $operation = [pscustomobject]@{
                state = "merged"
                reason = "Merge committed."
                commitMessage = $message
                commitSha = [string]$shaResult.output
            }
        }
        "abort" {
            Undo-MergeAttempt -RepoRoot $context.repoRoot
            $operation = [pscustomobject]@{
                state = "pending_merge"
                reason = "Prepared merge was aborted."
                commitMessage = ""
                commitSha = ""
            }
        }
        "discard" {
            Undo-MergeAttempt -RepoRoot $context.repoRoot
            $operation = [pscustomobject]@{
                state = "discarded"
                reason = "Task was discarded."
                commitMessage = ""
                commitSha = ""
            }
        }
        "requeue" {
            Undo-MergeAttempt -RepoRoot $context.repoRoot
            $operation = [pscustomobject]@{
                state = "requeue"
                reason = "Task was rescheduled."
                commitMessage = ""
                commitSha = ""
            }
        }
        default {
            throw "Unsupported merge decision '$Decision'."
        }
    }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) {
            throw "Task '$TaskId' disappeared during merge resolution."
        }

        switch ($Decision) {
            "commit" {
                $task.state = "merged"
                $task.waitingUserTest = $false
                $task.retryScheduled = $false
                $task.mergeState = "merged"
                $task.merge.state = "merged"
                $task.merge.commitMessage = [string]$operation.commitMessage
                $task.merge.commitSha = [string]$operation.commitSha
                $task.merge.reason = ""
                Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName ([string]$task.latestRun.branchName)
            }
            "abort" {
                $task.state = "pending_merge"
                $task.waitingUserTest = $false
                $task.mergeState = "pending"
                $task.merge.state = "pending"
                $task.merge.reason = [string]$operation.reason
            }
            "discard" {
                $task.state = "discarded"
                $task.waitingUserTest = $false
                $task.retryScheduled = $false
                $task.mergeState = "discarded"
                $task.merge.state = "discarded"
                $task.merge.reason = [string]$operation.reason
                Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName ([string]$task.latestRun.branchName)
            }
            "requeue" {
                Get-RetryableResult -Task $task -Reason ([string]$operation.reason)
                Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName ([string]$task.latestRun.branchName)
            }
        }

        Write-TaskResultFile -Task $task
        $null = Update-CircuitBreakerState -State $state -EventsFile $context.paths.eventsFile
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "merge_resolved" -Message ([string]$operation.reason) -Data @{
            decision = $Decision
            state = [string]$task.state
            commitSha = [string]$task.merge.commitSha
        }

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $task -RepoRoot $context.repoRoot
            decision = $Decision
            reason = [string]$operation.reason
            commitMessage = [string]$task.merge.commitMessage
            commitSha = [string]$task.merge.commitSha
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Admin-Clear-Breaker {
    param([string]$ResolvedSolutionPath)

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $state.circuitBreaker = New-CircuitBreakerRecord
        $state.circuitBreaker.status = "manual_override"
        $state.circuitBreaker.reasonCategory = "manual_override"
        $state.circuitBreaker.reasonSummary = "Manual circuit-breaker override is active."
        $state.circuitBreaker.closedAt = (Get-Date).ToString("o")
        $state.circuitBreaker.manualOverrideUntil = (Get-Date).AddMinutes(10).ToString("o")
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId "" -Kind "circuit_breaker_cleared" -Message "Circuit breaker manually cleared." -Data $state.circuitBreaker

        return [pscustomobject]@{
            circuitBreaker = $state.circuitBreaker
            snapshot = Get-SnapshotPayload -State $state -EventsFile $context.paths.eventsFile
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

$resolvedSolutionPath = if ($SolutionPath) { Get-CanonicalPath -Path $SolutionPath } else { "" }
$resolvedTasksFile = if ($TasksFile) { Get-CanonicalPath -Path $TasksFile } else { "" }
$resolvedPlanFile = if ($PlanFile) { Get-CanonicalPath -Path $PlanFile } else { "" }
$resolvedEditFile = if ($EditFile) { Get-CanonicalPath -Path $EditFile } else { "" }

switch ($Mode) {
    "prepare-environment" {
        Write-JsonOutput -Object (Prepare-Environment -ResolvedSolutionPath $resolvedSolutionPath)
        break
    }
    "snapshot-queue" {
        Write-JsonOutput -Object (Snapshot-Queue -ResolvedSolutionPath $resolvedSolutionPath)
        break
    }
    "register-tasks" {
        Write-JsonOutput -Object (Register-Tasks -ResolvedSolutionPath $resolvedSolutionPath -ResolvedTasksFile $resolvedTasksFile)
        break
    }
    "apply-plan" {
        Write-JsonOutput -Object (Apply-Plan -ResolvedSolutionPath $resolvedSolutionPath -ResolvedPlanFile $resolvedPlanFile)
        break
    }
    "run-task" {
        Write-JsonOutput -Object (Run-Task -ResolvedSolutionPath $resolvedSolutionPath -TaskId $TaskId)
        break
    }
    "wait-queue" {
        Write-JsonOutput -Object (Wait-Queue -ResolvedSolutionPath $resolvedSolutionPath -WaitTimeoutSeconds $WaitTimeoutSeconds -IdlePollSeconds $IdlePollSeconds -WakeOnAnyCompletion $WakeOnAnyCompletion -WakeOnMergeReady $WakeOnMergeReady -WakeOnBreakerOpen $WakeOnBreakerOpen)
        break
    }
    "prepare-merge" {
        Write-JsonOutput -Object (Prepare-Merge -ResolvedSolutionPath $resolvedSolutionPath -TaskId $TaskId)
        break
    }
    "resolve-merge" {
        Write-JsonOutput -Object (Resolve-Merge -ResolvedSolutionPath $resolvedSolutionPath -TaskId $TaskId -Decision $Decision -CommitMessage $CommitMessage)
        break
    }
    "admin-edit-task" {
        Write-JsonOutput -Object (Admin-Edit-Task -ResolvedSolutionPath $resolvedSolutionPath -ResolvedEditFile $resolvedEditFile)
        break
    }
    "admin-clear-breaker" {
        Write-JsonOutput -Object (Admin-Clear-Breaker -ResolvedSolutionPath $resolvedSolutionPath)
        break
    }
}
