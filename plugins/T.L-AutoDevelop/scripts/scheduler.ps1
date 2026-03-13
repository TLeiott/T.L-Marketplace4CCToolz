# scheduler.ps1 -- Repo-scoped single-task scheduler for wave-managed AutoDevelop runs
param(
    [Parameter(Mandatory)][ValidateSet("submit-single", "run-single", "resolve-interactive")][string]$Mode,
    [string]$CommandType = "develop",
    [string]$PromptFile = "",
    [string]$PlanFile = "",
    [string]$SolutionPath = "",
    [string]$ResultFile = "",
    [string]$TaskId = "",
    [string]$Decision = "",
    [string]$CommitMessage = "",
    [switch]$AllowNuget,
    [switch]$UsageGateDisabled
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
    $Object | ConvertTo-Json -Depth 20
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

function Ensure-Directory {
    param([string]$Path)
    if ($Path -and -not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-ParentDirectory {
    param([string]$Path)
    $parent = Split-Path $Path -Parent
    if ($parent) { Ensure-Directory -Path $parent }
}

function Normalize-RepoRelativePath {
    param([string]$Path)
    if (-not $Path) { return "" }
    $normalized = $Path.Trim().Replace("/", "\")
    while ($normalized.StartsWith(".\")) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized.TrimStart('\').Trim()
}

function Get-NormalizedPathSet {
    param([string[]]$Paths)
    return @(
        @($Paths | ForEach-Object {
            $value = Normalize-RepoRelativePath -Path ([string]$_)
            if ($value) { $value }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-CanonicalRepoRoot {
    param([string]$SolutionPath)
    $solutionDir = Split-Path (Get-CanonicalPath -Path $SolutionPath) -Parent
    $result = Invoke-NativeCommand git @("rev-parse", "--show-toplevel") $solutionDir
    if ($result.exitCode -ne 0 -or -not $result.output) {
        throw "Kein Git-Repository fuer Solution gefunden: $SolutionPath"
    }
    return (Get-CanonicalPath -Path $result.output)
}

function Get-RepoHash {
    param([string]$RepoRoot)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RepoRoot.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString("x2") } | Select-Object -First 12)
    } finally {
        $sha.Dispose()
    }
}

function Get-StatePaths {
    param([string]$RepoRoot)
    $repoHash = Get-RepoHash -RepoRoot $RepoRoot
    $baseDir = Join-Path $env:TEMP "claude-develop\scheduler\$repoHash"
    return [pscustomobject]@{
        repoHash = $repoHash
        baseDir = $baseDir
        stateFile = Join-Path $baseDir "state.json"
        eventsFile = Join-Path $baseDir "events.jsonl"
        lockFile = Join-Path $baseDir "state.lock"
    }
}

function New-EmptyState {
    param([string]$RepoRoot, [string]$RepoHash)
    return [pscustomobject]@{
        version = 1
        repoRoot = $RepoRoot
        repoHash = $RepoHash
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
        tasks = @()
    }
}

function Load-State {
    param([string]$StateFile, [string]$RepoRoot, [string]$RepoHash)
    if (-not (Test-Path $StateFile)) {
        return New-EmptyState -RepoRoot $RepoRoot -RepoHash $RepoHash
    }
    $state = Get-Content $StateFile -Raw | ConvertFrom-Json
    if (-not $state.tasks) { $state | Add-Member -NotePropertyName tasks -NotePropertyValue @() -Force }
    if (-not $state.repoRoot) { $state | Add-Member -NotePropertyName repoRoot -NotePropertyValue $RepoRoot -Force }
    if (-not $state.repoHash) { $state | Add-Member -NotePropertyName repoHash -NotePropertyValue $RepoHash -Force }
    return $state
}

function Save-State {
    param([string]$StateFile, $State)
    $State.updatedAt = (Get-Date).ToString("o")
    Ensure-ParentDirectory -Path $StateFile
    [System.IO.File]::WriteAllText($StateFile, ($State | ConvertTo-Json -Depth 20), [System.Text.Encoding]::UTF8)
}

function Append-StateEvent {
    param([string]$EventsFile, [string]$TaskId, [string]$Kind, [string]$Message, $Data)
    Ensure-ParentDirectory -Path $EventsFile
    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        taskId = $TaskId
        kind = $Kind
        message = $Message
        data = $Data
    } | ConvertTo-Json -Depth 12 -Compress
    Add-Content -Path $EventsFile -Value $entry -Encoding UTF8
}

function Acquire-Lock {
    param([string]$LockFile, [int]$TimeoutSeconds = 180)
    Ensure-ParentDirectory -Path $LockFile
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            return [System.IO.File]::Open($LockFile, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Scheduler-Lock konnte nicht erworben werden: $LockFile"
}

function Release-Lock {
    param($LockHandle)
    if ($LockHandle) { $LockHandle.Dispose() }
}

function Get-TaskById {
    param($State, [string]$TaskId)
    return @($State.tasks | Where-Object { $_.taskId -eq $TaskId } | Select-Object -First 1)[0]
}

function Get-Tasks {
    param($State)
    return @($State.tasks | Where-Object { $_ })
}

function Get-TaskMode {
    param([string]$CommandType)
    if ($CommandType -eq "TLA-develop") { return "autonomous" }
    return "interactive"
}

function Get-TaskNamePrefix {
    param([string]$CommandType)
    if ($CommandType -eq "TLA-develop") { return "tla" }
    return "develop"
}

function Get-ShortTaskId {
    param([string]$TaskId)
    if (-not $TaskId) { return "task" }
    $token = ($TaskId -replace '[^A-Za-z0-9]', '')
    if ($token.Length -gt 8) { return $token.Substring(0, 8).ToLowerInvariant() }
    return $token.ToLowerInvariant()
}

function New-SchedulerTaskRecord {
    param(
        [string]$TaskId,
        [string]$CommandType,
        [string]$PromptFile,
        [string]$PlanFile,
        [string]$SolutionPath,
        [string]$ResultFile,
        [string]$RepoRoot,
        [int]$SubmissionOrder,
        [int]$WaveNumber,
        $Plan,
        [bool]$AllowNuget,
        [bool]$UsageGateDisabled,
        [string]$StateDir
    )
    $taskName = "{0}-{1}-{2}" -f (Get-TaskNamePrefix -CommandType $CommandType), (Get-Date -Format "yyyyMMdd-HHmmss"), (Get-ShortTaskId -TaskId $TaskId)
    $runDir = Join-Path (Join-Path $RepoRoot ".claude-develop-logs\runs") $taskName
    return [pscustomobject]@{
        taskId = $TaskId
        commandType = $CommandType
        mode = Get-TaskMode -CommandType $CommandType
        taskName = $taskName
        promptFile = $PromptFile
        planFile = $PlanFile
        resultFile = $ResultFile
        pipelineResultFile = Join-Path $StateDir ("pipeline-" + $TaskId + ".json")
        mergeOutcomeFile = Join-Path $StateDir ("merge-" + $TaskId + ".json")
        solutionPath = $SolutionPath
        repoRoot = $RepoRoot
        createdAt = (Get-Date).ToString("o")
        updatedAt = (Get-Date).ToString("o")
        submissionOrder = $SubmissionOrder
        waveNumber = $WaveNumber
        state = "queued"
        allowNuget = [bool]$AllowNuget
        usageGateDisabled = [bool]$UsageGateDisabled
        plan = [pscustomobject]@{
            taskText = [string]$Plan.taskText
            taskClassGuess = [string]$Plan.taskClassGuess
            likelyAreas = @(Get-NormalizedPathSet -Paths $Plan.likelyAreas)
            likelyFiles = @(Get-NormalizedPathSet -Paths $Plan.likelyFiles)
            searchPatterns = @(Get-NormalizedPathSet -Paths $Plan.searchPatterns)
            dependencyHints = @($Plan.dependencyHints | Where-Object { $_ } | Select-Object -Unique)
            conflictRisk = if ($Plan.conflictRisk) { [string]$Plan.conflictRisk } else { "HIGH" }
            confidence = if ($Plan.confidence) { [string]$Plan.confidence } else { "LOW" }
            rationale = [string]$Plan.rationale
        }
        run = [pscustomobject]@{
            processId = 0
            route = ""
            testability = ""
            discoverTargetHints = @()
            investigationTargets = @()
            planTargets = @()
            actualFiles = @()
            finalStatus = ""
            finalCategory = ""
            summary = ""
            feedback = ""
            noChangeReason = ""
            attempts = 0
            branchName = ""
            worktreePath = ""
            artifacts = [pscustomobject]@{
                runDir = $runDir
                debugDir = ""
            }
        }
        merge = [pscustomobject]@{
            state = ""
            commitMessage = ""
            commitSha = ""
            reason = ""
            mergeReadyAt = ""
            resolvedAt = ""
        }
        scheduler = [pscustomobject]@{
            owner = ""
            runnerProcessId = 0
            runnerHeartbeatAt = ""
        }
    }
}

function Get-PlanFromFile {
    param([string]$PlanFile)
    if (-not (Test-Path $PlanFile)) {
        throw "Plan-Datei nicht gefunden: $PlanFile"
    }
    $plan = Get-Content $PlanFile -Raw | ConvertFrom-Json
    if (-not $plan.taskText) {
        throw "Plan-Datei enthaelt kein taskText: $PlanFile"
    }
    return $plan
}

function Ensure-TaskSchedulerMetadata {
    param($Task)
    if (-not $Task.scheduler) {
        $Task | Add-Member -NotePropertyName scheduler -NotePropertyValue ([pscustomobject]@{
            owner = ""
            runnerProcessId = 0
            runnerHeartbeatAt = ""
        }) -Force
    }
    if ($null -eq $Task.scheduler.owner) { $Task.scheduler.owner = "" }
    if ($null -eq $Task.scheduler.runnerProcessId) { $Task.scheduler.runnerProcessId = 0 }
    if ($null -eq $Task.scheduler.runnerHeartbeatAt) { $Task.scheduler.runnerHeartbeatAt = "" }
}

function Set-TaskRunnerOwnership {
    param($Task, [string]$Owner)
    Ensure-TaskSchedulerMetadata -Task $Task
    $Task.scheduler.owner = $Owner
    $Task.scheduler.runnerProcessId = $PID
    $Task.scheduler.runnerHeartbeatAt = (Get-Date).ToString("o")
}

function Clear-TaskRunnerOwnership {
    param($Task)
    Ensure-TaskSchedulerMetadata -Task $Task
    $Task.scheduler.owner = ""
    $Task.scheduler.runnerProcessId = 0
    $Task.scheduler.runnerHeartbeatAt = ""
}

function Set-TaskOrphaned {
    param($Task, [string]$Reason)
    Clear-TaskRunnerOwnership -Task $Task
    $Task.state = "orphaned_error"
    $Task.merge.state = "orphaned"
    $Task.merge.reason = $Reason
    $Task.merge.resolvedAt = (Get-Date).ToString("o")
}

function Ensure-TaskArtifactMetadata {
    param($Task)
    if (-not $Task.pipelineResultFile) {
        $stateDir = Join-Path $env:TEMP ("claude-develop\scheduler\" + (Get-RepoHash -RepoRoot $Task.repoRoot))
        $Task | Add-Member -NotePropertyName pipelineResultFile -NotePropertyValue (Join-Path $stateDir ("pipeline-" + $Task.taskId + ".json")) -Force
    }
    if (-not $Task.mergeOutcomeFile) {
        $stateDir = Split-Path $Task.pipelineResultFile -Parent
        $Task | Add-Member -NotePropertyName mergeOutcomeFile -NotePropertyValue (Join-Path $stateDir ("merge-" + $Task.taskId + ".json")) -Force
    }
}

function Try-ReadJsonFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content $Path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function New-TaskPipelineLikeResult {
    param($Task)
    return [pscustomobject]@{
        finalCategory = [string]$Task.run.finalCategory
        summary = [string]$Task.run.summary
        feedback = [string]$Task.run.feedback
        noChangeReason = [string]$Task.run.noChangeReason
        files = @(Get-NormalizedPathSet -Paths $Task.run.actualFiles)
        attempts = [int]$Task.run.attempts
        attemptsByPhase = $null
        artifacts = $Task.run.artifacts
        branch = [string]$Task.run.branchName
    }
}

function Set-TaskSchedulerError {
    param(
        $Task,
        [string]$FinalCategory,
        [string]$Summary,
        [string]$Feedback = ""
    )
    $Task.state = "completed_error"
    $Task.run.finalStatus = "ERROR"
    $Task.run.finalCategory = $FinalCategory
    $Task.run.summary = $Summary
    $Task.run.feedback = $Feedback
    $Task.merge.state = "error"
    $Task.merge.reason = $Summary
    $Task.merge.resolvedAt = (Get-Date).ToString("o")
    Clear-TaskRunnerOwnership -Task $Task
}

function Save-TaskMergeOutcome {
    param(
        $Task,
        [string]$State,
        [string]$Summary,
        [string]$CommitMessage = "",
        [string]$CommitSha = ""
    )
    Ensure-TaskArtifactMetadata -Task $Task
    Ensure-ParentDirectory -Path $Task.mergeOutcomeFile
    $payload = [pscustomobject]@{
        version = 1
        taskId = $Task.taskId
        state = $State
        summary = $Summary
        commitMessage = $CommitMessage
        commitSha = $CommitSha
        resolvedAt = (Get-Date).ToString("o")
    }
    [System.IO.File]::WriteAllText($Task.mergeOutcomeFile, ($payload | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)
    return $payload
}

function Apply-MergeOutcomeToTask {
    param($Task, $MergeOutcome)
    if (-not $MergeOutcome) { return $false }
    $Task.state = [string]$MergeOutcome.state
    $Task.merge.state = [string]$MergeOutcome.state
    $Task.merge.reason = [string]$MergeOutcome.summary
    $Task.merge.commitMessage = [string]$MergeOutcome.commitMessage
    $Task.merge.commitSha = [string]$MergeOutcome.commitSha
    $Task.merge.resolvedAt = if ($MergeOutcome.resolvedAt) { [string]$MergeOutcome.resolvedAt } else { (Get-Date).ToString("o") }
    Clear-TaskRunnerOwnership -Task $Task
    return $true
}

function Get-TaskResultStatus {
    param($Task)
    switch ([string]$Task.state) {
        "awaiting_interactive_decision" { return "MERGE_READY" }
        "completed_no_change" { return "NO_CHANGE" }
        "completed_failed" { return "FAILED" }
        "completed_error" { return "ERROR" }
        "merged_committed" { return "COMMITTED" }
        "merged_discarded" { return "DISCARDED" }
        "skipped_conflict" { return "SKIPPED_CONFLICT" }
        "skipped_merge_conflict" { return "SKIPPED_MERGE_CONFLICT" }
        "skipped_build_failure" { return "SKIPPED_BUILD_FAILURE" }
        "orphaned_error" { return "ERROR" }
        default { return "" }
    }
}

function Get-TaskPipelineResultOrFallback {
    param($Task)
    Ensure-TaskArtifactMetadata -Task $Task
    $pipelineResult = Try-ReadJsonFile -Path $Task.pipelineResultFile
    if ($pipelineResult) { return $pipelineResult }
    return (New-TaskPipelineLikeResult -Task $Task)
}

function Write-TaskResultIfMissing {
    param($Task)
    if (Test-Path $Task.resultFile) { return $false }
    $status = Get-TaskResultStatus -Task $Task
    if (-not $status) { return $false }
    $pipelineResult = Get-TaskPipelineResultOrFallback -Task $Task
    $message = switch ($status) {
        "MERGE_READY" { "Task ist merge-bereit." }
        "ERROR" { if ($Task.merge.reason) { [string]$Task.merge.reason } else { [string]$Task.run.summary } }
        default { if ($Task.merge.reason) { [string]$Task.merge.reason } else { [string]$Task.run.summary } }
    }
    $commitMessage = if ($Task.state -eq "merged_committed") { [string]$Task.merge.commitMessage } else { "" }
    Write-UserResult -Path $Task.resultFile -Status $status -TaskId $Task.taskId -WaveNumber ([int]$Task.waveNumber) -PipelineResult $pipelineResult -Task $Task -Message $message -CommitMessage $commitMessage
    return $true
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

function Is-ResolvedTaskState {
    param([string]$State)
    return $State -in @(
        "completed_no_change",
        "completed_failed",
        "completed_error",
        "merged_committed",
        "merged_discarded",
        "skipped_conflict",
        "skipped_merge_conflict",
        "skipped_build_failure",
        "orphaned_error"
    )
}

function Is-PreTerminalTaskState {
    param([string]$State)
    return $State -in @("queued", "usage_wait", "running")
}

function Get-UnresolvedTasks {
    param($State)
    return @((Get-Tasks -State $State) | Where-Object { -not (Is-ResolvedTaskState -State $_.state) })
}

function Get-NextSubmissionOrder {
    param($State)
    $tasks = Get-Tasks -State $State
    if ($tasks.Count -eq 0) { return 1 }
    return ((@($tasks | ForEach-Object { [int]$_.submissionOrder } | Measure-Object -Maximum).Maximum) + 1)
}

function Get-CurrentOpenWaveNumber {
    param($State)
    $unresolved = Get-UnresolvedTasks -State $State
    if ($unresolved.Count -eq 0) { return 0 }
    $minWave = (@($unresolved | ForEach-Object { [int]$_.waveNumber } | Measure-Object -Minimum).Minimum)
    $waveTasks = @($unresolved | Where-Object { [int]$_.waveNumber -eq $minWave })
    if ($waveTasks.Count -eq 0) { return 0 }
    if (@($waveTasks | Where-Object { -not (Is-PreTerminalTaskState -State $_.state) }).Count -gt 0) { return 0 }
    return $minWave
}

function Get-NextWaveNumber {
    param($State)
    $tasks = Get-Tasks -State $State
    if ($tasks.Count -eq 0) { return 1 }
    return ((@($tasks | ForEach-Object { [int]$_.waveNumber } | Measure-Object -Maximum).Maximum) + 1)
}

function Get-ComparisonData {
    param($TaskLike)
    $paths = [System.Collections.ArrayList]::new()
    foreach ($item in @($TaskLike.run.actualFiles + $TaskLike.run.planTargets + $TaskLike.run.investigationTargets + $TaskLike.run.discoverTargetHints + $TaskLike.plan.likelyFiles)) {
        $value = Normalize-RepoRelativePath -Path ([string]$item)
        if ($value) { [void]$paths.Add($value) }
    }
    $areas = [System.Collections.ArrayList]::new()
    foreach ($item in @($TaskLike.plan.likelyAreas + $TaskLike.plan.searchPatterns)) {
        $value = Normalize-RepoRelativePath -Path ([string]$item)
        if ($value) { [void]$areas.Add($value) }
    }
    $topLevel = [System.Collections.ArrayList]::new()
    foreach ($value in @($paths + $areas)) {
        $token = $value
        if ($token.Contains("\")) {
            $token = ($token -split "\\")[0]
        } elseif ($token.Contains("/")) {
            $token = ($token -split "/")[0]
        }
        if ($token) { [void]$topLevel.Add($token.ToLowerInvariant()) }
    }
    $configLike = @($paths + $areas | Where-Object { $_ -match '(?i)\.(csproj|sln|slnx|props|targets|json|ya?ml|config)$' })
    return [pscustomobject]@{
        files = @($paths | Select-Object -Unique)
        areas = @($areas | Select-Object -Unique)
        topLevel = @($topLevel | Select-Object -Unique)
        configLike = @(Get-NormalizedPathSet -Paths $configLike)
        broad = (($TaskLike.plan.confidence -ne "HIGH") -or ($TaskLike.plan.conflictRisk -ne "LOW") -or (@($paths).Count -eq 0))
    }
}

function Test-PathOverlap {
    param([string[]]$Left, [string[]]$Right)
    foreach ($a in @($Left)) {
        foreach ($b in @($Right)) {
            if ($a -ieq $b) { return $true }
            if ($a.StartsWith($b.TrimEnd('\') + "\", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ($b.StartsWith($a.TrimEnd('\') + "\", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Test-PlanConflict {
    param($LeftTask, $RightTask)
    $left = Get-ComparisonData -TaskLike $LeftTask
    $right = Get-ComparisonData -TaskLike $RightTask
    if ($left.files.Count -eq 0 -and $right.files.Count -eq 0 -and $left.areas.Count -eq 0 -and $right.areas.Count -eq 0) {
        return $true
    }
    if (Test-PathOverlap -Left $left.files -Right $right.files) { return $true }
    if (Test-PathOverlap -Left $left.configLike -Right $right.configLike) { return $true }
    if (Test-PathOverlap -Left ($left.files + $left.areas) -Right ($right.files + $right.areas)) { return $true }
    $sharedTop = @($left.topLevel | Where-Object { $right.topLevel -contains $_ })
    if ($sharedTop.Count -gt 0 -and ($left.broad -or $right.broad)) { return $true }
    if (($left.broad -or $right.broad) -and ($left.topLevel.Count -eq 0 -or $right.topLevel.Count -eq 0)) { return $true }
    return $false
}

function Get-ExternalDebugRecords {
    param([string]$RepoRoot, [string[]]$KnownTaskNames)
    $debugRoot = Join-Path $env:TEMP "claude-develop\debug"
    if (-not (Test-Path $debugRoot)) { return @() }
    $records = [System.Collections.ArrayList]::new()
    foreach ($dir in @(Get-ChildItem -Path $debugRoot -Directory -ErrorAction SilentlyContinue)) {
        $manifestPath = Join-Path $dir.FullName "manifest.json"
        if (-not (Test-Path $manifestPath)) { continue }
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        } catch {
            continue
        }
        if (-not $manifest.repoRoot) { continue }
        if ((Get-CanonicalPath -Path $manifest.repoRoot) -ne $RepoRoot) { continue }
        if ($KnownTaskNames -contains $manifest.taskName) { continue }
        $snapshotPath = ""
        if ($manifest.artifactRunDir) {
            $candidate = Join-Path $manifest.artifactRunDir "scheduler-snapshot.json"
            if (Test-Path $candidate) { $snapshotPath = $candidate }
        }
        if (-not $snapshotPath -and $manifest.debugDir) {
            $candidate = Join-Path $manifest.debugDir "scheduler-snapshot.json"
            if (Test-Path $candidate) { $snapshotPath = $candidate }
        }
        $snapshot = $null
        if ($snapshotPath) {
            try { $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json } catch { $snapshot = $null }
        }
        [void]$records.Add([pscustomobject]@{
            taskName = [string]$manifest.taskName
            commandType = if ($snapshot -and $snapshot.commandType) { [string]$snapshot.commandType } else { "legacy" }
            branchName = if ($snapshot -and $snapshot.branchName) { [string]$snapshot.branchName } else { [string]$manifest.branchName }
            manifest = $manifest
            snapshot = $snapshot
            processAlive = (Test-ProcessAlive -ProcessId ([int]$manifest.processId))
        })
    }
    return @($records)
}

function Get-UnownedAutoBranches {
    param([string]$RepoRoot, [string[]]$KnownBranches)
    $result = Invoke-NativeCommand git @("branch", "--list", "auto/*") $RepoRoot
    if ($result.exitCode -ne 0 -or -not $result.output) { return @() }
    return @(
        @($result.output -split "`r?`n" | ForEach-Object {
            ($_ -replace '^[\*\+\s]+', '').Trim()
        } | Where-Object { $_ -and -not ($KnownBranches -contains $_) } | Select-Object -Unique)
    )
}

function New-ExternalTaskFromRecord {
    param($Record, [string]$State, [string]$Rationale)
    $snapshot = $Record.snapshot
    return [pscustomobject]@{
        taskId = "external:" + $Record.taskName
        taskName = $Record.taskName
        commandType = $Record.commandType
        state = $State
        plan = [pscustomobject]@{
            taskText = ""
            taskClassGuess = ""
            likelyAreas = @()
            likelyFiles = if ($snapshot) { @(Get-NormalizedPathSet -Paths ($snapshot.planTargets + $snapshot.changedFiles)) } else { @() }
            searchPatterns = if ($snapshot) { @(Get-NormalizedPathSet -Paths ($snapshot.investigationTargets + $snapshot.discoverTargetHints)) } else { @() }
            dependencyHints = @()
            conflictRisk = if ($snapshot) { "MEDIUM" } else { "HIGH" }
            confidence = if ($snapshot) { "MEDIUM" } else { "LOW" }
            rationale = $Rationale
        }
        run = [pscustomobject]@{
            actualFiles = if ($snapshot) { @(Get-NormalizedPathSet -Paths $snapshot.changedFiles) } else { @() }
            planTargets = if ($snapshot) { @(Get-NormalizedPathSet -Paths $snapshot.planTargets) } else { @() }
            investigationTargets = if ($snapshot) { @(Get-NormalizedPathSet -Paths $snapshot.investigationTargets) } else { @() }
            discoverTargetHints = if ($snapshot) { @(Get-NormalizedPathSet -Paths $snapshot.discoverTargetHints) } else { @() }
            branchName = [string]$Record.branchName
        }
    }
}

function Get-ExternalAutoTasks {
    param([string]$RepoRoot, [string[]]$KnownTaskNames, [string[]]$KnownBranches)
    $records = Get-ExternalDebugRecords -RepoRoot $RepoRoot -KnownTaskNames $KnownTaskNames
    $unownedBranches = @(Get-UnownedAutoBranches -RepoRoot $RepoRoot -KnownBranches $KnownBranches)
    $tasks = [System.Collections.ArrayList]::new()
    $classifiedBranches = [System.Collections.ArrayList]::new()

    foreach ($record in @($records)) {
        if (-not $record.branchName) { continue }
        if ($KnownBranches -contains $record.branchName) { continue }
        if ($unownedBranches -notcontains $record.branchName) { continue }

        if ($record.processAlive) {
            [void]$tasks.Add((New-ExternalTaskFromRecord -Record $record -State "running" -Rationale "Aktiver externer AutoDevelop-Lauf."))
            [void]$classifiedBranches.Add($record.branchName)
            continue
        }

        if ($record.snapshot -and [string]$record.snapshot.finalStatus -eq "ACCEPTED") {
            [void]$tasks.Add((New-ExternalTaskFromRecord -Record $record -State "pending_merge" -Rationale "Externe akzeptierte Aenderung wartet noch auf Merge oder Abschluss."))
            [void]$classifiedBranches.Add($record.branchName)
        }
    }

    $unknownBranches = @(
        @($unownedBranches | Where-Object { $classifiedBranches -notcontains $_ })
    )

    return [pscustomobject]@{
        tasks = @($tasks)
        unknownBranches = @($unknownBranches)
    }
}

function Refresh-ManagedTaskFromSnapshot {
    param($Task)
    Ensure-TaskSchedulerMetadata -Task $Task
    $snapshotPath = Join-Path $Task.run.artifacts.runDir "scheduler-snapshot.json"
    if (-not (Test-Path $snapshotPath)) { return }
    try {
        $snapshot = Get-Content $snapshotPath -Raw | ConvertFrom-Json
    } catch {
        return
    }
    $Task.run.route = [string]$snapshot.route
    $Task.run.testability = [string]$snapshot.testability
    $Task.run.discoverTargetHints = @(Get-NormalizedPathSet -Paths $snapshot.discoverTargetHints)
    $Task.run.investigationTargets = @(Get-NormalizedPathSet -Paths $snapshot.investigationTargets)
    $Task.run.planTargets = @(Get-NormalizedPathSet -Paths $snapshot.planTargets)
    $Task.run.actualFiles = @(Get-NormalizedPathSet -Paths $snapshot.changedFiles)
    $Task.run.branchName = [string]$snapshot.branchName
    if ($snapshot.artifacts -and $snapshot.artifacts.debugDir) {
        $Task.run.artifacts.debugDir = [string]$snapshot.artifacts.debugDir
    }
    if ($snapshot.worktreePath) {
        $Task.run.worktreePath = [string]$snapshot.worktreePath
    }
    if ($snapshot.processId) {
        $Task.run.processId = [int]$snapshot.processId
    }
}

function Reconcile-TaskState {
    param($Task)
    Ensure-TaskSchedulerMetadata -Task $Task
    Ensure-TaskArtifactMetadata -Task $Task
    Refresh-ManagedTaskFromSnapshot -Task $Task
    $runnerAlive = ($Task.scheduler.runnerProcessId -gt 0 -and (Test-ProcessAlive -ProcessId ([int]$Task.scheduler.runnerProcessId)))
    $pipelineAlive = ($Task.run.processId -gt 0 -and (Test-ProcessAlive -ProcessId ([int]$Task.run.processId)))

    $mergeOutcome = Try-ReadJsonFile -Path $Task.mergeOutcomeFile
    if (Apply-MergeOutcomeToTask -Task $Task -MergeOutcome $mergeOutcome) {
        return
    }

    $pipelineResult = Try-ReadJsonFile -Path $Task.pipelineResultFile
    if ($pipelineResult) {
        Update-TaskFromPipelineResult -Task $Task -PipelineResult $pipelineResult
        if (-not $runnerAlive) {
            Clear-TaskRunnerOwnership -Task $Task
        }
        return
    }

    if ($Task.state -eq "running" -and $Task.run.processId -and -not $pipelineAlive) {
        Set-TaskOrphaned -Task $Task -Reason "Pipeline-Prozess beendet ohne Result-Datei."
        return
    }
    if ($Task.state -in @("queued", "usage_wait", "running", "accepted_pending_wave_close", "merge_in_progress")) {
        if ($Task.scheduler.owner -and -not $runnerAlive) {
            $reason = switch ($Task.state) {
                "queued" { "Scheduler-Runner ist vor dem Start ausgefallen." }
                "usage_wait" { "Scheduler-Runner ist waehrend des Usage-Waits ausgefallen." }
                "running" { "Scheduler-Runner ist waehrend der Pipeline-Ausfuehrung ausgefallen." }
                "accepted_pending_wave_close" { "Scheduler-Runner ist vor der Merge-Freigabe ausgefallen." }
                "merge_in_progress" { "Scheduler-Runner ist waehrend des Merge-Schritts ausgefallen." }
                default { "Scheduler-Runner ist ausgefallen." }
            }
            Set-TaskOrphaned -Task $Task -Reason $reason
        }
    }
}

function Get-KnownBranches {
    param($State)
    return @(
        @((Get-Tasks -State $State) | ForEach-Object {
            if ($_.run.branchName) { [string]$_.run.branchName }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-TaskByWaveOrder {
    param($State, [int]$WaveNumber)
    return @((Get-Tasks -State $State) | Where-Object { [int]$_.waveNumber -eq $WaveNumber } | Sort-Object submissionOrder)
}

function Test-WaveRunComplete {
    param($State, [int]$WaveNumber)
    $waveTasks = Get-TaskByWaveOrder -State $State -WaveNumber $WaveNumber
    if ($waveTasks.Count -eq 0) { return $true }
    return (@($waveTasks | Where-Object { $_.state -in @("queued", "usage_wait", "running") }).Count -eq 0)
}

function Test-WavesBeforeResolved {
    param($State, [int]$WaveNumber)
    return (@((Get-Tasks -State $State) | Where-Object { ([int]$_.waveNumber -lt $WaveNumber) -and -not (Is-ResolvedTaskState -State $_.state) }).Count -eq 0)
}

function Get-MergedFilesBeforeTask {
    param($State, [int]$WaveNumber, [int]$SubmissionOrder)
    $files = [System.Collections.ArrayList]::new()
    foreach ($task in @((Get-Tasks -State $State) | Sort-Object waveNumber, submissionOrder)) {
        if ($task.waveNumber -gt $WaveNumber) { break }
        if ($task.waveNumber -eq $WaveNumber -and $task.submissionOrder -ge $SubmissionOrder) { break }
        if ($task.state -eq "merged_committed") {
            foreach ($file in @($task.run.actualFiles)) {
                $normalized = Normalize-RepoRelativePath -Path ([string]$file)
                if ($normalized) { [void]$files.Add($normalized) }
            }
        }
    }
    return @($files | Select-Object -Unique)
}

function Try-MarkSkippedConflict {
    param($State, $Task)
    $actualFiles = @(Get-NormalizedPathSet -Paths $Task.run.actualFiles)
    $mergedFiles = Get-MergedFilesBeforeTask -State $State -WaveNumber ([int]$Task.waveNumber) -SubmissionOrder ([int]$Task.submissionOrder)
    $overlap = @($actualFiles | Where-Object { $mergedFiles -contains $_ })
    $parallelCount = @((Get-TaskByWaveOrder -State $State -WaveNumber ([int]$Task.waveNumber))).Count
    $riskyEmpty = ($actualFiles.Count -eq 0 -and $parallelCount -gt 1 -and $Task.plan.confidence -ne "HIGH")
    if ($overlap.Count -eq 0 -and -not $riskyEmpty) { return $false }
    $Task.state = "skipped_conflict"
    $Task.merge.state = "skipped_conflict"
    $Task.merge.reason = if ($overlap.Count -gt 0) {
        "Unerwartete Datei-Ueberschneidung nach Lauf."
    } else {
        "Leere result.files in paralleler unsicherer Welle."
    }
    $Task.merge.resolvedAt = (Get-Date).ToString("o")
    return $true
}

function Get-AcceptedWaveTasksInOrder {
    param($State, [int]$WaveNumber)
    return @((Get-TaskByWaveOrder -State $State -WaveNumber $WaveNumber) | Where-Object {
        $_.state -in @("accepted_pending_wave_close", "awaiting_interactive_decision", "merge_in_progress", "merged_committed", "merged_discarded", "skipped_conflict", "skipped_merge_conflict", "skipped_build_failure")
    })
}

function Test-IsMergeTurn {
    param($State, $Task)
    if (-not (Test-WavesBeforeResolved -State $State -WaveNumber ([int]$Task.waveNumber))) { return $false }
    if (-not (Test-WaveRunComplete -State $State -WaveNumber ([int]$Task.waveNumber))) { return $false }
    $accepted = Get-AcceptedWaveTasksInOrder -State $State -WaveNumber ([int]$Task.waveNumber)
    foreach ($candidate in $accepted) {
        if ($candidate.state -in @("accepted_pending_wave_close", "merge_in_progress", "awaiting_interactive_decision")) {
            return ($candidate.taskId -eq $Task.taskId)
        }
    }
    return $false
}

function Test-TaskCanStartNow {
    param($State, $Task, $ExternalTasks)
    if (-not (Test-WavesBeforeResolved -State $State -WaveNumber ([int]$Task.waveNumber))) { return $false }
    if (@($ExternalTasks | Where-Object { $_.state -eq "pending_merge" }).Count -gt 0) { return $false }
    foreach ($external in @($ExternalTasks)) {
        if ($external.state -eq "pending_merge") { continue }
        if (Test-PlanConflict -LeftTask $Task -RightTask $external) { return $false }
    }
    return $true
}

function Get-AutoDevelopScriptPath {
    return (Get-CanonicalPath -Path (Join-Path $PSScriptRoot "auto-develop.ps1"))
}

function Get-UsageGatePath {
    $candidate = Join-Path $PSScriptRoot "claude-usage-gate.ps1"
    if (Test-Path $candidate) { return $candidate }
    return ""
}

function Wait-ForUsageGate {
    param([string]$StateDir, [string]$TaskId, [bool]$Disabled)
    if ($Disabled) {
        return [pscustomobject]@{
            ok = $true
            processStatus = "disabled"
            waitedSeconds = 0
            source = "disabled"
            fiveHourUtilization = $null
            errors = @()
        }
    }
    $gateScript = Get-UsageGatePath
    if (-not $gateScript) {
        return [pscustomobject]@{
            ok = $false
            processStatus = "unavailable"
            waitedSeconds = 0
            source = "none"
            fiveHourUtilization = $null
            errors = @("claude-usage-gate.ps1 wurde nicht gefunden.")
        }
    }
    $gateJson = Join-Path $StateDir ("usage-" + $TaskId + ".json")
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $gateScript,
        "-Mode", "wait",
        "-ThresholdPercent", "90"
    )
    $proc = Start-Process powershell.exe -ArgumentList $args -RedirectStandardOutput $gateJson -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0 -or -not (Test-Path $gateJson)) {
        return [pscustomobject]@{
            ok = $false
            processStatus = "fatal"
            waitedSeconds = 0
            source = "none"
            fiveHourUtilization = $null
            errors = @("Wait-Mode des 5h-Usage-Gates lieferte kein lesbares JSON-Ergebnis.")
        }
    }
    try {
        return (Get-Content $gateJson -Raw | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{
            ok = $false
            processStatus = "fatal"
            waitedSeconds = 0
            source = "none"
            fiveHourUtilization = $null
            errors = @("Wait-Mode des 5h-Usage-Gates konnte nicht geparst werden.")
        }
    }
}

function Write-UserResult {
    param(
        [string]$Path,
        [string]$Status,
        [string]$TaskId,
        [int]$WaveNumber,
        $PipelineResult,
        $Task,
        [string]$Message = "",
        [string]$CommitMessage = ""
    )
    Ensure-ParentDirectory -Path $Path
    $payload = [pscustomobject]@{
        status = $Status
        schedulerTaskId = $TaskId
        waveNumber = $WaveNumber
        schedulerState = $Task.state
        finalCategory = if ($PipelineResult) { [string]$PipelineResult.finalCategory } else { "" }
        summary = if ($Message) { $Message } elseif ($PipelineResult) { [string]$PipelineResult.summary } else { "" }
        feedback = if ($PipelineResult) { [string]$PipelineResult.feedback } else { "" }
        noChangeReason = if ($PipelineResult) { [string]$PipelineResult.noChangeReason } else { "" }
        files = if ($PipelineResult) { @(Get-NormalizedPathSet -Paths $PipelineResult.files) } else { @() }
        attempts = if ($PipelineResult) { [int]$PipelineResult.attempts } else { 0 }
        attemptsByPhase = if ($PipelineResult) { $PipelineResult.attemptsByPhase } else { $null }
        artifacts = if ($PipelineResult) { $PipelineResult.artifacts } else { $Task.run.artifacts }
        branch = if ($PipelineResult) { [string]$PipelineResult.branch } else { [string]$Task.run.branchName }
        commitMessage = $CommitMessage
        mergeReason = [string]$Task.merge.reason
    }
    [System.IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)
}

function Start-AutoDevelopRun {
    param($Task)
    $autoDevelop = Get-AutoDevelopScriptPath
    Ensure-ParentDirectory -Path $Task.pipelineResultFile
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $autoDevelop,
        "-PromptFile", $Task.promptFile,
        "-SolutionPath", $Task.solutionPath,
        "-ResultFile", $Task.pipelineResultFile,
        "-TaskName", $Task.taskName,
        "-SchedulerTaskId", $Task.taskId,
        "-CommandType", $Task.commandType
    )
    if ($Task.allowNuget) { $args += "-AllowNuget" }
    Start-Process powershell.exe -ArgumentList $args -WorkingDirectory $Task.repoRoot -Wait -PassThru -NoNewWindow | Out-Null
    if (Test-Path $Task.pipelineResultFile) {
        return Get-Content $Task.pipelineResultFile -Raw | ConvertFrom-Json
    }
    return [pscustomobject]@{
        status = "ERROR"
        finalCategory = "MISSING_RESULT_FILE"
        summary = "Pipeline lieferte keine Result-Datei."
        feedback = ""
        noChangeReason = ""
        attempts = 0
        files = @()
        artifacts = [pscustomobject]@{
            runDir = $Task.run.artifacts.runDir
            debugDir = $Task.run.artifacts.debugDir
        }
        branch = ""
    }
}

function Update-TaskFromPipelineResult {
    param($Task, $PipelineResult)
    Refresh-ManagedTaskFromSnapshot -Task $Task
    $Task.run.finalStatus = [string]$PipelineResult.status
    $Task.run.finalCategory = [string]$PipelineResult.finalCategory
    $Task.run.summary = [string]$PipelineResult.summary
    $Task.run.feedback = [string]$PipelineResult.feedback
    $Task.run.noChangeReason = [string]$PipelineResult.noChangeReason
    $Task.run.attempts = [int]$PipelineResult.attempts
    $Task.run.actualFiles = @(Get-NormalizedPathSet -Paths $PipelineResult.files)
    if ($PipelineResult.branch) {
        $Task.run.branchName = [string]$PipelineResult.branch
    }
    if ($PipelineResult.artifacts) {
        if ($PipelineResult.artifacts.runDir) { $Task.run.artifacts.runDir = [string]$PipelineResult.artifacts.runDir }
        if ($PipelineResult.artifacts.debugDir) { $Task.run.artifacts.debugDir = [string]$PipelineResult.artifacts.debugDir }
    }
    switch ([string]$PipelineResult.status) {
        "ACCEPTED" { $Task.state = "accepted_pending_wave_close" }
        "NO_CHANGE" { $Task.state = "completed_no_change" }
        "FAILED" { $Task.state = "completed_failed" }
        default { $Task.state = "completed_error" }
    }
    if ($Task.state -in @("completed_no_change", "completed_failed", "completed_error")) {
        Clear-TaskRunnerOwnership -Task $Task
    }
}

function Invoke-GitCleanCheck {
    param([string]$RepoRoot)
    $status = Invoke-NativeCommand git @("status", "--porcelain") $RepoRoot
    return (-not $status.output)
}

function Reset-RepoAfterMergeAttempt {
    param([string]$RepoRoot)
    Invoke-NativeCommand git @("reset", "HEAD", ".") $RepoRoot | Out-Null
    Invoke-NativeCommand git @("checkout", "--", ".") $RepoRoot | Out-Null
}

function Resolve-InteractiveMerge {
    param($Task, [string]$Decision, [string]$CommitMessage)
    if (-not (Invoke-GitCleanCheck -RepoRoot $Task.repoRoot)) {
        throw "Working Tree ist nicht sauber. Interaktive Merge-Entscheidung abgebrochen."
    }
    if ($Decision -eq "discard") {
        if ($Task.run.branchName) {
            Invoke-NativeCommand git @("branch", "-D", $Task.run.branchName) $Task.repoRoot | Out-Null
        }
        return [pscustomobject]@{
            state = "merged_discarded"
            commitSha = ""
            message = ""
            summary = "Aenderungen verworfen."
        }
    }
    $mergeResult = Invoke-NativeCommand git @("merge", "--squash", $Task.run.branchName) $Task.repoRoot
    if ($mergeResult.exitCode -ne 0) {
        Invoke-NativeCommand git @("merge", "--abort") $Task.repoRoot | Out-Null
        if (-not (Invoke-GitCleanCheck -RepoRoot $Task.repoRoot)) {
            Reset-RepoAfterMergeAttempt -RepoRoot $Task.repoRoot
        }
        return [pscustomobject]@{
            state = "skipped_merge_conflict"
            commitSha = ""
            message = ""
            summary = "Squash-Merge erzeugte Konflikte."
        }
    }
    $buildResult = Invoke-NativeCommand dotnet @("build", $Task.solutionPath) $Task.repoRoot
    if ($buildResult.exitCode -ne 0) {
        Reset-RepoAfterMergeAttempt -RepoRoot $Task.repoRoot
        return [pscustomobject]@{
            state = "skipped_build_failure"
            commitSha = ""
            message = ""
            summary = "Build nach Merge fehlgeschlagen."
        }
    }
    $commitResult = Invoke-NativeCommand git @("commit", "-m", $CommitMessage) $Task.repoRoot
    if ($commitResult.exitCode -ne 0) {
        throw "Commit fehlgeschlagen: $($commitResult.output)"
    }
    $shaResult = Invoke-NativeCommand git @("rev-parse", "HEAD") $Task.repoRoot
    if ($Task.run.branchName) {
        Invoke-NativeCommand git @("branch", "-D", $Task.run.branchName) $Task.repoRoot | Out-Null
    }
    return [pscustomobject]@{
        state = "merged_committed"
        commitSha = [string]$shaResult.output
        message = $CommitMessage
        summary = "Aenderungen uebernommen und committet."
    }
}

function Resolve-AutonomousMerge {
    param($Task)
    $message = "AutoDevelop: $($Task.plan.taskText)"
    $result = Resolve-InteractiveMerge -Task $Task -Decision "commit" -CommitMessage $message
    $result | Add-Member -NotePropertyName autoCommitMessage -NotePropertyValue $message -Force
    return $result
}

function Submit-SingleTask {
    param(
        [string]$CommandType,
        [string]$PromptFile,
        [string]$PlanFile,
        [string]$SolutionPath,
        [string]$ResultFile,
        [bool]$AllowNuget,
        [bool]$UsageGateDisabled
    )
    $repoRoot = Get-CanonicalRepoRoot -SolutionPath $SolutionPath
    if (-not (Invoke-GitCleanCheck -RepoRoot $repoRoot)) {
        throw "Working Tree ist nicht sauber."
    }
    $plan = Get-PlanFromFile -PlanFile $PlanFile
    $paths = Get-StatePaths -RepoRoot $repoRoot
    Ensure-Directory -Path $paths.baseDir
    $lock = Acquire-Lock -LockFile $paths.lockFile
    try {
        $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
        foreach ($existing in @(Get-Tasks -State $state)) {
            Reconcile-TaskState -Task $existing
        }
        foreach ($existing in @(Get-Tasks -State $state)) {
            [void](Write-TaskResultIfMissing -Task $existing)
        }
        $externalContext = Get-ExternalAutoTasks -RepoRoot $repoRoot -KnownTaskNames @((Get-Tasks -State $state | ForEach-Object { $_.taskName })) -KnownBranches (Get-KnownBranches -State $state)
        $external = @($externalContext.tasks)
        if ($externalContext.unknownBranches.Count -gt 0) {
            throw ("Offene auto/*-Branches ohne klassifizierbaren Kontext blockieren neue Tasks: " + ($externalContext.unknownBranches -join ", "))
        }
        $externalPendingMerge = @($external | Where-Object { $_.state -eq "pending_merge" })
        $taskId = [guid]::NewGuid().ToString("N")
        $submissionOrder = Get-NextSubmissionOrder -State $state
        $openWave = Get-CurrentOpenWaveNumber -State $state
        $waveNumber = 0
        $blockedBy = @()
        $task = $null
        if ($openWave -gt 0) {
            $candidate = New-SchedulerTaskRecord -TaskId $taskId -CommandType $CommandType -PromptFile $PromptFile -PlanFile $PlanFile -SolutionPath $SolutionPath -ResultFile $ResultFile -RepoRoot $repoRoot -SubmissionOrder $submissionOrder -WaveNumber $openWave -Plan $plan -AllowNuget $AllowNuget -UsageGateDisabled $UsageGateDisabled -StateDir $paths.baseDir
            $waveTasks = Get-TaskByWaveOrder -State $state -WaveNumber $openWave
            $conflictsWave = @($waveTasks | Where-Object { Test-PlanConflict -LeftTask $candidate -RightTask $_ })
            $conflictsExternal = @($external | Where-Object { $_.state -ne "pending_merge" -and (Test-PlanConflict -LeftTask $candidate -RightTask $_) })
            if ($externalPendingMerge.Count -eq 0 -and $conflictsWave.Count -eq 0 -and $conflictsExternal.Count -eq 0) {
                $waveNumber = $openWave
            } else {
                $waveNumber = Get-NextWaveNumber -State $state
                $blockedBy = @($conflictsWave.taskId + $conflictsExternal.taskId + $externalPendingMerge.taskId | Where-Object { $_ } | Select-Object -Unique)
            }
            $task = $candidate
            $task.waveNumber = $waveNumber
        } else {
            $waveNumber = Get-NextWaveNumber -State $state
            $task = New-SchedulerTaskRecord -TaskId $taskId -CommandType $CommandType -PromptFile $PromptFile -PlanFile $PlanFile -SolutionPath $SolutionPath -ResultFile $ResultFile -RepoRoot $repoRoot -SubmissionOrder $submissionOrder -WaveNumber $waveNumber -Plan $plan -AllowNuget $AllowNuget -UsageGateDisabled $UsageGateDisabled -StateDir $paths.baseDir
            $conflictsExternal = @($external | Where-Object { $_.state -ne "pending_merge" -and (Test-PlanConflict -LeftTask $task -RightTask $_) })
            if ($conflictsExternal.Count -gt 0 -or $externalPendingMerge.Count -gt 0) {
                $blockedBy = @($conflictsExternal.taskId + $externalPendingMerge.taskId | Where-Object { $_ } | Select-Object -Unique)
            }
        }
        $tasks = [System.Collections.ArrayList]::new()
        foreach ($item in @(Get-Tasks -State $state)) { [void]$tasks.Add($item) }
        [void]$tasks.Add($task)
        $state.tasks = @($tasks)
        Save-State -StateFile $paths.stateFile -State $state
        Append-StateEvent -EventsFile $paths.eventsFile -TaskId $taskId -Kind "submitted" -Message "Task eingereiht." -Data @{ wave = $waveNumber; blockedBy = $blockedBy }
        $action = if ($waveNumber -eq $openWave -and $blockedBy.Count -eq 0) { "startable" } elseif ($waveNumber -eq 1 -and $openWave -eq 0 -and $blockedBy.Count -eq 0) { "startable" } else { "queued" }
        return [pscustomobject]@{
            taskId = $taskId
            action = $action
            waveNumber = $waveNumber
            blockedBy = @($blockedBy)
            taskName = $task.taskName
            stateDir = $paths.baseDir
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

function Run-SingleTask {
    param([string]$TaskId, [string]$SolutionPath)
    $repoRoot = Get-CanonicalRepoRoot -SolutionPath $SolutionPath
    $paths = Get-StatePaths -RepoRoot $repoRoot
    while ($true) {
        $startPipeline = $false
        $pipelineTask = $null
        $writeResult = $null
        $runMerge = $null
        $runMergeOwnedByCurrentTask = $false
        $mustSaveState = $false
        $lock = Acquire-Lock -LockFile $paths.lockFile
        try {
            $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
            foreach ($existing in @(Get-Tasks -State $state)) {
                Reconcile-TaskState -Task $existing
            }
            foreach ($candidate in @((Get-Tasks -State $state) | Sort-Object waveNumber, submissionOrder)) {
                if ($candidate.state -ne "accepted_pending_wave_close") { continue }
                if ($candidate.scheduler.owner) { continue }
                if (-not (Test-IsMergeTurn -State $state -Task $candidate)) { continue }

                if (Try-MarkSkippedConflict -State $state -Task $candidate) {
                    Clear-TaskRunnerOwnership -Task $candidate
                    $mustSaveState = $true
                    continue
                }

                if ($candidate.mode -eq "interactive") {
                    $candidate.state = "awaiting_interactive_decision"
                    $candidate.merge.state = "merge_ready"
                    if (-not $candidate.merge.mergeReadyAt) {
                        $candidate.merge.mergeReadyAt = (Get-Date).ToString("o")
                    }
                    Clear-TaskRunnerOwnership -Task $candidate
                    $mustSaveState = $true
                    continue
                }

                if (-not $runMerge) {
                    Set-TaskRunnerOwnership -Task $candidate -Owner "run-single"
                    $candidate.state = "merge_in_progress"
                    $candidate.merge.state = "merge_in_progress"
                    $runMerge = $candidate
                    $runMergeOwnedByCurrentTask = ($candidate.taskId -eq $TaskId)
                    $mustSaveState = $true
                }
            }
            foreach ($existing in @(Get-Tasks -State $state)) {
                [void](Write-TaskResultIfMissing -Task $existing)
            }
            $task = Get-TaskById -State $state -TaskId $TaskId
            if (-not $task) { throw "Scheduler-Task nicht gefunden: $TaskId" }
            Set-TaskRunnerOwnership -Task $task -Owner "run-single"
            $externalContext = Get-ExternalAutoTasks -RepoRoot $repoRoot -KnownTaskNames @((Get-Tasks -State $state | ForEach-Object { $_.taskName })) -KnownBranches (Get-KnownBranches -State $state)
            if ($externalContext.unknownBranches.Count -gt 0) {
                throw ("Offene auto/*-Branches ohne klassifizierbaren Kontext blockieren Scheduler-Weiterlauf: " + ($externalContext.unknownBranches -join ", "))
            }
            $external = @($externalContext.tasks)
            if (($task.state -eq "awaiting_interactive_decision" -or (Is-ResolvedTaskState -State $task.state)) -and (Test-Path $task.resultFile)) {
                Clear-TaskRunnerOwnership -Task $task
                $mustSaveState = $true
                $writeResult = [pscustomobject]@{
                    task = $task
                    status = "__EXIT__"
                    message = ""
                }
            } elseif (-not $runMerge -and $task.state -eq "queued" -and (Test-TaskCanStartNow -State $state -Task $task -ExternalTasks $external)) {
                $task.state = "usage_wait"
                Save-State -StateFile $paths.stateFile -State $state
                Append-StateEvent -EventsFile $paths.eventsFile -TaskId $task.taskId -Kind "ready" -Message "Task darf starten." -Data @{ wave = $task.waveNumber }
                $startPipeline = $true
                $pipelineTask = $task
            } elseif (-not $runMerge -and $task.state -eq "accepted_pending_wave_close" -and (Test-IsMergeTurn -State $state -Task $task)) {
                if (Try-MarkSkippedConflict -State $state -Task $task) {
                    Clear-TaskRunnerOwnership -Task $task
                    Save-State -StateFile $paths.stateFile -State $state
                    $writeResult = [pscustomobject]@{
                        task = $task
                        status = "SKIPPED_CONFLICT"
                        message = $task.merge.reason
                    }
                } elseif ($task.mode -eq "interactive") {
                    $task.state = "awaiting_interactive_decision"
                    $task.merge.state = "merge_ready"
                    $task.merge.mergeReadyAt = (Get-Date).ToString("o")
                    Clear-TaskRunnerOwnership -Task $task
                    Save-State -StateFile $paths.stateFile -State $state
                    Append-StateEvent -EventsFile $paths.eventsFile -TaskId $task.taskId -Kind "merge_ready" -Message "Task ist merge-bereit." -Data @{ wave = $task.waveNumber }
                    $writeResult = [pscustomobject]@{
                        task = $task
                        status = "MERGE_READY"
                        message = "Task ist merge-bereit."
                    }
                } else {
                    $task.state = "merge_in_progress"
                    $task.merge.state = "merge_in_progress"
                    Save-State -StateFile $paths.stateFile -State $state
                    $runMerge = $task
                }
            } elseif (Is-ResolvedTaskState -State $task.state -and -not (Test-Path $task.resultFile)) {
                $status = switch ($task.state) {
                    "completed_no_change" { "NO_CHANGE" }
                    "completed_failed" { "FAILED" }
                    "completed_error" { "ERROR" }
                    "merged_committed" { "COMMITTED" }
                    "merged_discarded" { "DISCARDED" }
                    "skipped_conflict" { "SKIPPED_CONFLICT" }
                    "skipped_merge_conflict" { "SKIPPED_MERGE_CONFLICT" }
                    "skipped_build_failure" { "SKIPPED_BUILD_FAILURE" }
                    default { "ERROR" }
                }
                $writeResult = [pscustomobject]@{
                    task = $task
                    status = $status
                    message = if ($task.merge.reason) { $task.merge.reason } else { $task.run.summary }
                }
            }
            if ($mustSaveState -or (-not $startPipeline -and -not $runMerge -and -not $writeResult)) {
                Save-State -StateFile $paths.stateFile -State $state
            }
        } finally {
            Release-Lock -LockHandle $lock
        }
        if ($startPipeline) {
            $gateResult = Wait-ForUsageGate -StateDir $paths.baseDir -TaskId $pipelineTask.taskId -Disabled ([bool]$pipelineTask.usageGateDisabled)
            if ($gateResult.ok -ne $true) {
                $lock = Acquire-Lock -LockFile $paths.lockFile
                try {
                    $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
                    $task = Get-TaskById -State $state -TaskId $pipelineTask.taskId
                    if (-not $task) { throw "Scheduler-Task nach Usage-Gate nicht gefunden: $($pipelineTask.taskId)" }
                    Set-TaskSchedulerError -Task $task -FinalCategory "USAGE_GATE_UNAVAILABLE" -Summary "Task wurde nicht gestartet, weil der 5h-Usage-Gate spaeter nicht mehr verifizierbar war." -Feedback (($gateResult.errors | Where-Object { $_ }) -join "`n")
                    Save-State -StateFile $paths.stateFile -State $state
                    Append-StateEvent -EventsFile $paths.eventsFile -TaskId $task.taskId -Kind "usage_gate_unavailable" -Message "Start wegen nicht verifizierbarem 5h-Usage-Gate abgebrochen." -Data @{ processStatus = $gateResult.processStatus; errors = @($gateResult.errors) }
                    Write-UserResult -Path $task.resultFile -Status "ERROR" -TaskId $task.taskId -WaveNumber ([int]$task.waveNumber) -PipelineResult (New-TaskPipelineLikeResult -Task $task) -Task $task -Message $task.run.summary
                    return
                } finally {
                    Release-Lock -LockHandle $lock
                }
            }
            $lock = Acquire-Lock -LockFile $paths.lockFile
            try {
                $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
                $task = Get-TaskById -State $state -TaskId $pipelineTask.taskId
                if (-not $task) { throw "Scheduler-Task vor Pipeline-Start nicht gefunden: $($pipelineTask.taskId)" }
                Set-TaskRunnerOwnership -Task $task -Owner "run-single"
                $task.state = "running"
                Save-State -StateFile $paths.stateFile -State $state
                Append-StateEvent -EventsFile $paths.eventsFile -TaskId $task.taskId -Kind "started" -Message "Pipeline wird gestartet." -Data @{ wave = $task.waveNumber }
                $pipelineTask = $task
            } finally {
                Release-Lock -LockHandle $lock
            }
            $pipelineResult = Start-AutoDevelopRun -Task $pipelineTask
            $lock = Acquire-Lock -LockFile $paths.lockFile
            try {
                $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
                $task = Get-TaskById -State $state -TaskId $pipelineTask.taskId
                if (-not $task) { throw "Scheduler-Task nach Run nicht gefunden: $($pipelineTask.taskId)" }
                Update-TaskFromPipelineResult -Task $task -PipelineResult $pipelineResult
                Save-State -StateFile $paths.stateFile -State $state
                Append-StateEvent -EventsFile $paths.eventsFile -TaskId $task.taskId -Kind "pipeline_complete" -Message "Pipeline beendet." -Data @{ status = $pipelineResult.status; finalCategory = $pipelineResult.finalCategory }
            } finally {
                Release-Lock -LockHandle $lock
            }
            if ($pipelineResult.status -ne "ACCEPTED") {
                $status = switch ([string]$pipelineResult.status) {
                    "NO_CHANGE" { "NO_CHANGE" }
                    "FAILED" { "FAILED" }
                    default { "ERROR" }
                }
                Write-UserResult -Path $pipelineTask.resultFile -Status $status -TaskId $pipelineTask.taskId -WaveNumber ([int]$pipelineTask.waveNumber) -PipelineResult $pipelineResult -Task $pipelineTask -Message $pipelineResult.summary
                return
            }
            continue
        }
        if ($runMerge) {
            try {
                $mergeResult = Resolve-AutonomousMerge -Task $runMerge
            } catch {
                $mergeError = $_.Exception.Message
                Invoke-NativeCommand git @("reset", "HEAD", ".") $repoRoot | Out-Null
                Invoke-NativeCommand git @("checkout", "--", ".") $repoRoot | Out-Null
                $lock = Acquire-Lock -LockFile $paths.lockFile
                try {
                    $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
                    $task = Get-TaskById -State $state -TaskId $runMerge.taskId
                    if ($task) {
                        Set-TaskSchedulerError -Task $task -FinalCategory "MERGE_ERROR" -Summary "Autonomer Merge konnte nicht abgeschlossen werden." -Feedback $mergeError
                        Save-State -StateFile $paths.stateFile -State $state
                        Write-UserResult -Path $task.resultFile -Status "ERROR" -TaskId $task.taskId -WaveNumber ([int]$task.waveNumber) -PipelineResult (New-TaskPipelineLikeResult -Task $task) -Task $task -Message $task.run.summary
                    }
                } finally {
                    Release-Lock -LockHandle $lock
                }
                if ($runMergeOwnedByCurrentTask) { return }
                continue
            }
            $lock = Acquire-Lock -LockFile $paths.lockFile
            try {
                $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
                $task = Get-TaskById -State $state -TaskId $runMerge.taskId
                if (-not $task) { throw "Scheduler-Task fuer Merge nicht gefunden: $($runMerge.taskId)" }
                [void](Save-TaskMergeOutcome -Task $task -State $mergeResult.state -Summary $mergeResult.summary -CommitMessage $mergeResult.autoCommitMessage -CommitSha $mergeResult.commitSha)
                $task.state = $mergeResult.state
                $task.merge.state = $mergeResult.state
                $task.merge.reason = $mergeResult.summary
                $task.merge.commitMessage = $mergeResult.autoCommitMessage
                $task.merge.commitSha = $mergeResult.commitSha
                $task.merge.resolvedAt = (Get-Date).ToString("o")
                Clear-TaskRunnerOwnership -Task $task
                Save-State -StateFile $paths.stateFile -State $state
                Write-UserResult -Path $task.resultFile -Status (if ($mergeResult.state -eq "merged_committed") { "COMMITTED" } elseif ($mergeResult.state -eq "skipped_merge_conflict") { "SKIPPED_MERGE_CONFLICT" } else { "SKIPPED_BUILD_FAILURE" }) -TaskId $task.taskId -WaveNumber ([int]$task.waveNumber) -PipelineResult ([pscustomobject]@{ finalCategory = $task.run.finalCategory; summary = $task.run.summary; feedback = $task.run.feedback; noChangeReason = $task.run.noChangeReason; files = $task.run.actualFiles; attempts = $task.run.attempts; branch = $task.run.branchName; artifacts = $task.run.artifacts }) -Task $task -Message $mergeResult.summary -CommitMessage $mergeResult.autoCommitMessage
                if ($runMergeOwnedByCurrentTask) { return }
                continue
            } finally {
                Release-Lock -LockHandle $lock
            }
        }
        if ($writeResult) {
            if ($writeResult.status -eq "__EXIT__") { return }
            $task = $writeResult.task
            $pipelineResult = if (Test-Path $task.pipelineResultFile) { Get-Content $task.pipelineResultFile -Raw | ConvertFrom-Json } else { $null }
            Write-UserResult -Path $task.resultFile -Status $writeResult.status -TaskId $task.taskId -WaveNumber ([int]$task.waveNumber) -PipelineResult $pipelineResult -Task $task -Message $writeResult.message
            return
        }
        Start-Sleep -Seconds 3
    }
}

function Resolve-InteractiveTask {
    param([string]$TaskId, [string]$SolutionPath, [string]$Decision, [string]$CommitMessage)
    $repoRoot = Get-CanonicalRepoRoot -SolutionPath $SolutionPath
    $paths = Get-StatePaths -RepoRoot $repoRoot
    $task = $null
    $lock = Acquire-Lock -LockFile $paths.lockFile
    try {
        $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) { throw "Scheduler-Task nicht gefunden: $TaskId" }
        if ($task.state -ne "awaiting_interactive_decision") {
            throw "Task ist nicht im Zustand awaiting_interactive_decision."
        }
        if (-not (Invoke-GitCleanCheck -RepoRoot $repoRoot)) {
            return [pscustomobject]@{
                status = "ERROR"
                schedulerTaskId = $task.taskId
                waveNumber = [int]$task.waveNumber
                summary = "Working Tree ist nicht sauber. Merge-Entscheidung wurde nicht ausgefuehrt."
                commitMessage = ""
                commitSha = ""
            }
        }
        Set-TaskRunnerOwnership -Task $task -Owner "resolve-interactive"
        $task.state = "merge_in_progress"
        $task.merge.state = "merge_in_progress"
        Save-State -StateFile $paths.stateFile -State $state
    } finally {
        Release-Lock -LockHandle $lock
    }
    try {
        $mergeResult = Resolve-InteractiveMerge -Task $task -Decision $Decision -CommitMessage $CommitMessage
    } catch {
        $mergeError = $_.Exception.Message
        if (-not (Invoke-GitCleanCheck -RepoRoot $repoRoot)) {
            Reset-RepoAfterMergeAttempt -RepoRoot $repoRoot
        }
        $lock = Acquire-Lock -LockFile $paths.lockFile
        try {
            $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
            $task = Get-TaskById -State $state -TaskId $TaskId
            if ($task) {
                $task.state = "awaiting_interactive_decision"
                $task.merge.state = "merge_ready"
                $task.merge.reason = $mergeError
                Clear-TaskRunnerOwnership -Task $task
                Save-State -StateFile $paths.stateFile -State $state
            }
            return [pscustomobject]@{
                status = "ERROR"
                schedulerTaskId = $TaskId
                waveNumber = if ($task) { [int]$task.waveNumber } else { 0 }
                summary = $mergeError
                commitMessage = ""
                commitSha = ""
            }
        } finally {
            Release-Lock -LockHandle $lock
        }
    }
    $lock = Acquire-Lock -LockFile $paths.lockFile
    try {
        $state = Load-State -StateFile $paths.stateFile -RepoRoot $repoRoot -RepoHash $paths.repoHash
        $task = Get-TaskById -State $state -TaskId $TaskId
        if (-not $task) { throw "Scheduler-Task nach Merge nicht gefunden: $TaskId" }
        [void](Save-TaskMergeOutcome -Task $task -State $mergeResult.state -Summary $mergeResult.summary -CommitMessage $mergeResult.message -CommitSha $mergeResult.commitSha)
        $task.state = $mergeResult.state
        $task.merge.state = $mergeResult.state
        $task.merge.reason = $mergeResult.summary
        $task.merge.commitMessage = $mergeResult.message
        $task.merge.commitSha = $mergeResult.commitSha
        $task.merge.resolvedAt = (Get-Date).ToString("o")
        Clear-TaskRunnerOwnership -Task $task
        Save-State -StateFile $paths.stateFile -State $state
        return [pscustomobject]@{
            status = if ($mergeResult.state -eq "merged_committed") { "COMMITTED" } elseif ($mergeResult.state -eq "merged_discarded") { "DISCARDED" } elseif ($mergeResult.state -eq "skipped_merge_conflict") { "SKIPPED_MERGE_CONFLICT" } else { "SKIPPED_BUILD_FAILURE" }
            schedulerTaskId = $task.taskId
            waveNumber = [int]$task.waveNumber
            summary = $mergeResult.summary
            commitMessage = $mergeResult.message
            commitSha = $mergeResult.commitSha
        }
    } finally {
        Release-Lock -LockHandle $lock
    }
}

switch ($Mode) {
    "submit-single" {
        $result = Submit-SingleTask -CommandType $CommandType -PromptFile (Get-CanonicalPath -Path $PromptFile) -PlanFile (Get-CanonicalPath -Path $PlanFile) -SolutionPath (Get-CanonicalPath -Path $SolutionPath) -ResultFile (Get-CanonicalPath -Path $ResultFile) -AllowNuget ([bool]$AllowNuget) -UsageGateDisabled ([bool]$UsageGateDisabled)
        Write-JsonOutput -Object $result
        break
    }
    "run-single" {
        Run-SingleTask -TaskId $TaskId -SolutionPath (Get-CanonicalPath -Path $SolutionPath)
        break
    }
    "resolve-interactive" {
        $result = Resolve-InteractiveTask -TaskId $TaskId -SolutionPath (Get-CanonicalPath -Path $SolutionPath) -Decision $Decision -CommitMessage $CommitMessage
        Write-JsonOutput -Object $result
        break
    }
}
