# scheduler.ps1 -- Repo-scoped queue scheduler for AutoDevelop v4
param(
    [Parameter(Mandatory)][ValidateSet("snapshot-queue", "register-tasks", "apply-plan", "run-task", "prepare-merge", "resolve-merge")][string]$Mode,
    [string]$SolutionPath = "",
    [string]$TasksFile = "",
    [string]$PlanFile = "",
    [string]$TaskId = "",
    [string]$Decision = "",
    [string]$CommitMessage = ""
)

$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    $output = if ($WorkingDirectory) {
        & {
            $ErrorActionPreference = "Continue"
            Push-Location $WorkingDirectory
            try {
                & $Command @Arguments 2>&1
            } finally {
                Pop-Location
            }
        }
    } else {
        & {
            $ErrorActionPreference = "Continue"
            & $Command @Arguments 2>&1
        }
    }

    return [pscustomobject]@{
        output = ($output | Out-String).Trim()
        exitCode = $LASTEXITCODE
    }
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

function New-EmptyState {
    param([string]$RepoRoot)
    return [pscustomobject]@{
        version = 4
        repoRoot = $RepoRoot
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
        lastPlanAppliedAt = ""
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

function Get-ShortTaskToken {
    param([string]$TaskId)
    if (-not $TaskId) { return "task" }
    $clean = ($TaskId -replace "[^A-Za-z0-9]", "").ToLowerInvariant()
    if (-not $clean) { return "task" }
    if ($clean.Length -gt 8) { return $clean.Substring(0, 8) }
    return $clean
}

function Get-AttemptTaskName {
    param(
        [string]$TaskId,
        [string]$SourceCommand,
        [int]$AttemptNumber
    )

    $prefix = Get-TaskPrefix -SourceCommand $SourceCommand
    return "$prefix-$(Get-ShortTaskToken -TaskId $TaskId)-a$AttemptNumber"
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
    if (-not $Task.blockedBy) { $Task | Add-Member -NotePropertyName blockedBy -NotePropertyValue @() -Force }
    if (-not $Task.runs) { $Task | Add-Member -NotePropertyName runs -NotePropertyValue @() -Force }
    if (-not $Task.plannerMetadata) { $Task | Add-Member -NotePropertyName plannerMetadata -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $Task.latestRun) { $Task | Add-Member -NotePropertyName latestRun -NotePropertyValue ([pscustomobject]@{}) -Force }
    if (-not $Task.merge) {
        $Task | Add-Member -NotePropertyName merge -NotePropertyValue ([pscustomobject]@{
            state = ""
            preparedAt = ""
            commitMessage = ""
            commitSha = ""
            reason = ""
            branchName = ""
        }) -Force
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
}

function Get-TaskSummaryText {
    param($Task)
    if ($Task.latestRun.summary) { return [string]$Task.latestRun.summary }
    if ($Task.taskText) { return [string]$Task.taskText }
    return ""
}

function ConvertTo-TaskSnapshot {
    param($Task)

    return [pscustomobject]@{
        taskId = [string]$Task.taskId
        sourceCommand = [string]$Task.sourceCommand
        sourceInputType = [string]$Task.sourceInputType
        taskText = [string]$Task.taskText
        state = [string]$Task.state
        waveNumber = [int]$Task.waveNumber
        submissionOrder = [int]$Task.submissionOrder
        blockedBy = @($Task.blockedBy)
        attemptsUsed = [int]$Task.attemptsUsed
        attemptsRemaining = [int]$Task.attemptsRemaining
        retryScheduled = [bool]$Task.retryScheduled
        waitingUserTest = [bool]$Task.waitingUserTest
        mergeState = [string]$Task.mergeState
        branchName = [string]$Task.latestRun.branchName
        summary = Get-TaskSummaryText -Task $Task
        finalStatus = [string]$Task.latestRun.finalStatus
        finalCategory = [string]$Task.latestRun.finalCategory
        noChangeReason = [string]$Task.latestRun.noChangeReason
        actualFiles = @($Task.latestRun.actualFiles)
        plannerMetadata = $Task.plannerMetadata
        merge = $Task.merge
        resultFile = [string]$Task.resultFile
    }
}

function Write-TaskResultFile {
    param($Task)
    Ensure-ParentDirectory -Path $Task.resultFile
    [System.IO.File]::WriteAllText($Task.resultFile, ((ConvertTo-TaskSnapshot -Task $Task) | ConvertTo-Json -Depth 24), [System.Text.Encoding]::UTF8)
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

function Get-SubmissionOrder {
    param($State)
    $tasks = Get-Tasks -State $State
    if ($tasks.Count -eq 0) { return 1 }
    return ((@($tasks | ForEach-Object { [int]$_.submissionOrder } | Measure-Object -Maximum).Maximum) + 1)
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
    $waveNumber = Get-CurrentExecutionWave -State $State
    if ($waveNumber -le 0) { return @() }

    $waveTasks = @(Get-TasksInWave -State $State -WaveNumber $waveNumber)
    if ($waveTasks.Count -eq 0) { return @() }

    $mergeGateStates = @("pending_merge", "merge_prepared", "waiting_user_test")
    if (@($waveTasks | Where-Object { $mergeGateStates -contains $_.state }).Count -gt 0) {
        return @()
    }

    return @(
        @($waveTasks | Where-Object {
            [int]$_.waveNumber -eq $waveNumber -and (Is-QueueState -State $_.state)
        } | Sort-Object submissionOrder | ForEach-Object { [string]$_.taskId })
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

function Get-MergedFilesBeforeTask {
    param(
        $State,
        $Task
    )

    $files = [System.Collections.ArrayList]::new()
    foreach ($candidate in @((Get-Tasks -State $State) | Sort-Object waveNumber, submissionOrder)) {
        if ([int]$candidate.waveNumber -gt [int]$Task.waveNumber) { break }
        if ([int]$candidate.waveNumber -eq [int]$Task.waveNumber -and [int]$candidate.submissionOrder -ge [int]$Task.submissionOrder) { break }
        if ($candidate.state -ne "merged") { continue }
        foreach ($file in @(Get-NormalizedPathSet -RepoRoot $State.repoRoot -Paths $candidate.latestRun.actualFiles)) {
            if ($files -notcontains $file) {
                [void]$files.Add($file)
            }
        }
    }
    return @($files)
}

function Test-ActualOverlap {
    param(
        $State,
        $Task
    )

    $currentFiles = @(Get-NormalizedPathSet -RepoRoot $State.repoRoot -Paths $Task.latestRun.actualFiles)
    if ($currentFiles.Count -eq 0) { return @() }
    $previousFiles = @(Get-MergedFilesBeforeTask -State $State -Task $Task)
    return @($currentFiles | Where-Object { $previousFiles -contains $_ } | Select-Object -Unique)
}

function Invoke-GitCleanCheck {
    param([string]$RepoRoot)
    $status = Invoke-NativeCommand -Command "git" -Arguments @("status", "--porcelain") -WorkingDirectory $RepoRoot
    return (-not $status.output)
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
    } else {
        $Task.state = "completed_failed_terminal"
        $Task.retryScheduled = $false
        $Task.waitingUserTest = $false
        $Task.mergeState = "failed_terminal"
        $Task.merge.state = "failed_terminal"
        $Task.merge.reason = $Reason
    }
    $Task.attemptsRemaining = [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)
}

function Apply-PipelineResultToTask {
    param(
        $Task,
        $PipelineResult
    )

    $Task.latestRun.finalStatus = [string]$PipelineResult.status
    $Task.latestRun.finalCategory = [string]$PipelineResult.finalCategory
    $Task.latestRun.summary = [string]$PipelineResult.summary
    $Task.latestRun.feedback = [string]$PipelineResult.feedback
    $Task.latestRun.noChangeReason = [string]$PipelineResult.noChangeReason
    $Task.latestRun.actualFiles = @($PipelineResult.files)
    $Task.latestRun.branchName = [string]$PipelineResult.branch
    $Task.latestRun.artifacts = $PipelineResult.artifacts
    $Task.latestRun.completedAt = (Get-Date).ToString("o")

    $runRecord = [pscustomobject]@{
        attemptNumber = [int]$Task.attemptsUsed
        finalStatus = [string]$PipelineResult.status
        finalCategory = [string]$PipelineResult.finalCategory
        summary = [string]$PipelineResult.summary
        feedback = [string]$PipelineResult.feedback
        noChangeReason = [string]$PipelineResult.noChangeReason
        actualFiles = @($PipelineResult.files)
        branchName = [string]$PipelineResult.branch
        resultFile = [string]$Task.latestRun.resultFile
        completedAt = $Task.latestRun.completedAt
        artifacts = $PipelineResult.artifacts
    }
    $Task.runs = @($Task.runs) + @($runRecord)

    switch ([string]$PipelineResult.status) {
        "ACCEPTED" {
            $Task.state = "pending_merge"
            $Task.retryScheduled = $false
            $Task.waitingUserTest = $false
            $Task.mergeState = "pending"
            $Task.merge.state = "pending"
            $Task.merge.branchName = [string]$PipelineResult.branch
            $Task.merge.reason = ""
        }
        "NO_CHANGE" {
            if ([string]$PipelineResult.finalCategory -eq "NO_CHANGE_ALREADY_SATISFIED") {
                $Task.state = "completed_no_change"
                $Task.retryScheduled = $false
                $Task.waitingUserTest = $false
                $Task.mergeState = "no_change"
                $Task.merge.state = "no_change"
            } else {
                Get-RetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
            }
        }
        "FAILED" {
            Get-RetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
        }
        default {
            Get-RetryableResult -Task $Task -Reason ([string]$PipelineResult.finalCategory)
        }
    }

    $Task.attemptsRemaining = [Math]::Max(0, [int]$Task.maxAttempts - [int]$Task.attemptsUsed)
}

function Reconcile-TaskState {
    param($Task)

    if (-not (Is-RunningState -State $Task.state)) {
        return
    }

    $alive = Test-ProcessAlive -ProcessId ([int]$Task.latestRun.processId)
    if ($alive) {
        return
    }

    $pipelineResult = Read-JsonFile -Path $Task.latestRun.resultFile
    if ($pipelineResult) {
        Apply-PipelineResultToTask -Task $Task -PipelineResult $pipelineResult
        return
    }

    Get-RetryableResult -Task $Task -Reason "WORKER_EXITED_WITHOUT_RESULT"
}

function Reconcile-State {
    param($State)
    foreach ($task in @(Get-Tasks -State $State)) {
        Ensure-TaskShape -Task $task -RepoRoot $State.repoRoot
        Reconcile-TaskState -Task $task
        Write-TaskResultFile -Task $task
    }
}

function New-TaskRecord {
    param(
        [string]$RepoRoot,
        $InputTask,
        [int]$SubmissionOrder
    )

    $taskId = if ($InputTask.taskId) { [string]$InputTask.taskId } else { ([guid]::NewGuid().ToString("N")) }
    $resolvedSolutionPath = if ($InputTask.solutionPath) { Get-CanonicalPath -Path ([string]$InputTask.solutionPath) } else { "" }
    $resolvedPromptFile = if ($InputTask.promptFile) { Get-CanonicalPath -Path ([string]$InputTask.promptFile) } else { "" }
    $resolvedPlanFile = if ($InputTask.planFile) { Get-CanonicalPath -Path ([string]$InputTask.planFile) } else { "" }
    $resultFile = if ($InputTask.resultFile) { Get-CanonicalPath -Path ([string]$InputTask.resultFile) } else { Get-DefaultTaskResultPath -RepoRoot $RepoRoot -TaskId $taskId }

    return [pscustomobject]@{
        taskId = $taskId
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
        maxAttempts = 3
        attemptsUsed = 0
        attemptsRemaining = 3
        retryScheduled = $false
        waitingUserTest = $false
        mergeState = ""
        state = "queued"
        plannerMetadata = if ($InputTask.plannerMetadata) { $InputTask.plannerMetadata } else { [pscustomobject]@{} }
        latestRun = [pscustomobject]@{}
        runs = @()
        merge = [pscustomobject]@{
            state = ""
            preparedAt = ""
            commitMessage = ""
            commitSha = ""
            reason = ""
            branchName = ""
        }
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

        $hasUnfinishedPipes = @($waveTasks | Where-Object { $_.state -in @("queued", "retry_scheduled", "running") }).Count -gt 0
        if ($hasUnfinishedPipes) {
            return $null
        }

        $pendingMergeTask = @($waveTasks | Where-Object { $_.state -eq "pending_merge" } | Select-Object -First 1)[0]
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

function Get-SnapshotPayload {
    param($State)

    $knownBranches = Get-KnownBranches -State $State
    $unknownBranches = Get-UnknownAutoBranches -RepoRoot $State.repoRoot -KnownBranches $knownBranches
    $nextMergeTask = Get-NextMergeCandidate -State $State
    $mergePreparedTask = Get-MergePreparedTask -State $State

    return [pscustomobject]@{
        repoRoot = $State.repoRoot
        updatedAt = [string]$State.updatedAt
        lastPlanAppliedAt = [string]$State.lastPlanAppliedAt
        tasks = @((Get-Tasks -State $State) | Sort-Object waveNumber, submissionOrder | ForEach-Object { ConvertTo-TaskSnapshot -Task $_ })
        runningTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "running" } | ForEach-Object { [string]$_.taskId })
        queuedTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "queued" } | ForEach-Object { [string]$_.taskId })
        retryTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "retry_scheduled" } | ForEach-Object { [string]$_.taskId })
        pendingMergeTaskIds = @((Get-Tasks -State $State) | Where-Object { $_.state -eq "pending_merge" } | ForEach-Object { [string]$_.taskId })
        startableTaskIds = @(Get-StartableTaskIds -State $State)
        nextMergeTaskId = if ($nextMergeTask) { [string]$nextMergeTask.taskId } else { "" }
        mergePreparedTaskId = if ($mergePreparedTask) { [string]$mergePreparedTask.taskId } else { "" }
        unknownAutoBranches = @($unknownBranches)
    }
}

function Snapshot-Queue {
    param([string]$ResolvedSolutionPath)

    $context = Get-SchedulerContext -ResolvedSolutionPath $ResolvedSolutionPath
    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        Reconcile-State -State $state
        Save-State -StateFile $context.paths.stateFile -State $state
        return (Get-SnapshotPayload -State $state)
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
        Reconcile-State -State $state

        $submissionOrder = Get-SubmissionOrder -State $state
        $registered = [System.Collections.ArrayList]::new()

        foreach ($inputTask in $registrationTasks) {
            $task = New-TaskRecord -RepoRoot $context.repoRoot -InputTask $inputTask -SubmissionOrder $submissionOrder
            Ensure-TaskShape -Task $task -RepoRoot $context.repoRoot
            if (Get-TaskById -State $state -TaskId $task.taskId) {
                throw "Task id '$($task.taskId)' is already registered."
            }
            $state.tasks = @($state.tasks) + @($task)
            Write-TaskResultFile -Task $task
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "registered" -Message "Task registered." -Data @{ sourceCommand = $task.sourceCommand; sourceInputType = $task.sourceInputType }
            [void]$registered.Add((ConvertTo-TaskSnapshot -Task $task))
            $submissionOrder += 1
        }

        Save-State -StateFile $context.paths.stateFile -State $state

        return [pscustomobject]@{
            registered = @($registered)
            snapshot = Get-SnapshotPayload -State $state
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
        Reconcile-State -State $state

        foreach ($assignment in $assignments) {
            if (-not $assignment.taskId) { continue }
            $task = Get-TaskById -State $state -TaskId ([string]$assignment.taskId)
            if (-not $task) { continue }
            if (Is-TerminalState -State $task.state) { continue }

            if ($assignment.waveNumber) { $task.waveNumber = [int]$assignment.waveNumber }
            $task.blockedBy = if ($assignment.blockedBy) { @($assignment.blockedBy) } else { @() }
            if ($assignment.plannerMetadata) {
                $task.plannerMetadata = $assignment.plannerMetadata
            }
            if ($assignment.plannedState -and (Is-QueueState -State $task.state)) {
                $task.state = [string]$assignment.plannedState
            }
            Write-TaskResultFile -Task $task
        }

        $state.lastPlanAppliedAt = (Get-Date).ToString("o")
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId "" -Kind "plan_applied" -Message "Planner output applied." -Data @{
            summary = [string]$planPayload.summary
            startableTaskIds = @(Get-StartableTaskIds -State $state)
        }

        return [pscustomobject]@{
            summary = [string]$planPayload.summary
            startableTaskIds = @(Get-StartableTaskIds -State $state)
            snapshot = Get-SnapshotPayload -State $state
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

    $task = $null
    $pipelineResultPath = ""
    $attemptNumber = 0

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        Reconcile-State -State $state
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

        $task.state = "running"
        $task.retryScheduled = $false
        $task.waitingUserTest = $false
        $task.mergeState = ""
        $task.attemptsUsed = [int]$task.attemptsUsed + 1
        $task.attemptsRemaining = [Math]::Max(0, [int]$task.maxAttempts - [int]$task.attemptsUsed)
        $attemptNumber = [int]$task.attemptsUsed
        $pipelineResultPath = Join-Path $context.paths.tasksDir "$TaskId-attempt-$attemptNumber-result.json"
        $task.latestRun = [pscustomobject]@{
            attemptNumber = $attemptNumber
            taskName = Get-AttemptTaskName -TaskId $TaskId -SourceCommand $task.sourceCommand -AttemptNumber $attemptNumber
            resultFile = $pipelineResultPath
            processId = $PID
            startedAt = (Get-Date).ToString("o")
            finalStatus = ""
            finalCategory = ""
            summary = ""
            feedback = ""
            noChangeReason = ""
            actualFiles = @()
            branchName = ""
            artifacts = $null
        }
        Write-TaskResultFile -Task $task
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "started" -Message "Task pipeline started." -Data @{ attempt = $attemptNumber; waveNumber = $task.waveNumber }
    } finally {
        Release-Lock -LockHandle $lock
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $autoDevelopScript,
        "-PromptFile", $task.promptFile,
        "-SolutionPath", $task.solutionPath,
        "-ResultFile", $pipelineResultPath,
        "-TaskName", $task.latestRun.taskName,
        "-SchedulerTaskId", $task.taskId,
        "-CommandType", $task.sourceCommand
    )
    if ([bool]$task.allowNuget) {
        $arguments += "-AllowNuget"
    }

    $workerResult = Invoke-NativeCommand -Command "powershell.exe" -Arguments $arguments -WorkingDirectory $context.repoRoot
    $pipelineResult = Read-JsonFile -Path $pipelineResultPath
    if (-not $pipelineResult) {
        $pipelineResult = [pscustomobject]@{
            status = "ERROR"
            finalCategory = "PIPELINE_RESULT_MISSING"
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
        Apply-PipelineResultToTask -Task $task -PipelineResult $pipelineResult
        Write-TaskResultFile -Task $task
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "completed" -Message "Task pipeline finished." -Data @{
            attempt = $attemptNumber
            finalStatus = [string]$task.latestRun.finalStatus
            finalCategory = [string]$task.latestRun.finalCategory
            state = [string]$task.state
        }

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $task
            snapshot = Get-SnapshotPayload -State $state
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

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        Reconcile-State -State $state

        $alreadyPrepared = Get-MergePreparedTask -State $state
        if ($alreadyPrepared -and ((-not $TaskId) -or [string]$alreadyPrepared.taskId -ne $TaskId)) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $alreadyPrepared
                blocked = $true
                reason = "Another task already has a prepared merge."
                snapshot = Get-SnapshotPayload -State $state
            }
        }

        $selectedTask = if ($TaskId) { Get-TaskById -State $state -TaskId $TaskId } else { Get-NextMergeCandidate -State $state }
        if (-not $selectedTask) {
            return [pscustomobject]@{
                task = $null
                blocked = $false
                reason = "No task is ready for merge preparation."
                snapshot = Get-SnapshotPayload -State $state
            }
        }
        if ($selectedTask.state -ne "pending_merge") {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask
                blocked = $true
                reason = "The selected task is not pending merge."
                snapshot = Get-SnapshotPayload -State $state
            }
        }

        $unknownBranches = Get-UnknownAutoBranches -RepoRoot $context.repoRoot -KnownBranches (Get-KnownBranches -State $state)
        if ($unknownBranches.Count -gt 0) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask
                blocked = $true
                reason = "Untracked auto/* branches are blocking merge preparation."
                unknownAutoBranches = @($unknownBranches)
                snapshot = Get-SnapshotPayload -State $state
            }
        }

        if (-not (Invoke-GitCleanCheck -RepoRoot $context.repoRoot)) {
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask
                blocked = $true
                reason = "The repository worktree is not clean."
                snapshot = Get-SnapshotPayload -State $state
            }
        }

        $overlap = @(Test-ActualOverlap -State $state -Task $selectedTask)
        if ($overlap.Count -gt 0) {
            Get-RetryableResult -Task $selectedTask -Reason ("ACTUAL_OVERLAP: " + ($overlap -join ", "))
            Write-TaskResultFile -Task $selectedTask
            Save-State -StateFile $context.paths.stateFile -State $state
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $selectedTask.taskId -Kind "merge_retry" -Message "Task rescheduled after actual file overlap was detected." -Data @{ overlap = @($overlap) }
            return [pscustomobject]@{
                task = ConvertTo-TaskSnapshot -Task $selectedTask
                blocked = $false
                reason = "Task was requeued because the merged files overlap."
                snapshot = Get-SnapshotPayload -State $state
            }
        }
    } finally {
        Release-Lock -LockHandle $lock
    }

    $branchName = [string]$selectedTask.latestRun.branchName
    $mergeCommand = Invoke-NativeCommand -Command "git" -Arguments @("merge", "--no-commit", "--no-ff", $branchName) -WorkingDirectory $context.repoRoot
    if ($mergeCommand.exitCode -ne 0) {
        Undo-MergeAttempt -RepoRoot $context.repoRoot
        $mergeResult = [pscustomobject]@{
            success = $false
            reason = if ($mergeCommand.output) { $mergeCommand.output } else { "Merge conflict." }
        }
    } else {
        $buildCommand = Invoke-NativeCommand -Command "dotnet" -Arguments @("build", $selectedTask.solutionPath, "--no-restore") -WorkingDirectory $context.repoRoot
        if ($buildCommand.exitCode -ne 0) {
            Undo-MergeAttempt -RepoRoot $context.repoRoot
            $mergeResult = [pscustomobject]@{
                success = $false
                reason = if ($buildCommand.output) { $buildCommand.output } else { "Build failed after merge preparation." }
            }
        } else {
            $mergeResult = [pscustomobject]@{
                success = $true
                reason = "Merge prepared successfully."
            }
        }
    }

    $lock = Acquire-Lock -LockFile $context.paths.lockFile
    try {
        $state = Load-State -StateFile $context.paths.stateFile -RepoRoot $context.repoRoot
        $selectedTask = Get-TaskById -State $state -TaskId $selectedTask.taskId
        if (-not $selectedTask) {
            throw "Task '$TaskId' disappeared during merge preparation."
        }

        if ($mergeResult.success) {
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
            Get-RetryableResult -Task $selectedTask -Reason ([string]$mergeResult.reason)
            Remove-TaskBranch -RepoRoot $context.repoRoot -BranchName ([string]$selectedTask.latestRun.branchName)
            Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $selectedTask.taskId -Kind "merge_failed" -Message "Merge preparation failed." -Data @{ reason = [string]$mergeResult.reason }
        }

        Write-TaskResultFile -Task $selectedTask
        Save-State -StateFile $context.paths.stateFile -State $state

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $selectedTask
            prepared = [bool]$mergeResult.success
            reason = [string]$mergeResult.reason
            snapshot = Get-SnapshotPayload -State $state
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
        Reconcile-State -State $state
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
        Save-State -StateFile $context.paths.stateFile -State $state
        Append-StateEvent -EventsFile $context.paths.eventsFile -TaskId $task.taskId -Kind "merge_resolved" -Message ([string]$operation.reason) -Data @{
            decision = $Decision
            state = [string]$task.state
            commitSha = [string]$task.merge.commitSha
        }

        return [pscustomobject]@{
            task = ConvertTo-TaskSnapshot -Task $task
            decision = $Decision
            reason = [string]$operation.reason
            commitMessage = [string]$task.merge.commitMessage
            commitSha = [string]$task.merge.commitSha
            snapshot = Get-SnapshotPayload -State $state
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

$resolvedSolutionPath = if ($SolutionPath) { Get-CanonicalPath -Path $SolutionPath } else { "" }
$resolvedTasksFile = if ($TasksFile) { Get-CanonicalPath -Path $TasksFile } else { "" }
$resolvedPlanFile = if ($PlanFile) { Get-CanonicalPath -Path $PlanFile } else { "" }

switch ($Mode) {
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
    "prepare-merge" {
        Write-JsonOutput -Object (Prepare-Merge -ResolvedSolutionPath $resolvedSolutionPath -TaskId $TaskId)
        break
    }
    "resolve-merge" {
        Write-JsonOutput -Object (Resolve-Merge -ResolvedSolutionPath $resolvedSolutionPath -TaskId $TaskId -Decision $Decision -CommitMessage $CommitMessage)
        break
    }
}
