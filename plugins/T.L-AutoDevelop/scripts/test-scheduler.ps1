param()

$ErrorActionPreference = "Stop"

$script:SchedulerPath = Join-Path $PSScriptRoot "scheduler.ps1"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-TestRepo {
    $root = Join-Path $env:TEMP ("autodev-scheduler-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Push-Location $root
    try {
        git init | Out-Null
        git config user.email "autodev-tests@example.com"
        git config user.name "AutoDevelop Tests"
        Set-Content -LiteralPath (Join-Path $root "Test.slnx") -Value "{}" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root "task-prompt.md") -Value "## Task`nTest prompt" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $root ".gitignore") -Value ".claude-develop-logs/" -Encoding UTF8
        git add . | Out-Null
        git commit -m "init" | Out-Null
    } finally {
        Pop-Location
    }

    return [pscustomobject]@{
        root = $root
        solution = Join-Path $root "Test.slnx"
        promptFile = Join-Path $root "task-prompt.md"
        stateFile = Join-Path $root ".claude-develop-logs\scheduler\state.json"
        tasksDir = Join-Path $root ".claude-develop-logs\scheduler\tasks"
        resultsDir = Join-Path $root ".claude-develop-logs\scheduler\results"
    }
}

function New-TestLatestRun {
    param(
        [int]$AttemptNumber = 0,
        [int]$LaunchSequence = 0,
        [string]$TaskName = "",
        [string]$ResultFile = "",
        [int]$ProcessId = 0,
        [string]$StartedAt = ""
    )

    return [pscustomobject]@{
        attemptNumber = $AttemptNumber
        launchSequence = $LaunchSequence
        taskName = $TaskName
        resultFile = $ResultFile
        processId = $ProcessId
        startedAt = $StartedAt
        completedAt = ""
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

function New-TestMergeRecord {
    return [pscustomobject]@{
        state = ""
        preparedAt = ""
        commitMessage = ""
        commitSha = ""
        reason = ""
        branchName = ""
    }
}

function Remove-TestRepo {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}

function Invoke-SchedulerJson {
    param(
        [string]$RepoSolution,
        [string]$Mode,
        [string]$TasksFile = "",
        [string]$PlanFile = "",
        [string]$TaskId = "",
        [int]$WaitTimeoutSeconds = 0,
        [int]$IdlePollSeconds = 0
    )

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:SchedulerPath,
        "-Mode", $Mode,
        "-SolutionPath", $RepoSolution
    )
    if ($TasksFile) { $arguments += @("-TasksFile", $TasksFile) }
    if ($PlanFile) { $arguments += @("-PlanFile", $PlanFile) }
    if ($TaskId) { $arguments += @("-TaskId", $TaskId) }
    if ($WaitTimeoutSeconds -gt 0) { $arguments += @("-WaitTimeoutSeconds", [string]$WaitTimeoutSeconds) }
    if ($IdlePollSeconds -gt 0) { $arguments += @("-IdlePollSeconds", [string]$IdlePollSeconds) }

    $raw = & powershell.exe @arguments
    return ($raw | Out-String | ConvertFrom-Json)
}

function Get-TestGitDir {
    param([string]$RepoRoot)

    Push-Location $RepoRoot
    try {
        $gitDir = (& git rev-parse --git-dir | Out-String).Trim()
        if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
            $gitDir = Join-Path $RepoRoot $gitDir
        }
        return [System.IO.Path]::GetFullPath($gitDir)
    } finally {
        Pop-Location
    }
}

function Get-FunctionDefinitionText {
    param(
        [string]$ScriptPath,
        [string]$FunctionName
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "Unable to parse script for function extraction: $ScriptPath"
    }

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
    }, $true)

    if (-not $functionAst) {
        throw "Function not found in script: $FunctionName"
    }

    return $functionAst.Extent.Text
}

function Invoke-AutoDevelopHelperFunctions {
    param(
        [string[]]$FunctionNames,
        [scriptblock]$ScriptBlock
    )

    $autoDevelopPath = Join-Path $PSScriptRoot "auto-develop.ps1"
    $functionDefinitions = @($FunctionNames | ForEach-Object { Get-FunctionDefinitionText -ScriptPath $autoDevelopPath -FunctionName $_ })
    $bootstrap = ($functionDefinitions -join "`r`n`r`n")
    $wrapped = @"
$bootstrap
& {
$($ScriptBlock.ToString())
}
"@
    $tempScript = Join-Path $env:TEMP ("autodev-helper-test-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        [System.IO.File]::WriteAllText($tempScript, $wrapped, [System.Text.Encoding]::UTF8)
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScript
        return ($raw | Out-String).Trim()
    } finally {
        Remove-Item -LiteralPath $tempScript -ErrorAction SilentlyContinue
    }
}

function Invoke-SchedulerHelperFunctions {
    param(
        [string[]]$FunctionNames,
        [scriptblock]$ScriptBlock,
        [object[]]$Arguments = @()
    )

    $functionDefinitions = @($FunctionNames | ForEach-Object { Get-FunctionDefinitionText -ScriptPath $script:SchedulerPath -FunctionName $_ })
    $bootstrap = ($functionDefinitions -join "`r`n`r`n")
    $argumentsJson = ($Arguments | ConvertTo-Json -Depth 16 -Compress)
    $wrapped = @"
$bootstrap
`$__codexArgs = ConvertFrom-Json @'
$argumentsJson
'@
& {
$($ScriptBlock.ToString())
} @`$__codexArgs
"@
    $tempScript = Join-Path $env:TEMP ("scheduler-helper-test-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        [System.IO.File]::WriteAllText($tempScript, $wrapped, [System.Text.Encoding]::UTF8)
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScript
        return ($raw | Out-String).Trim()
    } finally {
        Remove-Item -LiteralPath $tempScript -ErrorAction SilentlyContinue
    }
}

function Write-StateFile {
    param(
        [string]$StateFile,
        $State
    )

    $parent = Split-Path -Path $StateFile -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($StateFile, ($State | ConvertTo-Json -Depth 32), [System.Text.Encoding]::UTF8)
}

function Invoke-WithEnvironment {
    param(
        [hashtable]$Variables,
        [scriptblock]$ScriptBlock
    )

    $original = @{}
    foreach ($entry in $Variables.GetEnumerator()) {
        $original[$entry.Key] = [System.Environment]::GetEnvironmentVariable($entry.Key, "Process")
        [System.Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, "Process")
    }

    try {
        & $ScriptBlock
    } finally {
        foreach ($entry in $Variables.GetEnumerator()) {
            [System.Environment]::SetEnvironmentVariable($entry.Key, $original[$entry.Key], "Process")
        }
    }
}

function Assert-Throws {
    param(
        [scriptblock]$ScriptBlock,
        [string]$ExpectedMessage
    )

    $threw = $false
    try {
        & $ScriptBlock
    } catch {
        $threw = $true
        if ($ExpectedMessage -and $_.Exception.Message -notmatch [regex]::Escape($ExpectedMessage)) {
            throw "Expected error containing '$ExpectedMessage' but got '$($_.Exception.Message)'."
        }
    }
    if (-not $threw) {
        throw "Expected command to throw."
    }
}

function New-MockCommandSet {
    param(
        [string]$Root,
        [string]$DotnetBehavior = "lock-then-success"
    )

    $mockDir = Join-Path $Root "mock-bin"
    New-Item -ItemType Directory -Path $mockDir -Force | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $mockDir "git.cmd"), '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0git-behavior.ps1" %*', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $mockDir "dotnet.cmd"), '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dotnet-behavior.ps1" %*', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $mockDir "taskkill.cmd"), '@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0taskkill-behavior.ps1" %*', [System.Text.Encoding]::ASCII)

    [System.IO.File]::WriteAllText((Join-Path $mockDir "git-behavior.ps1"), @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$commandLine = ($Args -join ' ')
if ($env:AUTODEV_TEST_GIT_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_GIT_LOG -Value $commandLine -Encoding UTF8
}
if ($Args.Count -ge 2 -and $Args[0] -eq 'rev-parse' -and $Args[1] -eq '--show-toplevel') {
    Write-Output $env:AUTODEV_TEST_REPO_ROOT
    exit 0
}
if ($Args.Count -ge 2 -and $Args[0] -eq 'rev-parse' -and $Args[1] -eq 'HEAD') {
    Write-Output '1111111111111111111111111111111111111111'
    exit 0
}
if ($Args.Count -ge 3 -and $Args[0] -eq 'rev-parse' -and $Args[1] -eq '--verify') {
    $branch = $Args[2]
    $known = @()
    if ($env:AUTODEV_TEST_BRANCH_SHA_MAP) {
        try { $known = @((ConvertFrom-Json $env:AUTODEV_TEST_BRANCH_SHA_MAP).psobject.Properties) } catch { $known = @() }
    }
    $sha = ''
    foreach ($entry in $known) {
        if ([string]$entry.Name -eq $branch) {
            $sha = [string]$entry.Value
            break
        }
    }
    if ($sha) {
        Write-Output $sha
        exit 0
    }
    exit 1
}
if ($Args.Count -ge 4 -and $Args[0] -eq 'merge-base' -and $Args[1] -eq '--is-ancestor') {
    $ancestorSha = $Args[2]
    $merged = @()
    if ($env:AUTODEV_TEST_MERGED_SHAS) {
        try { $merged = @((ConvertFrom-Json $env:AUTODEV_TEST_MERGED_SHAS)) } catch { $merged = @() }
    }
    if ($merged -contains $ancestorSha) { exit 0 }
    exit 1
}
if ($Args.Count -ge 1 -and $Args[0] -eq 'merge') {
    if ($env:AUTODEV_TEST_GIT_MERGE_BEHAVIOR -eq 'conflict') {
        Write-Output 'CONFLICT (content): Merge conflict'
        exit 1
    }
    exit 0
}
if ($Args.Count -ge 1 -and $Args[0] -eq 'status') {
    if ($env:AUTODEV_TEST_GIT_STATUS_OUTPUT) {
        Write-Output $env:AUTODEV_TEST_GIT_STATUS_OUTPUT
        exit 0
    }
    exit 0
}
if ($Args.Count -ge 1 -and $Args[0] -in @('branch','reset','commit')) {
    exit 0
}
exit 0
'@, [System.Text.Encoding]::UTF8)

    $dotnetScript = switch ($DotnetBehavior) {
        "compile-fail" {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
Write-Output "error CS1002: ; expected"
exit 1
'@
        }
        "success" {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
Write-Output 'Build succeeded.'
exit 0
'@
        }
        default {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$countFile = $env:AUTODEV_TEST_DOTNET_COUNT_FILE
$count = 0
if ($countFile -and (Test-Path -LiteralPath $countFile)) {
    $count = [int](Get-Content -LiteralPath $countFile -Raw)
}
$count++
if ($countFile) {
    Set-Content -LiteralPath $countFile -Value $count -Encoding UTF8
}
if ($count -eq 1) {
    Write-Output "error MSB3027: Could not copy `"bin\Debug\net8.0\Hmd.Docs.dll`" because it is being used by another process."
    Write-Output "error MSB3021: Access to the path `"bin\Debug\net8.0\Hmd.Docs.dll`" is denied."
    exit 1
}
Write-Output 'Build succeeded.'
exit 0
'@
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $mockDir "dotnet-behavior.ps1"), $dotnetScript, [System.Text.Encoding]::UTF8)

    [System.IO.File]::WriteAllText((Join-Path $mockDir "taskkill-behavior.ps1"), @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
if ($env:AUTODEV_TEST_TASKKILL_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_TASKKILL_LOG -Value ($Args -join ' ') -Encoding UTF8
}
Write-Output 'SUCCESS: Sent termination signal.'
exit 0
'@, [System.Text.Encoding]::UTF8)

    return [pscustomobject]@{
        git = (Join-Path $mockDir "git.cmd")
        dotnet = (Join-Path $mockDir "dotnet.cmd")
        taskkill = (Join-Path $mockDir "taskkill.cmd")
    }
}

function Test-SolutionPathFallback {
    $repo = New-TestRepo
    try {
        $tasksFile = Join-Path $repo.root "tasks-no-solution.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-fallback"
                taskText = "uses scheduler solution"
                sourceCommand = "develop"
                sourceInputType = "inline"
                promptFile = $repo.promptFile
                resultFile = (Join-Path $repo.resultsDir "task-fallback.json")
                allowNuget = $false
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $registerResult = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "register-tasks" -TasksFile $tasksFile
        Assert-True ([string]$registerResult.registered[0].taskId -eq "task-fallback") "Task should register successfully without explicit solutionPath."

        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $actualSolution = [System.IO.Path]::GetFullPath([string]$savedState.tasks[0].solutionPath)
        $expectedSolution = [System.IO.Path]::GetFullPath($repo.solution)
        Assert-True ($actualSolution -eq $expectedSolution) "Missing task solutionPath should fall back to the scheduler solution."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-CompletedAtRoundTrip {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-1-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("src/File.cs")
            branch = "auto/task-1"
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-1"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "test task"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-1.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-1-a1"
                        resultFile = $resultPath
                        processId = 999999
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
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ($snapshot.schedulerHealthy -eq $true) "snapshot-queue should stay healthy after reconciling a completed task."
        Assert-True ($snapshot.pendingMergeTaskIds -contains "task-1") "Accepted task should move to pending_merge."
        Assert-True ([string]$snapshot.tasks[0].finalStatus -eq "ACCEPTED") "Final status should be copied into latestRun."

        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$savedState.tasks[0].latestRun.completedAt)) "completedAt should be persisted after reconciliation."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-EnvironmentFailureRefundsAttempts {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-env-attempt-1-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ERROR"
            finalCategory = "WORKTREE_INVALID"
            summary = "worktree missing"
            feedback = "The worktree is empty."
            noChangeReason = ""
            files = @()
            branch = ""
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-env"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "environment broken"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-env.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-env-a1"
                        resultFile = $resultPath
                        processId = 999999
                        startedAt = (Get-Date).ToString("o")
                        completedAt = ""
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-env" })[0]
        Assert-True ([string]$task.state -eq "environment_retry_scheduled") "Environment failures should enter environment_retry_scheduled."
        Assert-True ([int]$task.attemptsUsed -eq 0) "Environment failures should refund the consumed task attempt."
        Assert-True ([int]$task.environmentRepairAttemptsUsed -eq 1) "Environment repair budget should be consumed."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "WORKTREE_INVALID") "Environment failure category should be preserved."
        Assert-True ([int]$task.waveNumber -eq 0) "Environment retries should detach from their original wave."
        Assert-True (@($task.blockedBy).Count -eq 0) "Environment retries should clear stale dependency blockers."
        Assert-True ([string]$task.progress.detail -match "worktree missing") "Environment retries should surface the summary, not only the category."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RunTaskMissingResultUsesCanonicalEnvironmentFailure {
    $repo = New-TestRepo
    $shimPath = Join-Path $repo.root "fake-powershell.cmd"
    try {
        [System.IO.File]::WriteAllText($shimPath, "@echo off`r`nexit /b 0`r`n", [System.Text.Encoding]::ASCII)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "run-missing-result"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "worker exits without result"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "run-missing-result.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 0
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -ResultFile (Join-Path $repo.resultsDir "run-missing-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $result = Invoke-WithEnvironment -Variables @{ AUTODEV_POWERSHELL_COMMAND = $shimPath } -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "run-task" -TaskId "run-missing-result"
        }

        $task = $result.task
        Assert-True ([string]$task.state -eq "environment_retry_scheduled") "Direct run-task missing results should become environment retries."
        Assert-True ([string]$task.finalCategory -eq "WORKER_EXITED_WITHOUT_RESULT") "Direct run-task missing results should use the canonical environment category."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "WORKER_EXITED_WITHOUT_RESULT") "Canonical environment category should be preserved on the task."
        Assert-True ([string]$task.progress.artifactPointers.workerStdoutPath -match 'stdout\.log$') "Task snapshots should expose the worker stdout log path."
        Assert-True ([string]$task.progress.artifactPointers.workerStderrPath -match 'stderr\.log$') "Task snapshots should expose the worker stderr log path."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ReconcileAcceptedResultClearsEnvironmentFailureCategory {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "accepted-after-env-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("src/File.cs")
            branch = "auto/task-accepted"
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-accepted"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "accepted result after env failure"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-accepted.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "environment_retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-task-accepted-a1" -ResultFile $resultPath -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-accepted" })[0]
        Assert-True ([string]$task.state -eq "pending_merge") "Accepted latest-run results should recover env-retry tasks into pending_merge."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "") "Accepted recovery should clear stale environment failure metadata."
        Assert-True ([string]$task.merge.reason -eq "") "Accepted recovery should clear stale merge failure reasons."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-EnvironmentRepairBudgetFallsBackToNormalRetryAtLimit {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-env-limit"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "env failure at repair limit"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-env-limit.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKTREE_INVALID"
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-task-env-limit-a1" -ResultFile (Join-Path $repo.tasksDir "missing-result.json") -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-env-limit" })[0]
        Assert-True ([string]$task.state -eq "retry_scheduled") "Environment failures at the repair limit should fall back to normal retry scheduling."
        Assert-True ([int]$task.environmentRepairAttemptsUsed -eq 2) "The final environment repair budget unit should still be counted."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "WORKER_EXITED_WITHOUT_RESULT") "The terminal environment failure category should still be recorded."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ReadJsonFileBestEffortRetriesMalformedJson {
    $testPath = Join-Path $env:TEMP ("scheduler-best-effort-" + [guid]::NewGuid().ToString("N") + ".json")
    $tempScript = Join-Path $env:TEMP ("scheduler-best-effort-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        [System.IO.File]::WriteAllText($testPath, '{"status":', [System.Text.Encoding]::UTF8)
        $functionDefinition = Get-FunctionDefinitionText -ScriptPath $script:SchedulerPath -FunctionName "Read-JsonFileBestEffort"
        $escapedPath = $testPath.Replace("'", "''")
        $wrapped = @"
$functionDefinition
`$path = '$escapedPath'
`$repairJob = Start-Job -ScriptBlock {
    param(`$TargetPath)
    Start-Sleep -Milliseconds 250
    [System.IO.File]::WriteAllText(`$TargetPath, (@{
        status = "ACCEPTED"
        finalCategory = "IMPLEMENTED"
    } | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8)
} -ArgumentList `$path
try {
    `$result = Read-JsonFileBestEffort -Path `$path -RetryCount 10 -RetryDelayMilliseconds 100
    if (`$result) {
        [string]`$result.status
    }
} finally {
    Wait-Job `$repairJob | Out-Null
    Remove-Job `$repairJob -Force -ErrorAction SilentlyContinue
}
"@
        [System.IO.File]::WriteAllText($tempScript, $wrapped, [System.Text.Encoding]::UTF8)
        $status = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tempScript | Out-String).Trim()
        Assert-True (([string]$status).Trim() -match "ACCEPTED") "Best-effort JSON reads should recover from a transient malformed file."
    } finally {
        Remove-Item -LiteralPath $tempScript, $testPath -ErrorAction SilentlyContinue
    }
}

function Test-EnvironmentRetryDoesNotBecomeDirectlyStartable {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-merge-ready"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "merge ready"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-merge-ready.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = New-TestLatestRun -AttemptNumber 1 -TaskName "develop-task-merge-ready-a1" -ResultFile (Join-Path $repo.tasksDir "merge-ready-result.json") -StartedAt ((Get-Date).ToString("o"))
                    runs = @()
                    merge = [pscustomobject]@{ state = "pending"; preparedAt = ""; commitMessage = ""; commitSha = ""; reason = ""; branchName = "auto/merge-ready" }
                },
                [pscustomobject]@{
                    taskId = "task-env"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "environment detached"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-env.json")
                    allowNuget = $false
                    submissionOrder = 2
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKTREE_INVALID"
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "environment_retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = New-TestLatestRun -AttemptNumber 1 -TaskName "develop-task-env-a1" -ResultFile (Join-Path $repo.tasksDir "env-result.json") -StartedAt ((Get-Date).ToString("o"))
                    runs = @()
                    merge = New-TestMergeRecord
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.nextMergeTaskId -eq "task-merge-ready") "Detached environment retries must not block merge readiness."
        Assert-True (@($snapshot.startableTaskIds).Count -eq 0) "Detached environment retries must not become directly startable."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WorkerLaunchSequenceSeparatesIdentityFromAttempts {
    $attemptsUsed = 0
    $workerLaunchSequence = 2
    $taskName = Invoke-SchedulerHelperFunctions -FunctionNames @("Get-TaskPrefix", "Get-ShortTaskLabel", "Get-TaskIdentityToken", "Get-AttemptTaskName") -ScriptBlock {
        Get-AttemptTaskName -TaskId "task-abcdef-1234" -SourceCommand "develop" -LaunchSequence 2
    }
    $resultPath = "task-1-launch-$workerLaunchSequence-result.json"

    Assert-True ($attemptsUsed -eq 0) "Attempt refund scenario should allow zero consumed normal attempts."
    Assert-True ($taskName -match '^develop-taskab-[a-z0-9]{10}-a2$') "Worker identity must come from launch sequence and a collision-safe task token."
    Assert-True ($resultPath -eq "task-1-launch-2-result.json") "Result artifacts must use launch sequence naming."
}

function Test-PreflightMissingSolutionIsEnvironmentFailure {
    $repo = New-TestRepo
    try {
        $missingSolution = Join-Path $repo.root "Missing.slnx"
        $scriptPath = 'D:\Repos\T.L-Marketplace\plugins\T.L-AutoDevelop\scripts\preflight.ps1'
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SolutionPath $missingSolution
        $result = ($raw | Out-String | ConvertFrom-Json)
        Assert-True ($result.passed -eq $false) "Missing solution path should fail preflight."
        Assert-True ($result.environmentFailure -eq $true) "Missing solution path should be marked as environment failure."
        Assert-True ([string]$result.environmentCategory -eq "SOLUTION_PATH_MISSING") "Preflight should classify missing solution paths explicitly."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-InvestigationInconclusiveGetsOneNormalRetry {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-investigation.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "FAILED"
            finalCategory = "INVESTIGATION_INCONCLUSIVE"
            summary = "Investigation could not determine a reliable change path."
            feedback = "Error: Reached max turns (14)"
            noChangeReason = ""
            files = @()
            branch = ""
            artifacts = $null
            investigationConclusion = "INCONCLUSIVE"
            reproductionConfirmed = $false
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-investigation"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "investigate timeline refresh"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = $resultPath
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    manualDebugReason = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "develop-task-investigation-a1" -ResultFile $resultPath -StartedAt ((Get-Date).ToString("o")))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-investigation" })[0]
        Assert-True ([string]$task.state -eq "retry_scheduled") "The first inconclusive investigation should still get one normal retry."
        Assert-True (-not $snapshot.manualDebugTaskIds -or @($snapshot.manualDebugTaskIds).Count -eq 0) "The first inconclusive investigation must not be paused immediately."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RepeatedInvestigationInconclusiveBecomesManualDebugNeeded {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-investigation-repeat.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "FAILED"
            finalCategory = "INVESTIGATION_INCONCLUSIVE"
            summary = "Investigation could not determine a reliable change path."
            feedback = "Error: Reached max turns (14)"
            noChangeReason = ""
            files = @()
            branch = ""
            artifacts = $null
            investigationConclusion = "INCONCLUSIVE"
            reproductionConfirmed = $false
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-merge-ready"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "already accepted"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-merge-ready.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    manualDebugReason = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "develop-task-merge-ready-a1" -ResultFile (Join-Path $repo.tasksDir "merge-ready-result.json") -StartedAt ((Get-Date).ToString("o")))
                    runs = @()
                    merge = [pscustomobject]@{ state = "pending"; preparedAt = ""; commitMessage = ""; commitSha = ""; reason = ""; branchName = "auto/merge-ready" }
                },
                [pscustomobject]@{
                    taskId = "task-investigation"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "rollback fix investigation"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = $resultPath
                    allowNuget = $false
                    submissionOrder = 2
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 2
                    attemptsRemaining = 1
                    workerLaunchSequence = 2
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    manualDebugReason = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 2 -TaskName "develop-task-investigation-a2" -ResultFile $resultPath -StartedAt ((Get-Date).ToString("o")))
                    runs = @(
                        [pscustomobject]@{
                            attemptNumber = 1
                            finalStatus = "FAILED"
                            finalCategory = "INVESTIGATION_INCONCLUSIVE"
                            summary = "Investigation could not determine a reliable change path."
                            feedback = "Error: Reached max turns (14)"
                            noChangeReason = ""
                            investigationConclusion = "INCONCLUSIVE"
                            reproductionConfirmed = $false
                            actualFiles = @()
                            branchName = ""
                            resultFile = (Join-Path $repo.resultsDir "previous.json")
                            completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                            artifacts = $null
                        }
                    )
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-investigation" })[0]
        Assert-True ([string]$task.state -eq "manual_debug_needed") "Repeated inconclusive investigation without new evidence should pause in manual_debug_needed."
        Assert-True ([int]$task.waveNumber -eq 0) "Manual debug tasks should detach from the original wave."
        Assert-True (@($snapshot.manualDebugTaskIds) -contains "task-investigation") "Manual debug tasks should be visible in the snapshot."
        Assert-True ([string]$snapshot.nextMergeTaskId -eq "task-merge-ready") "Manual debug tasks must not block merge readiness."
        Assert-True (@($snapshot.startableTaskIds).Count -eq 0) "Manual debug tasks must not be directly startable."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ManualDebugTaskResumesToQueuedOnPositiveReplan {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-base"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "base dependency"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-base.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 0
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    manualDebugReason = ""
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -ResultFile (Join-Path $repo.tasksDir "task-base-run.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                },
                [pscustomobject]@{
                    taskId = "task-manual"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "paused investigation task"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-manual.json")
                    allowNuget = $false
                    submissionOrder = 2
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 2
                    attemptsRemaining = 1
                    workerLaunchSequence = 2
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    manualDebugReason = "Repeated inconclusive investigation produced no new evidence."
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "manual_debug_needed"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 2 -TaskName "develop-task-manual-a2" -ResultFile (Join-Path $repo.tasksDir "task-manual-run.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $planFile = Join-Path $repo.root "plan-manual-debug.json"
        [System.IO.File]::WriteAllText($planFile, (@{
            summary = "resume paused task"
            tasks = @(
                @{
                    taskId = "task-base"
                    waveNumber = 1
                    blockedBy = @()
                    plannerMetadata = @{}
                },
                @{
                    taskId = "task-manual"
                    waveNumber = 2
                    blockedBy = @("task-base")
                    plannerMetadata = @{ resumed = $true }
                }
            )
            startableTaskIds = @("task-base")
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $applyResult = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "apply-plan" -PlanFile $planFile
        $task = @($applyResult.snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-manual" })[0]
        Assert-True ([string]$task.state -eq "queued") "A positive-wave replan should resume manual_debug_needed tasks back to queued."
        Assert-True ([int]$task.waveNumber -eq 2) "The resumed task should adopt the replanned wave."
        Assert-True (@($task.blockedBy).Count -eq 1 -and [string]$task.blockedBy[0] -eq "task-base") "The resumed task should preserve replanned blockers."
        Assert-True (-not (@($applyResult.snapshot.startableTaskIds) -contains "task-manual")) "The resumed task should still respect its blockers and not start early."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ManualDebugTaskStaysPausedWithoutPositiveWaveReplan {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-manual"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "paused investigation task"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-manual.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 2
                    attemptsRemaining = 1
                    workerLaunchSequence = 2
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 0
                    environmentRepairAttemptsRemaining = 2
                    lastEnvironmentFailureCategory = ""
                    manualDebugReason = "Repeated inconclusive investigation produced no new evidence."
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "manual_debug_needed"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 2 -TaskName "develop-task-manual-a2" -ResultFile (Join-Path $repo.tasksDir "task-manual-run.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $planFile = Join-Path $repo.root "plan-manual-debug-stays-paused.json"
        [System.IO.File]::WriteAllText($planFile, (@{
            summary = "leave paused task detached"
            tasks = @(
                @{
                    taskId = "task-manual"
                    waveNumber = 0
                    blockedBy = @()
                    plannerMetadata = @{ resumed = $false }
                }
            )
            startableTaskIds = @()
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $applyResult = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "apply-plan" -PlanFile $planFile
        $task = @($applyResult.snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-manual" })[0]
        Assert-True ([string]$task.state -eq "manual_debug_needed") "Without a positive wave assignment, manual_debug_needed should stay paused."
        Assert-True ([int]$task.waveNumber -eq 0) "The paused task should remain detached."
        Assert-True (@($applyResult.snapshot.startableTaskIds).Count -eq 0) "The paused task must remain non-startable."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-SnapshotResilience {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "bad-task"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "broken"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "bad-task.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        resultFile = ""
                        processId = "NaN"
                    }
                    runs = @()
                    merge = [pscustomobject]@{}
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ($snapshot.schedulerHealthy -eq $false) "snapshot-queue should report reconcile errors without crashing."
        Assert-True (@($snapshot.reconcileErrors).Count -eq 1) "snapshot-queue should surface one reconcile error for the malformed task."
        Assert-True ([string]$snapshot.reconcileErrors[0].taskId -eq "bad-task") "reconcileErrors should name the malformed task."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-EncodedWorkerLaunchCommandPreservesSpacedPaths {
    $scriptPath = 'C:\Users\Example User Name\.claude\plugins\cache\marketplace\scripts\auto-develop.ps1'
    $promptFile = 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\prompt file.md'
    $solutionPath = 'D:\Repos\My Repo\My Solution.slnx'
    $resultFile = 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\result file.json'
    $plannerContextFile = 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\planner context.json'
    $taskName = 'develop-task-a1'
    $taskId = 'task-spaces'
    $commandType = 'develop'

    $encoded = Invoke-SchedulerHelperFunctions -FunctionNames @("ConvertTo-PowerShellSingleQuotedLiteral", "Get-EncodedWorkerLaunchCommand") -ScriptBlock {
        Get-EncodedWorkerLaunchCommand -ScriptPath 'C:\Users\Example User Name\.claude\plugins\cache\marketplace\scripts\auto-develop.ps1' -PromptFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\prompt file.md' -SolutionPath 'D:\Repos\My Repo\My Solution.slnx' -ResultFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\result file.json' -PlannerContextFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\planner context.json' -TaskName 'develop-task-a1' -SchedulerTaskId 'task-spaces' -CommandType 'develop' -AllowNuget:$false
    }

    $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(([string]$encoded).Trim()))

    Assert-True ($decoded -match [regex]::Escape("`$ErrorActionPreference = 'Stop'")) "Encoded worker launch must preserve the literal ErrorActionPreference assignment."
    Assert-True ($decoded -match [regex]::Escape($scriptPath)) "Encoded worker launch must preserve the full spaced script path."
    Assert-True ($decoded -match [regex]::Escape($promptFile)) "Encoded worker launch must preserve the full spaced prompt path."
    Assert-True ($decoded -match [regex]::Escape($solutionPath)) "Encoded worker launch must preserve the full spaced solution path."
    Assert-True ($decoded -match [regex]::Escape($resultFile)) "Encoded worker launch must preserve the full spaced result path."
    Assert-True ($decoded -match [regex]::Escape($plannerContextFile)) "Encoded worker launch must preserve the planner context file path."
    Assert-True ($decoded -notmatch '-File\s+C:\\Users\\Example') "Encoded worker launch must not rely on a raw -File argument that can split at spaces."
}

function Test-WritePlannerContextFilePersistsEffortClass {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @("Ensure-Directory", "Ensure-ParentDirectory", "Write-PlannerContextFile") -ScriptBlock {
        $path = Join-Path $env:TEMP ("planner-context-" + [guid]::NewGuid().ToString("N") + ".json")
        $task = [pscustomobject]@{
            taskId = "task-planner"
            waveNumber = 3
            plannerMetadata = [pscustomobject]@{
                effortClass = "LOW"
                likelyFiles = @("src\App.cs")
            }
        }
        Write-PlannerContextFile -Path $path -Task $task
        try {
            [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $raw | ConvertFrom-Json
    Assert-True ([string]$parsed.taskId -eq "task-planner") "Planner context file should persist the task id."
    Assert-True ([int]$parsed.waveNumber -eq 3) "Planner context file should persist the wave number."
    Assert-True ([string]$parsed.plannerMetadata.effortClass -eq "LOW") "Planner context file should persist plannerMetadata.effortClass."
}

function Test-PlannerContextLowEffortSelectsSimpleProfile {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Get-NormalizedPlannerEffortClass",
        "Get-PipelineProfile"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("planner-context-" + [guid]::NewGuid().ToString("N") + ".json")
        [System.IO.File]::WriteAllText($path, '{"plannerMetadata":{"effortClass":"LOW"}}', [System.Text.Encoding]::UTF8)
        try {
            $context = Read-JsonFileBestEffort -Path $path
            [pscustomobject]@{
                plannerEffortClass = Get-NormalizedPlannerEffortClass -EffortClass ([string]$context.plannerMetadata.effortClass)
                pipelineProfile = Get-PipelineProfile -PlannerEffortClass ([string]$context.plannerMetadata.effortClass)
            } | ConvertTo-Json -Depth 6
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.plannerEffortClass -eq "LOW") "LOW planner effort should remain normalized as LOW."
    Assert-True ([string]$parsed.pipelineProfile -eq "SIMPLE") "LOW planner effort should select the SIMPLE pipeline profile."
}

function Test-MissingPlannerContextFallsBackToComplexProfile {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Get-NormalizedPlannerEffortClass",
        "Get-PipelineProfile"
    ) -ScriptBlock {
        $missingPath = Join-Path $env:TEMP ("missing-planner-context-" + [guid]::NewGuid().ToString("N") + ".json")
        $context = Read-JsonFileBestEffort -Path $missingPath
        $plannerEffortClass = if ($context -and $context.plannerMetadata) {
            Get-NormalizedPlannerEffortClass -EffortClass ([string]$context.plannerMetadata.effortClass)
        } else {
            "UNKNOWN"
        }
        [pscustomobject]@{
            contextLoaded = [bool]$context
            plannerEffortClass = $plannerEffortClass
            pipelineProfile = Get-PipelineProfile -PlannerEffortClass $plannerEffortClass
        } | ConvertTo-Json -Depth 6
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.contextLoaded -eq $false) "Missing planner context should not load successfully."
    Assert-True ([string]$parsed.plannerEffortClass -eq "UNKNOWN") "Missing planner context should fall back to UNKNOWN effort."
    Assert-True ([string]$parsed.pipelineProfile -eq "COMPLEX") "Missing planner context should fall back to the COMPLEX profile."
}

function Test-RegistrationRejectsMissingPromptFile {
    $repo = New-TestRepo
    try {
        $tasksFile = Join-Path $repo.root "tasks-missing-prompt.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-missing-prompt"
                taskText = "A"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                resultFile = (Join-Path $repo.resultsDir "task-missing-prompt.json")
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $stdout = Join-Path $repo.root "register-missing-prompt.stdout.txt"
        $stderr = Join-Path $repo.root "register-missing-prompt.stderr.txt"
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:SchedulerPath,
            "-Mode", "register-tasks",
            "-SolutionPath", $repo.solution,
            "-TasksFile", $tasksFile
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $combined = ""
        if (Test-Path -LiteralPath $stdout) { $combined += (Get-Content -LiteralPath $stdout -Raw) }
        if (Test-Path -LiteralPath $stderr) { $combined += (Get-Content -LiteralPath $stderr -Raw) }

        Assert-True ($process.ExitCode -ne 0) "register-tasks should fail when promptFile is missing."
        Assert-True ($combined -match "promptFile is missing") "register-tasks should explain the missing promptFile."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-CollidingTaskIdPrefixesGenerateUniqueTaskNames {
    $firstName = Invoke-SchedulerHelperFunctions -FunctionNames @("Get-TaskPrefix", "Get-ShortTaskLabel", "Get-TaskIdentityToken", "Get-AttemptTaskName") -ScriptBlock {
        Get-AttemptTaskName -TaskId "tla-20260318-151706-t01" -SourceCommand "TLA-develop" -LaunchSequence 1
    }
    $secondName = Invoke-SchedulerHelperFunctions -FunctionNames @("Get-TaskPrefix", "Get-ShortTaskLabel", "Get-TaskIdentityToken", "Get-AttemptTaskName") -ScriptBlock {
        Get-AttemptTaskName -TaskId "tla-20260318-151706-t99" -SourceCommand "TLA-develop" -LaunchSequence 1
    }

    Assert-True ($firstName -ne $secondName) "Different task ids with the same short prefix must generate unique task names."
}

function Test-SnapshotSurfacesMissingPromptFileIntegrityError {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-bad-prompt"
                    taskToken = "taskba-deadbeef00"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "bad prompt"
                    solutionPath = $repo.solution
                    promptFile = ""
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-bad-prompt.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 0
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -ResultFile (Join-Path $repo.resultsDir "task-bad-prompt.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.stateIntegrity.status -eq "warning") "snapshot-queue should warn on malformed runnable tasks with missing prompt files."
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-bad-prompt" })[0]
        Assert-True (@($task.integrityWarnings).Count -gt 0) "Task snapshots should expose prompt integrity warnings."
        Assert-True (@($task.integrityWarnings) -contains "promptFile is missing for a runnable task.") "Integrity warning should explain the missing prompt file."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WorkerPowerShellLauncherHonorsEnvironmentOverride {
    $resolved = Invoke-WithEnvironment -Variables @{ AUTODEV_POWERSHELL_COMMAND = "powershell.exe" } -ScriptBlock {
        Invoke-SchedulerHelperFunctions -FunctionNames @("Get-WorkerPowerShellLauncher") -ScriptBlock {
            (Get-WorkerPowerShellLauncher | ConvertTo-Json -Compress)
        } | ConvertFrom-Json
    }

    Assert-True ([string]$resolved.source -eq "AUTODEV_POWERSHELL_COMMAND") "Explicit AUTODEV_POWERSHELL_COMMAND should be honored."
    Assert-True ([string]$resolved.command -match 'powershell(\.exe)?$') "Resolved override should point at powershell.exe."
}

function Test-BlockedByNormalization {
    $repo = New-TestRepo
    try {
        $tasksFile = Join-Path $repo.root "tasks.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-a"
                taskText = "A"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $repo.promptFile
                resultFile = (Join-Path $repo.resultsDir "task-a.json")
                allowNuget = $false
            },
            @{
                taskId = "task-b"
                taskText = "B"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $repo.promptFile
                resultFile = (Join-Path $repo.resultsDir "task-b.json")
                allowNuget = $false
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)
        $null = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "register-tasks" -TasksFile $tasksFile

        $planFile = Join-Path $repo.root "plan.json"
        [System.IO.File]::WriteAllText($planFile, (@{
            summary = "plan"
            tasks = @(
                @{
                    taskId = "task-a"
                    waveNumber = 1
                    blockedBy = @()
                    plannerMetadata = @{}
                },
                @{
                    taskId = "task-b"
                    waveNumber = 2
                    blockedBy = "task-a"
                    plannerMetadata = @{}
                }
            )
            startableTaskIds = @("task-a")
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)
        $null = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "apply-plan" -PlanFile $planFile

        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $taskB = @($savedState.tasks | Where-Object { $_.taskId -eq "task-b" })[0]
        Assert-True ($taskB.blockedBy -is [System.Array]) "blockedBy must persist as an array even with one dependency."
        Assert-True (@($taskB.blockedBy).Count -eq 1 -and [string]$taskB.blockedBy[0] -eq "task-a") "blockedBy should preserve the dependency id."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-NextMergeGate {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-merge"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "merge"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-merge.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "develop-task-merge-a1" -ResultFile (Join-Path $repo.tasksDir "task-merge-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                },
                [pscustomobject]@{
                    taskId = "task-queued"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "queued"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-queued.json")
                    allowNuget = $false
                    submissionOrder = 2
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.nextMergeTaskId -eq "") "nextMergeTaskId should stay empty while the same wave still has unfinished work."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-DeclaredDependencyValidation {
    $repo = New-TestRepo
    try {
        $tasksFile = Join-Path $repo.root "tasks-deps.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-a"
                taskText = "A"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $repo.promptFile
                resultFile = (Join-Path $repo.resultsDir "task-a.json")
            },
            @{
                taskId = "task-b"
                taskText = "B"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $repo.promptFile
                resultFile = (Join-Path $repo.resultsDir "task-b.json")
                declaredDependencies = @("task-a")
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)
        $null = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "register-tasks" -TasksFile $tasksFile

        $planFile = Join-Path $repo.root "bad-plan.json"
        [System.IO.File]::WriteAllText($planFile, (@{
            summary = "bad plan"
            tasks = @(
                @{ taskId = "task-a"; waveNumber = 2; blockedBy = @(); plannerMetadata = @{} },
                @{ taskId = "task-b"; waveNumber = 1; blockedBy = @(); plannerMetadata = @{} }
            )
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $stdout = Join-Path $repo.root "apply-plan.stdout.txt"
        $stderr = Join-Path $repo.root "apply-plan.stderr.txt"
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $script:SchedulerPath,
            "-Mode", "apply-plan",
            "-SolutionPath", $repo.solution,
            "-PlanFile", $planFile
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        $combined = ""
        if (Test-Path -LiteralPath $stdout) { $combined += (Get-Content -LiteralPath $stdout -Raw) }
        if (Test-Path -LiteralPath $stderr) { $combined += (Get-Content -LiteralPath $stderr -Raw) }
        Assert-True ($process.ExitCode -ne 0) "apply-plan should fail when declared dependencies are violated."
        Assert-True ($combined -match "does not respect declared dependency") "Dependency validation error should explain the violated declaration."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-DeclaredDependencyBlocksStartUntilSatisfied {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-a"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "A"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "task-a.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                },
                [pscustomobject]@{
                    taskId = "task-b"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "B"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "task-b.json")
                    submissionOrder = 2
                    waveNumber = 2
                    blockedBy = @("task-a")
                    declaredDependencies = @("task-a")
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True (@($snapshot.startableTaskIds).Count -eq 1 -and [string]$snapshot.startableTaskIds[0] -eq "task-a") "Only the dependency root should start before the dependent task is satisfied."

        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $savedState.tasks[0].state = "merged"
        $savedState.tasks[0].latestRun.completedAt = (Get-Date).ToString("o")
        Write-StateFile -StateFile $repo.stateFile -State $savedState

        $snapshotAfterMerge = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True (@($snapshotAfterMerge.startableTaskIds).Count -eq 1 -and [string]$snapshotAfterMerge.startableTaskIds[0] -eq "task-b") "Dependent task should become startable only after the dependency is successfully resolved."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-UsageProjectionAndPlannerFeedback {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-feedback-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("src/File.cs")
            branch = "auto/task-feedback"
            artifacts = $null
            reproductionConfirmed = $true
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-feedback"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "Investigate and fix build issue with tests"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-feedback.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{ likelyFiles = @("src/File.cs") }
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-feedback-a1"
                        resultFile = $resultPath
                        processId = 999999
                        startedAt = (Get-Date).AddMinutes(-18).ToString("o")
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ($snapshot.plannerFeedbackSummary.evaluatedTasks -eq 1) "Snapshot should expose planner feedback summary."
        Assert-True ([double]$snapshot.plannerFeedbackSummary.averageHitRate -gt 0) "Planner feedback summary should include a hit rate."
        Assert-True ([int]$snapshot.usageProjection.fullQueueEstimatedMinutes -ge 0) "Snapshot should expose queue usage projection."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-TaskDiscoveryBriefUsesCompactCompletedTaskData {
    $output = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Normalize-StringArray",
        "Clip-DiscoveryBriefText",
        "Get-DiscoveryBriefConflictHint",
        "Get-TaskDiscoveryBrief"
    ) -ScriptBlock {
        $task = [pscustomobject]@{
            taskId = "task-brief"
            waveNumber = 2
            state = "pending_merge"
            taskText = "Fix null reference in OrderService.GetById by tightening DTO access and keeping test coverage up to date."
            plannerMetadata = [pscustomobject]@{
                likelyAreas = @("Services", "DTO")
                likelyFiles = @("src\\Services\\OrderService.cs")
            }
            plannerFeedback = [pscustomobject]@{
                classification = "broad"
            }
            latestRun = [pscustomobject]@{
                finalStatus = "ACCEPTED"
                finalCategory = "ACCEPTED"
                summary = "Added null-safe navigation in OrderService and extended regression test coverage for the failing DTO branch."
                investigationConclusion = "OrderService shares CustomerDto with ShippingService and both paths rely on the same null-sensitive shape."
                feedback = ""
                actualFiles = @(
                    "src\\Services\\OrderService.cs",
                    "tests\\OrderServiceTests.cs",
                    "src\\Shared\\CustomerDto.cs",
                    "docs\\note.md",
                    "extra\\one.cs",
                    "extra\\two.cs",
                    "extra\\three.cs"
                )
                completedAt = "2026-03-24T10:00:00.0000000Z"
            }
        }
        (Get-TaskDiscoveryBrief -Task $task) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.taskId -eq "task-brief") "Discovery brief should preserve task id."
    Assert-True ([string]$parsed.status -eq "ACCEPTED") "Discovery brief should use latest final status."
    Assert-True (@($parsed.filesChanged).Count -eq 6) "Discovery brief should cap changed files."
    Assert-True (@($parsed.discoveries).Count -le 2) "Discovery brief should cap discoveries."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$parsed.conflictHints)) "Discovery brief should emit a compact conflict hint when useful."
}

function Test-CompletedTaskBriefsAreOrderedAndCapped {
    $output = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Get-Tasks",
        "Normalize-StringArray",
        "Clip-DiscoveryBriefText",
        "Get-DiscoveryBriefConflictHint",
        "Get-TaskDiscoveryBrief",
        "Get-DiscoveryBriefPriority",
        "Get-CompletedTaskBriefs"
    ) -ScriptBlock {
        $state = [pscustomobject]@{
            tasks = @(
                1..10 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "task-$($_)"
                        submissionOrder = $_
                        waveNumber = 1
                        state = "merged"
                        taskText = "Task $_"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            finalStatus = "ACCEPTED"
                            finalCategory = "ACCEPTED"
                            summary = "Done $_"
                            feedback = ""
                            investigationConclusion = ""
                            actualFiles = @("src\\File$($_).cs")
                            completedAt = ("2026-03-24T{0:d2}:00:00.0000000Z" -f $_)
                        }
                    }
                }
            )
        }
        (Get-CompletedTaskBriefs -State $state) | ConvertTo-Json -Depth 8
    }

    [object[]]$parsed = ConvertFrom-Json $output
    Assert-True ($parsed.Count -eq 8) "Completed task briefs should be capped to the most recent eight entries."
    Assert-True ([string]$parsed[0].taskId -eq "task-10") "Completed task briefs should order newest completed tasks first."
    Assert-True ([string]$parsed[-1].taskId -eq "task-3") "Completed task briefs should trim older completed tasks."
}

function Test-CompletedTaskBriefsPreferHigherConfidenceStatesWhenCapped {
    $output = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Get-Tasks",
        "Normalize-StringArray",
        "Clip-DiscoveryBriefText",
        "Get-DiscoveryBriefConflictHint",
        "Get-TaskDiscoveryBrief",
        "Get-DiscoveryBriefPriority",
        "Get-CompletedTaskBriefs"
    ) -ScriptBlock {
        $state = [pscustomobject]@{
            tasks = @(
                1..5 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "merged-$($_)"
                        submissionOrder = $_
                        waveNumber = 1
                        state = "merged"
                        taskText = "Merged $_"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            finalStatus = "ACCEPTED"
                            finalCategory = "ACCEPTED"
                            summary = "Merged $_"
                            feedback = ""
                            investigationConclusion = ""
                            actualFiles = @("src\\Merged$($_).cs")
                            completedAt = ("2026-03-24T0{0}:00:00.0000000Z" -f $_)
                        }
                    }
                }
                6..10 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "failed-$($_)"
                        submissionOrder = $_
                        waveNumber = 1
                        state = "completed_failed_terminal"
                        taskText = "Failed $_"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            finalStatus = "FAILED"
                            finalCategory = "PREFLIGHT_FAILED"
                            summary = "Failed $_"
                            feedback = "Failure $_"
                            investigationConclusion = ""
                            actualFiles = @("src\\Failed$($_).cs")
                            completedAt = ("2026-03-24T1{0}:00:00.0000000Z" -f ($_ - 5))
                        }
                    }
                }
            )
        }
        (Get-CompletedTaskBriefs -State $state) | ConvertTo-Json -Depth 8
    }

    [object[]]$parsed = ConvertFrom-Json $output
    Assert-True ($parsed.Count -eq 8) "Completed task briefs should still cap to eight entries after priority sorting."
    Assert-True (@($parsed | Where-Object { [string]$_.taskId -like 'merged-*' }).Count -eq 5) "Higher-confidence merged briefs should survive capping."
    Assert-True (@($parsed | Where-Object { [string]$_.taskId -like 'failed-*' }).Count -eq 3) "Lower-confidence failed briefs should only fill remaining brief slots."
}

function Test-CompletedTaskBriefsUseRecencyWithinSameConfidenceTier {
    $output = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Get-Tasks",
        "Normalize-StringArray",
        "Clip-DiscoveryBriefText",
        "Get-DiscoveryBriefConflictHint",
        "Get-TaskDiscoveryBrief",
        "Get-DiscoveryBriefPriority",
        "Get-CompletedTaskBriefs"
    ) -ScriptBlock {
        $state = [pscustomobject]@{
            tasks = @(
                [pscustomobject]@{
                    taskId = "pending-newer"
                    submissionOrder = 2
                    waveNumber = 1
                    state = "pending_merge"
                    taskText = "Newer pending"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        finalStatus = "ACCEPTED"
                        finalCategory = "ACCEPTED"
                        summary = "Newer pending"
                        feedback = ""
                        investigationConclusion = ""
                        actualFiles = @("src\\PendingNewer.cs")
                        completedAt = "2026-03-24T11:00:00.0000000Z"
                    }
                },
                [pscustomobject]@{
                    taskId = "pending-older"
                    submissionOrder = 1
                    waveNumber = 1
                    state = "pending_merge"
                    taskText = "Older pending"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        finalStatus = "ACCEPTED"
                        finalCategory = "ACCEPTED"
                        summary = "Older pending"
                        feedback = ""
                        investigationConclusion = ""
                        actualFiles = @("src\\PendingOlder.cs")
                        completedAt = "2026-03-24T10:00:00.0000000Z"
                    }
                },
                [pscustomobject]@{
                    taskId = "failed-newer"
                    submissionOrder = 4
                    waveNumber = 1
                    state = "completed_failed_terminal"
                    taskText = "Newer failed"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        finalStatus = "FAILED"
                        finalCategory = "PREFLIGHT_FAILED"
                        summary = "Newer failed"
                        feedback = "Failure"
                        investigationConclusion = ""
                        actualFiles = @("src\\FailedNewer.cs")
                        completedAt = "2026-03-24T13:00:00.0000000Z"
                    }
                },
                [pscustomobject]@{
                    taskId = "failed-older"
                    submissionOrder = 3
                    waveNumber = 1
                    state = "completed_failed_terminal"
                    taskText = "Older failed"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        finalStatus = "FAILED"
                        finalCategory = "PREFLIGHT_FAILED"
                        summary = "Older failed"
                        feedback = "Failure"
                        investigationConclusion = ""
                        actualFiles = @("src\\FailedOlder.cs")
                        completedAt = "2026-03-24T12:00:00.0000000Z"
                    }
                }
            )
        }
        (Get-CompletedTaskBriefs -State $state) | ConvertTo-Json -Depth 8
    }

    [object[]]$parsed = ConvertFrom-Json $output
    Assert-True ([string]$parsed[0].taskId -eq "pending-newer") "Newer tasks should sort first within the same confidence tier."
    Assert-True ([string]$parsed[1].taskId -eq "pending-older") "Older tasks should follow within the same confidence tier."
    Assert-True ([string]$parsed[2].taskId -eq "failed-newer") "Lower-confidence tiers should still be ordered by recency internally."
    Assert-True ([string]$parsed[3].taskId -eq "failed-older") "Older tasks in the same lower-confidence tier should follow newer ones."
}

function Test-SnapshotIncludesCompletedTaskBriefs {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = [pscustomobject]@{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-complete"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "Tighten the null handling in OrderService."
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-complete.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "merged"
                    plannerMetadata = [pscustomobject]@{ likelyAreas = @("Services") }
                    plannerFeedback = [pscustomobject]@{ classification = "acceptable" }
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        launchSequence = 1
                        taskName = "develop-task-complete-a1"
                        resultFile = (Join-Path $repo.resultsDir "task-complete.json")
                        processId = 0
                        startedAt = (Get-Date).AddMinutes(-20).ToString("o")
                        completedAt = (Get-Date).AddMinutes(-10).ToString("o")
                        finalStatus = "ACCEPTED"
                        finalCategory = "ACCEPTED"
                        summary = "Updated OrderService null handling and kept the regression test passing."
                        feedback = ""
                        noChangeReason = ""
                        investigationConclusion = "OrderService and CustomerDto are shared with shipping-related code paths."
                        reproductionConfirmed = $false
                        actualFiles = @("src\\Services\\OrderService.cs", "tests\\OrderServiceTests.cs")
                        branchName = "auto/task-complete"
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                },
                [pscustomobject]@{
                    taskId = "task-running"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "Still running."
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-running.json")
                    allowNuget = $false
                    submissionOrder = 2
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-running-a1"
                        resultFile = (Join-Path $repo.resultsDir "task-running.json")
                        processId = 999999
                        startedAt = (Get-Date).AddMinutes(-5).ToString("o")
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True (@($snapshot.completedTaskBriefs).Count -eq 1) "Snapshot should expose one completed task brief for the finished task."
        Assert-True ([string]$snapshot.completedTaskBriefs[0].taskId -eq "task-complete") "Snapshot should include the completed task brief."
        Assert-True (@($snapshot.completedTaskBriefs | Where-Object { [string]$_.taskId -eq "task-running" }).Count -eq 0) "Snapshot should exclude running tasks from completed task briefs."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RetryDoesNotBlockMerge {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-ready-merge"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "merge"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-ready-merge.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 0
                    mergeAttemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "task-ready-merge" -ResultFile (Join-Path $repo.tasksDir "task-ready-merge-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                },
                [pscustomobject]@{
                    taskId = "task-worker-retry"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "retry later"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-worker-retry.json")
                    allowNuget = $false
                    submissionOrder = 2
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 0
                    mergeAttemptsRemaining = 3
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.nextMergeTaskId -eq "task-ready-merge") "Detached worker retries must not block merge readiness for completed wave work."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-TlaMergeLockRemediation {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root
        $dotnetCountFile = Join-Path $repo.root "dotnet-count.txt"
        $taskkillLog = Join-Path $repo.root "taskkill.log"
        $gitLog = Join-Path $repo.root "git.log"

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "tla-merge"
                    sourceCommand = "TLA-develop"
                    sourceInputType = "inline"
                    taskText = "merge autonomously"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "tla-merge.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "tla-tla-merge-a1" -ResultFile (Join-Path $repo.tasksDir "tla-merge-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $savedState.tasks[0].latestRun.branchName = "auto/tla-merge"
        Write-StateFile -StateFile $repo.stateFile -State $savedState

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_DOTNET_COUNT_FILE = $dotnetCountFile
            AUTODEV_TEST_TASKKILL_LOG = $taskkillLog
            AUTODEV_TEST_GIT_LOG = $gitLog
            AUTODEV_TEST_PROCESS_CANDIDATES = (@(
                @{ id = 1111; processName = "devenv" },
                @{ id = 2222; processName = "iisexpress" }
            ) | ConvertTo-Json -Depth 8 -Compress)
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $true) "TLA prepare-merge should succeed after lock remediation."
        Assert-True ($prepareResult.lockRemediationAttempted -eq $true) "TLA prepare-merge should attempt lock remediation on MSB3027/MSB3021 failures."
        Assert-True (@($prepareResult.killedProcesses).Count -eq 2) "TLA lock remediation should taskkill the mocked Visual Studio and IIS Express processes."
        Assert-True ([string]$prepareResult.task.state -eq "merge_prepared") "Successful TLA prepare-merge should end in merge_prepared state."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$prepareResult.mergePreview.taskSummary)) "Successful prepare-merge should return a merge preview."

        $taskkillEntries = @(Get-Content -LiteralPath $taskkillLog)
        Assert-True ($taskkillEntries.Count -eq 2) "taskkill should be called once per candidate process."
        Assert-True ((Get-Content -LiteralPath $dotnetCountFile -Raw).Trim() -eq "2") "dotnet build should be retried once after taskkill remediation."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-CircuitBreakerBlocksStarts {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                1..3 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "task-fail-$_"
                        sourceCommand = "develop"
                        sourceInputType = "inline"
                        taskText = "Build task $_"
                        solutionPath = $repo.solution
                        promptFile = $repo.promptFile
                        planFile = ""
                        resultFile = (Join-Path $repo.resultsDir "task-fail-$_.json")
                        allowNuget = $false
                        submissionOrder = $_
                        waveNumber = 1
                        blockedBy = @()
                        declaredDependencies = @()
                        declaredPriority = "normal"
                        serialOnly = $false
                        maxAttempts = 3
                        attemptsUsed = 1
                        attemptsRemaining = 2
                        retryScheduled = $true
                        waitingUserTest = $false
                        mergeState = ""
                        state = "retry_scheduled"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            attemptNumber = 1
                            taskName = "task-fail-$_"
                            resultFile = ""
                            processId = 0
                            startedAt = (Get-Date).AddMinutes(-10).ToString("o")
                            completedAt = (Get-Date).AddMinutes(-2).ToString("o")
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = "Build failed"
                            noChangeReason = ""
                            actualFiles = @()
                            branchName = ""
                            artifacts = $null
                        }
                        runs = @()
                        merge = (New-TestMergeRecord)
                    }
                }
            ) + @(
                [pscustomobject]@{
                    taskId = "task-queued"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "queued"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-queued.json")
                    allowNuget = $false
                    submissionOrder = 4
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "high"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.circuitBreaker.status -eq "wave_open") "Correlated same-wave failures should open the breaker."
        Assert-True (@($snapshot.startableTaskIds).Count -eq 0) "Open breaker should block new starts."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-SharedFileWithoutConflictDoesNotRequeue {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root -DotnetBehavior "success"
        $gitLog = Join-Path $repo.root "git-shared-file.log"

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "merged-css"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "panel colors"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "merged-css.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "merged"
                    state = "merged"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "merged-css"
                        resultFile = ""
                        processId = 0
                        startedAt = (Get-Date).AddMinutes(-20).ToString("o")
                        completedAt = (Get-Date).AddMinutes(-15).ToString("o")
                        finalStatus = "ACCEPTED"
                        finalCategory = "IMPLEMENTED"
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @("app.css")
                        branchName = "auto/merged-css"
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                },
                [pscustomobject]@{
                    taskId = "pending-css"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "editor transition"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "pending-css.json")
                    submissionOrder = 2
                    waveNumber = 2
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 0
                    mergeAttemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "pending-css"
                        resultFile = ""
                        processId = 0
                        startedAt = (Get-Date).AddMinutes(-10).ToString("o")
                        completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                        finalStatus = "ACCEPTED"
                        finalCategory = "IMPLEMENTED"
                        summary = "editor transition"
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @("app.css")
                        branchName = "auto/pending-css"
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_GIT_LOG = $gitLog
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $true) "Shared-file edits without a real merge conflict should still prepare successfully."
        Assert-True ([string]$prepareResult.task.state -in @("waiting_user_test","merge_prepared")) "Shared-file non-conflicts should not be requeued."
        Assert-True ([string]$prepareResult.reason -notmatch "overlap") "Shared-file non-conflicts should not report overlap requeue reasons."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RealMergeConflictStillRetries {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "conflict-task"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "conflict task"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "conflict-task.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 0
                    mergeAttemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "conflict-task"
                        resultFile = ""
                        processId = 0
                        startedAt = (Get-Date).AddMinutes(-10).ToString("o")
                        completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                        finalStatus = "ACCEPTED"
                        finalCategory = "IMPLEMENTED"
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @("app.css")
                        branchName = "auto/conflict-task"
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_GIT_MERGE_BEHAVIOR = "conflict"
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $false) "Real git merge conflicts should still fail merge preparation."
        Assert-True ([string]$prepareResult.task.state -eq "retry_scheduled") "Real git merge conflicts should still trigger worker retry scheduling."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ExternalMergeReconciliation {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "externally-merged"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "already merged"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "externally-merged.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 0
                    mergeAttemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "externally-merged"
                        resultFile = ""
                        processId = 0
                        startedAt = (Get-Date).AddMinutes(-20).ToString("o")
                        completedAt = (Get-Date).AddMinutes(-15).ToString("o")
                        finalStatus = "ACCEPTED"
                        finalCategory = "IMPLEMENTED"
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @("app.css")
                        branchName = "auto/external"
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_BRANCH_SHA_MAP = (@{ "auto/external" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } | ConvertTo-Json -Compress)
            AUTODEV_TEST_MERGED_SHAS = (@("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") | ConvertTo-Json -Compress)
        }

        $snapshot = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        }

        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "externally-merged" })[0]
        Assert-True ([string]$task.state -eq "merged") "Snapshot reconciliation should mark externally merged task branches as merged."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-SnapshotIncludesStructuredProgress {
    $repo = New-TestRepo
    try {
        $runDir = Join-Path $repo.root ".claude-develop-logs\runs\running-task"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runDir "scheduler-snapshot.json"), (@{
            currentPhase = "IMPLEMENT"
            changedFiles = @("src\\Feature.cs")
        } | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $runDir "timeline.json"), (@(
            @{
                timestamp = (Get-Date).AddMinutes(-1).ToString("o")
                phase = "IMPLEMENT"
                message = "Repair implementation changed files."
                category = "CHANGE_APPLIED"
                data = @{ files = @("src\\Feature.cs") }
            }
        ) | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)

        $eventsFile = Join-Path $repo.root ".claude-develop-logs\scheduler\events.jsonl"
        New-Item -ItemType Directory -Path (Split-Path $eventsFile -Parent) -Force | Out-Null
        Add-Content -LiteralPath $eventsFile -Value (@{
            timestamp = (Get-Date).ToString("o")
            taskId = "running-progress"
            kind = "started"
            message = "Task pipeline started."
            data = @{ attempt = 1; waveNumber = 1 }
        } | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "running-progress"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "show progress"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "running-progress.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "running-task"
                        resultFile = (Join-Path $repo.resultsDir "running-progress.json")
                        processId = $PID
                        startedAt = (Get-Date).AddMinutes(-3).ToString("o")
                        completedAt = ""
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                        runDir = $runDir
                        schedulerSnapshotPath = (Join-Path $runDir "scheduler-snapshot.json")
                        timelinePath = (Join-Path $runDir "timeline.json")
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "running-progress" })[0]

        Assert-True ([string]$task.progress.phaseLabel -eq "Implement") "Snapshot should expose the live worker phase label."
        Assert-True ([string]$task.progress.latestMilestone -eq "Repair implementation changed files.") "Snapshot should expose the latest display-safe milestone."
        Assert-True (@($task.progress.changedFilesPreview).Count -eq 1) "Snapshot should expose changed file previews."
        Assert-True ([int]$snapshot.queueProgressSummary.runningCount -eq 1) "Snapshot should expose queue progress summary counts."
        Assert-True (@($snapshot.runningTaskProgress).Count -eq 1) "Snapshot should expose running task progress entries."
        Assert-True (@($snapshot.recentQueueEvents).Count -ge 1) "Snapshot should expose recent queue events."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-MalformedProgressArtifactsDoNotBreakSnapshot {
    $repo = New-TestRepo
    try {
        $runDir = Join-Path $repo.root ".claude-develop-logs\runs\malformed-task"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runDir "scheduler-snapshot.json"), '{"currentPhase":', [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText((Join-Path $runDir "timeline.json"), '[{', [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "malformed-progress"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "fallback progress"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "malformed-progress.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "malformed-task"
                        resultFile = (Join-Path $repo.resultsDir "malformed-progress.json")
                        processId = $PID
                        startedAt = (Get-Date).AddMinutes(-2).ToString("o")
                        completedAt = ""
                        finalStatus = ""
                        finalCategory = ""
                        summary = "fallback summary"
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                        runDir = $runDir
                        schedulerSnapshotPath = (Join-Path $runDir "scheduler-snapshot.json")
                        timelinePath = (Join-Path $runDir "timeline.json")
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "malformed-progress" })[0]

        Assert-True ([string]$task.state -eq "running") "Malformed progress artifacts must not break snapshot reconciliation."
        Assert-True ([string]$task.progress.detail -eq "fallback summary") "Malformed progress artifacts should fall back to task summary."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ProgressMilestonesTranslateToEnglish {
    $repo = New-TestRepo
    try {
        $runDir = Join-Path $repo.root ".claude-develop-logs\runs\translated-task"
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runDir "timeline.json"), (@(
            @{
                timestamp = (Get-Date).AddMinutes(-1).ToString("o")
                phase = "MODEL"
                message = "FIX_PLAN nutzt claude-sonnet"
                category = "FIX_PLAN_MODEL"
                data = @{}
            }
        ) | ConvertTo-Json -Depth 6), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                [pscustomobject]@{
                    taskId = "translated-progress"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "translated progress"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "translated-progress.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "translated-task"
                        resultFile = (Join-Path $repo.resultsDir "translated-progress.json")
                        processId = $PID
                        startedAt = (Get-Date).AddMinutes(-1).ToString("o")
                        completedAt = ""
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                        runDir = $runDir
                        schedulerSnapshotPath = (Join-Path $runDir "scheduler-snapshot.json")
                        timelinePath = (Join-Path $runDir "timeline.json")
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "translated-progress" })[0]

        Assert-True ([string]$task.progress.latestMilestone -eq "FIX_PLAN uses claude-sonnet") "Surfaced progress milestones should be translated to English."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PlannerFeedbackMatchesFilenameOnlyPredictions {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-filename-match-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("Hmd.Docs\\Components\\History\\PageTimeline.razor", "Hmd.Docs\\wwwroot\\css\\app.css")
            branch = "auto/task-filename-match"
            artifacts = $null
            reproductionConfirmed = $true
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-filename-match"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "match filename only predictions"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-filename-match.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{ likelyFiles = @("PageTimeline.razor", "app.css") }
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-filename-match-a1"
                        resultFile = $resultPath
                        processId = 999999
                        startedAt = (Get-Date).AddMinutes(-12).ToString("o")
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-filename-match" })[0]
        Assert-True ([string]$task.plannerFeedback.classification -ne "missed") "Filename-only predictions should not be scored as missed when they uniquely match actual files."
        Assert-True ([int]$task.plannerFeedback.matchKindsSummary.suffix -ge 2) "Filename-only predictions should be tracked as suffix matches."
        Assert-True (@($task.plannerFeedback.falseNegatives).Count -eq 0) "All actual files should be matched by unique filename-only predictions."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PlannerFeedbackTreatsDirectoryPredictionsAsBroadMatches {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-directory-match-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("Hmd.Docs\\Components\\History\\PageTimeline.razor")
            branch = "auto/task-directory-match"
            artifacts = $null
            reproductionConfirmed = $true
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-directory-match"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "match directory prediction"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-directory-match.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{ likelyFiles = @("Hmd.Docs\\Components\\History") }
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-directory-match-a1"
                        resultFile = $resultPath
                        processId = 999999
                        startedAt = (Get-Date).AddMinutes(-12).ToString("o")
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-directory-match" })[0]
        Assert-True ([string]$task.plannerFeedback.classification -eq "broad") "Directory-level predictions should count as broad rather than missed."
        Assert-True ([int]$task.plannerFeedback.matchKindsSummary.directory -eq 1) "Directory-level predictions should be tracked as directory matches."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PlannerFeedbackDoesNotOvermatchAmbiguousFilenamePredictions {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-ambiguous-filename-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("A\\Foo.cs", "B\\Foo.cs")
            branch = "auto/task-ambiguous-filename"
            artifacts = $null
            reproductionConfirmed = $true
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-ambiguous-filename"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "ambiguous filename prediction"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-ambiguous-filename.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{ likelyFiles = @("Foo.cs") }
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        attemptNumber = 1
                        taskName = "develop-task-ambiguous-filename-a1"
                        resultFile = $resultPath
                        processId = 999999
                        startedAt = (Get-Date).AddMinutes(-12).ToString("o")
                        finalStatus = ""
                        finalCategory = ""
                        summary = ""
                        feedback = ""
                        noChangeReason = ""
                        actualFiles = @()
                        branchName = ""
                        artifacts = $null
                    }
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-ambiguous-filename" })[0]
        Assert-True ([int]$task.plannerFeedback.matchKindsSummary.suffix -eq 0) "Ambiguous filename-only predictions must not count as suffix matches."
        Assert-True (@($task.plannerFeedback.falsePositives).Count -eq 1 -and [string]$task.plannerFeedback.falsePositives[0] -eq "Foo.cs") "Ambiguous filename-only predictions should remain unmatched."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ChangedFilesDetectionPreservesRootFilesWithoutExtension {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Test-LikelyRepoRelativePath",
        "ConvertTo-StructuredPathList"
    ) -ScriptBlock {
        $result = ConvertTo-StructuredPathList -Text "Dockerfile`nLICENSE`n.editorconfig`nsrc\App.cs"
        $result | ConvertTo-Json -Depth 8
    }

    $parsed = ($output | ConvertFrom-Json)
    Assert-True (@($parsed).Count -eq 4) "Structured path parsing should preserve root files without extension."
    Assert-True (@($parsed) -contains "Dockerfile") "Dockerfile should be preserved."
    Assert-True (@($parsed) -contains "LICENSE") "LICENSE should be preserved."
    Assert-True (@($parsed) -contains ".editorconfig") "Dotfiles should be preserved."
}

function Test-ChangedFilesDetectionRejectsGitNoiseButNotPaths {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Test-LikelyRepoRelativePath",
        "ConvertTo-StructuredPathList"
    ) -ScriptBlock {
        $result = ConvertTo-StructuredPathList -Text "fatal: not a git repository`nusage: git diff`nsrc\App.cs`nDockerfile"
        $result | ConvertTo-Json -Depth 8
    }

    $parsed = ($output | ConvertFrom-Json)
    Assert-True (@($parsed).Count -eq 2) "Structured path parsing should reject git noise while preserving valid paths."
    Assert-True (@($parsed) -contains "src\App.cs") "Regular repo-relative paths should be preserved."
    Assert-True (@($parsed) -contains "Dockerfile") "Root files should be preserved alongside nested files."
}

function Test-ChangedFilesDetectionReportsGitFailuresExplicitly {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Test-LikelyRepoRelativePath",
        "ConvertTo-StructuredPathList",
        "Get-ChangedFilesResult"
    ) -ScriptBlock {
        function Invoke-NativeCommand {
            param([string]$Command, [string[]]$Arguments)
            if ($Arguments[0] -eq "diff") {
                return @{ output = "fatal: not a git repository"; exitCode = 128 }
            }
            return @{ output = "Dockerfile`nsrc\App.cs"; exitCode = 0 }
        }

        $result = Get-ChangedFilesResult
        $result | ConvertTo-Json -Depth 8
    }

    $parsed = ($output | ConvertFrom-Json)
    Assert-True ($parsed.ok -eq $false) "Changed-files detection should report git failures explicitly."
    Assert-True (@($parsed.sourceErrors).Count -eq 1) "Changed-files detection should preserve the failing source error."
}

function Test-QueueStallDetectedWhenWorkRemainsButNothingCanRun {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "unplanned-queued"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "queued but unplanned"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "unplanned-queued.json")
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.queueStall.status -eq "stalled") "Queued work without running/startable/merge progress should be marked stalled."
        Assert-True ($snapshot.needsReplan -eq $true) "Stalled queues should explicitly request replanning."
        Assert-True ([string]$snapshot.queueStall.recommendedAction -eq "replan") "Stalled queues should recommend replanning."
        Assert-True (@($snapshot.queueStall.candidateTaskIds) -contains "unplanned-queued") "Stall diagnostics should point at the remaining queued work."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-QueueStallDoesNotTriggerWhileWaitingForUserMergeDecision {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "awaiting-merge-decision"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "waiting for merge decision"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "awaiting-merge-decision.json")
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    retryScheduled = $false
                    waitingUserTest = $true
                    mergeState = "prepared"
                    state = "waiting_user_test"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "awaiting-merge-decision" -ResultFile (Join-Path $repo.tasksDir "awaiting-merge-decision-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.queueStall.status -eq "blocked") "Waiting user test should be reported as blocked, not stalled."
        Assert-True ([string]$snapshot.queueStall.recommendedAction -eq "wait_for_user_merge_decision") "Waiting user test should recommend merge resolution."
        Assert-True ($snapshot.needsReplan -eq $false) "Waiting user test must not request replanning."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-QueueStallDoesNotTriggerWhileCircuitBreakerIsOpen {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "wave_open"
                openedAt = (Get-Date).AddMinutes(-1).ToString("o")
                closedAt = ""
                scopeWave = 1
                reasonCategory = "build_infra"
                reasonSummary = "Correlated failures opened the wave breaker."
                affectedTaskIds = @("breaker-fail-1","breaker-fail-2","breaker-fail-3")
                manualOverrideUntil = ""
            }
            tasks = @(
                1..3 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "breaker-fail-$_"
                        sourceCommand = "develop"
                        sourceInputType = "inline"
                        taskText = "Recent failed task $_"
                        solutionPath = $repo.solution
                        resultFile = (Join-Path $repo.resultsDir "breaker-fail-$_.json")
                        submissionOrder = $_
                        waveNumber = 1
                        blockedBy = @()
                        declaredDependencies = @()
                        declaredPriority = "normal"
                        serialOnly = $false
                        maxAttempts = 3
                        attemptsUsed = 1
                        attemptsRemaining = 2
                        retryScheduled = $true
                        waitingUserTest = $false
                        mergeState = ""
                        state = "retry_scheduled"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            attemptNumber = 1
                            taskName = "breaker-fail-$_"
                            resultFile = ""
                            processId = 0
                            startedAt = (Get-Date).AddMinutes(-10).ToString("o")
                            completedAt = (Get-Date).AddMinutes(-2).ToString("o")
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = "Build failed"
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $false
                            actualFiles = @()
                            branchName = ""
                            artifacts = $null
                        }
                        runs = @()
                        merge = (New-TestMergeRecord)
                    }
                }
            ) + @(
                [pscustomobject]@{
                    taskId = "breaker-queued"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "Queued behind breaker"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "breaker-queued.json")
                    submissionOrder = 4
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "high"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.queueStall.status -eq "blocked") "Open circuit breaker should block the queue without reporting a stall."
        Assert-True ([string]$snapshot.queueStall.recommendedAction -eq "wait_for_breaker_clear") "Open circuit breaker should recommend waiting for breaker clear."
        Assert-True ($snapshot.needsReplan -eq $false) "Breaker-blocked queues must not request replanning."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-OldFailuresDoNotReopenBreaker {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "closed"
                openedAt = ""
                closedAt = ""
                scopeWave = 0
                reasonCategory = ""
                reasonSummary = ""
                affectedTaskIds = @()
                manualOverrideUntil = ""
            }
            tasks = @(
                1..3 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "old-fail-$_"
                        sourceCommand = "develop"
                        sourceInputType = "inline"
                        taskText = "Old failed task $_"
                        solutionPath = $repo.solution
                        resultFile = (Join-Path $repo.resultsDir "old-fail-$_.json")
                        submissionOrder = $_
                        waveNumber = 1
                        blockedBy = @()
                        declaredDependencies = @()
                        declaredPriority = "normal"
                        serialOnly = $false
                        maxAttempts = 3
                        attemptsUsed = 1
                        attemptsRemaining = 2
                        retryScheduled = $true
                        waitingUserTest = $false
                        mergeState = ""
                        state = "retry_scheduled"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            attemptNumber = 1
                            taskName = "old-fail-$_"
                            resultFile = ""
                            processId = 0
                            startedAt = (Get-Date).AddHours(-2).ToString("o")
                            completedAt = (Get-Date).AddHours(-2).AddMinutes(5).ToString("o")
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = "Build failed"
                            noChangeReason = ""
                            actualFiles = @()
                            branchName = ""
                            artifacts = $null
                        }
                        runs = @()
                        merge = (New-TestMergeRecord)
                    }
                }
            ) + @(
                [pscustomobject]@{
                    taskId = "fresh-queued"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "Fresh queued task"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "fresh-queued.json")
                    submissionOrder = 4
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.circuitBreaker.status -eq "closed") "Old failures outside the recent window must not open the breaker."
        Assert-True (@($snapshot.startableTaskIds) -contains "fresh-queued") "Old failures must not block fresh work."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-ManualOverridePersistsAcrossSnapshots {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            circuitBreaker = @{
                status = "wave_open"
                openedAt = (Get-Date).AddMinutes(-1).ToString("o")
                closedAt = ""
                scopeWave = 1
                reasonCategory = "build_infra"
                reasonSummary = "Correlated failures opened the wave breaker."
                affectedTaskIds = @("task-fail-1","task-fail-2","task-fail-3")
                manualOverrideUntil = ""
            }
            tasks = @(
                1..3 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "task-fail-$_"
                        sourceCommand = "develop"
                        sourceInputType = "inline"
                        taskText = "Recent failed task $_"
                        solutionPath = $repo.solution
                        resultFile = (Join-Path $repo.resultsDir "task-fail-$_.json")
                        submissionOrder = $_
                        waveNumber = 1
                        blockedBy = @()
                        declaredDependencies = @()
                        declaredPriority = "normal"
                        serialOnly = $false
                        maxAttempts = 3
                        attemptsUsed = 1
                        attemptsRemaining = 2
                        retryScheduled = $true
                        waitingUserTest = $false
                        mergeState = ""
                        state = "retry_scheduled"
                        plannerMetadata = [pscustomobject]@{}
                        plannerFeedback = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            attemptNumber = 1
                            taskName = "task-fail-$_"
                            resultFile = ""
                            processId = 0
                            startedAt = (Get-Date).AddMinutes(-10).ToString("o")
                            completedAt = (Get-Date).AddMinutes(-2).ToString("o")
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = "Build failed"
                            noChangeReason = ""
                            actualFiles = @()
                            branchName = ""
                            artifacts = $null
                        }
                        runs = @()
                        merge = (New-TestMergeRecord)
                    }
                }
            ) + @(
                [pscustomobject]@{
                    taskId = "task-queued"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "Queued task"
                    solutionPath = $repo.solution
                    resultFile = (Join-Path $repo.resultsDir "task-queued.json")
                    submissionOrder = 4
                    waveNumber = 1
                    blockedBy = @()
                    declaredDependencies = @()
                    declaredPriority = "high"
                    serialOnly = $false
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $clearResultRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:SchedulerPath -Mode "admin-clear-breaker" -SolutionPath $repo.solution
        $clearResult = ($clearResultRaw | Out-String | ConvertFrom-Json)
        Assert-True ([string]$clearResult.circuitBreaker.status -eq "manual_override") "Manual clear should immediately move the breaker into manual override."

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.circuitBreaker.status -eq "manual_override") "Manual override must survive a normal snapshot."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$snapshot.circuitBreaker.manualOverrideUntil)) "Manual override must preserve its expiry timestamp."
        Assert-True (@($snapshot.startableTaskIds) -contains "task-queued") "Manual override should temporarily allow startable work despite recent failures."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-MergeBuildFailurePreservesBranch {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root -DotnetBehavior "compile-fail"
        $gitLog = Join-Path $repo.root "git-compile.log"

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "merge-build-retry"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "preserve branch on build fail"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "merge-build-retry.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 0
                    mergeAttemptsRemaining = 3
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "merge-build-retry" -ResultFile (Join-Path $repo.tasksDir "merge-build-retry-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $savedState.tasks[0].latestRun.branchName = "auto/merge-build-retry"
        Write-StateFile -StateFile $repo.stateFile -State $savedState

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_GIT_LOG = $gitLog
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $false) "Compile failure should still fail merge preparation."
        Assert-True ([string]$prepareResult.task.state -eq "merge_retry_scheduled") "Build failures during prepare-merge should preserve accepted work as merge_retry_scheduled."
        Assert-True ([string]$prepareResult.task.branchName -eq "auto/merge-build-retry") "Merge-stage retry must preserve the accepted branch."
        Assert-True ([int]$prepareResult.task.mergeAttemptsUsed -eq 1) "Merge retry budget should be consumed."

        $gitEntries = if (Test-Path -LiteralPath $gitLog) { @(Get-Content -LiteralPath $gitLog) } else { @() }
        Assert-True (@($gitEntries | Where-Object { $_ -match 'branch\s+-D' }).Count -eq 0) "Branch should not be deleted on merge-stage build failure."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-AdminEditTask {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "admin-fix"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "repair me"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "admin-fix.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    maxMergeAttempts = 3
                    mergeAttemptsUsed = 1
                    mergeAttemptsRemaining = 2
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $editFile = Join-Path $repo.root "admin-edit.json"
        [System.IO.File]::WriteAllText($editFile, (@{
            taskId = "admin-fix"
            updates = @{
                state = "queued"
                waveNumber = 2
                blockedBy = @("task-a")
                retryScheduled = $false
                mergeAttemptsUsed = 0
                mergeAttemptsRemaining = 3
                latestRun = @{
                    branchName = "auto/admin-fix"
                }
                merge = @{
                    state = "pending"
                    reason = "manual reset"
                }
            }
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:SchedulerPath -Mode "admin-edit-task" -SolutionPath $repo.solution -EditFile $editFile
        $editResult = ($raw | Out-String | ConvertFrom-Json)

        Assert-True ([string]$editResult.task.state -eq "queued") "Admin edit should update task state."
        Assert-True ([int]$editResult.task.waveNumber -eq 2) "Admin edit should update wave number."
        Assert-True (@($editResult.task.blockedBy).Count -eq 1 -and [string]$editResult.task.blockedBy[0] -eq "task-a") "Admin edit should normalize blockedBy."
        Assert-True ([string]$editResult.task.branchName -eq "auto/admin-fix") "Admin edit should allow latestRun branch repair."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RunHistoryCapturesLaunchSequence {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "task-launch-sequence-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("src/File.cs")
            branch = "auto/task-launch-sequence"
            artifacts = $null
            reproductionConfirmed = $true
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-launch-sequence"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "capture launch sequence"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = $resultPath
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 2
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 2 -TaskName "develop-task-launch-sequence-a2" -ResultFile $resultPath -StartedAt ((Get-Date).AddMinutes(-2).ToString("o")))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-launch-sequence" })[0]
        Assert-True ([int]$task.latestRunLaunchSequence -eq 2) "latestRun should expose the worker launch sequence."
        Assert-True (@($task.runs).Count -eq 1) "A completed run should be appended to run history."
        Assert-True ([int]$task.runs[0].launchSequence -eq 2) "Run history should persist the worker launch sequence."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-StateIntegrityWarnsOnDuplicateLaunchSequence {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-drift"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "drift"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-drift.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-task-drift-a1" -ResultFile (Join-Path $repo.resultsDir "task-drift.json"))
                    runs = @(
                        [pscustomobject]@{
                            attemptNumber = 1
                            launchSequence = 1
                            taskName = "develop-task-drift-a1"
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = ""
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $false
                            actualFiles = @("src/File.cs")
                            branchName = "auto/task-drift-a1"
                            resultFile = "result-1.json"
                            completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                            artifacts = $null
                        },
                        [pscustomobject]@{
                            attemptNumber = 1
                            launchSequence = 1
                            taskName = "develop-task-drift-a1-duplicate"
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = ""
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $false
                            actualFiles = @("src/Other.cs")
                            branchName = "auto/task-drift-a1b"
                            resultFile = "result-2.json"
                            completedAt = (Get-Date).AddMinutes(-4).ToString("o")
                            artifacts = $null
                        }
                    )
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.stateIntegrity.status -eq "warning") "Duplicate launch sequences should surface as integrity warnings."
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-drift" })[0]
        Assert-True (@($task.integrityWarnings).Count -gt 0) "Task snapshots should expose integrity warnings."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-AdminEditTaskReturnsIntegrityWarnings {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "admin-warning"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "warn me"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "admin-warning.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "queued"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-admin-warning-a1" -ResultFile (Join-Path $repo.resultsDir "admin-warning.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $editFile = Join-Path $repo.root "admin-warning-edit.json"
        [System.IO.File]::WriteAllText($editFile, (@{
            taskId = "admin-warning"
            updates = @{
                attemptsUsed = 3
                attemptsRemaining = 3
            }
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:SchedulerPath -Mode "admin-edit-task" -SolutionPath $repo.solution -EditFile $editFile
        $editResult = ($raw | Out-String | ConvertFrom-Json)
        Assert-True (@($editResult.integrityWarnings).Count -gt 0) "Admin edit should return integrity warnings when it creates inconsistent counters."
        Assert-True ($editResult.snapshot.hasIntegrityWarnings -eq $true) "Snapshot should expose integrity warnings after inconsistent admin edits."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentReportsReadyOnCleanState {
    $repo = New-TestRepo
    try {
        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ($result.ready -eq $true) "prepare-environment should mark a clean repo as ready."
        Assert-True ([string]$result.status -eq "ready") "Clean state should report ready status."
        Assert-True (@($result.cleanupActions).Count -eq 0) "Clean state should not perform cleanup."
        Assert-True ($result.snapshot.schedulerHealthy -eq $true) "Prepare should return a healthy post-prepare snapshot."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentBlocksDirtyRepository {
    $repo = New-TestRepo
    try {
        Set-Content -LiteralPath (Join-Path $repo.root "dirty.txt") -Value "dirty" -Encoding UTF8
        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ($result.ready -eq $false) "Dirty repo should block prepare-environment."
        Assert-True ([string]$result.status -eq "blocked") "Dirty repo should report blocked status."
        Assert-True (@($result.dirtyFiles).Count -gt 0) "Dirty repo should surface dirty files."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentBlocksUnresolvedGitOperation {
    $repo = New-TestRepo
    try {
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        Set-Content -LiteralPath (Join-Path $gitDir "MERGE_HEAD") -Value ("1" * 40) -Encoding ASCII
        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ($result.ready -eq $false) "Unresolved merge state should block prepare-environment."
        Assert-True ([string]$result.status -eq "blocked") "Unresolved merge state should report blocked status."
        Assert-True (@($result.repoState.operationBlockers).Count -gt 0) "Prepare should surface git operation blockers."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentCleansStaleAutoDevelopRemnants {
    $repo = New-TestRepo
    $worktreePath = $null
    try {
        Push-Location $repo.root
        try {
            git branch "auto/stale-prepared" | Out-Null
        } finally {
            Pop-Location
        }

        $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
        $worktreePath = Join-Path $worktreeBase ("stale-prepare-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $worktreePath "orphan.txt") -Value "orphan" -Encoding UTF8
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        $fakeGitPointer = "gitdir: {0}" -f (Join-Path $gitDir "worktrees\stale-prepare")
        Set-Content -LiteralPath (Join-Path $worktreePath ".git") -Value $fakeGitPointer -Encoding UTF8

        $orphanRunDir = Join-Path $repo.root ".claude-develop-logs\runs\stale-prepare-artifact"
        New-Item -ItemType Directory -Path $orphanRunDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $orphanRunDir "timeline.json") -Value "{}" -Encoding UTF8

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ($result.ready -eq $true) "Stale AutoDevelop remnants should be cleaned without blocking prepare."
        Assert-True ([string]$result.status -eq "cleaned") "Cleanup should report cleaned status."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_branch" }).Count) -eq 1) "Prepare should remove stale merged auto branches."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_worktree" }).Count) -eq 1) "Prepare should remove orphaned AutoDevelop worktree directories."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_run_artifact" }).Count) -eq 1) "Prepare should remove orphaned run artifact directories."

        Push-Location $repo.root
        try {
            $branchList = (& git branch --format "%(refname:short)" --list "auto/stale-prepared" | Out-String).Trim()
            Assert-True (-not $branchList) "Stale auto branch should be deleted."
        } finally {
            Pop-Location
        }
        Assert-True (-not (Test-Path -LiteralPath $worktreePath)) "Orphaned AutoDevelop worktree should be deleted."
        Assert-True (-not (Test-Path -LiteralPath $orphanRunDir)) "Orphaned run artifact dir should be deleted."
    } finally {
        if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentCleansHistoricalOnlyBranchAndArtifacts {
    $repo = New-TestRepo
    $worktreePath = $null
    try {
        $taskName = "develop-historycleanup-a1"
        $branchName = "auto/history-cleanup-a1"

        Push-Location $repo.root
        try {
            git branch $branchName | Out-Null
        } finally {
            Pop-Location
        }

        $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
        $worktreePath = Join-Path $worktreeBase $taskName
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        $fakeGitPointer = "gitdir: {0}" -f (Join-Path $gitDir "worktrees\history-cleanup")
        Set-Content -LiteralPath (Join-Path $worktreePath ".git") -Value $fakeGitPointer -Encoding UTF8

        $orphanRunDir = Join-Path $repo.root (".claude-develop-logs\\runs\\" + $taskName)
        New-Item -ItemType Directory -Path $orphanRunDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $orphanRunDir "timeline.json") -Value "{}" -Encoding UTF8

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "historical-cleanup"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "completed task"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "historical-cleanup.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "merged"
                    state = "merged"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "" -ResultFile (Join-Path $repo.resultsDir "historical-cleanup.json"))
                    runs = @(
                        [pscustomobject]@{
                            attemptNumber = 1
                            launchSequence = 1
                            taskName = $taskName
                            finalStatus = "ACCEPTED"
                            finalCategory = "IMPLEMENTED"
                            summary = ""
                            feedback = ""
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $true
                            actualFiles = @("src/File.cs")
                            branchName = $branchName
                            resultFile = "historical-result.json"
                            completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                            artifacts = $null
                        }
                    )
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ([string]$result.status -eq "cleaned") "Historical-only leftovers should be cleanup-eligible."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_branch" }).Count) -eq 1) "Historical-only auto branch should be removed."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_worktree" }).Count) -eq 1) "Historical-only worktree should be removed."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_run_artifact" }).Count) -eq 1) "Historical-only artifact dir should be removed."
    } finally {
        if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentPreservesRunningLaunchArtifactsAndBranch {
    $repo = New-TestRepo
    $worktreePath = $null
    $sleepProcess = $null
    try {
        $taskName = "develop-activecleanup-a1"
        $branchName = "auto/active-cleanup-a1"

        Push-Location $repo.root
        try {
            git branch $branchName | Out-Null
        } finally {
            Pop-Location
        }

        $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
        $worktreePath = Join-Path $worktreeBase $taskName
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        $fakeGitPointer = "gitdir: {0}" -f (Join-Path $gitDir "worktrees\active-cleanup")
        Set-Content -LiteralPath (Join-Path $worktreePath ".git") -Value $fakeGitPointer -Encoding UTF8

        $runDir = Join-Path $repo.root (".claude-develop-logs\\runs\\" + $taskName)
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir "timeline.json") -Value "{}" -Encoding UTF8

        $sleepProcess = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -PassThru -WindowStyle Hidden

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "active-cleanup"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "running task"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "active-cleanup.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName $taskName -ResultFile (Join-Path $repo.resultsDir "active-cleanup.json") -ProcessId $sleepProcess.Id)
                    runs = @(
                        [pscustomobject]@{
                            attemptNumber = 1
                            launchSequence = 1
                            taskName = $taskName
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = ""
                            feedback = ""
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $false
                            actualFiles = @("src/File.cs")
                            branchName = $branchName
                            resultFile = "active-result.json"
                            completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                            artifacts = $null
                        }
                    )
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $state = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $state.tasks[0].latestRun.branchName = $branchName
        Write-StateFile -StateFile $repo.stateFile -State $state

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ([string]$result.status -eq "warning" -or [string]$result.status -eq "ready") "Running launch artifacts and branch should not be cleaned."
        Assert-True ((@($result.cleanupActions).Count) -eq 0) "Prepare should not clean the currently running branch/worktree/artifact."
        Push-Location $repo.root
        try {
            $branchList = (& git branch --format "%(refname:short)" --list $branchName | Out-String).Trim()
            Assert-True ([string]$branchList -eq $branchName) "Active auto branch should be preserved."
        } finally {
            Pop-Location
        }
        Assert-True (Test-Path -LiteralPath $worktreePath) "Active worktree should be preserved."
        Assert-True (Test-Path -LiteralPath $runDir) "Active run artifact dir should be preserved."
    } finally {
        if ($sleepProcess -and -not $sleepProcess.HasExited) {
            Stop-Process -Id $sleepProcess.Id -Force -ErrorAction SilentlyContinue
        }
        if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentCleansRetryScheduledLaunchArtifactsButPreservesNoBranchByDefault {
    $repo = New-TestRepo
    $worktreePath = $null
    try {
        $taskName = "develop-retryleftover-a1"
        $branchName = "auto/retry-leftover-a1"

        Push-Location $repo.root
        try {
            git branch $branchName | Out-Null
        } finally {
            Pop-Location
        }

        $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
        $worktreePath = Join-Path $worktreeBase $taskName
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        $fakeGitPointer = "gitdir: {0}" -f (Join-Path $gitDir "worktrees\retry-leftover")
        Set-Content -LiteralPath (Join-Path $worktreePath ".git") -Value $fakeGitPointer -Encoding UTF8

        $runDir = Join-Path $repo.root (".claude-develop-logs\\runs\\" + $taskName)
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir "timeline.json") -Value "{}" -Encoding UTF8

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "retry-leftover"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "retry task"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "retry-leftover.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName $taskName -ResultFile (Join-Path $repo.resultsDir "retry-leftover.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $state = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $state.tasks[0].latestRun.branchName = $branchName
        Write-StateFile -StateFile $repo.stateFile -State $state

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_worktree" }).Count) -eq 1) "Retry-scheduled tasks should not protect old worktree leftovers."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_run_artifact" }).Count) -eq 1) "Retry-scheduled tasks should not protect old run artifacts."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_branch" }).Count) -eq 1) "Retry-scheduled tasks should not protect stale old branches by default."
    } finally {
        if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentPreservesPendingMergeBranchButCleansOldLaunchArtifacts {
    $repo = New-TestRepo
    $worktreePath = $null
    try {
        $taskName = "develop-pendingmerge-a1"
        $branchName = "auto/pending-merge-a1"

        Push-Location $repo.root
        try {
            git branch $branchName | Out-Null
        } finally {
            Pop-Location
        }

        $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
        $worktreePath = Join-Path $worktreeBase $taskName
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        $fakeGitPointer = "gitdir: {0}" -f (Join-Path $gitDir "worktrees\pending-merge")
        Set-Content -LiteralPath (Join-Path $worktreePath ".git") -Value $fakeGitPointer -Encoding UTF8

        $runDir = Join-Path $repo.root (".claude-develop-logs\\runs\\" + $taskName)
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir "timeline.json") -Value "{}" -Encoding UTF8

        $merge = New-TestMergeRecord
        $merge.branchName = $branchName
        $merge.state = "pending"
        $merge.reason = ""

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "pending-merge-leftover"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "pending merge"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "pending-merge-leftover.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = "pending"
                    state = "pending_merge"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName $taskName -ResultFile (Join-Path $repo.resultsDir "pending-merge-leftover.json"))
                    runs = @()
                    merge = $merge
                }
            )
        })
        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_branch" }).Count) -eq 0) "Pending-merge branch must be preserved."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_auto_worktree" }).Count) -eq 1) "Pending-merge state should not protect old worktree leftovers."
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_run_artifact" }).Count) -eq 1) "Pending-merge state should not protect old run artifacts."
    } finally {
        if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareEnvironmentPreservesAliveRetryLaunchArtifacts {
    $repo = New-TestRepo
    $worktreePath = $null
    $sleepProcess = $null
    try {
        $taskName = "develop-alive-env-retry-a1"

        $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
        $worktreePath = Join-Path $worktreeBase $taskName
        New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
        $gitDir = Get-TestGitDir -RepoRoot $repo.root
        $fakeGitPointer = "gitdir: {0}" -f (Join-Path $gitDir "worktrees\alive-env-retry")
        Set-Content -LiteralPath (Join-Path $worktreePath ".git") -Value $fakeGitPointer -Encoding UTF8

        $runDir = Join-Path $repo.root (".claude-develop-logs\\runs\\" + $taskName)
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $runDir "timeline.json") -Value "{}" -Encoding UTF8

        $sleepProcess = Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -PassThru -WindowStyle Hidden

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "alive-env-retry"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "env retry still alive"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "alive-env-retry.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "environment_retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName $taskName -ResultFile (Join-Path $repo.resultsDir "alive-env-retry.json") -ProcessId $sleepProcess.Id)
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-environment"
        Assert-True ((@($result.cleanupActions | Where-Object { [string]$_.kind -eq "remove_run_artifact" }).Count) -eq 0) "Alive env-retry workers should keep their run artifacts."
        Assert-True (Test-Path -LiteralPath $runDir) "Alive env-retry run artifacts should remain on disk."
    } finally {
        if ($sleepProcess -and -not $sleepProcess.HasExited) {
            Stop-Process -Id $sleepProcess.Id -Force -ErrorAction SilentlyContinue
        }
        if ($worktreePath -and (Test-Path -LiteralPath $worktreePath)) {
            Remove-Item -LiteralPath $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WaitQueueWakesOnTaskCompletion {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "wait-complete-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "done"
            feedback = ""
            noChangeReason = ""
            files = @("src\\Feature.cs")
            branch = "auto/wait-complete"
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "wait-complete"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "complete while waiting"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "wait-complete.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-wait-complete-a1" -ResultFile $resultPath -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "wait-queue" -WaitTimeoutSeconds 1 -IdlePollSeconds 1
        Assert-True ([string]$result.status -eq "woke") "wait-queue should wake when a running task completes."
        Assert-True ([string]$result.reason -eq "task_completed") "wait-queue should report task_completed."
        Assert-True (@($result.completedTaskIds) -contains "wait-complete") "wait-queue should report completed task ids."
        Assert-True ([string]$result.snapshot.pendingMergeTaskIds[0] -eq "wait-complete") "wait-queue snapshot should include reconciled pending merge task."
        Assert-True ($null -ne $result.queueProgressSummary) "wait-queue should return queue progress summary."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WaitQueueWakesOnMergeReady {
    $repo = New-TestRepo
    try {
        $merge = New-TestMergeRecord
        $merge.state = "prepared"
        $merge.preparedAt = (Get-Date).ToString("o")

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "wait-merge-ready"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "merge ready"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "wait-merge-ready.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $true
                    mergeState = "prepared"
                    state = "waiting_user_test"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-wait-merge-ready-a1" -ResultFile (Join-Path $repo.resultsDir "wait-merge-ready.json"))
                    runs = @()
                    merge = $merge
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "wait-queue" -WaitTimeoutSeconds 1 -IdlePollSeconds 1
        Assert-True ([string]$result.status -eq "woke") "wait-queue should wake when merge is ready."
        Assert-True ([string]$result.reason -eq "merge_ready") "wait-queue should report merge_ready."
        Assert-True (@($result.waitingUserTestTaskIds) -contains "wait-merge-ready") "wait-queue should report waiting_user_test tasks."
        Assert-True ($null -ne $result.mergeTaskProgress) "wait-queue should include merge task progress."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WaitQueueWakesOnBreakerOpen {
    $repo = New-TestRepo
    try {
        $completedAt = (Get-Date).ToString("o")
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                1..3 | ForEach-Object {
                    [pscustomobject]@{
                        taskId = "wait-breaker-$($_)"
                        sourceCommand = "develop"
                        sourceInputType = "inline"
                        taskText = "breaker candidate $($_)"
                        solutionPath = $repo.solution
                        promptFile = $repo.promptFile
                        planFile = ""
                        resultFile = (Join-Path $repo.resultsDir ("wait-breaker-" + $_ + ".json"))
                        allowNuget = $false
                        submissionOrder = $_
                        waveNumber = 1
                        blockedBy = @()
                        maxAttempts = 3
                        attemptsUsed = 1
                        attemptsRemaining = 2
                        workerLaunchSequence = 1
                        retryScheduled = $true
                        waitingUserTest = $false
                        mergeState = ""
                        state = "retry_scheduled"
                        plannerMetadata = [pscustomobject]@{}
                        latestRun = [pscustomobject]@{
                            attemptNumber = 1
                            launchSequence = 1
                            taskName = "develop-wait-breaker-$($_)-a1"
                            resultFile = (Join-Path $repo.tasksDir ("wait-breaker-" + $_ + "-result.json"))
                            processId = 0
                            startedAt = (Get-Date).AddMinutes(-5).ToString("o")
                            completedAt = $completedAt
                            finalStatus = "FAILED"
                            finalCategory = "BUILD_FAILED"
                            summary = "failed"
                            feedback = "failed"
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $false
                            actualFiles = @()
                            branchName = ""
                            artifacts = $null
                            runDir = ""
                            schedulerSnapshotPath = ""
                            timelinePath = ""
                        }
                        runs = @()
                        merge = (New-TestMergeRecord)
                    }
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "wait-queue" -WaitTimeoutSeconds 1 -IdlePollSeconds 1
        Assert-True ([string]$result.status -eq "woke") "wait-queue should wake when the circuit breaker is open."
        Assert-True ([string]$result.reason -eq "breaker_opened") "wait-queue should report breaker_opened."
        Assert-True ([string]$result.snapshot.circuitBreaker.status -eq "wave_open") "wait-queue snapshot should expose the opened breaker state."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WaitQueueTimesOutWithoutChanges {
    $repo = New-TestRepo
    try {
        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "wait-queue" -WaitTimeoutSeconds 1 -IdlePollSeconds 1
        Assert-True ([string]$result.status -eq "timeout") "wait-queue should time out when nothing changes."
        Assert-True ([string]$result.reason -eq "timeout") "wait-queue should report timeout."
        Assert-True ($null -ne $result.snapshot) "wait-queue should still return a snapshot on timeout."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-WaitQueueReconcilesWorkerExitWithoutResult {
    $repo = New-TestRepo
    try {
        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "wait-missing-result"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "missing result"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "wait-missing-result.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 1
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
                    retryScheduled = $false
                    waitingUserTest = $false
                    mergeState = ""
                    state = "running"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-wait-missing-result-a1" -ResultFile (Join-Path $repo.tasksDir "missing-launch-result.json") -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "wait-queue" -WaitTimeoutSeconds 1 -IdlePollSeconds 1
        $task = @($result.snapshot.tasks | Where-Object { [string]$_.taskId -eq "wait-missing-result" })[0]
        Assert-True ([string]$result.status -eq "woke") "wait-queue should wake when a worker exits without a result."
        Assert-True ([string]$result.reason -eq "task_completed") "worker exit without result should still count as a completed wake."
        Assert-True ([string]$task.state -eq "environment_retry_scheduled") "missing result should reconcile into environment retry."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "WORKER_EXITED_WITHOUT_RESULT") "missing result should preserve the environment failure category."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-EnvironmentRetryLateResultRecoversToPendingMerge {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "late-arriving-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ACCEPTED"
            finalCategory = "IMPLEMENTED"
            summary = "late success"
            feedback = ""
            noChangeReason = ""
            files = @("src/Late.cs")
            branch = "auto/task-late"
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-late"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "late result"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-late.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "environment_retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-task-late-a1" -ResultFile $resultPath -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-late" })[0]
        Assert-True ([string]$task.state -eq "pending_merge") "Env-retry tasks should recover when the latest-run result appears later."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "") "Late accepted results should clear stale environment failure metadata."
        Assert-True ([string]$task.finalStatus -eq "ACCEPTED") "Recovered late results should populate the task snapshot status."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-EnvironmentRetryLateNoChangeRecoversWithoutFailureResidue {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "late-no-change-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "NO_CHANGE"
            finalCategory = "NO_CHANGE_ALREADY_SATISFIED"
            summary = "already satisfied"
            feedback = ""
            noChangeReason = "NO_CHANGE_ALREADY_SATISFIED"
            files = @()
            branch = ""
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-late-no-change"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "late no change"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-late-no-change.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "environment_retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-task-late-no-change-a1" -ResultFile $resultPath -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-late-no-change" })[0]
        Assert-True ([string]$task.state -eq "completed_no_change") "Late no-change results should recover env-retry tasks into completed_no_change."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "") "Late no-change recovery should clear stale environment failure metadata."
        Assert-True ([string]$task.merge.reason -eq "") "Late no-change recovery should clear stale merge failure reasons."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-EnvironmentRetryReconcileDoesNotReplayFailureResult {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "late-failure-result.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "ERROR"
            finalCategory = "WORKER_EXITED_WITHOUT_RESULT"
            summary = "missing result"
            feedback = ""
            noChangeReason = ""
            files = @()
            branch = ""
            artifacts = $null
        } | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "task-late-failure"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "late failure result"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-late-failure.json")
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 0
                    blockedBy = @()
                    maxAttempts = 3
                    attemptsUsed = 0
                    attemptsRemaining = 3
                    workerLaunchSequence = 1
                    maxEnvironmentRepairAttempts = 2
                    environmentRepairAttemptsUsed = 1
                    environmentRepairAttemptsRemaining = 1
                    lastEnvironmentFailureCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    retryScheduled = $true
                    waitingUserTest = $false
                    mergeState = ""
                    state = "environment_retry_scheduled"
                    plannerMetadata = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-task-late-failure-a1" -ResultFile $resultPath -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $firstSnapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $secondSnapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($secondSnapshot.tasks | Where-Object { [string]$_.taskId -eq "task-late-failure" })[0]
        $firstTask = @($firstSnapshot.tasks | Where-Object { [string]$_.taskId -eq "task-late-failure" })[0]
        Assert-True ([string]$firstTask.state -eq "environment_retry_scheduled") "Failure artifacts should not recover env-retry tasks."
        Assert-True ([string]$task.state -eq "environment_retry_scheduled") "Repeated reconciliation should leave failure-result env retries unchanged."
        Assert-True ([int]$task.environmentRepairAttemptsUsed -eq 1) "Repeated reconciliation should not consume extra environment repair budget."
        Assert-True ((@($task.runs).Count) -eq 0) "Repeated reconciliation should not append duplicate run records for failure artifacts."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

Test-SolutionPathFallback
Test-CompletedAtRoundTrip
Test-EnvironmentFailureRefundsAttempts
Test-RunTaskMissingResultUsesCanonicalEnvironmentFailure
Test-ReconcileAcceptedResultClearsEnvironmentFailureCategory
Test-EnvironmentRepairBudgetFallsBackToNormalRetryAtLimit
Test-ReadJsonFileBestEffortRetriesMalformedJson
Test-EnvironmentRetryDoesNotBecomeDirectlyStartable
Test-WorkerLaunchSequenceSeparatesIdentityFromAttempts
Test-CollidingTaskIdPrefixesGenerateUniqueTaskNames
Test-PreflightMissingSolutionIsEnvironmentFailure
Test-InvestigationInconclusiveGetsOneNormalRetry
Test-RepeatedInvestigationInconclusiveBecomesManualDebugNeeded
Test-ManualDebugTaskResumesToQueuedOnPositiveReplan
Test-ManualDebugTaskStaysPausedWithoutPositiveWaveReplan
Test-SnapshotResilience
Test-EncodedWorkerLaunchCommandPreservesSpacedPaths
Test-WritePlannerContextFilePersistsEffortClass
Test-PlannerContextLowEffortSelectsSimpleProfile
Test-MissingPlannerContextFallsBackToComplexProfile
Test-RegistrationRejectsMissingPromptFile
Test-SnapshotSurfacesMissingPromptFileIntegrityError
Test-BlockedByNormalization
Test-DeclaredDependencyValidation
Test-DeclaredDependencyBlocksStartUntilSatisfied
Test-UsageProjectionAndPlannerFeedback
Test-TaskDiscoveryBriefUsesCompactCompletedTaskData
Test-CompletedTaskBriefsAreOrderedAndCapped
Test-CompletedTaskBriefsPreferHigherConfidenceStatesWhenCapped
Test-CompletedTaskBriefsUseRecencyWithinSameConfidenceTier
Test-SnapshotIncludesCompletedTaskBriefs
Test-PlannerFeedbackMatchesFilenameOnlyPredictions
Test-PlannerFeedbackTreatsDirectoryPredictionsAsBroadMatches
Test-PlannerFeedbackDoesNotOvermatchAmbiguousFilenamePredictions
Test-ChangedFilesDetectionPreservesRootFilesWithoutExtension
Test-ChangedFilesDetectionRejectsGitNoiseButNotPaths
Test-ChangedFilesDetectionReportsGitFailuresExplicitly
Test-NextMergeGate
Test-RetryDoesNotBlockMerge
Test-CircuitBreakerBlocksStarts
Test-OldFailuresDoNotReopenBreaker
Test-ManualOverridePersistsAcrossSnapshots
Test-SharedFileWithoutConflictDoesNotRequeue
Test-RealMergeConflictStillRetries
Test-ExternalMergeReconciliation
Test-SnapshotIncludesStructuredProgress
Test-MalformedProgressArtifactsDoNotBreakSnapshot
Test-ProgressMilestonesTranslateToEnglish
Test-QueueStallDetectedWhenWorkRemainsButNothingCanRun
Test-QueueStallDoesNotTriggerWhileWaitingForUserMergeDecision
Test-QueueStallDoesNotTriggerWhileCircuitBreakerIsOpen
Test-TlaMergeLockRemediation
Test-MergeBuildFailurePreservesBranch
Test-AdminEditTask
Test-RunHistoryCapturesLaunchSequence
Test-StateIntegrityWarnsOnDuplicateLaunchSequence
Test-AdminEditTaskReturnsIntegrityWarnings
Test-WorkerPowerShellLauncherHonorsEnvironmentOverride
Test-PrepareEnvironmentReportsReadyOnCleanState
Test-PrepareEnvironmentBlocksDirtyRepository
Test-PrepareEnvironmentBlocksUnresolvedGitOperation
Test-PrepareEnvironmentCleansStaleAutoDevelopRemnants
Test-PrepareEnvironmentCleansHistoricalOnlyBranchAndArtifacts
Test-PrepareEnvironmentPreservesRunningLaunchArtifactsAndBranch
Test-PrepareEnvironmentPreservesAliveRetryLaunchArtifacts
Test-PrepareEnvironmentCleansRetryScheduledLaunchArtifactsButPreservesNoBranchByDefault
Test-PrepareEnvironmentPreservesPendingMergeBranchButCleansOldLaunchArtifacts
Test-WaitQueueWakesOnTaskCompletion
Test-EnvironmentRetryLateResultRecoversToPendingMerge
Test-EnvironmentRetryLateNoChangeRecoversWithoutFailureResidue
Test-EnvironmentRetryReconcileDoesNotReplayFailureResult
Test-WaitQueueWakesOnMergeReady
Test-WaitQueueWakesOnBreakerOpen
Test-WaitQueueTimesOutWithoutChanges
Test-WaitQueueReconcilesWorkerExitWithoutResult

Write-Host "Scheduler regression checks passed."
