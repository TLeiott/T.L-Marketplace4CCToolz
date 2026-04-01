param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][string]$SnapshotFile,
    [Parameter(Mandatory)][string]$OutputFile,
    [string]$NewTaskIdsFile = "",
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "autodevelop-config.ps1")

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory = "")

    $resolvedCommand = Resolve-AutoDevelopNativeCommandName -Command $Command

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

function Read-JsonFileBestEffort {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        try {
            return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
}

function Get-CanonicalPath {
    param([string]$Path)

    if (-not $Path) { return "" }
    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    } catch {
        return [System.IO.Path]::GetFullPath($Path)
    }
}

function Get-RepoRootFromSolution {
    param([string]$ResolvedSolutionPath)

    $solutionDir = Split-Path -Path $ResolvedSolutionPath -Parent
    $gitResult = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "--show-toplevel") -WorkingDirectory $solutionDir
    if ($gitResult.exitCode -ne 0 -or -not $gitResult.output) {
        throw "Could not resolve git repository root for '$ResolvedSolutionPath'."
    }
    return (Get-CanonicalPath -Path $gitResult.output)
}

function Get-JsonObjectFromText {
    param([string]$Text)

    if (-not $Text) { return $null }
    $trimmed = $Text.Trim()
    foreach ($candidate in @($trimmed, (($trimmed -replace '(?s)^```(?:json)?\s*', '') -replace '\s*```$', '').Trim())) {
        if (-not $candidate) { continue }
        try {
            return ($candidate | ConvertFrom-Json)
        } catch {
        }
    }
    return $null
}

function Get-AdditionalMarkdownFiles {
    param([string]$RepoRoot)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        (Join-Path $RepoRoot "docs"),
        (Join-Path $RepoRoot ".claude")
    )) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $path -Filter *.md -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 3) {
            if (-not $candidates.Contains($file.FullName)) {
                [void]$candidates.Add($file.FullName)
            }
        }
    }

    return @($candidates | Select-Object -First 3)
}

function Format-MarkdownContextBlock {
    param([string]$RepoRoot)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($name in @("CLAUDE.md", "AGENTS.md", "README.md")) {
        $path = Join-Path $RepoRoot $name
        if (Test-Path -LiteralPath $path) {
            $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            [void]$parts.Add("FILE: $name`n$content")
        }
    }

    foreach ($file in Get-AdditionalMarkdownFiles -RepoRoot $RepoRoot) {
        $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $file)
        $content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        [void]$parts.Add("FILE: $relative`n$content")
    }

    return ($parts -join "`n`n")
}

function Invoke-ClaudePlanner {
    param(
        [string]$Prompt,
        $RoleConfig,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds
    )

    $tempPromptFile = Join-Path $env:TEMP ("autodev-planner-input-" + [guid]::NewGuid().ToString("N") + ".md")
    $tempOutputFile = Join-Path $env:TEMP ("autodev-planner-output-" + [guid]::NewGuid().ToString("N") + ".txt")
    $parent = Split-Path -Path $tempPromptFile -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($tempPromptFile, $Prompt, [System.Text.Encoding]::UTF8)
    $exe = Get-ClaudeExecutablePath -RoleConfig $RoleConfig
    $arguments = @("-p") + (Get-ClaudeRoleArguments -RoleConfig $RoleConfig)

    $job = Start-Job -ScriptBlock {
        param($Executable, $PromptFile, $Args, $OutFile, $Location)
        Set-Location $Location
        Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
        $content = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
        try {
            $output = $content | & $Executable @Args 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } catch {
            $output = "JOB_EXCEPTION: $_"
            $exitCode = 99
        }
        [System.IO.File]::WriteAllText($OutFile, "$exitCode`n$output", [System.Text.Encoding]::UTF8)
    } -ArgumentList $exe, $tempPromptFile, $arguments, $tempOutputFile, $WorkingDirectory

    try {
        $completed = Wait-Job $job -Timeout $TimeoutSeconds
        if (-not $completed -or $job.State -eq "Running") {
            Stop-Job $job -ErrorAction SilentlyContinue
            throw "Planner role timed out after $TimeoutSeconds seconds."
        }

        $jobErrors = Receive-Job $job 2>&1 | Out-String
        if ($job.State -eq "Failed") {
            throw "Planner role job failed: $jobErrors"
        }

        $raw = [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8)
        $parts = $raw -split "`n", 2
        $exitCode = if ($parts.Count -ge 1 -and $parts[0] -match '^\d+$') { [int]$parts[0] } else { 99 }
        $output = if ($parts.Count -ge 2) { $parts[1] } else { $raw }
        return [pscustomobject]@{
            exitCode = $exitCode
            output = $output.Trim()
            command = $exe
            args = $arguments
        }
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempPromptFile, $tempOutputFile -ErrorAction SilentlyContinue
    }
}

$resolvedSolution = Get-CanonicalPath -Path $SolutionPath
if (-not (Test-Path -LiteralPath $resolvedSolution)) {
    throw "Solution path not found: $SolutionPath"
}

$snapshot = Read-JsonFileBestEffort -Path $SnapshotFile
if (-not $snapshot) {
    throw "Snapshot file '$SnapshotFile' could not be read."
}

$repoRoot = Get-RepoRootFromSolution -ResolvedSolutionPath $resolvedSolution
$configState = Get-AutoDevelopConfigState -RepoRoot $repoRoot
$schedulerRole = Resolve-AutoDevelopRoleConfig -ConfigState $configState -RoleName "scheduler"
$resolvedTimeoutSeconds = Get-AutoDevelopResolvedTimeoutSeconds -RoleConfig $schedulerRole -FallbackTimeoutSeconds $TimeoutSec
$promptTemplate = Get-AutoDevelopPromptTemplateBody -BasePath (Join-Path $PSScriptRoot "..") -RelativePath ([string]$schedulerRole.promptTemplatePath)
$newTaskIds = @(ConvertTo-AutoDevelopStringArray -Value (Read-JsonFileBestEffort -Path $NewTaskIdsFile))
$runningTasks = @($snapshot.tasks | Where-Object { [string]$_.state -eq "running" })
$pendingMergeTasks = @($snapshot.tasks | Where-Object { [string]$_.state -in @("pending_merge", "waiting_user_test") })
$completedBriefs = @($snapshot.completedTaskBriefs)
$markdownContext = Format-MarkdownContextBlock -RepoRoot $repoRoot
$warningBlock = if (@($configState.warnings).Count -gt 0) {
    ((@($configState.warnings) | ForEach-Object { "- $($_.scope): $($_.message)" }) -join "`n")
} else {
    ""
}

$prompt = @"
$promptTemplate

You are running as the AutoDevelop scheduler role. Return valid JSON only.

## Solution
$resolvedSolution

## Config Warnings
$warningBlock

## Newly Added Task Ids
$(($newTaskIds | ConvertTo-Json -Depth 8))

## Running Tasks
$(($runningTasks | ConvertTo-Json -Depth 16))

## Pending Merge Tasks
$(($pendingMergeTasks | ConvertTo-Json -Depth 16))

## Completed Task Briefs
$(($completedBriefs | ConvertTo-Json -Depth 16))

## Planner Feedback Summary
$(($snapshot.plannerFeedbackSummary | ConvertTo-Json -Depth 16))

## Full Queue Snapshot
$(($snapshot | ConvertTo-Json -Depth 24))

## Markdown Context
$markdownContext
"@

$result = Invoke-ClaudePlanner -Prompt $prompt -RoleConfig $schedulerRole -WorkingDirectory $repoRoot -TimeoutSeconds $resolvedTimeoutSeconds
if ($result.exitCode -ne 0) {
    throw "Planner role failed with exit code $($result.exitCode): $($result.output)"
}

$planObject = Get-JsonObjectFromText -Text $result.output
if (-not $planObject) {
    throw "Planner output was not valid JSON. Output:`n$($result.output)"
}

$outputParent = Split-Path -Path $OutputFile -Parent
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent)) {
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

[System.IO.File]::WriteAllText($OutputFile, ($planObject | ConvertTo-Json -Depth 32), [System.Text.Encoding]::UTF8)
[Console]::Out.WriteLine(($planObject | ConvertTo-Json -Depth 32))
