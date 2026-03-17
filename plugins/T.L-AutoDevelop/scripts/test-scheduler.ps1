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
        Set-Content -LiteralPath (Join-Path $root ".gitignore") -Value ".claude-develop-logs/" -Encoding UTF8
        git add . | Out-Null
        git commit -m "init" | Out-Null
    } finally {
        Pop-Location
    }

    return [pscustomobject]@{
        root = $root
        solution = Join-Path $root "Test.slnx"
        stateFile = Join-Path $root ".claude-develop-logs\scheduler\state.json"
        tasksDir = Join-Path $root ".claude-develop-logs\scheduler\tasks"
        resultsDir = Join-Path $root ".claude-develop-logs\scheduler\results"
    }
}

function New-TestLatestRun {
    param(
        [int]$AttemptNumber = 0,
        [string]$TaskName = "",
        [string]$ResultFile = "",
        [int]$ProcessId = 0,
        [string]$StartedAt = ""
    )

    return [pscustomobject]@{
        attemptNumber = $AttemptNumber
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
        actualFiles = @()
        branchName = ""
        artifacts = $null
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
        [string]$TaskId = ""
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

    $raw = & powershell.exe @arguments
    return ($raw | Out-String | ConvertFrom-Json)
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

function New-MockCommandSet {
    param([string]$Root)

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
if ($Args.Count -ge 1 -and $Args[0] -in @('branch','status','merge','reset','commit')) {
    exit 0
}
exit 0
'@, [System.Text.Encoding]::UTF8)

    [System.IO.File]::WriteAllText((Join-Path $mockDir "dotnet-behavior.ps1"), @'
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
'@, [System.Text.Encoding]::UTF8)

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
                    promptFile = ""
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
                    promptFile = ""
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
                promptFile = ""
                resultFile = (Join-Path $repo.resultsDir "task-a.json")
                allowNuget = $false
            },
            @{
                taskId = "task-b"
                taskText = "B"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = ""
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
                    promptFile = ""
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
                    promptFile = ""
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
                    promptFile = ""
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

        $taskkillEntries = @(Get-Content -LiteralPath $taskkillLog)
        Assert-True ($taskkillEntries.Count -eq 2) "taskkill should be called once per candidate process."
        Assert-True ((Get-Content -LiteralPath $dotnetCountFile -Raw).Trim() -eq "2") "dotnet build should be retried once after taskkill remediation."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

Test-CompletedAtRoundTrip
Test-SnapshotResilience
Test-BlockedByNormalization
Test-NextMergeGate
Test-TlaMergeLockRemediation

Write-Host "Scheduler regression checks passed."
