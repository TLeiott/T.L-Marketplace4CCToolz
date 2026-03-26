param()

$ErrorActionPreference = "Stop"

$script:SchedulerPath = Join-Path $PSScriptRoot "scheduler.ps1"
$script:PreflightPath = Join-Path $PSScriptRoot "preflight.ps1"

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

function Write-TestFile {
    param(
        [string]$Path,
        [string]$Content
    )
    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function New-TestBlazorRepo {
    $root = Join-Path $env:TEMP ("autodev-preflight-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Push-Location $root
    try {
        git init | Out-Null
        git config user.email "autodev-tests@example.com"
        git config user.name "AutoDevelop Tests"

        $projectPath = Join-Path $root "TestApp.csproj"
        Write-TestFile -Path $projectPath -Content @"
<Project Sdk="Microsoft.NET.Sdk.Razor">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <SupportedPlatform Include="browser" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.AspNetCore.Components.Web" Version="10.0.2" />
  </ItemGroup>
</Project>
"@
        Write-TestFile -Path (Join-Path $root "_Imports.razor") -Content @"
@namespace TestApp
@using Microsoft.AspNetCore.Components
"@
        Write-TestFile -Path (Join-Path $root "ChildWidget.razor") -Content @"
<div>Child widget</div>
"@
        Write-TestFile -Path (Join-Path $root "ParentHost.razor") -Content @"
<ChildWidget />
"@
        Write-TestFile -Path (Join-Path $root "InteropBridge.cs") -Content @"
using System.Threading.Tasks;

namespace TestApp;

public static class InteropBridge
{
    public static Task BootAsync() => Task.CompletedTask;
}
"@
        Write-TestFile -Path (Join-Path $root "wwwroot\app.js") -Content @"
export function boot() {
  return true;
}
"@
        Write-TestFile -Path (Join-Path $root ".gitignore") -Content ".claude-develop-logs/"
        $restore = & dotnet restore $projectPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to restore the Blazor test project: $restore"
        }
        git add . | Out-Null
        git commit -m "init" | Out-Null
    } finally {
        Pop-Location
    }

    return [pscustomobject]@{
        root = $root
        solution = Join-Path $root "TestApp.csproj"
        childComponent = Join-Path $root "ChildWidget.razor"
        parentComponent = Join-Path $root "ParentHost.razor"
        interopBridge = Join-Path $root "InteropBridge.cs"
        scriptFile = Join-Path $root "wwwroot\app.js"
    }
}

function Invoke-PreflightJson {
    param(
        [string]$RepoRoot,
        [string]$SolutionPath
    )
    Push-Location $RepoRoot
    try {
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:PreflightPath -SolutionPath $SolutionPath -SkipRun
        return ($raw | Out-String | ConvertFrom-Json)
    } finally {
        Pop-Location
    }
}

function Invoke-UsageGateJson {
    param(
        [string]$ClaudeHome,
        [string]$Mode = "probe",
        [int]$ThresholdPercent = 90,
        [string]$MockUsageJson = "",
        [string]$MockErrorKind = "",
        [string]$MockUsageSequencePath = "",
        [int]$PollSeconds = 1,
        [int]$FastPollSeconds = 1,
        [int]$FastWindowSeconds = 1
    )

    $gatePath = Join-Path $PSScriptRoot "claude-usage-gate.ps1"
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $gatePath,
        "-Mode", $Mode,
        "-ClaudeHome", $ClaudeHome,
        "-ThresholdPercent", $ThresholdPercent.ToString(),
        "-PollSeconds", $PollSeconds.ToString(),
        "-FastPollSeconds", $FastPollSeconds.ToString(),
        "-FastWindowSeconds", $FastWindowSeconds.ToString()
    )

    if ($MockUsageJson) {
        $arguments += @("-MockUsageJson", $MockUsageJson)
    }
    if ($MockErrorKind) {
        $arguments += @("-MockErrorKind", $MockErrorKind)
    }
    if ($MockUsageSequencePath) {
        $arguments += @("-MockUsageSequencePath", $MockUsageSequencePath)
    }

    $raw = & powershell.exe @arguments
    $rawText = ($raw | Out-String).Trim()
    if (-not $rawText) {
        throw "Usage gate returned no JSON output. Args: $($arguments -join ' ')"
    }

    try {
        return ($rawText | ConvertFrom-Json)
    } catch {
        throw "Usage gate returned invalid JSON: $($_.Exception.Message)`nRAW:`n$rawText"
    }
}

function Write-UsageGateMockFile {
    param(
        [string]$Root,
        [object]$Payload,
        [string]$FileName = "usage-mock.json"
    )

    $path = Join-Path $Root $FileName
    [System.IO.File]::WriteAllText($path, ($Payload | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8)
    return $path
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
        [string]$View = "",
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
    if ($View) { $arguments += @("-View", $View) }
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
$commandLine = ($Args -join ' ')
if ($env:AUTODEV_TEST_DOTNET_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_DOTNET_LOG -Value $commandLine -Encoding UTF8
}
if ($Args.Count -gt 0 -and $Args[0] -eq 'restore') {
    Write-Output 'Restore succeeded.'
    exit 0
}
Write-Output 'error CS1002: ; expected'
exit 1
'@
        }
        "restore-fail" {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$commandLine = ($Args -join ' ')
if ($env:AUTODEV_TEST_DOTNET_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_DOTNET_LOG -Value $commandLine -Encoding UTF8
}
if ($Args.Count -gt 0 -and $Args[0] -eq 'restore') {
    Write-Output 'error NU1101: Unable to find package ModelContextProtocol.'
    exit 1
}
Write-Output 'Build succeeded.'
exit 0
'@
        }
        "lock-then-restore-fail" {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$commandLine = ($Args -join ' ')
if ($env:AUTODEV_TEST_DOTNET_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_DOTNET_LOG -Value $commandLine -Encoding UTF8
}
$sequenceFile = $env:AUTODEV_TEST_DOTNET_SEQUENCE_FILE
$sequence = 0
if ($sequenceFile -and (Test-Path -LiteralPath $sequenceFile)) {
    $sequence = [int](Get-Content -LiteralPath $sequenceFile -Raw)
}
$sequence++
if ($sequenceFile) {
    Set-Content -LiteralPath $sequenceFile -Value $sequence -Encoding UTF8
}
if ($sequence -eq 1) {
    Write-Output 'Restore succeeded.'
    exit 0
}
if ($sequence -eq 2) {
    Write-Output "error MSB3027: Could not copy `"bin\Debug\net8.0\Hmd.Docs.dll`" because it is being used by another process."
    Write-Output "error MSB3021: Access to the path `"bin\Debug\net8.0\Hmd.Docs.dll`" is denied."
    exit 1
}
if ($sequence -eq 3) {
    Write-Output 'error NU1101: Unable to find package ModelContextProtocol.'
    exit 1
}
Write-Output 'Build succeeded.'
exit 0
'@
        }
        "success" {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$commandLine = ($Args -join ' ')
if ($env:AUTODEV_TEST_DOTNET_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_DOTNET_LOG -Value $commandLine -Encoding UTF8
}
if ($Args.Count -gt 0 -and $Args[0] -eq 'restore') {
    Write-Output 'Restore succeeded.'
    exit 0
}
Write-Output 'Build succeeded.'
exit 0
'@
        }
        default {
@'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
$commandLine = ($Args -join ' ')
if ($env:AUTODEV_TEST_DOTNET_LOG) {
    Add-Content -LiteralPath $env:AUTODEV_TEST_DOTNET_LOG -Value $commandLine -Encoding UTF8
}
if ($Args.Count -gt 0 -and $Args[0] -eq 'restore') {
    Write-Output 'Restore succeeded.'
    exit 0
}
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
        Assert-True ([int]$task.waveNumber -eq 1) "Environment retries should preserve the last planned wave by default."
        Assert-True (@($task.blockedBy).Count -eq 0) "Environment retries should still clear stale dependency blockers when none were planned."
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
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:PreflightPath -SolutionPath $missingSolution
        $result = ($raw | Out-String | ConvertFrom-Json)
        Assert-True ($result.passed -eq $false) "Missing solution path should fail preflight."
        Assert-True ($result.environmentFailure -eq $true) "Missing solution path should be marked as environment failure."
        Assert-True ([string]$result.environmentCategory -eq "SOLUTION_PATH_MISSING") "Preflight should classify missing solution paths explicitly."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RetryRestoresLastPlannedWavePlacement {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Normalize-StringArray",
        "Restore-RetryWavePlacement",
        "Get-RetryableResult"
    ) -ScriptBlock {
        $task = [pscustomobject]@{
            attemptsUsed = 1
            maxAttempts = 3
            state = "running"
            retryScheduled = $false
            waitingUserTest = $false
            waveNumber = 1
            blockedBy = @()
            declaredDependencies = @("task-a")
            lastPlannedWaveNumber = 3
            lastPlannedBlockedBy = @("task-a")
            mergeState = ""
            merge = [pscustomobject]@{
                state = ""
                reason = ""
                branchName = ""
            }
            manualDebugReason = ""
            attemptsRemaining = 2
        }

        Get-RetryableResult -Task $task -Reason "FIX_PLAN_INSUFFICIENT"
        [pscustomobject]@{
            state = [string]$task.state
            waveNumber = [int]$task.waveNumber
            blockedBy = @($task.blockedBy)
            retryScheduled = [bool]$task.retryScheduled
        } | ConvertTo-Json -Depth 8
    }

    $parsed = $raw | ConvertFrom-Json
    Assert-True ([string]$parsed.state -eq "retry_scheduled") "Retry scheduling should still transition the task into retry_scheduled."
    Assert-True ([int]$parsed.waveNumber -eq 3) "Retry scheduling should restore the last planned wave when it is still usable."
    Assert-True (@($parsed.blockedBy) -contains "task-a") "Retry scheduling should restore the last planned blockers."
    Assert-True ($parsed.retryScheduled -eq $true) "Retry scheduling should keep the retryScheduled marker."
}

function Test-RetryFallsBackWhenPreservedPlacementIsStale {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Normalize-StringArray",
        "Is-TerminalState",
        "Get-Tasks",
        "Restore-RetryWavePlacement",
        "Get-RetryableResult"
    ) -ScriptBlock {
        $task = [pscustomobject]@{
            taskId = "task-stale"
            attemptsUsed = 1
            maxAttempts = 3
            state = "running"
            retryScheduled = $false
            waitingUserTest = $false
            waveNumber = 1
            blockedBy = @()
            declaredDependencies = @("task-missing")
            lastPlannedWaveNumber = 5
            lastPlannedBlockedBy = @("task-missing")
            mergeState = ""
            merge = [pscustomobject]@{
                state = ""
                reason = ""
                branchName = ""
            }
            manualDebugReason = ""
            attemptsRemaining = 2
        }
        $state = [pscustomobject]@{
            tasks = @(
                $task,
                [pscustomobject]@{
                    taskId = "task-other"
                    state = "queued"
                    waveNumber = 2
                }
            )
        }

        Get-RetryableResult -Task $task -Reason "FIX_PLAN_INSUFFICIENT" -State $state
        [pscustomobject]@{
            state = [string]$task.state
            waveNumber = [int]$task.waveNumber
            blockedBy = @($task.blockedBy)
            retryScheduled = [bool]$task.retryScheduled
        } | ConvertTo-Json -Depth 8
    }

    $parsed = $raw | ConvertFrom-Json
    Assert-True ([string]$parsed.state -eq "retry_scheduled") "Retry scheduling should still keep the task retryable when stale placement is rejected."
    Assert-True ([int]$parsed.waveNumber -eq 0) "Retry scheduling should clear the restored wave when the preserved placement is stale."
    Assert-True (@($parsed.blockedBy).Count -eq 0) "Retry scheduling should clear stale blockers when preserved placement can no longer be trusted."
    Assert-True ($parsed.retryScheduled -eq $true) "Retry scheduling should keep retryScheduled true after stale placement fallback."
}

function Test-SnapshotCompactViewExcludesRunHistory {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "compact-view-result.json"
        $state = [ordered]@{
            repoRoot = $repo.root
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = (Get-Date).ToString("o")
            circuitBreaker = [ordered]@{
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
                [ordered]@{
                    taskId = "task-compact"
                    taskToken = "task-compact"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "compact snapshot"
                    promptFile = $repo.promptFile
                    solutionPath = $repo.solution
                    resultFile = $resultPath
                    allowNuget = $false
                    submissionOrder = 1
                    waveNumber = 2
                    blockedBy = @()
                    lastPlannedWaveNumber = 2
                    lastPlannedBlockedBy = @()
                    lastPlanSignature = "wave=2;blockedBy="
                    declaredDependencies = @()
                    declaredPriority = "normal"
                    serialOnly = $false
                    usageCostClass = "MEDIUM"
                    usageEstimateMinutes = 20
                    usageEstimateSource = "heuristic"
                    maxAttempts = 3
                    attemptsUsed = 1
                    attemptsRemaining = 2
                    workerLaunchSequence = 1
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
                    plannerMetadata = [pscustomobject]@{ likelyFiles = @("src/File.cs") }
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "compact-view" -ResultFile $resultPath)
                    runs = @(
                        [pscustomobject]@{
                            attemptNumber = 1
                            launchSequence = 1
                            taskName = "compact-view"
                            finalStatus = "FAILED"
                            finalCategory = "FIX_PLAN_INSUFFICIENT"
                            summary = "summary"
                            feedback = "feedback"
                            validationIssues = @("Plan does not name any concrete file or search targets.")
                            failurePhase = "FINALIZE"
                            readOnlyPhaseConfusion = $false
                            noChangeReason = ""
                            investigationConclusion = ""
                            reproductionConfirmed = $false
                            retryLessons = @()
                            actualFiles = @()
                            branchName = ""
                            resultFile = $resultPath
                            completedAt = (Get-Date).ToString("o")
                            artifacts = $null
                        }
                    )
                    merge = (New-TestMergeRecord)
                }
            )
        }
        Write-StateFile -StateFile $repo.stateFile -State $state

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue" -View "Compact"
        $task = @($snapshot.tasks)[0]
        Assert-True ([string]$snapshot.view -eq "Compact") "Compact snapshots should advertise their selected view."
        Assert-True ($null -eq $task.runs) "Compact snapshots should omit verbose run history."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$task.summary)) "Compact snapshots should still carry task summary fields."
        Assert-True ([string]$task.state -eq "queued") "Compact snapshots should preserve task state."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RegisterTasksPreservesUnicodeTaskText {
    $repo = New-TestRepo
    try {
        $promptFile = Join-Path $repo.root "unicode-task.md"
        $taskText = 'Fix unicode handling — keep “smart quotes”, café, and Grüß Gott intact.'
        [System.IO.File]::WriteAllText($promptFile, "## Task`n$taskText`n`n## Solution`n$($repo.solution)", [System.Text.Encoding]::UTF8)

        $tasksFile = Join-Path $repo.root "unicode-tasks.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            [ordered]@{
                taskId = "unicode-task"
                taskText = $taskText
                sourceCommand = "develop"
                sourceInputType = "inline"
                promptFile = $promptFile
                resultFile = (Join-Path $repo.tasksDir "unicode-result.json")
                solutionPath = $repo.solution
                allowNuget = $false
            }
        ) | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)

        $null = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "register-tasks" -TasksFile $tasksFile
        $state = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $task = @($state.tasks | Where-Object { [string]$_.taskId -eq "unicode-task" })[0]

        Assert-True ([string]$task.taskText -eq $taskText) "Task registration should preserve arbitrary Unicode task text exactly."
        Assert-True ((Get-Content -LiteralPath $promptFile -Raw) -match [regex]::Escape($taskText)) "Prompt files should preserve arbitrary Unicode task text exactly."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightWarnsOnUnboundEventCallback {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.childComponent -Content @"
<button @onclick="TriggerSave">Save</button>

@code {
    [Parameter] public EventCallback OnSave { get; set; }

    private async Task TriggerSave()
    {
        await OnSave.InvokeAsync();
    }
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "eventcallback_wiring" })
        Assert-True ($result.passed -eq $true) "EventCallback wiring warnings should not fail preflight."
        Assert-True ($wiringWarnings.Count -eq 1) "Preflight should warn when a newly introduced EventCallback is unbound in existing parent usages."
        Assert-True ([string]$wiringWarnings[0].message -match "OnSave") "EventCallback warning should identify the missing callback binding."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightAcceptsExplicitEventCallbackBinding {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.childComponent -Content @"
<button @onclick="TriggerSave">Save</button>

@code {
    [Parameter] public EventCallback OnSave { get; set; }

    private async Task TriggerSave()
    {
        await OnSave.InvokeAsync();
    }
}
"@
        Write-TestFile -Path $repo.parentComponent -Content @"
<ChildWidget OnSave="HandleSave" />

@code {
    private Task HandleSave()
    {
        return Task.CompletedTask;
    }
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "eventcallback_wiring" })
        Assert-True ($result.passed -eq $true) "Bound EventCallback changes should pass preflight."
        Assert-True ($wiringWarnings.Count -eq 0) "Explicit parent callback bindings should satisfy the wiring check."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightAcceptsBindSyntaxForChangedCallback {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.childComponent -Content @"
<button @onclick="NotifyChange">Update</button>

@code {
    [Parameter] public string Value { get; set; } = "";
    [Parameter] public EventCallback<string> ValueChanged { get; set; }

    private async Task NotifyChange()
    {
        await ValueChanged.InvokeAsync("next");
    }
}
"@
        Write-TestFile -Path $repo.parentComponent -Content @"
<ChildWidget @bind-Value="CurrentValue" />

@code {
    private string CurrentValue { get; set; } = "seed";
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "eventcallback_wiring" })
        Assert-True ($result.passed -eq $true) "Component @bind wiring should pass preflight."
        Assert-True ($wiringWarnings.Count -eq 0) "@bind-X should satisfy the XChanged EventCallback requirement."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightSkipsPageComponentsForEventCallbackWiring {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.childComponent -Content @"
@page "/child"

<button @onclick="TriggerSave">Save</button>

@code {
    [Parameter] public EventCallback OnSave { get; set; }

    private async Task TriggerSave()
    {
        await OnSave.InvokeAsync();
    }
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "eventcallback_wiring" })
        Assert-True ($result.passed -eq $true) "Page components should not fail preflight for parent-binding checks."
        Assert-True ($wiringWarnings.Count -eq 0) "Components with @page should be excluded from EventCallback parent-binding warnings."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightBlocksMissingStaticJsInvokableTarget {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.scriptFile -Content @"
export async function boot() {
  return DotNet.invokeMethodAsync('TestApp', 'MissingMethod');
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringBlockers = @($result.blockers | Where-Object { [string]$_.check -eq "jsinterop_wiring" })
        Assert-True ($result.passed -eq $false) "Missing local static JS interop targets should fail preflight."
        Assert-True ($wiringBlockers.Count -eq 1) "Preflight should block unresolved local static JS interop calls."
        Assert-True ([string]$wiringBlockers[0].message -match "MissingMethod") "Static JS interop blocker should name the missing identifier."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightAcceptsAliasedStaticJsInvokableTarget {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.interopBridge -Content @"
using System.Threading.Tasks;
using Microsoft.JSInterop;

namespace TestApp;

public static class InteropBridge
{
    [JSInvokable("OpenDialog")]
    public static Task OpenDialogAsync()
    {
        return Task.CompletedTask;
    }
}
"@
        Write-TestFile -Path $repo.scriptFile -Content @"
export async function boot() {
  return DotNet.invokeMethodAsync('TestApp', 'OpenDialog');
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringBlockers = @($result.blockers | Where-Object { [string]$_.check -eq "jsinterop_wiring" })
        Assert-True ($result.passed -eq $true) "Matching aliased static JS interop targets should pass preflight."
        Assert-True ($wiringBlockers.Count -eq 0) "[JSInvokable(\"Alias\")] should satisfy the static JS interop wiring check."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightWarnsOnMissingInstanceJsInvokableTarget {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.scriptFile -Content @"
export async function boot(dotNetHelper) {
  return dotNetHelper.invokeMethodAsync('MissingMethod');
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "jsinterop_wiring" })
        Assert-True ($result.passed -eq $true) "Missing instance JS interop targets should warn but not fail preflight."
        Assert-True ($wiringWarnings.Count -eq 1) "Preflight should warn on unresolved instance JS interop calls."
        Assert-True ([string]$wiringWarnings[0].message -match "MissingMethod") "Instance JS interop warning should name the missing identifier."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightIgnoresNonDotNetInvokeMethodPatterns {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.scriptFile -Content @"
export async function boot(widget) {
  return widget.invokeMethodAsync('MissingMethod');
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "jsinterop_wiring" })
        Assert-True ($result.passed -eq $true) "Non-.NET JS invokeMethodAsync patterns should not fail preflight."
        Assert-True ($wiringWarnings.Count -eq 0) "Arbitrary JS objects should not be treated as DotNetObjectReference helpers."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PreflightDoesNotCrossWireDuplicateComponentNames {
    $repo = New-TestBlazorRepo
    try {
        Write-TestFile -Path $repo.childComponent -Content @"
<button @onclick="TriggerSave">Save</button>

@code {
    [Parameter] public EventCallback OnSave { get; set; }

    private async Task TriggerSave()
    {
        await OnSave.InvokeAsync();
    }
}
"@
        Write-TestFile -Path (Join-Path $repo.root "Admin\_Imports.razor") -Content @"
@namespace TestApp.Admin
@using Microsoft.AspNetCore.Components
"@
        Write-TestFile -Path (Join-Path $repo.root "Admin\ChildWidget.razor") -Content @"
<button @onclick="TriggerSave">Save</button>

@code {
    [Parameter] public EventCallback OnSave { get; set; }

    private async Task TriggerSave()
    {
        await OnSave.InvokeAsync();
    }
}
"@
        Write-TestFile -Path (Join-Path $repo.root "Admin\AdminHost.razor") -Content @"
<TestApp.Admin.ChildWidget OnSave="HandleSave" />

@code {
    private Task HandleSave()
    {
        return Task.CompletedTask;
    }
}
"@

        $result = Invoke-PreflightJson -RepoRoot $repo.root -SolutionPath $repo.solution
        $wiringWarnings = @($result.warnings | Where-Object { [string]$_.check -eq "eventcallback_wiring" })
        Assert-True ($result.passed -eq $true) "Duplicate component names in other namespaces should not fail preflight."
        Assert-True ($wiringWarnings.Count -eq 1) "Bindings for a different namespace-qualified component should not suppress the root component warning."
        $warningPath = [string]$wiringWarnings[0].file
        Assert-True (($warningPath -match '(^|[\\/])ChildWidget\.razor$') -and ($warningPath -notmatch '(^|[\\/])Admin[\\/]')) "The warning should remain attached to the changed root component."
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
    $retryContextFile = 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\retry context.json'
    $briefsFile = 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\worker briefs.json'
    $taskName = 'develop-task-a1'
    $taskId = 'task-spaces'
    $commandType = 'develop'

    $encoded = Invoke-SchedulerHelperFunctions -FunctionNames @("ConvertTo-PowerShellSingleQuotedLiteral", "Get-EncodedWorkerLaunchCommand") -ScriptBlock {
        Get-EncodedWorkerLaunchCommand -ScriptPath 'C:\Users\Example User Name\.claude\plugins\cache\marketplace\scripts\auto-develop.ps1' -PromptFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\prompt file.md' -SolutionPath 'D:\Repos\My Repo\My Solution.slnx' -ResultFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\result file.json' -PlannerContextFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\planner context.json' -RetryContextFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\retry context.json' -BriefsFile 'C:\Users\Example User Name\AppData\Local\Temp\claude-develop\worker briefs.json' -TaskName 'develop-task-a1' -SchedulerTaskId 'task-spaces' -CommandType 'develop' -AllowNuget:$false
    }

    $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(([string]$encoded).Trim()))

    Assert-True ($decoded -match [regex]::Escape("`$ErrorActionPreference = 'Stop'")) "Encoded worker launch must preserve the literal ErrorActionPreference assignment."
    Assert-True ($decoded -match [regex]::Escape($scriptPath)) "Encoded worker launch must preserve the full spaced script path."
    Assert-True ($decoded -match [regex]::Escape($promptFile)) "Encoded worker launch must preserve the full spaced prompt path."
    Assert-True ($decoded -match [regex]::Escape($solutionPath)) "Encoded worker launch must preserve the full spaced solution path."
    Assert-True ($decoded -match [regex]::Escape($resultFile)) "Encoded worker launch must preserve the full spaced result path."
    Assert-True ($decoded -match [regex]::Escape($plannerContextFile)) "Encoded worker launch must preserve the planner context file path."
    Assert-True ($decoded -match [regex]::Escape($retryContextFile)) "Encoded worker launch must preserve the retry context file path."
    Assert-True ($decoded -match [regex]::Escape($briefsFile)) "Encoded worker launch must preserve the worker briefs file path."
    Assert-True ($decoded -notmatch '-File\s+C:\\Users\\Example') "Encoded worker launch must not rely on a raw -File argument that can split at spaces."
}

function Test-WritePlannerContextFilePersistsEffortClass {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @("Ensure-Directory", "Ensure-ParentDirectory", "Write-PlannerContextFile") -ScriptBlock {
        $path = Join-Path $env:TEMP ("planner-context-" + [guid]::NewGuid().ToString("N") + ".json")
        $task = [pscustomobject]@{
            taskId = "task-planner"
            waveNumber = 3
            attemptsUsed = 2
            workerLaunchSequence = 5
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
    Assert-True ([int]$parsed.attemptNumber -eq 2) "Planner context file should persist the current worker attempt number."
    Assert-True ([int]$parsed.launchSequence -eq 5) "Planner context file should persist the current launch sequence."
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

function Test-WriteWorkerBriefsFilePersistsAcceptedCompletedBriefs {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Get-Tasks",
        "Normalize-StringArray",
        "Clip-DiscoveryBriefText",
        "Get-DiscoveryBriefConflictHint",
        "Get-TaskDiscoveryBrief",
        "Get-DiscoveryBriefPriority",
        "Get-CompletedTaskBriefs",
        "Get-WorkerBriefEntries",
        "Get-WorkerBriefsPayload",
        "Ensure-Directory",
        "Ensure-ParentDirectory",
        "Write-WorkerBriefsFile"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("worker-briefs-" + [guid]::NewGuid().ToString("N") + ".json")
        $state = [pscustomobject]@{
            tasks = @(
                [pscustomobject]@{
                    taskId = "accepted-brief"
                    submissionOrder = 2
                    waveNumber = 2
                    state = "merged"
                    taskText = "Reuse the existing converter in OrderService."
                    plannerMetadata = [pscustomobject]@{ likelyAreas = @("Services") }
                    plannerFeedback = [pscustomobject]@{ classification = "broad" }
                    latestRun = [pscustomobject]@{
                        finalStatus = "ACCEPTED"
                        finalCategory = "ACCEPTED"
                        summary = "Reused the existing converter path in OrderService."
                        feedback = ""
                        investigationConclusion = "OrderService already shared the same conversion path."
                        actualFiles = @("src\\Services\\OrderService.cs", "tests\\OrderServiceTests.cs")
                        completedAt = "2026-03-25T10:00:00.0000000Z"
                    }
                }
                [pscustomobject]@{
                    taskId = "failed-brief"
                    submissionOrder = 1
                    waveNumber = 1
                    state = "completed_failed_terminal"
                    taskText = "Broken attempt"
                    plannerMetadata = [pscustomobject]@{}
                    plannerFeedback = [pscustomobject]@{}
                    latestRun = [pscustomobject]@{
                        finalStatus = "FAILED"
                        finalCategory = "PREFLIGHT_FAILED"
                        summary = "Failed"
                        feedback = "Do not use this brief."
                        investigationConclusion = ""
                        actualFiles = @("src\\Ignore.cs")
                        completedAt = "2026-03-25T09:00:00.0000000Z"
                    }
                }
            )
        }
        $task = [pscustomobject]@{ taskId = "task-current" }
        $payload = Write-WorkerBriefsFile -Path $path -State $state -Task $task
        try {
            [pscustomobject]@{
                hasPayload = [bool]$payload
                raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            } | ConvertTo-Json -Depth 16
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $raw | ConvertFrom-Json
    $json = $parsed.raw | ConvertFrom-Json
    Assert-True ($parsed.hasPayload -eq $true) "Worker briefs should be written when accepted completed-task briefs exist."
    Assert-True ([string]$json.taskId -eq "task-current") "Worker briefs payload should preserve the current task id."
    Assert-True ([int]$json.briefCount -eq 1) "Worker briefs should exclude failed-terminal completed tasks."
    Assert-True ([string]$json.briefs[0].taskId -eq "accepted-brief") "Worker briefs should preserve accepted completed-task brief content."
}

function Test-WorkerBriefsRoundTripLoadsWorkerState {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-WorkerBriefsState"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("worker-briefs-state-" + [guid]::NewGuid().ToString("N") + ".json")
        [System.IO.File]::WriteAllText($path, '{"version":1,"taskId":"task-briefs","briefCount":1,"briefs":[{"taskId":"accepted-brief","waveNumber":2,"status":"ACCEPTED","finalCategory":"ACCEPTED","taskSummary":"Reuse the existing converter in OrderService.","whatWasBuilt":"Reused the existing converter path in OrderService.","discoveries":["OrderService already shared the same conversion path."],"filesChanged":[".\\src\\Services\\OrderService.cs"],"conflictHints":"Touches Services."}]}', [System.Text.Encoding]::UTF8)
        try {
            (Get-WorkerBriefsState -BriefsFile $path -ExpectedTaskId "task-briefs") | ConvertTo-Json -Depth 16
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.loaded -eq $true) "Valid worker briefs files should load successfully."
    Assert-True ([int]$parsed.briefCount -eq 1) "Worker briefs should preserve the brief count."
    Assert-True ([string]$parsed.briefs[0].taskId -eq "accepted-brief") "Worker briefs should preserve brief task ids."
    Assert-True (@($parsed.briefs[0].filesChanged) -contains "src\Services\OrderService.cs") "Worker briefs should normalize changed-file paths."
}

function Test-FormatWorkerBriefsPromptBlockIncludesDiscoveries {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Clip-Text",
        "Format-WorkerBriefsPromptBlock"
    ) -ScriptBlock {
        $briefs = [pscustomobject]@{
            loaded = $true
            briefs = @(
                [pscustomobject]@{
                    taskId = "accepted-brief"
                    taskSummary = "Reuse the existing converter in OrderService."
                    whatWasBuilt = "Reused the existing converter path in OrderService."
                    discoveries = @("OrderService already shared the same conversion path.")
                    filesChanged = @("src\Services\OrderService.cs")
                    conflictHints = "Touches Services."
                }
            )
        }

        Format-WorkerBriefsPromptBlock -WorkerBriefs $briefs -Mode "INVESTIGATE" -MaxChars 1200
    }

    Assert-True ([string]$output -match "accepted-brief") "Worker briefs prompt blocks should include the source task id."
    Assert-True ([string]$output -match "Discoveries") "Worker briefs prompt blocks should include compact discovery summaries."
    Assert-True ([string]$output -match "BRIEF RULE") "Worker briefs prompt blocks should include the mode-specific grounding rule."
}

function Test-InvestigationPriorArtOutputBlockUsesFileQualifiedSearchHitContract {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-InvestigationPriorArtOutputBlock"
    ) -ScriptBlock {
        Get-InvestigationPriorArtOutputBlock -Required $true
    }

    Assert-True ([string]$output -match "file-qualified search hit") "Investigation prior-art contract should allow file-qualified search hits."
    Assert-True ([string]$output -match "REUSE_STRATEGY") "Investigation prior-art contract should require a reuse strategy."
}

function Test-PlanPriorArtOutputBlockRequiresConcreteRelativePath {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-PlanPriorArtOutputBlock"
    ) -ScriptBlock {
        Get-PlanPriorArtOutputBlock -Required $true
    }

    Assert-True ([string]$output -match "<concrete relative path>") "Plan prior-art contract should require concrete relative paths."
    Assert-True ([string]$output -notmatch "search pattern") "Plan prior-art contract should not advertise search patterns."
}

function Test-PriorArtRequirementDetectsReuseAndCrossLayerSignals {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Test-PriorArtReuseText",
        "Get-TaskCodeReferenceHints",
        "Get-PriorArtRequirement"
    ) -ScriptBlock {
        (Get-PriorArtRequirement -TaskText "Reuse the existing OrderConverter and align SaveDialogInterop.InvokeSave with the current handler." -TaskClass "INVESTIGATIVE" -Targets @("Components\\Editor.razor", "Services\\OrderService.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.required -eq $true) "Reuse-heavy cross-layer tasks should require prior-art grounding."
    Assert-True ([string]$parsed.triggerKind -eq "reuse_text") "Explicit reuse wording should trigger the prior-art requirement."
    Assert-True (@($parsed.namedReferences).Count -gt 0) "Named code references should be captured for prior-art grounding."
}

function Test-PriorArtRequirementSkipsSimpleDirectEdit {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Test-PriorArtReuseText",
        "Get-TaskCodeReferenceHints",
        "Get-PriorArtRequirement"
    ) -ScriptBlock {
        (Get-PriorArtRequirement -TaskText "Rename the banner title text on the settings page." -TaskClass "DIRECT_EDIT" -Targets @("Pages\\Settings.razor")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.required -eq $false) "Simple direct-edit tasks should not be forced through prior-art grounding."
}

function Test-PriorArtRequirementIgnoresGenericRoleNouns {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Test-PriorArtReuseText",
        "Get-TaskCodeReferenceHints",
        "Get-PriorArtRequirement"
    ) -ScriptBlock {
        [pscustomobject]@{
            callback = Get-PriorArtRequirement -TaskText "Add a callback so the new wizard can notify completion." -TaskClass "DIRECT_EDIT" -Targets @("Pages\\Wizard.razor")
            converter = Get-PriorArtRequirement -TaskText "Create a new converter for CSV import." -TaskClass "DIRECT_EDIT" -Targets @("Converters\\CsvImportConverter.cs")
        } | ConvertTo-Json -Depth 10
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.callback.required -eq $false) "Generic callback wording must not force prior-art grounding."
    Assert-True ($parsed.converter.required -eq $false) "Generic converter wording must not force prior-art grounding."
}

function Test-InvestigationVerdictParsesPriorArtFields {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-SectionLines",
        "Get-BulletSectionValues",
        "Get-ScalarSectionText",
        "Get-InvestigationVerdict"
    ) -ScriptBlock {
        @"
RESULT: CHANGE_NEEDED
TARGET_FILES:
- Components\Editor.razor
ROOT_CAUSE:
The current callback path already exists in the editor service.
TESTABILITY_REASSESSMENT: YES
RECOMMENDED_NEXT_PHASE: FIX_PLAN
NEXT_ACTION:
Reuse the existing callback path.
PRIOR_ART_REQUIRED: YES
REFERENCE_FILES:
- Services\EditorService.cs
- Components\Shared\EditorCallbacks.razor
REFERENCE_FINDINGS:
EditorService already owns the callback registration.
REUSE_STRATEGY:
Bind the existing callback path instead of introducing a parallel implementation.
"@ | ForEach-Object {
            (Get-InvestigationVerdict -Output $_) | ConvertTo-Json -Depth 12
        }
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.priorArtRequired -eq $true) "Investigation verdicts should preserve the prior-art-required marker."
    Assert-True (@($parsed.referenceFiles).Count -eq 2) "Investigation verdicts should parse concrete reference files."
    Assert-True ([string]$parsed.reuseStrategy -match "existing callback path") "Investigation verdicts should preserve the reuse strategy."
}

function Test-InvestigationPriorArtValidationRequiresAllFields {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-InvestigationPriorArtValidation"
    ) -ScriptBlock {
        $verdict = [pscustomobject]@{
            priorArtRequired = $true
            referenceFiles = @("Services\\EditorService.cs")
            referenceFindings = ""
            reuseStrategy = ""
        }

        (Get-InvestigationPriorArtValidation -PriorArtRequired $true -InvestigationVerdict $verdict) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Prior-art validation should reject investigations that omit findings and reuse strategy."
    Assert-True ((@($parsed.issues) -join "`n") -match "reference findings") "Prior-art validation should report missing findings."
    Assert-True ((@($parsed.issues) -join "`n") -match "reuse strategy") "Prior-art validation should report missing reuse strategy."
}

function Test-InvestigationPriorArtValidationAcceptsFileQualifiedSearchHits {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-InvestigationPriorArtValidation"
    ) -ScriptBlock {
        $verdict = [pscustomobject]@{
            priorArtRequired = $true
            referenceFiles = @("Services\\EditorService.cs:42 callback registration")
            referenceFindings = "EditorService already owns the callback registration."
            reuseStrategy = "Reuse the existing callback registration path."
        }

        (Get-InvestigationPriorArtValidation -PriorArtRequired $true -InvestigationVerdict $verdict) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $true) "File-qualified search hits should satisfy investigation prior-art validation."
    Assert-True (@($parsed.referenceFiles) -contains "Services\\EditorService.cs") "File-qualified search hits should normalize to concrete reference files."
}

function Test-InvestigationPriorArtValidationRejectsRawSearchCommands {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-InvestigationPriorArtValidation"
    ) -ScriptBlock {
        $verdict = [pscustomobject]@{
            priorArtRequired = $true
            referenceFiles = @('rg "OrderConverter" src')
            referenceFindings = "Search output looked relevant."
            reuseStrategy = "Reuse the converter path."
        }

        (Get-InvestigationPriorArtValidation -PriorArtRequired $true -InvestigationVerdict $verdict) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Raw search commands should not satisfy investigation prior-art validation."
    Assert-True ((@($parsed.issues) -join "`n") -match "reference file") "Investigation prior-art validation should explain that concrete reference evidence is missing."
}

function Test-PlanValidationRequiresReuseSectionWhenPriorArtRequired {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-PlanValidation"
    ) -ScriptBlock {
        (Get-PlanValidation -PriorArtRequired $true -Plan @"
## Goal
Fix the editor callback.

## Files
- Path: Components\Editor.razor
- Action: MODIFY
- Changes: Wire the callback.

## Order
1. Update the component.
2. Run the build.

## Constraints
- Keep the change focused.

investigationRequired: false
"@) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Plans missing the reuse/reference section should fail validation when prior-art is required."
    Assert-True ((@($parsed.issues) -join "`n") -match "Reuse / Reference Pattern") "Validation should explain that the reuse/reference section is missing."
}

function Test-PlanValidationAcceptsConcreteReuseSectionWhenPriorArtRequired {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-PlanValidation"
    ) -ScriptBlock {
        (Get-PlanValidation -PriorArtRequired $true -Plan @"
## Goal
Fix the editor callback.

## Files
- Path: Components\Editor.razor
- Action: MODIFY
- Changes: Wire the callback.

## Order
1. Update the component.
2. Run the build.

## Constraints
- Keep the change focused.

## Reuse / Reference Pattern
Required: YES
Reference Files:
- Services\EditorService.cs
- Components\Shared\EditorCallbacks.razor
Reuse Path:
Reuse the existing callback registration path from EditorService.

investigationRequired: false
"@) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $true) "Concrete reuse/reference sections should satisfy prior-art plan validation."
    Assert-True (@($parsed.referenceFiles).Count -eq 2) "Plan validation should preserve parsed reference files separately from implementation targets."
}

function Test-PlanValidationRejectsSearchPatternReferenceWhenPriorArtRequired {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-PlanValidation"
    ) -ScriptBlock {
        (Get-PlanValidation -PriorArtRequired $true -Plan @"
## Goal
Fix the editor callback.

## Files
- Path: Components\Editor.razor
- Action: MODIFY
- Changes: Wire the callback.

## Order
1. Update the component.
2. Run the build.

## Constraints
- Keep the change focused.

## Reuse / Reference Pattern
Required: YES
Reference Files:
- rg ""EditorService"" Services
Reuse Path:
Reuse the existing callback registration path from EditorService.

investigationRequired: false
"@) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Search-pattern-only references should not satisfy plan prior-art validation."
    Assert-True ((@($parsed.issues) -join "`n") -match "reference file paths") "Plan validation should explain that concrete reference file paths are required."
}

function Test-PlanValidationAcceptsMarkdownDecoratedPaths {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-PlanValidation"
    ) -ScriptBlock {
        (Get-PlanValidation -PriorArtRequired $true -Plan @"
## Goal
Darken the divider colors.

## Files
- **Path:** `Hmd.Docs/wwwroot/css/app.css`
- **Action:** MODIFY
- **Changes:** Replace the existing dark-mode divider color.

## Order
1. Update the CSS file.
2. Verify the result.

## Constraints
- Keep the change scoped to the dark-mode divider rules.

## Reuse / Reference Pattern
Required: YES
Reference Files:
- `Hmd.Docs/wwwroot/css/app.css` (lines 2533-2635, existing dark-mode override block)
Reuse Path:
Extend the existing dark-mode border-color overrides already defined in app.css.

investigationRequired: false
"@) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $true) "Markdown-decorated file paths and inline line notes should still satisfy plan validation."
    Assert-True ($output -match [regex]::Escape('"targets":  [')) "Markdown-decorated plan validation should still emit parsed targets."
    Assert-True ($output -match [regex]::Escape("Hmd.Docs\\wwwroot\\css\\app.css")) "Markdown path bullets should normalize to concrete target and reference paths."
}

function Test-PriorArtReferenceFilesAcceptMarkdownWrappedEntries {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-PriorArtReferenceFiles"
    ) -ScriptBlock {
        (Get-PriorArtReferenceFiles -Entries @(
            '`Hmd.Docs/Components/Editor/VorlagenBrowserDialog.razor` (lines 118-134, confirmed via Read)',
            '**Hmd.Docs.Tests/Components/Editor/VorlagenBrowserDialogGroupingTests.cs**'
        )) | ConvertTo-Json -Depth 12
    }

    Assert-True ($output -match [regex]::Escape("Hmd.Docs\\Components\\Editor\\VorlagenBrowserDialog.razor")) "Backticked reference entries with inline notes should normalize to concrete file paths."
    Assert-True ($output -match [regex]::Escape("Hmd.Docs.Tests\\Components\\Editor\\VorlagenBrowserDialogGroupingTests.cs")) "Markdown emphasis around reference entries should not break path extraction."
}

function Test-ReadOnlyPhaseConfusionDetectorFlagsApprovalChatter {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion"
    ) -ScriptBlock {
        [pscustomobject]@{
            waiting = (Test-ReadOnlyPhaseConfusion -Text "Waiting for permission to write to app.css.")
            approve = (Test-ReadOnlyPhaseConfusion -Text "Please approve the file edit above to apply the CSS fix.")
            legitPermission = (Test-ReadOnlyPhaseConfusion -Text "Restore write permission handling for exported files.")
            clean = (Test-ReadOnlyPhaseConfusion -Text "RESULT: CHANGE_NEEDED`nTARGET_FILES:`n- app.css")
        } | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.waiting -eq $true) "Waiting-for-permission chatter must be detected in read-only phases."
    Assert-True ($parsed.approve -eq $true) "Approval-request chatter must be detected in read-only phases."
    Assert-True ($parsed.legitPermission -eq $false) "Legitimate permission-domain language must not be flagged as approval chatter."
    Assert-True ($parsed.clean -eq $false) "Structured read-only outputs without approval chatter must not be flagged."
}

function Test-SanitizeReadOnlyPhaseTextPreservesStructuredEvidence {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Sanitize-ReadOnlyPhaseText"
    ) -ScriptBlock {
        Sanitize-ReadOnlyPhaseText -Text @"
Please approve the file write to apply the CSS fix.

RESULT: CHANGE_NEEDED
TARGET_FILES:
- Hmd.Docs/wwwroot/css/app.css
ROOT_CAUSE:
The CSS flex layout collapses block markdown content into one row.
"@
    }

    Assert-True ($output -notmatch '(?i)please approve') "Sanitization must remove approval chatter from read-only reused context."
    Assert-True ($output -match [regex]::Escape("RESULT: CHANGE_NEEDED")) "Sanitization must preserve structured investigation evidence."
    Assert-True ($output -match [regex]::Escape("Hmd.Docs/wwwroot/css/app.css")) "Sanitization must preserve concrete targets."
}

function Test-PlanValidationRejectsApprovalChatterInOtherwiseValidPlan {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-ConcretePathToken",
        "Get-ReadOnlyPhaseConfusionPatterns",
        "Test-ReadOnlyPhaseConfusion",
        "Get-ReadOnlyPhaseConfusionIssue",
        "Get-PriorArtReferenceFiles",
        "Get-PlanValidation"
    ) -ScriptBlock {
        (Get-PlanValidation -PriorArtRequired $true -Plan @"
## Goal
Darken the divider colors.

Please approve the file edit above to apply the CSS fix.

## Files
- Path: Hmd.Docs/wwwroot/css/app.css
- Action: MODIFY
- Changes: Replace the existing dark-mode divider color.

## Order
1. Update the CSS file.
2. Verify the result.

## Constraints
- Keep the change scoped to the dark-mode divider rules.

## Reuse / Reference Pattern
Required: YES
Reference Files:
- Hmd.Docs/wwwroot/css/app.css
Reuse Path:
Extend the existing dark-mode border-color overrides already defined in app.css.

investigationRequired: false
"@) | ConvertTo-Json -Depth 12
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Approval chatter must invalidate otherwise well-formed read-only fix plans."
    Assert-True ((@($parsed.issues) -join "`n") -match "approval or permission chatter") "Plan validation must report the read-only phase-confusion issue explicitly."
}

function Test-GetRetryLessonsFromFeedbackHistoryProducesStructuredLessons {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Clip-Text",
        "Get-RetryLessonComparisonText",
        "Get-RetryLessonsFromFeedbackHistory"
    ) -ScriptBlock {
        $history = [System.Collections.ArrayList]::new()
        [void]$history.Add([ordered]@{
            attempt = 1
            source = "REVIEW"
            category = "REVIEW_DENIED_MAJOR"
            feedback = "Use the existing converter`nDo not add a parallel path."
        })
        [void]$history.Add([ordered]@{
            attempt = 1
            source = "REVIEW"
            category = "REVIEW_DENIED_MAJOR"
            feedback = "Use the existing converter."
        })
        [void]$history.Add([ordered]@{
            attempt = 2
            source = "PREFLIGHT"
            category = "PREFLIGHT_FAILED"
            feedback = "Build failed with CS0103."
        })

        (Get-RetryLessonsFromFeedbackHistory -History $history -RunAttemptNumber 2) | ConvertTo-Json -Depth 8
    }

    $parsed = ConvertFrom-Json $output
    $parsed = @($parsed)
    Assert-True ($parsed.Count -eq 2) "Retry lesson extraction should deduplicate repeated lessons and keep the most recent distinct blockers."
    Assert-True ([string]$parsed[0].category -eq "PREFLIGHT_FAILED") "Retry lessons should keep the most recent unique blocker first."
    Assert-True ([string]$parsed[1].category -eq "REVIEW_DENIED_MAJOR") "Retry lessons should retain prior review-denial context."
    Assert-True ([int]$parsed[0].runAttemptNumber -eq 2) "Retry lessons should persist the scheduler run attempt number."
    Assert-True ([int]$parsed[0].phaseAttempt -eq 2) "Retry lessons should preserve the local phase attempt number separately."
}

function Test-RetryContextRoundTripLoadsWorkerState {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-RetryContextState"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("retry-context-" + [guid]::NewGuid().ToString("N") + ".json")
        [System.IO.File]::WriteAllText($path, '{"version":1,"taskId":"task-retry","attemptNumber":2,"latestFailure":{"finalCategory":"REVIEW_DENIED_MAJOR","summary":"review denied"},"priorChangedFiles":[".\\src\\Feature.cs"],"retryLessons":[{"runAttemptNumber":1,"phaseAttempt":1,"source":"REVIEW","category":"REVIEW_DENIED_MAJOR","feedbackExcerpt":"Reuse the existing converter."}]}', [System.Text.Encoding]::UTF8)
        try {
            (Get-RetryContextState -RetryContextFile $path -ExpectedTaskId "task-retry") | ConvertTo-Json -Depth 12
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.loaded -eq $true) "Valid retry context files should load successfully."
    Assert-True ([int]$parsed.attemptNumber -eq 2) "Retry context should preserve the retry attempt number."
    Assert-True ([string]$parsed.latestFailure.finalCategory -eq "REVIEW_DENIED_MAJOR") "Retry context should preserve the latest failure category."
    Assert-True (@($parsed.priorChangedFiles) -contains "src\Feature.cs") "Retry context should normalize prior changed files."
    Assert-True (@($parsed.retryLessons).Count -eq 1) "Retry context should preserve structured retry lessons."
    Assert-True ([int]$parsed.retryLessons[0].runAttemptNumber -eq 1) "Retry context should preserve lesson run attempt numbers."
    Assert-True ([int]$parsed.retryLessons[0].phaseAttempt -eq 1) "Retry context should preserve lesson phase attempt numbers."
}

function Test-WrongTaskRetryContextFallsBackGracefully {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-RetryContextState"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("retry-context-wrong-task-" + [guid]::NewGuid().ToString("N") + ".json")
        [System.IO.File]::WriteAllText($path, '{"version":1,"taskId":"task-retry","attemptNumber":2,"latestFailure":{"finalCategory":"REVIEW_DENIED_MAJOR","summary":"review denied"}}', [System.Text.Encoding]::UTF8)
        try {
            (Get-RetryContextState -RetryContextFile $path -ExpectedTaskId "task-other") | ConvertTo-Json -Depth 12
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.loaded -eq $false) "Retry context should reject payloads for the wrong task."
}

function Test-EmptyRetryContextPayloadFallsBackGracefully {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-RetryContextState"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("retry-context-empty-" + [guid]::NewGuid().ToString("N") + ".json")
        [System.IO.File]::WriteAllText($path, '{"version":1,"taskId":"task-retry","attemptNumber":2}', [System.Text.Encoding]::UTF8)
        try {
            (Get-RetryContextState -RetryContextFile $path -ExpectedTaskId "task-retry") | ConvertTo-Json -Depth 12
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.loaded -eq $false) "Retry context should reject payloads without actionable signal."
}

function Test-MissingRetryContextFallsBackGracefully {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Read-JsonFileBestEffort",
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-RetryContextState"
    ) -ScriptBlock {
        $missingPath = Join-Path $env:TEMP ("missing-retry-context-" + [guid]::NewGuid().ToString("N") + ".json")
        (Get-RetryContextState -RetryContextFile $missingPath) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.loaded -eq $false) "Missing retry context should fall back without loading."
    Assert-True ([int]$parsed.attemptNumber -eq 0) "Missing retry context should preserve the empty-state attempt number."
    Assert-True (@($parsed.retryLessons).Count -eq 0) "Missing retry context should not synthesize lessons."
}

function Test-RetryContextPromptBlockIncludesPriorDenialText {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Clip-Text",
        "Format-BulletList",
        "Format-RetryContextPromptBlock"
    ) -ScriptBlock {
        $retryContext = [pscustomobject]@{
            loaded = $true
            attemptNumber = 2
            latestFailure = [pscustomobject]@{
                finalCategory = "REVIEW_DENIED_MAJOR"
                summary = "review denied"
                feedback = "Reuse the existing converter."
                investigationConclusion = ""
            }
            priorChangedFiles = @("src\Feature.cs")
            retryLessons = @(
                [pscustomobject]@{
                    runAttemptNumber = 1
                    phaseAttempt = 1
                    source = "REVIEW"
                    category = "REVIEW_DENIED_MAJOR"
                    feedbackExcerpt = "Reuse the existing converter."
                }
            )
        }

        Format-RetryContextPromptBlock -RetryContext $retryContext -Mode "IMPLEMENT" -MaxChars 1200
    }

    Assert-True ([string]$output -match "existing converter") "Retry prompt blocks should include prior denial text."
    Assert-True ([string]$output -match "RETRY RULE") "Retry prompt blocks should include the mode-specific retry rule."
    Assert-True ([string]$output -match "- Run 1 \[REVIEW/REVIEW_DENIED_MAJOR\]") "Retry prompt blocks should label prior lessons with the scheduler run number."
    Assert-True ([string]$output -notmatch "- Attempt 1 \[") "Retry prompt blocks should not expose ambiguous phase attempt labels."
}

function Test-RetryContextPromptBlockIncludesValidationIssues {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Format-BulletList",
        "Clip-Text",
        "Format-RetryContextPromptBlock"
    ) -ScriptBlock {
        $retryContext = [pscustomobject]@{
            loaded = $true
            attemptNumber = 2
            latestFailure = [pscustomobject]@{
                finalStatus = "FAILED"
                finalCategory = "FIX_PLAN_PHASE_CONFUSION"
                summary = "plan failed"
                feedback = "Please approve the file edit above."
                validationIssues = @(
                    "Output contains approval or permission chatter that is invalid in this read-only phase.",
                    "Plan does not name any concrete file or search targets."
                )
                failurePhase = "FINALIZE"
                readOnlyPhaseConfusion = $true
                investigationConclusion = ""
            }
            priorChangedFiles = @()
            retryLessons = @()
        }

        Format-RetryContextPromptBlock -RetryContext $retryContext -Mode "FIX_PLAN" -MaxChars 1200
    }

    Assert-True ([string]$output -match "LATEST FAILURE VALIDATION ISSUES") "Retry prompt blocks should expose structured validation issues."
    Assert-True ([string]$output -match "read-only phase") "Retry prompt blocks should carry the concrete validation issue text."
    Assert-True ([string]$output -match "LATEST FAILURE READ-ONLY PHASE CONFUSION: YES") "Retry prompt blocks should preserve phase-confusion markers."
}

function Test-WriteRetryContextFilePersistsRelevantPriorFailures {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Normalize-StringArray",
        "Normalize-RetryLessons",
        "Ensure-Directory",
        "Ensure-ParentDirectory",
        "Get-EnvironmentFailureCategories",
        "Is-EnvironmentFailureCategory",
        "Clip-DiscoveryBriefText",
        "Get-RetryLessonComparisonText",
        "Get-ValidationIssuesFromResult",
        "Is-RetryContextSemanticCategory",
        "Get-RetryContextRelevantRuns",
        "Get-FallbackRetryLesson",
        "Get-RetryContextPayload",
        "Write-RetryContextFile"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("retry-context-" + [guid]::NewGuid().ToString("N") + ".json")
        $task = [pscustomobject]@{
            taskId = "task-retry"
            runs = @(
                [pscustomobject]@{
                    attemptNumber = 1
                    launchSequence = 1
                    finalStatus = "FAILED"
                    finalCategory = "REVIEW_DENIED_MAJOR"
                    summary = "The reviewer rejected the first attempt."
                    feedback = "REVIEW DENIED (MAJOR): Reuse the existing converter instead of adding a parallel path."
                    validationIssues = @("Reuse/reference section must name concrete reference file paths.")
                    failurePhase = "FINALIZE"
                    readOnlyPhaseConfusion = $false
                    investigationConclusion = "CHANGE_NEEDED"
                    retryLessons = @(
                        [pscustomobject]@{
                            runAttemptNumber = 1
                            phaseAttempt = 1
                            source = "REVIEW"
                            category = "REVIEW_DENIED_MAJOR"
                            feedbackExcerpt = "Reuse the existing converter instead of adding a parallel path."
                        }
                    )
                    actualFiles = @("src\Feature.cs", "src\ExistingConverter.cs")
                    completedAt = (Get-Date).AddMinutes(-6).ToString("o")
                }
                [pscustomobject]@{
                    attemptNumber = 2
                    launchSequence = 2
                    finalStatus = "FAILED"
                    finalCategory = "REVIEW_INFRA_FAILURE"
                    summary = "review infra issue"
                    feedback = "review call failed"
                    retryLessons = @()
                    actualFiles = @()
                    completedAt = (Get-Date).AddMinutes(-5).ToString("o")
                }
                [pscustomobject]@{
                    attemptNumber = 3
                    launchSequence = 3
                    finalStatus = "ERROR"
                    finalCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    summary = "environment issue"
                    feedback = "worker crashed"
                    retryLessons = @()
                    actualFiles = @()
                    completedAt = (Get-Date).AddMinutes(-4).ToString("o")
                }
                [pscustomobject]@{
                    attemptNumber = 4
                    launchSequence = 4
                    finalStatus = "NO_CHANGE"
                    finalCategory = "NO_CHANGE_ALREADY_SATISFIED"
                    summary = "already done"
                    feedback = "already done"
                    retryLessons = @()
                    actualFiles = @("src\Ignore.cs")
                    completedAt = (Get-Date).AddMinutes(-3).ToString("o")
                }
            )
        }

        $payload = Write-RetryContextFile -Path $path -Task $task -AttemptNumber 5
        try {
            [pscustomobject]@{
                payload = $payload
                json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            } | ConvertTo-Json -Depth 16
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $raw | ConvertFrom-Json
    $payload = $parsed.payload
    $json = $parsed.json | ConvertFrom-Json
    Assert-True ([int]$payload.attemptNumber -eq 5) "Retry context files should preserve the target retry attempt number."
    Assert-True ([string]$payload.latestFailure.finalCategory -eq "REVIEW_DENIED_MAJOR") "Retry context should use the latest semantically relevant failure as the current blocker."
    Assert-True (@($payload.retryLessons).Count -eq 1) "Retry context should exclude infra-only, environment-only, and already-satisfied runs."
    Assert-True ([int]$payload.retryLessons[0].runAttemptNumber -eq 1) "Retry context should preserve lesson run attempt numbers."
    Assert-True ([string]$payload.retryLessons[0].category -eq "REVIEW_DENIED_MAJOR") "Retry context should preserve prior review-denial lessons."
    Assert-True (@($payload.priorChangedFiles) -contains "src\Feature.cs") "Retry context should carry prior changed files from relevant runs."
    Assert-True (-not (@($payload.priorChangedFiles) -contains "src\Ignore.cs")) "Retry context should exclude already-satisfied runs from prior changed files."
    Assert-True (@($payload.latestFailure.validationIssues) -contains "Reuse/reference section must name concrete reference file paths.") "Retry context should persist structured validation issues for the latest semantic failure."
    Assert-True ([string]$payload.latestFailure.failurePhase -eq "FINALIZE") "Retry context should preserve the latest failure phase."
    Assert-True ([string]$json.retryLessons[0].feedbackExcerpt -match "converter") "Retry context JSON should persist the prior denial text."
}

function Test-WriteRetryContextFileSkipsInfraOnlyHistory {
    $raw = Invoke-SchedulerHelperFunctions -FunctionNames @(
        "Normalize-StringArray",
        "Normalize-RetryLessons",
        "Ensure-Directory",
        "Ensure-ParentDirectory",
        "Get-EnvironmentFailureCategories",
        "Is-EnvironmentFailureCategory",
        "Clip-DiscoveryBriefText",
        "Get-RetryLessonComparisonText",
        "Get-ValidationIssuesFromResult",
        "Is-RetryContextSemanticCategory",
        "Get-RetryContextRelevantRuns",
        "Get-FallbackRetryLesson",
        "Get-RetryContextPayload",
        "Write-RetryContextFile"
    ) -ScriptBlock {
        $path = Join-Path $env:TEMP ("retry-context-none-" + [guid]::NewGuid().ToString("N") + ".json")
        $task = [pscustomobject]@{
            taskId = "task-retry-none"
            runs = @(
                [pscustomobject]@{
                    attemptNumber = 1
                    launchSequence = 1
                    finalStatus = "FAILED"
                    finalCategory = "REVIEW_INFRA_FAILURE"
                    summary = "review infra failed"
                    feedback = "review call failed"
                    retryLessons = @()
                    actualFiles = @()
                }
                [pscustomobject]@{
                    attemptNumber = 2
                    launchSequence = 2
                    finalStatus = "ERROR"
                    finalCategory = "UNEXPECTED_ERROR"
                    summary = "unexpected worker exception"
                    feedback = "unexpected worker exception"
                    retryLessons = @()
                    actualFiles = @()
                }
                [pscustomobject]@{
                    attemptNumber = 3
                    launchSequence = 3
                    finalStatus = "ERROR"
                    finalCategory = "WORKER_EXITED_WITHOUT_RESULT"
                    summary = "worker exited"
                    feedback = "worker exited"
                    retryLessons = @()
                    actualFiles = @()
                }
            )
        }

        try {
            $payload = Write-RetryContextFile -Path $path -Task $task -AttemptNumber 4
            [pscustomobject]@{
                hasPayload = [bool]$payload
                fileExists = Test-Path -LiteralPath $path
            } | ConvertTo-Json -Depth 8
        } finally {
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        }
    }

    $parsed = $raw | ConvertFrom-Json
    Assert-True ($parsed.hasPayload -eq $false) "Retry context should not be generated from infra-only history."
    Assert-True ($parsed.fileExists -eq $false) "Retry context files should not be written when no semantic retry memory exists."
}

function Test-ReconcilePersistsRetryLessonsAndRetryContextArtifacts {
    $repo = New-TestRepo
    try {
        $resultPath = Join-Path $repo.tasksDir "retry-context-reconcile-result.json"
        $plannerContextPath = Join-Path $repo.root "planner-context.json"
        $retryContextPath = Join-Path $repo.root "retry-context.json"
        $briefsFilePath = Join-Path $repo.root "worker-briefs.json"
        New-Item -ItemType Directory -Path $repo.tasksDir -Force | Out-Null
        [System.IO.File]::WriteAllText($resultPath, (@{
            status = "FAILED"
            finalCategory = "REVIEW_DENIED_MAJOR"
            summary = "review denied"
            feedback = "Reuse the existing converter."
            noChangeReason = ""
            files = @("src\Feature.cs")
            branch = ""
            retryLessons = @(
                @{
                    runAttemptNumber = 1
                    phaseAttempt = 1
                    source = "REVIEW"
                    category = "REVIEW_DENIED_MAJOR"
                    feedbackExcerpt = "Reuse the existing converter."
                }
            )
            artifacts = @{
                runDir = ""
                timeline = ""
                debugDir = (Join-Path $repo.root "debug")
            }
        } | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $latestRun = New-TestLatestRun -AttemptNumber 1 -LaunchSequence 1 -TaskName "develop-retry-context-a1" -ResultFile $resultPath -ProcessId 999999 -StartedAt (Get-Date).AddMinutes(-1).ToString("o")
        $latestRun.artifacts = [pscustomobject]@{
            plannerContext = $plannerContextPath
            retryContext = $retryContextPath
            briefs = $briefsFilePath
        }

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "retry-context-reconcile"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "retry context reconcile"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "retry-context-reconcile.json")
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
                    latestRun = $latestRun
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        $task = @($snapshot.tasks | Where-Object { [string]$_.taskId -eq "retry-context-reconcile" })[0]
        Assert-True ([string]$task.state -eq "retry_scheduled") "Review-denied results should reconcile into retry_scheduled."
        Assert-True (@($task.runs[0].retryLessons).Count -eq 1) "Reconciled run records should persist retry lessons."
        Assert-True ([int]$task.runs[0].retryLessons[0].runAttemptNumber -eq 1) "Persisted retry lessons should preserve the scheduler run attempt number."
        Assert-True ([string]$task.runs[0].retryLessons[0].category -eq "REVIEW_DENIED_MAJOR") "Persisted retry lessons should preserve the original blocker category."
        Assert-True ([string]$task.progress.artifactPointers.plannerContextPath -eq $plannerContextPath) "Task progress should expose the preserved planner context path."
        Assert-True ([string]$task.progress.artifactPointers.retryContextPath -eq $retryContextPath) "Task progress should expose the preserved retry context path."
        Assert-True ([string]$task.progress.artifactPointers.briefsFilePath -eq $briefsFilePath) "Task progress should expose the preserved worker briefs path."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-DirectionCheckVerdictParsesOnTrackCombination {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict"
    ) -ScriptBlock {
        (Get-DirectionCheckVerdict -Output "ALIGNMENT: ON_TRACK`nDRIFT_DESCRIPTION: Plan is correctly scoped.`nRECOMMENDATION: CONTINUE") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $true) "A valid ON_TRACK direction-check response should parse successfully."
    Assert-True ([string]$parsed.alignment -eq "ON_TRACK") "ON_TRACK alignment should be preserved."
    Assert-True ($parsed.shouldContinue -eq $true) "ON_TRACK should continue implementation."
}

function Test-DirectionCheckVerdictParsesMinorDriftCombination {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict",
        "Get-DirectionCheckGuardrail"
    ) -ScriptBlock {
        $verdict = Get-DirectionCheckVerdict -Output "ALIGNMENT: MINOR_DRIFT`nDRIFT_DESCRIPTION: The plan proposes an adjacent cleanup that is not required.`nRECOMMENDATION: TRIM_PLAN"
        [pscustomobject]@{
            verdict = $verdict
            guardrail = (Get-DirectionCheckGuardrail -Verdict $verdict)
        } | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.verdict.valid -eq $true) "A valid MINOR_DRIFT direction-check response should parse successfully."
    Assert-True ([string]$parsed.verdict.alignment -eq "MINOR_DRIFT") "MINOR_DRIFT alignment should be preserved."
    Assert-True ($parsed.verdict.shouldTrim -eq $true) "MINOR_DRIFT should request plan trimming."
    Assert-True ([string]$parsed.guardrail -match "adjacent cleanup") "Minor drift should produce an implementation guardrail that includes the drift description."
}

function Test-DirectionCheckVerdictParsesMajorDriftCombination {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict"
    ) -ScriptBlock {
        (Get-DirectionCheckVerdict -Output "ALIGNMENT: MAJOR_DRIFT`nDRIFT_DESCRIPTION: The plan broadens into a refactor beyond the requested fix.`nRECOMMENDATION: ABORT") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $true) "A valid MAJOR_DRIFT direction-check response should parse successfully."
    Assert-True ([string]$parsed.recommendation -eq "ABORT") "Major drift should preserve the ABORT recommendation."
    Assert-True ($parsed.shouldReplan -eq $true) "MAJOR_DRIFT should force replanning."
}

function Test-DirectionCheckVerdictRejectsMissingMarkers {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict"
    ) -ScriptBlock {
        (Get-DirectionCheckVerdict -Output "The plan looks broadly correct but may touch too much code.") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Direction-check output without required markers must be rejected."
}

function Test-DirectionCheckVerdictRejectsMixedCombination {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict"
    ) -ScriptBlock {
        (Get-DirectionCheckVerdict -Output "ALIGNMENT: ON_TRACK`nDRIFT_DESCRIPTION: Looks good.`nRECOMMENDATION: ABORT") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.valid -eq $false) "Direction-check output with an incompatible alignment/recommendation pair must be rejected."
}

function Test-AcceptedPlanTargetsKeepExistingTargetsWhenCandidateRejected {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-AcceptedPlanTargets"
    ) -ScriptBlock {
        (Get-AcceptedPlanTargets -ExistingTargets @("src\\Core\\Existing.cs") -CandidateTargets @("src\\Core\\Existing.cs", "src\\Overreach\\Rejected.cs") -AcceptCandidate $false) | ConvertTo-Json -Depth 8
    }

    Assert-True ($output -like '*Existing.cs*') "Rejected candidate targets must preserve the previously accepted target."
    Assert-True ($output -notlike '*Rejected.cs*') "Rejected candidate targets must not leak into the accepted target set."
}

function Test-AcceptedPlanTargetsReplaceExistingTargetsWhenAccepted {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-AcceptedPlanTargets"
    ) -ScriptBlock {
        (Get-AcceptedPlanTargets -ExistingTargets @("src\\Core\\Existing.cs") -CandidateTargets @("src\\Core\\Existing.cs", "src\\Fix\\Accepted.cs") -AcceptCandidate $true) | ConvertTo-Json -Depth 8
    }

    Assert-True ($output -like '*Existing.cs*') "Accepted candidate targets should preserve previously accepted targets that remain in the candidate set."
    Assert-True ($output -like '*Accepted.cs*') "Accepted candidate targets should include the new accepted target."
}

function Test-FixPlanFailureOutcomeUsesInsufficientForNonFinalDrift {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-FixPlanFailureOutcome"
    ) -ScriptBlock {
        (Get-FixPlanFailureOutcome -LastPlanFailureReason "PLAN_INVALID") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.finalCategory -eq "FIX_PLAN_INSUFFICIENT") "Non-drift final failures must report FIX_PLAN_INSUFFICIENT."
    Assert-True ([string]$parsed.terminalFailureCode -eq "TERMINAL_FIX_PLAN_INSUFFICIENT") "Non-drift final failures must use the insufficient terminal code."
}

function Test-FixPlanFailureOutcomeUsesDirectionDriftWhenFinalReasonIsDrift {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-FixPlanFailureOutcome"
    ) -ScriptBlock {
        (Get-FixPlanFailureOutcome -LastPlanFailureReason "DIRECTION_DRIFT") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.finalCategory -eq "FIX_PLAN_DIRECTION_DRIFT") "Final drift failures must report FIX_PLAN_DIRECTION_DRIFT."
    Assert-True ([string]$parsed.terminalFailureCode -eq "TERMINAL_FIX_PLAN_DIRECTION_DRIFT") "Final drift failures must use the drift terminal code."
}

function Test-PlanDirectionCheckRejectsRepairedPlanWithMajorDrift {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict",
        "Get-DirectionCheckGuardrail",
        "Get-AcceptedPlanTargets",
        "Invoke-PlanDirectionCheck"
    ) -ScriptBlock {
        $script:attemptsByPhase = [ordered]@{ directionCheck = 0 }
        $script:CONST_MODEL_FAST = "test-fast"

        function Save-JsonArtifact { param([string]$Name, $Object) return $null }
        function Add-FeedbackEntry { param([int]$Attempt, [string]$Source, [string]$Category, [string]$Feedback) }
        function Add-TimelineEvent { param([string]$Phase, [string]$Message, [string]$Category, $Data) }
        function Write-SchedulerSnapshot { }
        function Invoke-ClaudeDirectionCheck {
            param([string]$Prompt, [string]$Model, [int]$Attempt)
            return @{ success = $true; output = "ALIGNMENT: MAJOR_DRIFT`nDRIFT_DESCRIPTION: The repaired plan widens into a refactor.`nRECOMMENDATION: ABORT" }
        }

        (Invoke-PlanDirectionCheck -PlanAttempt 1 -PlanOutput "repaired plan" -ExistingTargets @("src\\Core\\Existing.cs") -CandidateTargets @("src\\Core\\Existing.cs", "src\\Fix\\Accepted.cs") -TaskPrompt "Fix the bug only." -TaskClass "BUG" -DiscoverConclusion "Known defect." -RouteDecision "DIRECT" -Testability "HIGH" -DiscoverBlock "discover" -InvestigationBlock "investigate" -ReproductionBlock "reproduce") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.accepted -eq $false) "Major drift must not accept a repaired plan."
    Assert-True ($parsed.requiresReplan -eq $true) "Major drift must force replanning for repaired plans."
    Assert-True ([string]$parsed.lastPlanFailureReason -eq "DIRECTION_DRIFT") "Major drift must report the direction-drift failure reason."
    Assert-True (($parsed.planTargets | ConvertTo-Json -Compress) -notlike '*Accepted.cs*') "Rejected repaired-plan targets must not replace the accepted target set."
}

function Test-PlanDirectionCheckAcceptsRepairedPlanWhenOnTrack {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict",
        "Get-DirectionCheckGuardrail",
        "Get-AcceptedPlanTargets",
        "Invoke-PlanDirectionCheck"
    ) -ScriptBlock {
        $script:attemptsByPhase = [ordered]@{ directionCheck = 0 }
        $script:CONST_MODEL_FAST = "test-fast"

        function Save-JsonArtifact { param([string]$Name, $Object) return $null }
        function Add-FeedbackEntry { param([int]$Attempt, [string]$Source, [string]$Category, [string]$Feedback) }
        function Add-TimelineEvent { param([string]$Phase, [string]$Message, [string]$Category, $Data) }
        function Write-SchedulerSnapshot { }
        function Invoke-ClaudeDirectionCheck {
            param([string]$Prompt, [string]$Model, [int]$Attempt)
            return @{ success = $true; output = "ALIGNMENT: ON_TRACK`nDRIFT_DESCRIPTION: The repaired plan is tightly scoped.`nRECOMMENDATION: CONTINUE" }
        }

        (Invoke-PlanDirectionCheck -PlanAttempt 1 -PlanOutput "repaired plan" -ExistingTargets @("src\\Core\\Existing.cs") -CandidateTargets @("src\\Core\\Existing.cs", "src\\Fix\\Accepted.cs") -TaskPrompt "Fix the bug only." -TaskClass "BUG" -DiscoverConclusion "Known defect." -RouteDecision "DIRECT" -Testability "HIGH" -DiscoverBlock "discover" -InvestigationBlock "investigate" -ReproductionBlock "reproduce") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.accepted -eq $true) "An on-track repaired plan should be accepted."
    Assert-True ($parsed.requiresReplan -eq $false) "An on-track repaired plan should not replan."
    Assert-True (($parsed.planTargets | ConvertTo-Json -Compress) -like '*Accepted.cs*') "Accepted repaired-plan targets should include the repaired target."
}

function Test-PlanDirectionCheckAddsGuardrailForRepairedMinorDrift {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Get-DirectionCheckVerdict",
        "Get-DirectionCheckGuardrail",
        "Get-AcceptedPlanTargets",
        "Invoke-PlanDirectionCheck"
    ) -ScriptBlock {
        $script:attemptsByPhase = [ordered]@{ directionCheck = 0 }
        $script:CONST_MODEL_FAST = "test-fast"

        function Save-JsonArtifact { param([string]$Name, $Object) return $null }
        function Add-FeedbackEntry { param([int]$Attempt, [string]$Source, [string]$Category, [string]$Feedback) }
        function Add-TimelineEvent { param([string]$Phase, [string]$Message, [string]$Category, $Data) }
        function Write-SchedulerSnapshot { }
        function Invoke-ClaudeDirectionCheck {
            param([string]$Prompt, [string]$Model, [int]$Attempt)
            return @{ success = $true; output = "ALIGNMENT: MINOR_DRIFT`nDRIFT_DESCRIPTION: The repaired plan includes adjacent cleanup.`nRECOMMENDATION: TRIM_PLAN" }
        }

        (Invoke-PlanDirectionCheck -PlanAttempt 1 -PlanOutput "repaired plan" -ExistingTargets @("src\\Core\\Existing.cs") -CandidateTargets @("src\\Core\\Existing.cs", "src\\Fix\\Accepted.cs") -TaskPrompt "Fix the bug only." -TaskClass "BUG" -DiscoverConclusion "Known defect." -RouteDecision "DIRECT" -Testability "HIGH" -DiscoverBlock "discover" -InvestigationBlock "investigate" -ReproductionBlock "reproduce") | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.accepted -eq $true) "Minor drift should still accept the repaired plan with a guardrail."
    Assert-True ([string]$parsed.directionCheckVerdict.alignment -eq "MINOR_DRIFT") "Minor drift should preserve the parsed direction-check verdict."
    Assert-True ([string]$parsed.directionCheckGuardrail -match "adjacent cleanup") "Minor drift should populate the repaired-plan guardrail."
}

function Test-ImplementationScopeCheckIsTightForExactMatches {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Feature.cs") -ChangedFiles @("src\\Feature.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ($parsed.evaluated -eq $true) "Exact file matches should be evaluated."
    Assert-True ([string]$parsed.classification -eq "tight") "Exact file matches should classify as tight."
    Assert-True (@($parsed.outOfScopeFiles).Count -eq 0) "Exact file matches should not report out-of-scope files."
    Assert-True ($parsed.shouldEscalateReview -eq $false) "Tight matches should not escalate review."
}

function Test-ImplementationScopeCheckAcceptsUniqueSuffixMatches {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("Feature.cs") -ChangedFiles @("src\\Feature.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "acceptable") "Unique filename-only targets should classify as acceptable."
    Assert-True ([int]$parsed.matchKindsSummary.suffix -eq 1) "Unique filename-only targets should count as suffix matches."
    Assert-True ($parsed.shouldEscalateReview -eq $false) "Acceptable suffix matches should not escalate review."
}

function Test-ImplementationScopeCheckEscalatesDirectoryTargets {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Services") -ChangedFiles @("src\\Services\\OrderService.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "broad") "Directory targets should classify as broad."
    Assert-True ([int]$parsed.matchKindsSummary.directory -eq 1) "Directory targets should count as directory matches."
    Assert-True ($parsed.shouldEscalateReview -eq $true) "Broad scope matches should escalate review."
}

function Test-ImplementationScopeCheckDetectsOutOfScopeFiles {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Services\\OrderService.cs") -ChangedFiles @("src\\Services\\OrderService.cs", "src\\Shared\\CustomerDto.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "drifted") "Extra changed files outside the plan should classify as drifted."
    Assert-True (@($parsed.outOfScopeFiles).Count -eq 1) "Scope drift should report the unexpected changed file."
    Assert-True ([string]$parsed.outOfScopeFiles[0] -eq "src\\Shared\\CustomerDto.cs") "Scope drift should preserve the unexpected file path."
    Assert-True ($parsed.shouldEscalateReview -eq $true) "Scope drift should escalate review."
}

function Test-ImplementationScopeCheckTreatsWildcardMatchesAsBroad {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Services\\*.cs") -ChangedFiles @("src\\Services\\OrderService.cs", "src\\Services\\CustomerService.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "broad") "Wildcard targets should classify as broad when they match the changed files."
    Assert-True ([int]$parsed.matchKindsSummary.wildcard -eq 1) "Wildcard targets should count as wildcard matches."
    Assert-True (@($parsed.outOfScopeFiles).Count -eq 0) "Wildcard-matched files should not be treated as out-of-scope."
    Assert-True ($parsed.shouldEscalateReview -eq $true) "Wildcard matches should escalate review for stricter inspection."
}

function Test-ImplementationScopeCheckWildcardStillDetectsOutOfScopeFiles {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Services\\*.cs") -ChangedFiles @("src\\Services\\OrderService.cs", "src\\Shared\\CustomerDto.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "drifted") "Wildcard targets should still classify as drifted when unrelated files change."
    Assert-True (@($parsed.outOfScopeFiles).Count -eq 1) "Wildcard scope drift should report the unrelated changed file."
    Assert-True ([string]$parsed.outOfScopeFiles[0] -eq "src\\Shared\\CustomerDto.cs") "Wildcard scope drift should preserve the unrelated file path."
    Assert-True ($parsed.shouldEscalateReview -eq $true) "Wildcard scope drift should escalate review."
}

function Test-ImplementationScopeCheckReportsUnmatchedWildcardTargets {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Services\\*.cs") -ChangedFiles @("docs\\note.md")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "drifted") "Unmatched wildcard targets should classify as drifted when all changes fall outside the allowed area."
    Assert-True (@($parsed.unmatchedTargets).Count -eq 1) "Unmatched wildcard targets should be surfaced explicitly."
    Assert-True ([string]$parsed.unmatchedTargets[0] -eq "src\\Services\\*.cs") "The unmatched wildcard target should be preserved."
    Assert-True (@($parsed.outOfScopeFiles).Count -eq 1 -and [string]$parsed.outOfScopeFiles[0] -eq "docs\\note.md") "All changed files should remain out-of-scope when the wildcard target does not match."
}

function Test-ImplementationScopeCheckSupportsMixedExactAndWildcardTargets {
    $output = Invoke-AutoDevelopHelperFunctions -FunctionNames @(
        "Normalize-RepoRelativePath",
        "Get-NormalizedPathSet",
        "Get-CanonicalComparisonPath",
        "Get-PathComparisonProfile",
        "Get-TargetPathMatches",
        "Match-AllowedTargetPaths",
        "Get-ImplementationScopeCheck"
    ) -ScriptBlock {
        (Get-ImplementationScopeCheck -PlanTargets @("src\\Services\\OrderService.cs", "src\\Tests\\*.cs") -ChangedFiles @("src\\Services\\OrderService.cs", "src\\Tests\\OrderServiceTests.cs")) | ConvertTo-Json -Depth 8
    }

    $parsed = $output | ConvertFrom-Json
    Assert-True ([string]$parsed.classification -eq "broad") "Mixed exact and wildcard targets should classify as broad when wildcard matching is involved without drift."
    Assert-True ([int]$parsed.matchKindsSummary.exact -eq 1) "Mixed targets should preserve exact-match accounting."
    Assert-True ([int]$parsed.matchKindsSummary.wildcard -eq 1) "Mixed targets should preserve wildcard-match accounting."
    Assert-True (@($parsed.outOfScopeFiles).Count -eq 0) "Mixed exact and wildcard targets should not produce out-of-scope files when all changes are covered."
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

function Test-RegistrationRejectsEmptyPromptFile {
    $repo = New-TestRepo
    try {
        $promptFile = Join-Path $repo.root "empty-task-prompt.md"
        [System.IO.File]::WriteAllText($promptFile, "", [System.Text.Encoding]::UTF8)
        $tasksFile = Join-Path $repo.root "tasks-empty-prompt.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-empty-prompt"
                taskText = "A"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $promptFile
                resultFile = (Join-Path $repo.resultsDir "task-empty-prompt.json")
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $stdout = Join-Path $repo.root "register-empty-prompt.stdout.txt"
        $stderr = Join-Path $repo.root "register-empty-prompt.stderr.txt"
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

        Assert-True ($process.ExitCode -ne 0) "register-tasks should fail when promptFile is empty."
        Assert-True ($combined -match "promptFile is empty") "register-tasks should explain the empty promptFile."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RegistrationRejectsPromptDirectoryPath {
    $repo = New-TestRepo
    try {
        $tasksFile = Join-Path $repo.root "tasks-directory-prompt.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-directory-prompt"
                taskText = "A"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $repo.root
                resultFile = (Join-Path $repo.resultsDir "task-directory-prompt.json")
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $stdout = Join-Path $repo.root "register-directory-prompt.stdout.txt"
        $stderr = Join-Path $repo.root "register-directory-prompt.stderr.txt"
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

        Assert-True ($process.ExitCode -ne 0) "register-tasks should fail when promptFile points to a directory."
        Assert-True ($combined -match "promptFile is not a file") "register-tasks should explain that promptFile must be a file."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-RegistrationRejectsPromptWithoutReadableTaskLine {
    $repo = New-TestRepo
    try {
        $promptFile = Join-Path $repo.root "heading-only-task-prompt.md"
        [System.IO.File]::WriteAllText($promptFile, "## Task`n`n## Solution`n$($repo.solution)", [System.Text.Encoding]::UTF8)
        $tasksFile = Join-Path $repo.root "tasks-heading-only-prompt.json"
        [System.IO.File]::WriteAllText($tasksFile, (@(
            @{
                taskId = "task-heading-only-prompt"
                taskText = "A"
                sourceCommand = "develop"
                sourceInputType = "inline"
                solutionPath = $repo.solution
                promptFile = $promptFile
                resultFile = (Join-Path $repo.resultsDir "task-heading-only-prompt.json")
            }
        ) | ConvertTo-Json -Depth 16), [System.Text.Encoding]::UTF8)

        $stdout = Join-Path $repo.root "register-heading-only-prompt.stdout.txt"
        $stderr = Join-Path $repo.root "register-heading-only-prompt.stderr.txt"
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

        Assert-True ($process.ExitCode -ne 0) "register-tasks should fail when promptFile has no readable task line."
        Assert-True ($combined -match "promptFile has no readable task line") "register-tasks should explain the malformed prompt content."
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

function Test-RunTaskInvalidPromptBecomesEnvironmentRetryWithoutBreaker {
    $repo = New-TestRepo
    try {
        $promptFile = Join-Path $repo.root "invalid-run-prompt.md"
        [System.IO.File]::WriteAllText($promptFile, "## Task`n`n## Solution`n$($repo.solution)", [System.Text.Encoding]::UTF8)
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
                    taskId = "task-invalid-run-prompt"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "bad prompt"
                    solutionPath = $repo.solution
                    promptFile = $promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "task-invalid-run-prompt.json")
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
                    latestRun = (New-TestLatestRun -ResultFile (Join-Path $repo.tasksDir "invalid-run-launch-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })

        $result = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "run-task" -TaskId "task-invalid-run-prompt"
        $task = @($result.snapshot.tasks | Where-Object { [string]$_.taskId -eq "task-invalid-run-prompt" })[0]
        Assert-True ($result.started -eq $false) "run-task should not start a worker when prompt validation fails."
        Assert-True ([string]$task.state -eq "environment_retry_scheduled") "Invalid prompt files should route through environment retry scheduling."
        Assert-True ([string]$task.finalCategory -eq "INVALID_PROMPT_FILE") "Invalid prompt files should record INVALID_PROMPT_FILE."
        Assert-True ([string]$task.lastEnvironmentFailureCategory -eq "INVALID_PROMPT_FILE") "Invalid prompt files should preserve the environment failure category."
        Assert-True ([int]$task.attemptsUsed -eq 0) "Invalid prompt prelaunch failures should not consume a worker attempt."
        Assert-True ([int]$task.environmentRepairAttemptsUsed -eq 1) "Invalid prompt prelaunch failures should consume one environment repair attempt."
        Assert-True ([string]$result.snapshot.circuitBreaker.status -eq "closed") "Invalid prompt failures should not open the circuit breaker."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-InvalidPromptFailuresDoNotOpenCircuitBreaker {
    $repo = New-TestRepo
    try {
        $tasks = foreach ($i in 1..3) {
            [pscustomobject]@{
                taskId = "invalid-prompt-$i"
                sourceCommand = "develop"
                sourceInputType = "inline"
                taskText = "invalid prompt $i"
                solutionPath = $repo.solution
                promptFile = $repo.promptFile
                planFile = ""
                resultFile = (Join-Path $repo.resultsDir "invalid-prompt-$i.json")
                allowNuget = $false
                submissionOrder = $i
                waveNumber = 1
                blockedBy = @()
                maxAttempts = 3
                attemptsUsed = 0
                attemptsRemaining = 3
                workerLaunchSequence = 1
                retryScheduled = $true
                waitingUserTest = $false
                mergeState = ""
                state = "retry_scheduled"
                plannerMetadata = [pscustomobject]@{}
                latestRun = [pscustomobject]@{
                    attemptNumber = 0
                    launchSequence = 0
                    taskName = ""
                    resultFile = (Join-Path $repo.tasksDir "invalid-prompt-$i-result.json")
                    processId = 0
                    startedAt = ""
                    completedAt = (Get-Date).AddMinutes(-1).ToString("o")
                    finalStatus = "ERROR"
                    finalCategory = "INVALID_PROMPT_FILE"
                    summary = "prompt invalid"
                    feedback = "promptFile has no readable task line."
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
                runs = @()
                merge = (New-TestMergeRecord)
            }
        }

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
            tasks = @($tasks)
        })

        $snapshot = Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "snapshot-queue"
        Assert-True ([string]$snapshot.circuitBreaker.status -eq "closed") "Correlated INVALID_PROMPT_FILE failures must not open the breaker."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-AutoDevelopInvalidPromptWritesStructuredErrorAndTimeline {
    $repo = New-TestRepo
    try {
        $promptFile = Join-Path $repo.root "worker-invalid-prompt.md"
        [System.IO.File]::WriteAllText($promptFile, "## Task`n`n## Solution`n$($repo.solution)", [System.Text.Encoding]::UTF8)
        $resultFile = Join-Path $repo.root "worker-invalid-prompt-result.json"
        $stdout = Join-Path $repo.root "worker-invalid-prompt.stdout.txt"
        $stderr = Join-Path $repo.root "worker-invalid-prompt.stderr.txt"
        $autoDevelopPath = Join-Path $PSScriptRoot "auto-develop.ps1"

        $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $autoDevelopPath,
            "-PromptFile", $promptFile,
            "-SolutionPath", $repo.solution,
            "-ResultFile", $resultFile,
            "-TaskName", "invalid-prompt-worker"
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        Assert-True ($process.ExitCode -ne 0) "auto-develop should fail fast on an invalid prompt file."
        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        Assert-True ([string]$result.finalCategory -eq "INVALID_PROMPT_FILE") "auto-develop should emit INVALID_PROMPT_FILE."
        Assert-True ([string]$result.phase -eq "VALIDATE") "Invalid prompt failures should report the VALIDATE phase."
        $timelinePath = [string]$result.artifacts.timeline
        Assert-True (-not [string]::IsNullOrWhiteSpace($timelinePath)) "Invalid prompt failures should still publish a timeline artifact path."
        Assert-True (Test-Path -LiteralPath $timelinePath) "Invalid prompt failures should create the timeline artifact."
        $timelineRaw = Get-Content -LiteralPath $timelinePath -Raw
        Assert-True (-not [string]::IsNullOrWhiteSpace($timelineRaw)) "Timeline artifact must not be empty for invalid prompt failures."
        $timeline = $timelineRaw | ConvertFrom-Json
        Assert-True (@($timeline).Count -ge 1) "Timeline artifact should record the invalid prompt validation event."
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

function Test-UsageGateWritesAutodevCacheOnFreshSuccess {
    $root = Join-Path $env:TEMP ("autodev-usage-gate-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $sequencePath = Write-UsageGateMockFile -Root $root -FileName "usage-success.json" -Payload @(
            [ordered]@{
                five_hour = [ordered]@{
                    utilization = 42.5
                    resets_at = "2026-03-25T18:00:00Z"
                }
                seven_day = [ordered]@{
                    utilization = 22.0
                    resets_at = "2026-03-30T18:00:00Z"
                }
            }
        )
        $result = Invoke-UsageGateJson -ClaudeHome $root -MockUsageSequencePath $sequencePath
        $cachePath = Join-Path $root "tl-autodev-usage-cache.json"

        Assert-True ($result.ok -eq $true) "Fresh success should mark the usage gate as available."
        Assert-True ([string]$result.processStatus -eq "ok") "Fresh success below threshold should return ok."
        Assert-True ([string]$result.source -eq "oauth") "Fresh success should report oauth as the source."
        Assert-True ($result.fresh -eq $true) "Fresh success should be marked as fresh."
        Assert-True (Test-Path -LiteralPath $cachePath) "Fresh success should create the autodev usage cache."

        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        Assert-True ([double]$cache.fiveHourUtilization -eq 42.5) "Cache should persist the fetched five-hour utilization."
        Assert-True ([string]$cache.source -eq "oauth") "Cache should record oauth as the source."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-UsageGateBlocksWhenThresholdIsExceeded {
    $root = Join-Path $env:TEMP ("autodev-usage-gate-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $sequencePath = Write-UsageGateMockFile -Root $root -FileName "usage-blocked.json" -Payload @(
            [ordered]@{
                five_hour = [ordered]@{
                    utilization = 94.0
                    resets_at = "2026-03-25T18:00:00Z"
                }
                seven_day = [ordered]@{
                    utilization = 35.0
                    resets_at = "2026-03-30T18:00:00Z"
                }
            }
        )
        $result = Invoke-UsageGateJson -ClaudeHome $root -ThresholdPercent 90 -MockUsageSequencePath $sequencePath

        Assert-True ($result.ok -eq $true) "Blocked usage should still count as a fresh verified state."
        Assert-True ([string]$result.processStatus -eq "blocked") "Threshold breaches should return blocked."
        Assert-True ($result.shouldBlock -eq $true) "Threshold breaches should set shouldBlock."
        Assert-True ([string]$result.fiveHourResetAt -eq "2026-03-25T18:00:00.0000000+00:00") "The reset time should be normalized and preserved."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-UsageGateNeverTrustsStaleCacheForLaunchDecisions {
    $root = Join-Path $env:TEMP ("autodev-usage-gate-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $cachePath = Join-Path $root "tl-autodev-usage-cache.json"
        Write-TestFile -Path $cachePath -Content @"
{
  "fetchedAt": "2026-03-25T14:00:00Z",
  "source": "oauth",
  "fiveHourUtilization": 12.0,
  "fiveHourResetAt": "2026-03-25T18:00:00Z",
  "sevenDayUtilization": 8.0,
  "thresholdPercent": 90,
  "shouldBlock": false,
  "lastError": ""
}
"@

        $result = Invoke-UsageGateJson -ClaudeHome $root -MockErrorKind "timeout"

        Assert-True ($result.ok -eq $false) "Timeouts must not authorize a launch from stale cache."
        Assert-True ([string]$result.processStatus -eq "unavailable_timeout") "Timeouts should classify as unavailable_timeout."
        Assert-True ([string]$result.source -eq "none") "Stale cache should not become the active source."
        Assert-True ([double]$result.fiveHourUtilization -eq 12.0) "Stale cache may still be returned as informational context."
        Assert-True ([string]$result.lastSuccessfulFetchAt -eq "2026-03-25T14:00:00.0000000+00:00") "Timeouts should surface the last successful fetch time from cache."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-UsageGateWaitModeSleepsUntilUsageOpens {
    $root = Join-Path $env:TEMP ("autodev-usage-gate-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $sequencePath = Join-Path $root "usage-sequence.json"
        Write-TestFile -Path $sequencePath -Content @"
[
  {
    "five_hour": {
      "utilization": 95.0,
      "resets_at": "2000-01-01T00:00:00Z"
    },
    "seven_day": {
      "utilization": 20.0,
      "resets_at": "2026-03-30T18:00:00Z"
    }
  },
  {
    "five_hour": {
      "utilization": 45.0,
      "resets_at": "2026-03-25T19:00:00Z"
    },
    "seven_day": {
      "utilization": 20.0,
      "resets_at": "2026-03-30T18:00:00Z"
    }
  }
]
"@

        $result = Invoke-UsageGateJson -ClaudeHome $root -Mode "wait" -MockUsageSequencePath $sequencePath -PollSeconds 1 -FastPollSeconds 1 -FastWindowSeconds 1

        Assert-True ($result.ok -eq $true) "Wait mode should end once usage opens."
        Assert-True ([string]$result.processStatus -eq "ok") "Wait mode should finish with ok when the follow-up probe opens."
        Assert-True ($result.waitedSeconds -ge 1) "Wait mode should record time spent waiting."
        Assert-True (@($result.history).Count -ge 2) "Wait mode should record both the blocked and the open probe."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-UsageGateWaitModeReturnsUnavailableWhenRefreshFailsAfterBlockedState {
    $root = Join-Path $env:TEMP ("autodev-usage-gate-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $sequencePath = Write-UsageGateMockFile -Root $root -FileName "usage-preblocked.json" -Payload @(
            [ordered]@{
                five_hour = [ordered]@{
                    utilization = 95.0
                    resets_at = "2000-01-01T00:00:00Z"
                }
                seven_day = [ordered]@{
                    utilization = 20.0
                    resets_at = "2026-03-30T18:00:00Z"
                }
            }
        )
        $blockedResult = Invoke-UsageGateJson -ClaudeHome $root -MockUsageSequencePath $sequencePath
        Assert-True ([string]$blockedResult.processStatus -eq "blocked") "The setup probe should confirm a blocked state."

        $waitResult = Invoke-UsageGateJson -ClaudeHome $root -Mode "wait" -MockErrorKind "timeout" -PollSeconds 1 -FastPollSeconds 1 -FastWindowSeconds 1

        Assert-True ($waitResult.ok -eq $false) "Wait mode should not mask a failed refresh after a blocked state."
        Assert-True ([string]$waitResult.processStatus -eq "unavailable_timeout") "A failed refresh after waiting should surface as unavailable_timeout."
        Assert-True (@($waitResult.history).Count -ge 1) "Wait mode should record the failed refresh attempt in history."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
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

function Test-TlaMergeLockRemediationUsesRestoreFailureReason {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root -DotnetBehavior "lock-then-restore-fail"
        $dotnetSequenceFile = Join-Path $repo.root "dotnet-sequence.txt"
        $taskkillLog = Join-Path $repo.root "taskkill-restore.log"
        $dotnetLog = Join-Path $repo.root "dotnet-restore.log"

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "tla-merge-restore-fail"
                    sourceCommand = "TLA-develop"
                    sourceInputType = "inline"
                    taskText = "merge autonomously but fail on rerun restore"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "tla-merge-restore-fail.json")
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
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "tla-merge-restore-fail" -ResultFile (Join-Path $repo.tasksDir "tla-merge-restore-fail-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $savedState.tasks[0].latestRun.branchName = "auto/tla-merge-restore-fail"
        Write-StateFile -StateFile $repo.stateFile -State $savedState

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_DOTNET_SEQUENCE_FILE = $dotnetSequenceFile
            AUTODEV_TEST_TASKKILL_LOG = $taskkillLog
            AUTODEV_TEST_DOTNET_LOG = $dotnetLog
            AUTODEV_TEST_PROCESS_CANDIDATES = (@(
                @{ id = 1111; processName = "devenv" },
                @{ id = 2222; processName = "iisexpress" }
            ) | ConvertTo-Json -Depth 8 -Compress)
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $false) "TLA prepare-merge should still fail when the rerun restore fails after lock remediation."
        Assert-True ($prepareResult.lockRemediationAttempted -eq $true) "TLA prepare-merge should record the remediation attempt before the rerun restore fails."
        Assert-True ([string]$prepareResult.task.state -eq "merge_retry_scheduled") "Rerun restore failure should stay on the merge retry path."
        Assert-True ([string]$prepareResult.reason -match '^Restore failed after autonomous lock remediation\.') "Post-remediation restore failures should surface a restore-specific reason."
        Assert-True ([string]$prepareResult.reason -notmatch '^Build failed after autonomous lock remediation\.') "Post-remediation restore failures must not be mislabeled as build failures."

        $taskkillEntries = if (Test-Path -LiteralPath $taskkillLog) { @(Get-Content -LiteralPath $taskkillLog) } else { @() }
        Assert-True ($taskkillEntries.Count -eq 2) "Lock remediation should still terminate the mocked processes before the rerun restore fails."

        $dotnetEntries = if (Test-Path -LiteralPath $dotnetLog) { @(Get-Content -LiteralPath $dotnetLog) } else { @() }
        $normalizedDotnetEntries = @($dotnetEntries | ForEach-Object { ([string]$_).TrimStart([char]0xFEFF).Trim() })
        Assert-True ($normalizedDotnetEntries.Count -eq 3) "Lock remediation rerun should execute restore, build, then restore."
        Assert-True ($normalizedDotnetEntries[0] -match '^restore\b') "The first merge attempt should start with restore."
        Assert-True ($normalizedDotnetEntries[1] -match '^build\b') "The initial failure should come from build before remediation."
        Assert-True ($normalizedDotnetEntries[2] -match '^restore\b') "The rerun after remediation should restart with restore."
    } finally {
        Remove-TestRepo -Root $repo.root
    }
}

function Test-PrepareMergeRunsRestoreBeforeBuild {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root -DotnetBehavior "success"
        $dotnetLog = Join-Path $repo.root "dotnet.log"

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "merge-restore-order"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "run restore before build"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "merge-restore-order.json")
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
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "merge-restore-order" -ResultFile (Join-Path $repo.tasksDir "merge-restore-order-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $savedState.tasks[0].latestRun.branchName = "auto/merge-restore-order"
        Write-StateFile -StateFile $repo.stateFile -State $savedState

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_DOTNET_LOG = $dotnetLog
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $true) "Prepare-merge should succeed when restore and build both succeed."

        $dotnetEntries = if (Test-Path -LiteralPath $dotnetLog) { @(Get-Content -LiteralPath $dotnetLog) } else { @() }
        $normalizedDotnetEntries = @($dotnetEntries | ForEach-Object { ([string]$_).TrimStart([char]0xFEFF).Trim() })
        Assert-True ($normalizedDotnetEntries.Count -eq 2) "Prepare-merge should invoke dotnet exactly twice on success."
        Assert-True ($normalizedDotnetEntries[0] -match '^restore\b') "Prepare-merge must run dotnet restore before build."
        Assert-True ($normalizedDotnetEntries[1] -match '^build\b') "Prepare-merge must run dotnet build after restore."
        Assert-True ($normalizedDotnetEntries[1] -match '--no-restore') "Prepare-merge build should keep --no-restore after the explicit restore step."
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

function Test-MergeRestoreFailurePreservesBranch {
    $repo = New-TestRepo
    try {
        $mockCommands = New-MockCommandSet -Root $repo.root -DotnetBehavior "restore-fail"
        $gitLog = Join-Path $repo.root "git-restore.log"
        $dotnetLog = Join-Path $repo.root "dotnet-restore.log"

        Write-StateFile -StateFile $repo.stateFile -State ([pscustomobject]@{
            version = 4
            repoRoot = $repo.root
            createdAt = (Get-Date).ToString("o")
            updatedAt = (Get-Date).ToString("o")
            lastPlanAppliedAt = ""
            tasks = @(
                [pscustomobject]@{
                    taskId = "merge-restore-retry"
                    sourceCommand = "develop"
                    sourceInputType = "inline"
                    taskText = "preserve branch on restore fail"
                    solutionPath = $repo.solution
                    promptFile = $repo.promptFile
                    planFile = ""
                    resultFile = (Join-Path $repo.resultsDir "merge-restore-retry.json")
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
                    latestRun = (New-TestLatestRun -AttemptNumber 1 -TaskName "merge-restore-retry" -ResultFile (Join-Path $repo.tasksDir "merge-restore-retry-result.json"))
                    runs = @()
                    merge = (New-TestMergeRecord)
                }
            )
        })
        $savedState = Get-Content -LiteralPath $repo.stateFile -Raw | ConvertFrom-Json
        $savedState.tasks[0].latestRun.branchName = "auto/merge-restore-retry"
        Write-StateFile -StateFile $repo.stateFile -State $savedState

        $envVars = @{
            AUTODEV_GIT_COMMAND = $mockCommands.git
            AUTODEV_DOTNET_COMMAND = $mockCommands.dotnet
            AUTODEV_TASKKILL_COMMAND = $mockCommands.taskkill
            AUTODEV_TEST_REPO_ROOT = $repo.root
            AUTODEV_TEST_GIT_LOG = $gitLog
            AUTODEV_TEST_DOTNET_LOG = $dotnetLog
        }

        $prepareResult = Invoke-WithEnvironment -Variables $envVars -ScriptBlock {
            Invoke-SchedulerJson -RepoSolution $repo.solution -Mode "prepare-merge"
        }

        Assert-True ($prepareResult.prepared -eq $false) "Restore failure should fail merge preparation."
        Assert-True ([string]$prepareResult.task.state -eq "merge_retry_scheduled") "Restore failures during prepare-merge should preserve accepted work as merge_retry_scheduled."
        Assert-True ([string]$prepareResult.task.branchName -eq "auto/merge-restore-retry") "Merge-stage retry must preserve the accepted branch after restore failure."
        Assert-True ([int]$prepareResult.task.mergeAttemptsUsed -eq 1) "Restore failure should consume merge retry budget."
        Assert-True ([string]$prepareResult.reason -match 'NU1101|Restore failed') "Restore failure reason should be surfaced."

        $gitEntries = if (Test-Path -LiteralPath $gitLog) { @(Get-Content -LiteralPath $gitLog) } else { @() }
        Assert-True (@($gitEntries | Where-Object { $_ -match 'branch\s+-D' }).Count -eq 0) "Branch should not be deleted on merge-stage restore failure."

        $dotnetEntries = if (Test-Path -LiteralPath $dotnetLog) { @(Get-Content -LiteralPath $dotnetLog) } else { @() }
        $normalizedDotnetEntries = @($dotnetEntries | ForEach-Object { ([string]$_).TrimStart([char]0xFEFF).Trim() })
        Assert-True ($normalizedDotnetEntries.Count -eq 1) "Prepare-merge should stop after restore failure."
        Assert-True ($normalizedDotnetEntries[0] -match '^restore\b') "Restore failure should happen before any build invocation."
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
Test-RetryRestoresLastPlannedWavePlacement
Test-RetryFallsBackWhenPreservedPlacementIsStale
Test-WorkerLaunchSequenceSeparatesIdentityFromAttempts
Test-CollidingTaskIdPrefixesGenerateUniqueTaskNames
Test-PreflightMissingSolutionIsEnvironmentFailure
Test-PreflightWarnsOnUnboundEventCallback
Test-PreflightAcceptsExplicitEventCallbackBinding
Test-PreflightAcceptsBindSyntaxForChangedCallback
Test-PreflightSkipsPageComponentsForEventCallbackWiring
Test-PreflightBlocksMissingStaticJsInvokableTarget
Test-PreflightAcceptsAliasedStaticJsInvokableTarget
Test-PreflightWarnsOnMissingInstanceJsInvokableTarget
Test-PreflightIgnoresNonDotNetInvokeMethodPatterns
Test-PreflightDoesNotCrossWireDuplicateComponentNames
Test-InvestigationInconclusiveGetsOneNormalRetry
Test-RepeatedInvestigationInconclusiveBecomesManualDebugNeeded
Test-ManualDebugTaskResumesToQueuedOnPositiveReplan
Test-ManualDebugTaskStaysPausedWithoutPositiveWaveReplan
Test-SnapshotResilience
Test-EncodedWorkerLaunchCommandPreservesSpacedPaths
Test-WritePlannerContextFilePersistsEffortClass
Test-PlannerContextLowEffortSelectsSimpleProfile
Test-MissingPlannerContextFallsBackToComplexProfile
Test-WriteWorkerBriefsFilePersistsAcceptedCompletedBriefs
Test-WorkerBriefsRoundTripLoadsWorkerState
Test-FormatWorkerBriefsPromptBlockIncludesDiscoveries
Test-InvestigationPriorArtOutputBlockUsesFileQualifiedSearchHitContract
Test-PlanPriorArtOutputBlockRequiresConcreteRelativePath
Test-PriorArtRequirementDetectsReuseAndCrossLayerSignals
Test-PriorArtRequirementSkipsSimpleDirectEdit
Test-PriorArtRequirementIgnoresGenericRoleNouns
Test-InvestigationVerdictParsesPriorArtFields
Test-InvestigationPriorArtValidationRequiresAllFields
Test-InvestigationPriorArtValidationAcceptsFileQualifiedSearchHits
Test-InvestigationPriorArtValidationRejectsRawSearchCommands
Test-PlanValidationRequiresReuseSectionWhenPriorArtRequired
Test-PlanValidationAcceptsConcreteReuseSectionWhenPriorArtRequired
Test-PlanValidationRejectsSearchPatternReferenceWhenPriorArtRequired
Test-PlanValidationAcceptsMarkdownDecoratedPaths
Test-PriorArtReferenceFilesAcceptMarkdownWrappedEntries
Test-ReadOnlyPhaseConfusionDetectorFlagsApprovalChatter
Test-SanitizeReadOnlyPhaseTextPreservesStructuredEvidence
Test-PlanValidationRejectsApprovalChatterInOtherwiseValidPlan
Test-GetRetryLessonsFromFeedbackHistoryProducesStructuredLessons
Test-RetryContextRoundTripLoadsWorkerState
Test-WrongTaskRetryContextFallsBackGracefully
Test-EmptyRetryContextPayloadFallsBackGracefully
Test-MissingRetryContextFallsBackGracefully
Test-RetryContextPromptBlockIncludesPriorDenialText
Test-RetryContextPromptBlockIncludesValidationIssues
Test-WriteRetryContextFilePersistsRelevantPriorFailures
Test-WriteRetryContextFileSkipsInfraOnlyHistory
Test-ReconcilePersistsRetryLessonsAndRetryContextArtifacts
Test-DirectionCheckVerdictParsesOnTrackCombination
Test-DirectionCheckVerdictParsesMinorDriftCombination
Test-DirectionCheckVerdictParsesMajorDriftCombination
Test-DirectionCheckVerdictRejectsMissingMarkers
Test-DirectionCheckVerdictRejectsMixedCombination
Test-AcceptedPlanTargetsKeepExistingTargetsWhenCandidateRejected
Test-AcceptedPlanTargetsReplaceExistingTargetsWhenAccepted
Test-FixPlanFailureOutcomeUsesInsufficientForNonFinalDrift
Test-FixPlanFailureOutcomeUsesDirectionDriftWhenFinalReasonIsDrift
Test-PlanDirectionCheckRejectsRepairedPlanWithMajorDrift
Test-PlanDirectionCheckAcceptsRepairedPlanWhenOnTrack
Test-PlanDirectionCheckAddsGuardrailForRepairedMinorDrift
Test-ImplementationScopeCheckIsTightForExactMatches
Test-ImplementationScopeCheckAcceptsUniqueSuffixMatches
Test-ImplementationScopeCheckEscalatesDirectoryTargets
Test-ImplementationScopeCheckDetectsOutOfScopeFiles
Test-ImplementationScopeCheckTreatsWildcardMatchesAsBroad
Test-ImplementationScopeCheckWildcardStillDetectsOutOfScopeFiles
Test-ImplementationScopeCheckReportsUnmatchedWildcardTargets
Test-ImplementationScopeCheckSupportsMixedExactAndWildcardTargets
Test-RegistrationRejectsMissingPromptFile
Test-RegistrationRejectsEmptyPromptFile
Test-RegistrationRejectsPromptDirectoryPath
Test-RegistrationRejectsPromptWithoutReadableTaskLine
Test-SnapshotSurfacesMissingPromptFileIntegrityError
Test-SnapshotCompactViewExcludesRunHistory
Test-BlockedByNormalization
Test-DeclaredDependencyValidation
Test-DeclaredDependencyBlocksStartUntilSatisfied
Test-RegisterTasksPreservesUnicodeTaskText
Test-UsageGateWritesAutodevCacheOnFreshSuccess
Test-UsageGateBlocksWhenThresholdIsExceeded
Test-UsageGateNeverTrustsStaleCacheForLaunchDecisions
Test-UsageGateWaitModeSleepsUntilUsageOpens
Test-UsageGateWaitModeReturnsUnavailableWhenRefreshFailsAfterBlockedState
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
Test-PrepareMergeRunsRestoreBeforeBuild
Test-SnapshotIncludesStructuredProgress
Test-MalformedProgressArtifactsDoNotBreakSnapshot
Test-ProgressMilestonesTranslateToEnglish
Test-QueueStallDetectedWhenWorkRemainsButNothingCanRun
Test-QueueStallDoesNotTriggerWhileWaitingForUserMergeDecision
Test-QueueStallDoesNotTriggerWhileCircuitBreakerIsOpen
Test-TlaMergeLockRemediation
Test-TlaMergeLockRemediationUsesRestoreFailureReason
Test-MergeRestoreFailurePreservesBranch
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
Test-RunTaskInvalidPromptBecomesEnvironmentRetryWithoutBreaker
Test-InvalidPromptFailuresDoNotOpenCircuitBreaker
Test-AutoDevelopInvalidPromptWritesStructuredErrorAndTimeline

Write-Host "Scheduler regression checks passed."
