# auto-develop.ps1 -- Deterministic pipeline with investigation, artifacts, and explicit no-op handling
param(
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$TaskName = "develop-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [switch]$SkipRun,
    [switch]$AllowNuget
)

$CONST_MODEL_PLAN = "claude-opus-4-6"
$CONST_MODEL_INVESTIGATE = "claude-opus-4-6"
$CONST_MODEL_IMPLEMENT = "claude-opus-4-6"
$CONST_MODEL_REVIEW = "claude-opus-4-6"
$CONST_MODEL_FAST = "claude-sonnet-4-6"
$CONST_MAX_TURNS_PLAN = 30
$CONST_MAX_TURNS_INVESTIGATE = 20
$CONST_MAX_TURNS_IMPL = 30
$CONST_MAX_TURNS_REVIEW = 10
$CONST_TIMEOUT_SECONDS = 900
$CONST_PLAN_ATTEMPTS = 2
$CONST_INVESTIGATION_ATTEMPTS = 2
$CONST_IMPLEMENT_ATTEMPTS = 2
$CONST_REMEDIATION_ATTEMPTS = 2
$CONST_REPAIR_ATTEMPTS = 2

$ErrorActionPreference = "Stop"
$originalDir = Get-Location
$worktreePath = $null
$branchName = "auto/$TaskName"
$currentPhase = "VALIDATE"
$repoRoot = $null
$artifactRunDir = $null
$debugRunDir = $null
$scriptStartTime = Get-Date
$runId = $null
$timeline = [System.Collections.ArrayList]::new()
$feedbackHistory = [System.Collections.ArrayList]::new()
$attemptsByPhase = [ordered]@{
    plan = 0
    investigate = 0
    implement = 0
    remediate = 0
    review = 0
}
$finalVerdict = "FAILED"
$finalFeedback = ""
$finalSeverity = ""
$finalCategory = ""
$finalSummary = ""
$finalStatus = "FAILED"
$changedFiles = @()
$planVersion = 0
$investigationRequired = $false
$investigationConclusion = ""
$taskClass = "UNCERTAIN"
$lastNoChangeReason = ""

Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)
    $output = & {
        $ErrorActionPreference = "Continue"
        & $Command @Arguments 2>&1
    }
    return @{ output = ($output | Out-String).Trim(); exitCode = $LASTEXITCODE }
}

function Add-TimelineEvent {
    param(
        [string]$Phase,
        [string]$Message,
        [string]$Category = "",
        [hashtable]$Data = @{}
    )
    [void]$timeline.Add([ordered]@{
        timestamp = (Get-Date -Format "o")
        phase = $Phase
        message = $Message
        category = $Category
        data = $Data
    })
}

function Get-SafeFileToken {
    param([string]$Text)
    if (-not $Text) { return "run" }
    $token = $Text.Trim()
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $token = $token.Replace($char, "-")
    }
    $token = $token -replace '\s+', '-'
    $token = $token -replace '-{2,}', '-'
    $token = $token.Trim('-')
    if (-not $token) { return "run" }
    if ($token.Length -gt 60) { return $token.Substring(0, 60) }
    return $token
}

function Ensure-ArtifactDir {
    param([string]$Root)
    if (-not $artifactRunDir) {
        $logDir = Join-Path $Root ".claude-develop-logs\runs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:artifactRunDir = Join-Path $logDir $TaskName
        if (-not (Test-Path $artifactRunDir)) { New-Item -ItemType Directory -Path $artifactRunDir -Force | Out-Null }
    }
    return $artifactRunDir
}

function Ensure-DebugDir {
    if (-not $runId) {
        $script:runId = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), (Get-SafeFileToken -Text $TaskName), ([guid]::NewGuid().ToString("N").Substring(0, 8))
    }
    if (-not $debugRunDir) {
        $debugRoot = Join-Path $env:TEMP "claude-develop\debug"
        if (-not (Test-Path $debugRoot)) { New-Item -ItemType Directory -Path $debugRoot -Force | Out-Null }
        $script:debugRunDir = Join-Path $debugRoot $runId
        if (-not (Test-Path $debugRunDir)) { New-Item -ItemType Directory -Path $debugRunDir -Force | Out-Null }
    }
    return $debugRunDir
}

function Save-Artifact {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Subdir = ""
    )
    if (-not $artifactRunDir) { return $null }
    $targetDir = $artifactRunDir
    if ($Subdir) {
        $targetDir = Join-Path $artifactRunDir $Subdir
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    }
    $path = Join-Path $targetDir $Name
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
    return $path
}

function Save-DebugText {
    param(
        [string]$Name,
        [string]$Content,
        [string]$Subdir = ""
    )
    $targetDir = Ensure-DebugDir
    if ($Subdir) {
        $targetDir = Join-Path $targetDir $Subdir
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    }
    $path = Join-Path $targetDir $Name
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
    return $path
}

function Save-JsonArtifact {
    param(
        [string]$Name,
        $Object,
        [string]$Subdir = ""
    )
    $json = $Object | ConvertTo-Json -Depth 8
    return Save-Artifact -Name $Name -Content $json -Subdir $Subdir
}

function Save-DebugJson {
    param(
        [string]$Name,
        $Object,
        [string]$Subdir = ""
    )
    $json = $Object | ConvertTo-Json -Depth 8
    return Save-DebugText -Name $Name -Content $json -Subdir $Subdir
}

function Add-DebugSnapshot {
    param(
        [string]$SourcePath,
        [string]$TargetName,
        [string]$Subdir = ""
    )
    if (-not $SourcePath -or -not (Test-Path $SourcePath)) { return $null }
    $targetDir = Ensure-DebugDir
    if ($Subdir) {
        $targetDir = Join-Path $targetDir $Subdir
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    }
    $targetPath = Join-Path $targetDir $TargetName
    Copy-Item -Path $SourcePath -Destination $targetPath -Force
    return $targetPath
}

function Write-DebugManifest {
    $manifest = [ordered]@{
        runId = Ensure-DebugDir | Split-Path -Leaf
        taskName = $TaskName
        promptFile = $PromptFile
        solutionPath = $SolutionPath
        resultFile = $ResultFile
        repoRoot = $repoRoot
        artifactRunDir = $artifactRunDir
        debugDir = $debugRunDir
        worktreePath = $worktreePath
        branchName = $branchName
        currentPhase = $currentPhase
        processId = $PID
        startedAt = $scriptStartTime.ToString("o")
        updatedAt = (Get-Date).ToString("o")
        skipRun = [bool]$SkipRun
        allowNuget = [bool]$AllowNuget
    }
    Save-DebugJson -Name "manifest.json" -Object $manifest | Out-Null
}

function Normalize-Text {
    param([string]$Text)
    if (-not $Text) { return "" }
    $normalized = $Text.ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, "\d{4}-\d{2}-\d{2}t\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:z|[+-]\d{2}:\d{2})?", "<ts>")
    $normalized = [regex]::Replace($normalized, "\s+", " ")
    return $normalized.Trim()
}

function Get-TextHash {
    param([string]$Text)
    return (Normalize-Text -Text $Text).GetHashCode().ToString()
}

function Test-ConcreteTargets {
    param([string[]]$Targets)
    if (-not $Targets -or $Targets.Count -eq 0) { return $false }
    $concrete = @($Targets | Where-Object {
        $_ -and $_ -notmatch '^<' -and $_ -match '(\*|\\|/|\.(razor|cs|css|js|ts|xaml|csproj)\b)'
    })
    return $concrete.Count -gt 0
}

function Get-ActionableItems {
    param([string]$Text)
    $items = [System.Collections.ArrayList]::new()
    if (-not $Text) { return @($items) }

    $pathMatches = [regex]::Matches($Text, '(?im)\b[\w\-.\\/]+\.(razor|cs|css|js|ts|xaml|csproj)\b')
    foreach ($match in $pathMatches) { [void]$items.Add($match.Value.Trim()) }

    $lineMatches = [regex]::Matches($Text, '(?im)\b(?:zeile|line|l)\s*\d+(?:\s*[-–]\s*\d+)?\b')
    foreach ($match in $lineMatches) { [void]$items.Add($match.Value.Trim()) }

    $replaceMatches = [regex]::Matches($Text, '(?im)\b(ersetz|replace|textersetzung|aendern|update|remove|entfern)\w*.*')
    foreach ($match in $replaceMatches) { [void]$items.Add($match.Value.Trim()) }

    return @($items | Where-Object { $_ } | Select-Object -Unique)
}

function Test-HasActionableSignal {
    param([string]$Text)
    return (Get-ActionableItems -Text $Text).Count -gt 0
}

function Test-LowComplexityImplement {
    param(
        [string]$TaskClass,
        [bool]$InvestigationRequired,
        [string[]]$Targets,
        [string]$TaskText = "",
        [string]$PhaseContext = ""
    )
    if (-not (Test-ConcreteTargets -Targets $Targets)) { return $false }
    if ($Targets.Count -gt 3) { return $false }
    if ($TaskClass -notin @("DIRECT_EDIT", "BUGFIX_DIAGNOSTIC")) { return $false }
    if ($InvestigationRequired -and $TaskClass -ne "DIRECT_EDIT") { return $false }
    $combined = "$TaskText`n$PhaseContext"
    if ($combined -match '(?im)root cause|ursache|warum|investig|debug|analys|architektur|refactor|migration') { return $false }
    return $true
}

function Get-ModelForPlan {
    param(
        [string]$TaskClass,
        [string[]]$Targets
    )
    if ($TaskClass -eq "DIRECT_EDIT" -or (Test-ConcreteTargets -Targets $Targets)) { return $CONST_MODEL_FAST }
    return $CONST_MODEL_PLAN
}

function Get-ModelForInvestigate {
    param()
    return $CONST_MODEL_INVESTIGATE
}

function Get-ModelForImplement {
    param(
        [string]$TaskClass,
        [bool]$InvestigationRequired,
        [string[]]$Targets,
        [string]$TaskText = "",
        [string]$PhaseContext = ""
    )
    if (Test-LowComplexityImplement -TaskClass $TaskClass -InvestigationRequired $InvestigationRequired -Targets $Targets -TaskText $TaskText -PhaseContext $PhaseContext) {
        return $CONST_MODEL_FAST
    }
    return $CONST_MODEL_IMPLEMENT
}

function Get-ModelForRepair {
    param(
        [string]$PhaseName,
        [string]$TaskClass,
        [bool]$InvestigationRequired,
        [string[]]$Targets,
        [string]$PreviousOutput = "",
        [string]$TaskText = ""
    )
    if ($PhaseName -eq "PLAN") { return $CONST_MODEL_FAST }
    if ($PhaseName -eq "INVESTIGATE") {
        if (Test-HasActionableSignal -Text $PreviousOutput) { return $CONST_MODEL_FAST }
        return $CONST_MODEL_INVESTIGATE
    }
    if ($PhaseName -eq "IMPLEMENT") {
        return Get-ModelForImplement -TaskClass $TaskClass -InvestigationRequired $InvestigationRequired -Targets $Targets -TaskText $TaskText -PhaseContext $PreviousOutput
    }
    if ($PhaseName -eq "REVIEW_MINOR") { return $CONST_MODEL_FAST }
    return $CONST_MODEL_IMPLEMENT
}

function Get-ModelForReview {
    param()
    return $CONST_MODEL_REVIEW
}

function Get-RepairBlock {
    param(
        [string]$FailureCode,
        [string[]]$Reasons,
        [string]$PreviousOutput
    )
    $salvaged = Get-ActionableItems -Text $PreviousOutput
    $reasonText = if ($Reasons -and $Reasons.Count -gt 0) {
        ($Reasons | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "- Keine Details vorhanden."
    }
    $salvageText = if ($salvaged.Count -gt 0) {
        ($salvaged | Select-Object -First 8 | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "- Nichts Verwertbares erkannt."
    }
    return @"
DEIN VORHERIGER VERSUCH WAR UNGUELTIG.

FEHLERKATEGORIE: $FailureCode
WARUM UNGUELTIG:
$reasonText

WAS BEREITS BRAUCHBAR IST:
$salvageText

WAS DU JETZT TUN MUSST:
- Behebe exakt die genannten Probleme.
- Wenn du Dateien nennst, nenne konkrete Pfade oder Suchmuster.
- Wenn du ein RESULT liefern sollst, schreibe die RESULT-Zeile exakt.
- Wenn du genug Hinweise siehst, nutze sie statt erneut vage zu bleiben.

WENN DU DIESES FORMAT NICHT EINHAELTST, GILT DER VERSUCH ALS FEHLER.
"@
}

function Invoke-ClaudeRepair {
    param(
        [string]$PhaseName,
        [string]$Prompt,
        [string]$Model,
        [int]$Attempt,
        [switch]$CanWrite
    )
    if ($CanWrite) {
        return Invoke-ClaudeImplement -Prompt $Prompt -Model $Model -Attempt $Attempt
    }
    if ($PhaseName -eq "PLAN") {
        return Invoke-ClaudePlan -Prompt $Prompt -Model $Model -Attempt $Attempt
    }
    return Invoke-ClaudeInvestigate -Prompt $Prompt -Model $Model -Attempt $Attempt
}

function Add-FeedbackEntry {
    param(
        [int]$Attempt,
        [string]$Source,
        [string]$Category,
        [string]$Feedback
    )
    [void]$feedbackHistory.Add([ordered]@{
        attempt = $Attempt
        source = $Source
        category = $Category
        feedback = $Feedback
    })
}

function Format-FeedbackHistory {
    param([System.Collections.ArrayList]$History, [int]$MaxEntries = 0)
    if ($History.Count -eq 0) { return "" }
    $entries = if ($MaxEntries -gt 0 -and $History.Count -gt $MaxEntries) {
        $History | Select-Object -Last $MaxEntries
    } else {
        $History
    }
    $parts = foreach ($entry in $entries) {
        "--- Versuch $($entry.attempt) [$($entry.source)/$($entry.category)] ---`n$($entry.feedback)"
    }
    return ($parts -join "`n`n")
}

function Write-TimelineArtifact {
    if ($artifactRunDir) {
        Save-JsonArtifact -Name "timeline.json" -Object @($timeline) | Out-Null
    }
    if ($debugRunDir) {
        Save-DebugJson -Name "timeline.json" -Object @($timeline) | Out-Null
    }
}

function Write-ResultJson {
    param(
        [string]$status,
        [string]$finalCategory,
        [string]$summary,
        [string]$branch = "",
        [string[]]$files = @(),
        [string]$verdict = "",
        [string]$feedback = "",
        [string]$error = "",
        [string]$severity = "",
        [string]$phase = "",
        [string]$investigationConclusion = "",
        [string]$noChangeReason = ""
    )
    $result = [ordered]@{
        status = $status
        finalCategory = $finalCategory
        phase = $phase
        branch = $branch
        files = @($files)
        verdict = $verdict
        feedback = $feedback
        error = $error
        taskName = $TaskName
        severity = $severity
        summary = $summary
        attempts = ($attemptsByPhase.Values | Measure-Object -Sum).Sum
        attemptsByPhase = $attemptsByPhase
        artifacts = [ordered]@{
            runDir = $artifactRunDir
            timeline = if ($artifactRunDir) { Join-Path $artifactRunDir "timeline.json" } else { "" }
            debugDir = $debugRunDir
        }
        planVersion = $planVersion
        investigationRequired = $investigationRequired
        investigationConclusion = $investigationConclusion
        noChangeReason = $noChangeReason
        taskClass = $taskClass
    } | ConvertTo-Json -Depth 8

    $resultDir = Split-Path $ResultFile -Parent
    if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($ResultFile, $result, [System.Text.Encoding]::UTF8)
    Save-DebugText -Name "result.json" -Content $result | Out-Null
    Write-DebugManifest
}

function Invoke-ClaudeWithTimeout {
    param(
        [string]$PhaseName,
        [string]$Prompt,
        [string[]]$ExtraArgs = @(),
        [int]$TimeoutSec = $CONST_TIMEOUT_SECONDS,
        [int]$Attempt = 1,
        [string]$Model = ""
    )
    Ensure-DebugDir | Out-Null
    $tempPromptFile = Join-Path $env:TEMP "claude-develop\claude-input-$(New-Guid).md"
    $tempOutputFile = Join-Path $env:TEMP "claude-develop\claude-output-$(New-Guid).txt"
    $tempDir = Split-Path $tempPromptFile -Parent
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    $debugSubdir = $PhaseName

    [System.IO.File]::WriteAllText($tempPromptFile, $Prompt, [System.Text.Encoding]::UTF8)

    $claudeExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
    if (-not $claudeExe) { $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe" }

    $job = Start-Job -ScriptBlock {
        param($exe, $promptFile, $extraArgs, $outFile, $workDir)
        Set-Location $workDir
        Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
        $promptContent = [System.IO.File]::ReadAllText($promptFile, [System.Text.Encoding]::UTF8)
        $allArgs = @("-p") + $extraArgs
        try {
            $output = $promptContent | & $exe @allArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } catch {
            $output = "JOB_EXCEPTION: $_"
            $exitCode = 99
        }
        [System.IO.File]::WriteAllText($outFile, "$exitCode`n$output", [System.Text.Encoding]::UTF8)
    } -ArgumentList $claudeExe, $tempPromptFile, $ExtraArgs, $tempOutputFile, (Get-Location).Path

    $completed = Wait-Job $job -Timeout $TimeoutSec
    if (-not $completed -or $job.State -eq "Running") {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Save-Artifact -Name "$PhaseName-attempt-$Attempt-prompt.md" -Content $Prompt | Out-Null
        Save-JsonArtifact -Name "$PhaseName-attempt-$Attempt-meta.json" -Object ([ordered]@{
            phase = $PhaseName
            attempt = $Attempt
            model = $Model
            exitCode = -1
            timeoutSeconds = $TimeoutSec
            args = $ExtraArgs
        }) | Out-Null
        Save-Artifact -Name "$PhaseName-attempt-$Attempt-output.txt" -Content "TIMEOUT nach $TimeoutSec Sekunden" | Out-Null
        Add-DebugSnapshot -SourcePath $tempPromptFile -TargetName "prompt.md" -Subdir $debugSubdir | Out-Null
        Save-DebugJson -Name "meta.json" -Object ([ordered]@{
            phase = $PhaseName
            attempt = $Attempt
            model = $Model
            exitCode = -1
            timeoutSeconds = $TimeoutSec
            args = $ExtraArgs
            claudeExe = $claudeExe
            workingDirectory = (Get-Location).Path
            tempPromptFile = $tempPromptFile
            tempOutputFile = $tempOutputFile
            timedOut = $true
            jobState = "Running"
        }) -Subdir $debugSubdir | Out-Null
        Save-DebugText -Name "output.txt" -Content "TIMEOUT nach $TimeoutSec Sekunden" -Subdir $debugSubdir | Out-Null
        Remove-Item $tempPromptFile -ErrorAction SilentlyContinue
        Remove-Item $tempOutputFile -ErrorAction SilentlyContinue
        return @{ success = $false; output = "TIMEOUT nach $TimeoutSec Sekunden"; timedOut = $true; exitCode = -1 }
    }

    $jobFailed = $job.State -eq "Failed"
    $jobErrors = Receive-Job $job 2>&1 | Out-String
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $rawOutput = ""
    if (Test-Path $tempOutputFile) {
        $rawOutput = [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8)
    }

    $lines = $rawOutput -split "`n", 2
    $exitCode = 0
    $output = $rawOutput
    if ($lines.Count -ge 2 -and $lines[0] -match "^\d+$") {
        $exitCode = [int]$lines[0]
        $output = $lines[1]
    }
    if ($jobFailed) {
        $output = "JOB_FAILED: $jobErrors"
        $exitCode = 99
    }

    Save-Artifact -Name "$PhaseName-attempt-$Attempt-prompt.md" -Content $Prompt | Out-Null
    Save-JsonArtifact -Name "$PhaseName-attempt-$Attempt-meta.json" -Object ([ordered]@{
        phase = $PhaseName
        attempt = $Attempt
        model = $Model
        exitCode = $exitCode
        timeoutSeconds = $TimeoutSec
        args = $ExtraArgs
        jobFailed = $jobFailed
    }) | Out-Null
    Save-Artifact -Name "$PhaseName-attempt-$Attempt-output.txt" -Content $output | Out-Null
    Add-DebugSnapshot -SourcePath $tempPromptFile -TargetName "prompt.md" -Subdir $debugSubdir | Out-Null
    Add-DebugSnapshot -SourcePath $tempOutputFile -TargetName "raw-output.txt" -Subdir $debugSubdir | Out-Null
    Save-DebugJson -Name "meta.json" -Object ([ordered]@{
        phase = $PhaseName
        attempt = $Attempt
        model = $Model
        exitCode = $exitCode
        timeoutSeconds = $TimeoutSec
        args = $ExtraArgs
        jobFailed = $jobFailed
        claudeExe = $claudeExe
        workingDirectory = (Get-Location).Path
        tempPromptFile = $tempPromptFile
        tempOutputFile = $tempOutputFile
        timedOut = $false
        promptChars = $Prompt.Length
        outputChars = $output.Length
    }) -Subdir $debugSubdir | Out-Null
    Save-DebugText -Name "output.txt" -Content $output -Subdir $debugSubdir | Out-Null
    if ($jobErrors.Trim()) {
        Save-DebugText -Name "job-errors.txt" -Content $jobErrors -Subdir $debugSubdir | Out-Null
    }

    Remove-Item $tempPromptFile -ErrorAction SilentlyContinue
    Remove-Item $tempOutputFile -ErrorAction SilentlyContinue

    return @{ success = ($exitCode -eq 0); output = $output; timedOut = $false; exitCode = $exitCode }
}

function Invoke-ClaudePlan {
    param([string]$Prompt, [string]$Model, [int]$Attempt)
    Add-TimelineEvent -Phase "MODEL" -Message "PLAN nutzt $Model" -Category "PLAN_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "plan-v$Attempt" -Prompt $Prompt -Model $Model -Attempt $Attempt -ExtraArgs @(
        "--model", $Model,
        "--allowedTools", "Read,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_PLAN.ToString()
    )
}

function Invoke-ClaudeInvestigate {
    param([string]$Prompt, [string]$Model, [int]$Attempt)
    Add-TimelineEvent -Phase "MODEL" -Message "INVESTIGATE nutzt $Model" -Category "INVESTIGATE_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "investigate-v$Attempt" -Prompt $Prompt -Model $Model -Attempt $Attempt -ExtraArgs @(
        "--model", $Model,
        "--allowedTools", "Read,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_INVESTIGATE.ToString()
    )
}

function Invoke-ClaudeImplement {
    param([string]$Prompt, [string]$Model, [int]$Attempt)
    Add-TimelineEvent -Phase "MODEL" -Message "IMPLEMENT nutzt $Model" -Category "IMPLEMENT_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "implement-v$Attempt" -Prompt $Prompt -Model $Model -Attempt $Attempt -TimeoutSec ($CONST_TIMEOUT_SECONDS * 2) -ExtraArgs @(
        "--model", $Model,
        "--dangerously-skip-permissions",
        "--allowedTools", "Read,Edit,Write,Bash,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_IMPL.ToString()
    )
}

function Invoke-ClaudeReview {
    param([string]$Prompt, [string]$AttemptLabel)
    $model = Get-ModelForReview
    Add-TimelineEvent -Phase "MODEL" -Message "REVIEW nutzt $model" -Category "REVIEW_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "review-$AttemptLabel" -Prompt $Prompt -Model $model -Attempt 1 -ExtraArgs @(
        "--model", $model,
        "--allowedTools", "Read,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_REVIEW.ToString()
    )
}

function Get-ReviewVerdict {
    param([string]$ReviewOutput)
    $lines = @($ReviewOutput -split "`n" | Where-Object { $_.Trim() -ne "" })
    if ($lines.Count -eq 0) { return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = "Leere Review-Antwort" } }

    $firstLine = $lines[0].Trim().ToUpperInvariant()
    $feedbackText = ($lines | Select-Object -Skip 1) -join "`n"

    if ($firstLine -match "^ACCEPTED\b") {
        return @{ verdict = "ACCEPTED"; severity = ""; feedback = $feedbackText }
    }
    if ($firstLine -match "^DENIED_(MINOR|MAJOR|RETHINK)\b") {
        return @{ verdict = "DENIED"; severity = $Matches[1]; feedback = $feedbackText }
    }
    if ($firstLine -match "^DENIED\b") {
        return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = $feedbackText }
    }
    return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = "Reviewer-Antwort unklar (erste Zeile: '$($lines[0])')`n$ReviewOutput" }
}

function Get-TaskClass {
    param([string]$TaskText)
    $text = $TaskText.ToLowerInvariant()
    if ($text -match "root cause|ursache|warum|investig|check whether|pruef|analys|debug|bug") { return "INVESTIGATIVE" }
    if ($text -match "replace|ersetz|dialog|banner|farbe|css|label|text|titel|rename|umbenennen") { return "DIRECT_EDIT" }
    if ($text -match "format|cursor|interop|save|speichern|editor") { return "BUGFIX_DIAGNOSTIC" }
    return "UNCERTAIN"
}

function Test-InvestigationRequired {
    param([string]$TaskText, [string]$TaskClass)
    if ($TaskClass -in @("INVESTIGATIVE", "BUGFIX_DIAGNOSTIC", "UNCERTAIN")) { return $true }
    return ($TaskText.ToLowerInvariant() -match "investig|root cause|check whether|warum|finde|suche")
}

function Get-PlanValidation {
    param([string]$Plan)
    $issues = [System.Collections.ArrayList]::new()
    $targets = [System.Collections.ArrayList]::new()
    $investigationFlag = $false

    if ($Plan -match "Freigabe bereit|approval pending|plan ready for approval") {
        [void]$issues.Add("Plan enthaelt UI-/Approval-Text.")
    }
    if ($Plan -notmatch "##\s*Ziel") { [void]$issues.Add("Abschnitt ## Ziel fehlt.") }
    if ($Plan -notmatch "##\s*Dateien") { [void]$issues.Add("Abschnitt ## Dateien fehlt.") }
    if ($Plan -notmatch "##\s*Reihenfolge") { [void]$issues.Add("Abschnitt ## Reihenfolge fehlt.") }
    if ($Plan -match "<relativer Pfad>|<Schritt>|<relevante Regeln") {
        [void]$issues.Add("Plan enthaelt Platzhalter aus dem Template.")
    }

    $nonEmpty = @($Plan -split "`n" | Where-Object { $_.Trim() -ne "" })
    if ($nonEmpty.Count -lt 10) { [void]$issues.Add("Plan ist zu kurz.") }

    $pathMatches = [regex]::Matches($Plan, "(?im)^\s*-\s*Pfad\s*:\s*(.+)$")
    foreach ($match in $pathMatches) {
        $value = $match.Groups[1].Value.Trim()
        if ($value -and $value -notmatch "^<" -and $value -match "(\\|/|\*|\.[A-Za-z0-9]{1,8}\b)") {
            [void]$targets.Add($value)
        }
    }
    if ($targets.Count -eq 0) {
        [void]$issues.Add("Plan benennt keine konkreten Datei- oder Suchziele.")
    }

    if ($Plan -match "(?im)investigationrequired\s*:\s*true|investigation required\s*:\s*true|unbekannt|erst pruefen|zuerst pruefen|root cause|analys") {
        $investigationFlag = $true
    }

    return [ordered]@{
        valid = ($issues.Count -eq 0)
        issues = @($issues)
        targets = @($targets | Select-Object -Unique)
        investigationRequired = $investigationFlag
    }
}

function Get-InvestigationVerdict {
    param([string]$Output)
    $result = "INCONCLUSIVE"
    if ($Output -match "(?im)^RESULT\s*:\s*(CHANGE_NEEDED|NO_CHANGE|INCONCLUSIVE)\s*$") {
        $result = $Matches[1].ToUpperInvariant()
    } elseif ($Output -match "keine aenderung|bereits implementiert") {
        $result = "NO_CHANGE"
    } elseif ($Output -match "zieldatei|ursache|aenderung noetig|change needed") {
        $result = "CHANGE_NEEDED"
    }

    $targetMatches = [regex]::Matches($Output, "(?im)^-\s+(.+)$")
    $targets = @($targetMatches | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
    return [ordered]@{
        result = $result
        targets = @($targets | Select-Object -Unique)
        summary = $Output.Trim()
    }
}

function Get-ImplementationOutcome {
    param([string]$Output)
    $category = "NO_CHANGE_UNCERTAIN"
    if ($Output -match "(?im)^RESULT\s*:\s*(CHANGE_APPLIED|NO_CHANGE_ALREADY_SATISFIED|NO_CHANGE_TARGET_NOT_FOUND|NO_CHANGE_BLOCKED|NO_CHANGE_UNCERTAIN)\s*$") {
        $category = $Matches[1].ToUpperInvariant()
    } elseif ($Output -match "already implemented|bereits implementiert") {
        $category = "NO_CHANGE_ALREADY_SATISFIED"
    } elseif ($Output -match "target not found|nicht gefunden") {
        $category = "NO_CHANGE_TARGET_NOT_FOUND"
    } elseif ($Output -match "blocked|kann nicht|unsicher") {
        $category = "NO_CHANGE_BLOCKED"
    }
    return [ordered]@{
        category = $category
        summary = $Output.Trim()
        hash = (Get-TextHash -Text $Output)
    }
}

function Get-ChangedFiles {
    $diffFiles = (Invoke-NativeCommand git @("diff", "--name-only", "HEAD")).output
    $untrackedFiles = (Invoke-NativeCommand git @("ls-files", "--others", "--exclude-standard")).output
    return @(($diffFiles + "`n" + $untrackedFiles) -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Unique)
}

function Reset-Worktree {
    Invoke-NativeCommand git @("checkout", "--", ".") | Out-Null
    Invoke-NativeCommand git @("clean", "-fd") | Out-Null
}

function Write-PipelineLog {
    param(
        [string]$RepoRoot,
        [string]$Task,
        [string]$Status,
        [string]$FinalCategory,
        [string[]]$FailureReasons,
        [string[]]$Files
    )
    $logDir = Join-Path $RepoRoot ".claude-develop-logs"
    $logFile = Join-Path $logDir "pipeline-history.jsonl"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $entry = [ordered]@{
        timestamp = (Get-Date -Format "o")
        taskName = $TaskName
        task = $Task
        status = $Status
        finalCategory = $FinalCategory
        attempts = ($attemptsByPhase.Values | Measure-Object -Sum).Sum
        attemptsByPhase = $attemptsByPhase
        failureReasons = @($FailureReasons)
        changedFiles = @($Files)
        artifacts = $artifactRunDir
    } | ConvertTo-Json -Compress -Depth 8
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
}

try {
    Write-Host "[VALIDATE] Pruefe Git-Status..."
    $r = Invoke-NativeCommand git @("rev-parse", "--is-inside-work-tree")
    if ($r.output -ne "true") {
        Write-ResultJson -status "ERROR" -finalCategory "VALIDATION_ERROR" -summary "Kein Git-Repository." -error "Kein Git-Repository" -phase "VALIDATE"
        exit 1
    }
    $r = Invoke-NativeCommand git @("status", "--porcelain")
    if ($r.output) {
        Write-ResultJson -status "ERROR" -finalCategory "DIRTY_WORKTREE" -summary "Working Tree ist nicht sauber." -error "Working Tree nicht sauber.`nSchmutzige Dateien:`n$($r.output)" -phase "VALIDATE"
        exit 1
    }
    if (-not (Test-Path $SolutionPath)) {
        Write-ResultJson -status "ERROR" -finalCategory "MISSING_SOLUTION" -summary "Solution wurde nicht gefunden." -error "Solution nicht gefunden: $SolutionPath" -phase "VALIDATE"
        exit 1
    }

    $currentPhase = "WORKTREE"
    Ensure-DebugDir | Out-Null
    $repoRoot = (Invoke-NativeCommand git @("rev-parse", "--show-toplevel")).output
    Ensure-ArtifactDir -Root $repoRoot | Out-Null
    Write-DebugManifest

    $taskPrompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    $taskLine = ($taskPrompt -split "`n" | Where-Object { $_ -notmatch "^\s*$|^##" } | Select-Object -First 1).Trim()
    $taskClass = Get-TaskClass -TaskText $taskPrompt
    $investigationRequired = Test-InvestigationRequired -TaskText $taskPrompt -TaskClass $taskClass
    Save-Artifact -Name "input-task.txt" -Content $taskPrompt | Out-Null
    Save-DebugText -Name "input-task.txt" -Content $taskPrompt | Out-Null
    Add-TimelineEvent -Phase "VALIDATE" -Message "Prompt eingelesen und Task klassifiziert." -Category $taskClass -Data @{ investigationRequired = $investigationRequired }

    $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
    $worktreePath = Join-Path $worktreeBase $TaskName
    if (-not (Test-Path $worktreeBase)) { New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null }
    Write-DebugManifest

    Write-Host "[WORKTREE] Erstelle $branchName..."
    $r = Invoke-NativeCommand git @("worktree", "add", $worktreePath, "-b", $branchName)
    if ($r.exitCode -ne 0) {
        Write-ResultJson -status "ERROR" -finalCategory "WORKTREE_ERROR" -summary "Worktree konnte nicht erstellt werden." -error $r.output -phase "WORKTREE"
        exit 1
    }

    $baseUri = [System.Uri]::new($repoRoot.TrimEnd("\") + "\")
    $targetUri = [System.Uri]::new($SolutionPath)
    $relSln = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
    $worktreeSln = Join-Path $worktreePath $relSln
    Write-DebugManifest

    Write-Host "[CONTEXT] Sammle Codebase-Kontext..."
    $codebaseContext = ""
    $claudeMdPath = Join-Path $repoRoot "CLAUDE.md"
    if (Test-Path $claudeMdPath) {
        $codebaseContext += "### CLAUDE.md:`n$([System.IO.File]::ReadAllText($claudeMdPath, [System.Text.Encoding]::UTF8))`n`n"
    }
    $slnListResult = Invoke-NativeCommand dotnet @("sln", $SolutionPath, "list")
    if ($slnListResult.exitCode -eq 0) {
        $codebaseContext += "### Projekte in Solution:`n$($slnListResult.output)`n`n"
    }
    $slnDir = Split-Path $SolutionPath -Parent
    $treeDirs = (Get-ChildItem -Path $slnDir -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Select-Object -First 50 | ForEach-Object { $_.FullName }) -join "`n"
    if ($treeDirs) {
        $codebaseContext += "### Verzeichnisstruktur (2 Ebenen):`n$treeDirs`n"
    }
    Save-Artifact -Name "context-summary.txt" -Content $codebaseContext | Out-Null
    Add-TimelineEvent -Phase "CONTEXT_SNAPSHOT" -Message "Codebase-Kontext erfasst." -Data @{ solution = $worktreeSln }

    $restoreJob = Start-Job -ScriptBlock {
        param($sln)
        & dotnet restore $sln 2>&1 | Out-String
    } -ArgumentList $worktreeSln

    Set-Location $worktreePath
    $effectiveModelPlan = Get-ModelForPlan -TaskClass $taskClass -Targets @()
    $effectiveModelImplement = $CONST_MODEL_IMPLEMENT
    $nugetRule = if ($AllowNuget) { "- Neue NuGet-Pakete erlaubt (nur wenn benoetigt)" } else { "- Keine neuen NuGet-Pakete" }

    $planValidation = $null
    $planOutput = ""
    $planTargets = @()
    $replanReason = ""
    $salvagedPlanTargets = @()
    for ($planAttempt = 1; $planAttempt -le $CONST_PLAN_ATTEMPTS; $planAttempt++) {
        $currentPhase = "PLAN"
        $attemptsByPhase.plan = $planAttempt
        $planVersion = $planAttempt
        Write-Host "[PLAN] Versuch $planAttempt/$CONST_PLAN_ATTEMPTS..."
        $replanBlock = if ($replanReason) { "`nKRITIK AM VORHERIGEN PLAN:`n$replanReason`n" } else { "" }
        $planPrompt = @"
Analysiere das Codebase und erstelle einen umsetzbaren Implementierungsplan.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln

TASK_CLASS: $taskClass
INVESTIGATION_REQUIRED_DEFAULT: $investigationRequired

CODEBASE KONTEXT:
$codebaseContext
$replanBlock
REGELN:
- Keine TODO/FIXME/HACK/Fix:/Note:/Hinweis(DE) Kommentare
- Kein throw new NotImplementedException()
- Max 1 Top-Level Typdeklaration pro Datei (nested/partial OK)
$nugetRule
- Kommentare auf Deutsch, minimal
- MessageService.ShowMessageBox statt MessageBox.Show
- Kein Dispatcher.Invoke/BeginInvoke wenn vermeidbar
- Wenn Ziel unklar ist: investigationRequired: true setzen und die Suchziele benennen

AUSGABEFORMAT:
## Ziel
Ein Satz.

## Dateien
Fuer jede relevante Datei oder Suchflaeche:
- Pfad: <konkreter relativer Pfad ODER Suchmuster>
- Aktion: ERSTELLEN | AENDERN | LOESCHEN | PRUEFEN
- Aenderungen: <konkrete erwartete Aenderung oder Untersuchung>

## Reihenfolge
1. <konkreter Schritt>
2. <konkreter Schritt>

## Einschraenkungen
- <konkretes Risiko>

investigationRequired: true|false
Schreibe NUR den Plan.
"@
        $effectiveModelPlan = Get-ModelForPlan -TaskClass $taskClass -Targets $planTargets
        $planResult = Invoke-ClaudePlan -Prompt $planPrompt -Model $effectiveModelPlan -Attempt $planAttempt
        if (-not $planResult.success) {
            $replanReason = "Planaufruf fehlgeschlagen: $($planResult.output)"
            Add-FeedbackEntry -Attempt $planAttempt -Source "PLAN" -Category "PLAN_CALL_FAILED" -Feedback $planResult.output
            Add-TimelineEvent -Phase "PLAN" -Message "Planaufruf fehlgeschlagen." -Category "PLAN_CALL_FAILED"
            continue
        }

        $planOutput = $planResult.output.Trim()
        Save-Artifact -Name "plan-v$planAttempt.txt" -Content $planOutput | Out-Null
        $planValidation = Get-PlanValidation -Plan $planOutput
        Save-JsonArtifact -Name "plan-v$planAttempt-validation.json" -Object $planValidation | Out-Null
        if ($planValidation.valid) {
            $planTargets = $planValidation.targets
            if ($planValidation.investigationRequired) { $investigationRequired = $true }
            Add-TimelineEvent -Phase "PLAN_VALIDATE" -Message "Plan akzeptiert." -Category "PLAN_VALID" -Data @{ targets = $planTargets; investigationRequired = $investigationRequired }
            break
        }

        $replanReason = ($planValidation.issues -join "`n")
        Add-FeedbackEntry -Attempt $planAttempt -Source "PLAN" -Category "PLAN_INSUFFICIENT" -Feedback $replanReason
        Add-TimelineEvent -Phase "PLAN_VALIDATE" -Message "Plan wurde verworfen." -Category "PLAN_INSUFFICIENT" -Data @{ issues = $planValidation.issues }
        $salvagedPlanTargets = Get-ActionableItems -Text $planOutput | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' }
        if ($salvagedPlanTargets.Count -gt 0) {
            $planTargets = @($salvagedPlanTargets | Select-Object -Unique)
            $planValidation.valid = $true
            Add-TimelineEvent -Phase "PLAN_VALIDATE" -Message "Plan via Salvage fortgesetzt." -Category "PLAN_SALVAGED" -Data @{ targets = $planTargets }
            break
        }

        for ($repairAttempt = 1; $repairAttempt -le $CONST_REPAIR_ATTEMPTS; $repairAttempt++) {
            $repairBlock = Get-RepairBlock -FailureCode "PLAN_MISSING_TARGETS" -Reasons $planValidation.issues -PreviousOutput $planOutput
            $repairPrompt = @"
$repairBlock

ERSTELLE JETZT EINEN KORRIGIERTEN PLAN FUER DENSELBEN TASK.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln

CODEBASE KONTEXT:
$codebaseContext

AUSGABEFORMAT:
## Ziel
Ein Satz.

## Dateien
- Pfad: <konkreter relativer Pfad ODER Suchmuster>
- Aktion: ERSTELLEN | AENDERN | LOESCHEN | PRUEFEN
- Aenderungen: <konkrete erwartete Aenderung oder Untersuchung>

## Reihenfolge
1. <konkreter Schritt>
2. <konkreter Schritt>

## Einschraenkungen
- <konkretes Risiko>

investigationRequired: true|false
"@
            $repairModel = Get-ModelForRepair -PhaseName "PLAN" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $planOutput -TaskText $taskPrompt
            $repairResult = Invoke-ClaudeRepair -PhaseName "PLAN" -Prompt $repairPrompt -Model $repairModel -Attempt (50 + $planAttempt * 10 + $repairAttempt)
            if (-not $repairResult.success) { continue }
            $planOutput = $repairResult.output.Trim()
            Save-Artifact -Name "plan-v$planAttempt-repair-$repairAttempt.txt" -Content $planOutput | Out-Null
            $planValidation = Get-PlanValidation -Plan $planOutput
            if ($planValidation.valid) {
                $planTargets = $planValidation.targets
                if ($planValidation.investigationRequired) { $investigationRequired = $true }
                Add-TimelineEvent -Phase "PLAN_VALIDATE" -Message "Plan nach Repair akzeptiert." -Category "PLAN_REPAIRED" -Data @{ targets = $planTargets }
                break
            }
            $salvagedPlanTargets = Get-ActionableItems -Text $planOutput | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' }
            if ($salvagedPlanTargets.Count -gt 0) {
                $planTargets = @($salvagedPlanTargets | Select-Object -Unique)
                $planValidation.valid = $true
                Add-TimelineEvent -Phase "PLAN_VALIDATE" -Message "Plan nach Repair salvaged." -Category "PLAN_SALVAGED" -Data @{ targets = $planTargets }
                break
            }
        }
        if ($planValidation.valid) { break }
    }

    Write-Host "[RESTORE] Warte auf dotnet restore..."
    Wait-Job $restoreJob -Timeout 120 | Out-Null
    $restoreOutput = Receive-Job $restoreJob -ErrorAction SilentlyContinue | Out-String
    Remove-Job $restoreJob -Force -ErrorAction SilentlyContinue
    Save-Artifact -Name "restore-output.txt" -Content $restoreOutput | Out-Null

    if ((-not $planValidation -or -not $planValidation.valid) -and $planTargets.Count -eq 0) {
        $investigationRequired = $true
        Add-TimelineEvent -Phase "PLAN_VALIDATE" -Message "Plan bleibt schwach; Pipeline wechselt in autonome Investigation-Fallback." -Category "PLAN_FALLBACK"
    }

    $investigationOutput = ""
    $investigationVerdict = [ordered]@{ result = "CHANGE_NEEDED"; targets = @(); summary = "" }
    $investigationHashes = [System.Collections.ArrayList]::new()
    if ($investigationRequired) {
        for ($investigateAttempt = 1; $investigateAttempt -le $CONST_INVESTIGATION_ATTEMPTS; $investigateAttempt++) {
            $currentPhase = "INVESTIGATE"
            $attemptsByPhase.investigate = $investigateAttempt
            Write-Host "[INVESTIGATE] Versuch $investigateAttempt/$CONST_INVESTIGATION_ATTEMPTS..."
            $historyText = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 2
            $investigatePrompt = @"
Untersuche den Task read-only und entscheide, ob eine Codeaenderung noetig ist.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln
TASK_CLASS: $taskClass

PLAN:
$planOutput

CODEBASE KONTEXT:
$codebaseContext

BISHERIGES FEEDBACK:
$historyText

AUSGABEFORMAT:
RESULT: CHANGE_NEEDED | NO_CHANGE | INCONCLUSIVE
TARGET_FILES:
- <konkreter Pfad oder Suchmuster>
ROOT_CAUSE:
<konkrete Analyse>
NEXT_ACTION:
<konkrete naechste Aenderung oder Begruendung>
"@
            $investigateModel = Get-ModelForInvestigate
            $investigateResult = Invoke-ClaudeInvestigate -Prompt $investigatePrompt -Model $investigateModel -Attempt $investigateAttempt
            if (-not $investigateResult.success) {
                Add-FeedbackEntry -Attempt $investigateAttempt -Source "INVESTIGATE" -Category "INVESTIGATION_CALL_FAILED" -Feedback $investigateResult.output
                continue
            }

            $investigationOutput = $investigateResult.output.Trim()
            Save-Artifact -Name "investigation-v$investigateAttempt.txt" -Content $investigationOutput | Out-Null
            $investigationVerdict = Get-InvestigationVerdict -Output $investigationOutput
            $investigationConclusion = $investigationVerdict.result
            [void]$investigationHashes.Add((Get-TextHash -Text $investigationOutput))
            Add-TimelineEvent -Phase "INVESTIGATE" -Message "Investigation-Ergebnis: $($investigationVerdict.result)" -Category $investigationVerdict.result -Data @{ targets = $investigationVerdict.targets }

            if ($investigationVerdict.result -eq "INCONCLUSIVE" -and (Test-HasActionableSignal -Text $investigationOutput)) {
                $investigationVerdict.result = "CHANGE_NEEDED"
                $investigationConclusion = "CHANGE_NEEDED_SALVAGED"
                $investigationVerdict.targets = @(Get-ActionableItems -Text $investigationOutput | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' } | Select-Object -Unique)
                Add-TimelineEvent -Phase "INVESTIGATE" -Message "Investigation wurde aus verwertbaren Hinweisen salvaged." -Category "CHANGE_NEEDED_SALVAGED" -Data @{ targets = $investigationVerdict.targets }
            }

            if ($investigationVerdict.result -eq "NO_CHANGE") {
                $verifyPrompt = @"
Pruefe die folgende Behauptung strikt read-only: Der Task ist bereits umgesetzt.

TASK:
$taskPrompt

INVESTIGATION:
$investigationOutput

ANTWORTE EXAKT:
RESULT: CONFIRMED | NOT_CONFIRMED
REASON:
<kurze Begruendung mit konkreten Dateien oder fehlenden Belegen>
"@
                $verifyResult = Invoke-ClaudeInvestigate -Prompt $verifyPrompt -Model (Get-ModelForInvestigate) -Attempt (80 + $investigateAttempt)
                if ($verifyResult.success -and $verifyResult.output -match '(?im)^RESULT\s*:\s*CONFIRMED\s*$') {
                    $finalStatus = "NO_CHANGE"
                    $finalCategory = "NO_CHANGE_ALREADY_SATISFIED"
                    $finalSummary = "Investigation ergab nach Verifikation, dass keine Codeaenderung noetig ist."
                    $finalFeedback = $investigationOutput
                    throw [System.Exception]::new("TERMINAL_NO_CHANGE")
                }
                Add-FeedbackEntry -Attempt $investigateAttempt -Source "INVESTIGATE" -Category "NO_CHANGE_NOT_CONFIRMED" -Feedback ($verifyResult.output)
                $investigationVerdict.result = "CHANGE_NEEDED"
                $investigationConclusion = "NO_CHANGE_REJECTED"
            }
            if ($investigationVerdict.result -eq "CHANGE_NEEDED") {
                if ($investigationVerdict.targets.Count -gt 0) {
                    $planTargets = @($planTargets + $investigationVerdict.targets | Select-Object -Unique)
                }
                break
            }

            Add-FeedbackEntry -Attempt $investigateAttempt -Source "INVESTIGATE" -Category "INVESTIGATION_INCONCLUSIVE" -Feedback $investigationOutput
            for ($repairAttempt = 1; $repairAttempt -le $CONST_REPAIR_ATTEMPTS; $repairAttempt++) {
                $repairBlock = Get-RepairBlock -FailureCode "INVESTIGATION_INCONCLUSIVE" -Reasons @("Dein Output war nicht eindeutig genug, um automatisch weiterzulaufen.") -PreviousOutput $investigationOutput
                $repairPrompt = @"
$repairBlock

LIEFERE JETZT EIN VERWERTBARES INVESTIGATION-ERGEBNIS.

TASK:
$taskPrompt

PLAN:
$planOutput

CODEBASE KONTEXT:
$codebaseContext

AUSGABEFORMAT:
RESULT: CHANGE_NEEDED | NO_CHANGE | INCONCLUSIVE
TARGET_FILES:
- <konkreter Pfad oder Suchmuster>
ROOT_CAUSE:
<konkrete Analyse>
NEXT_ACTION:
<konkrete naechste Aenderung oder Begruendung>
"@
                $repairModel = Get-ModelForRepair -PhaseName "INVESTIGATE" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $investigationOutput -TaskText $taskPrompt
                $repairResult = Invoke-ClaudeRepair -PhaseName "INVESTIGATE" -Prompt $repairPrompt -Model $repairModel -Attempt (90 + $investigateAttempt * 10 + $repairAttempt)
                if (-not $repairResult.success) { continue }
                $investigationOutput = $repairResult.output.Trim()
                Save-Artifact -Name "investigation-v$investigateAttempt-repair-$repairAttempt.txt" -Content $investigationOutput | Out-Null
                $investigationVerdict = Get-InvestigationVerdict -Output $investigationOutput
                if ($investigationVerdict.result -eq "INCONCLUSIVE" -and (Test-HasActionableSignal -Text $investigationOutput)) {
                    $investigationVerdict.result = "CHANGE_NEEDED"
                    $investigationConclusion = "CHANGE_NEEDED_SALVAGED"
                    $investigationVerdict.targets = @(Get-ActionableItems -Text $investigationOutput | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' } | Select-Object -Unique)
                }
                if ($investigationVerdict.result -eq "CHANGE_NEEDED") {
                    if ($investigationVerdict.targets.Count -gt 0) {
                        $planTargets = @($planTargets + $investigationVerdict.targets | Select-Object -Unique)
                    }
                    break
                }
            }
            if ($investigationVerdict.result -eq "CHANGE_NEEDED") { break }
            if ($investigationHashes.Count -ge 2) {
                $lastTwo = $investigationHashes | Select-Object -Last 2
                if (($lastTwo | Sort-Object -Unique).Count -eq 1 -and -not (Test-HasActionableSignal -Text $investigationOutput)) {
                    $finalStatus = "FAILED"
                    $finalCategory = "INVESTIGATION_INCONCLUSIVE"
                    $finalSummary = "Investigation blieb zweimal semantisch gleich und ergab keine neue Information."
                    $finalFeedback = $investigationOutput
                    throw [System.Exception]::new("TERMINAL_INVESTIGATION_INCONCLUSIVE")
                }
            }
        }

        if ($investigationVerdict.result -ne "CHANGE_NEEDED" -and -not (Test-HasActionableSignal -Text $investigationOutput)) {
            $finalStatus = "FAILED"
            $finalCategory = "INVESTIGATION_INCONCLUSIVE"
            $finalSummary = "Investigation konnte keinen belastbaren Aenderungspfad bestimmen."
            $finalFeedback = $investigationOutput
            throw [System.Exception]::new("TERMINAL_INVESTIGATION_INCONCLUSIVE")
        }
    }

    $implementationHistoryHashes = [System.Collections.ArrayList]::new()
    $accepted = $false
    $preflightScript = Join-Path $PSScriptRoot "preflight.ps1"
    $reviewerMd = Join-Path $PSScriptRoot "..\agents\reviewer.md"
    $reviewerContent = if (Test-Path $reviewerMd) { [System.IO.File]::ReadAllText($reviewerMd, [System.Text.Encoding]::UTF8) } else { "" }
    if ($reviewerContent -match "(?s)^---\r?\n.*?\r?\n---\r?\n(.*)$") {
        $reviewerContent = $Matches[1].TrimStart()
    }
    $lastImplementOutput = ""

    for ($implementAttempt = 1; $implementAttempt -le $CONST_IMPLEMENT_ATTEMPTS; $implementAttempt++) {
        $attemptsByPhase.implement = $implementAttempt
        $currentPhase = "IMPLEMENT"
        Reset-Worktree
        Write-Host "[IMPLEMENT] Versuch $implementAttempt/$CONST_IMPLEMENT_ATTEMPTS..."

        $historyText = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 4
        $targetText = if ($planTargets.Count -gt 0) { ($planTargets | ForEach-Object { "- $_" }) -join "`n" } else { "- keine expliziten Ziele aus Plan" }
        $investigationBlock = if ($investigationOutput) { $investigationOutput } else { "RESULT: CHANGE_NEEDED`nTARGET_FILES:`n$targetText" }
        $implPrompt = @"
Setze die Aenderung um. Du darfst nicht raten.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln
TASK_CLASS: $taskClass

VALIDIERTER PLAN:
$planOutput

INVESTIGATION:
$investigationBlock

ERLAUBTE ZIELDATEIEN ODER SUCHMUSTER:
$targetText

BISHERIGES FEEDBACK:
$historyText

REGELN:
- Aendere mindestens eine Repo-Datei ODER liefere ein maschinenlesbares NO_CHANGE-Ergebnis.
- Wenn du nichts aenderst, MUSST du einen RESULT-Marker verwenden.
- Oeffne nur Dateien, die fuer die Ziele relevant sind.
- Kommentare auf Deutsch, minimal.
- Keine TODO/FIXME/HACK/Fix:/Note:-Kommentare.
- Nach den Aenderungen: dotnet build $worktreeSln --no-restore, Fehler sofort beheben.

AUSGABEFORMAT AM ENDE:
RESULT: CHANGE_APPLIED | NO_CHANGE_ALREADY_SATISFIED | NO_CHANGE_TARGET_NOT_FOUND | NO_CHANGE_BLOCKED | NO_CHANGE_UNCERTAIN
SUMMARY:
<Kurze Begruendung>
"@
        $effectiveModelImplement = Get-ModelForImplement -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -TaskText $taskPrompt -PhaseContext $investigationBlock
        $implResult = Invoke-ClaudeImplement -Prompt $implPrompt -Model $effectiveModelImplement -Attempt $implementAttempt
        $lastImplementOutput = $implResult.output
        if (-not $implResult.success) {
            Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "NO_CHANGE_TOOL_FAILURE" -Feedback $implResult.output
            Add-TimelineEvent -Phase "IMPLEMENT" -Message "Implementierungsaufruf fehlgeschlagen." -Category "NO_CHANGE_TOOL_FAILURE"
            continue
        }

        $implOutcome = Get-ImplementationOutcome -Output $implResult.output
        [void]$implementationHistoryHashes.Add("$($implOutcome.category):$($implOutcome.hash)")
        $changedFiles = Get-ChangedFiles
        Save-Artifact -Name "implement-v$implementAttempt-changed-files.txt" -Content (($changedFiles -join "`n").Trim()) | Out-Null

        if ($changedFiles.Count -eq 0) {
            $lastNoChangeReason = $implOutcome.category
            Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "Keine Datei wurde geaendert." -Category $implOutcome.category
            Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category $implOutcome.category -Feedback $implResult.output

            if ($implOutcome.category -eq "NO_CHANGE_ALREADY_SATISFIED") {
                $verifyPrompt = @"
Pruefe strikt read-only, ob diese Aussage stimmt: Der Task ist bereits umgesetzt.

TASK:
$taskPrompt

IMPLEMENTIERUNGSANTWORT:
$($implResult.output)

ANTWORTE EXAKT:
RESULT: CONFIRMED | NOT_CONFIRMED
REASON:
<kurze Begruendung>
"@
                $verifyResult = Invoke-ClaudeInvestigate -Prompt $verifyPrompt -Model (Get-ModelForInvestigate) -Attempt (300 + $implementAttempt)
                if ($verifyResult.success -and $verifyResult.output -match '(?im)^RESULT\s*:\s*CONFIRMED\s*$') {
                    $finalStatus = "NO_CHANGE"
                    $finalCategory = "NO_CHANGE_ALREADY_SATISFIED"
                    $finalSummary = "Implementierung meldet nach Verifikation, dass der gewuenschte Zustand bereits erreicht ist."
                    $finalFeedback = $implResult.output
                    throw [System.Exception]::new("TERMINAL_NO_CHANGE")
                }
                Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "NO_CHANGE_NOT_CONFIRMED" -Feedback ($verifyResult.output)
            }

            $repairReasons = @()
            switch ($implOutcome.category) {
                "NO_CHANGE_TARGET_NOT_FOUND" { $repairReasons = @("Du hast das Ziel nicht gefunden.", "Nutze die vorhandenen Hinweise und suche gezielt in den genannten Dateien.") }
                "NO_CHANGE_BLOCKED" { $repairReasons = @("Du hast einen Blocker gemeldet.", "Erklaere den Blocker nicht nur, sondern setze die minimal moegliche Aenderung um oder liefere konkrete Suchtreffer.") }
                "NO_CHANGE_UNCERTAIN" { $repairReasons = @("Du warst unsicher.", "Unsicherheit ist kein Endzustand, wenn verwertbare Hinweise vorhanden sind.") }
                default { $repairReasons = @("Es wurden keine Dateien geaendert.", "Nutze die verwertbaren Hinweise aus deinem letzten Output.") }
            }
            if (Test-HasActionableSignal -Text $implResult.output) {
                $repairPrompt = @"
$(Get-RepairBlock -FailureCode $implOutcome.category -Reasons $repairReasons -PreviousOutput $implResult.output)

SETZE DEN TASK JETZT UM.

TASK:
$taskPrompt

VALIDIERTER PLAN:
$planOutput

INVESTIGATION:
$investigationBlock

ERLAUBTE ZIELDATEIEN:
$targetText

WICHTIG:
- Nutze die bereits genannten Dateien, Zeilen oder Ersetzungen.
- Liefere keine weitere vage Begruendung.
- Aendere mindestens eine Repo-Datei oder liefere ein klar begruendetes RESULT.
"@
                $repairModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $implResult.output -TaskText $taskPrompt
                $repairImplResult = Invoke-ClaudeRepair -PhaseName "IMPLEMENT" -Prompt $repairPrompt -Model $repairModel -Attempt (400 + $implementAttempt) -CanWrite
                if ($repairImplResult.success) {
                    $implResult = $repairImplResult
                    $implOutcome = Get-ImplementationOutcome -Output $implResult.output
                    $changedFiles = Get-ChangedFiles
                    if ($changedFiles.Count -gt 0) {
                        Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "Repair-Implementierung hat Dateien geaendert." -Category "CHANGE_APPLIED"
                    } else {
                        Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "IMPLEMENT_REPAIR_NO_CHANGE" -Feedback $implResult.output
                    }
                }
            }
            if ($changedFiles.Count -gt 0) {
                Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "$($changedFiles.Count) Datei(en) geaendert." -Category "CHANGE_APPLIED" -Data @{ files = $changedFiles }
            } else {
            if ($implementationHistoryHashes.Count -ge 2) {
                $lastTwo = $implementationHistoryHashes | Select-Object -Last 2
                if (($lastTwo | Sort-Object -Unique).Count -eq 1) {
                    $finalStatus = "FAILED"
                    $finalCategory = $implOutcome.category
                    $finalSummary = "Zwei identische No-Change-Ergebnisse ohne neue Information; weiterer Retry waere blind."
                    $finalFeedback = $implResult.output
                    throw [System.Exception]::new("TERMINAL_NO_CHANGE_REPEAT")
                }
            }
                continue
            }
        }

        Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "$($changedFiles.Count) Datei(en) geaendert." -Category "CHANGE_APPLIED" -Data @{ files = $changedFiles }
        $reviewCycle = 0
        while ($reviewCycle -le $CONST_REMEDIATION_ATTEMPTS) {
            $cycleLabel = "i$implementAttempt-r$reviewCycle"
            $currentPhase = "PREFLIGHT"
            Write-Host "[PREFLIGHT] Zyklus $cycleLabel..."
            $pfArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScript, "-SolutionPath", $worktreeSln)
            $preflightDebugDir = Join-Path (Ensure-DebugDir) "preflight\$cycleLabel"
            $pfArgs += @("-DebugDir", $preflightDebugDir)
            if ($SkipRun) { $pfArgs += "-SkipRun" }
            if ($AllowNuget) { $pfArgs += "-AllowNuget" }
            $preflightJson = & powershell.exe @pfArgs 2>&1 | Out-String
            Save-Artifact -Name "preflight-$cycleLabel.json" -Content $preflightJson | Out-Null
            Save-DebugText -Name "preflight-output.json" -Content $preflightJson -Subdir "preflight\$cycleLabel" | Out-Null
            try {
                $preflight = $preflightJson | ConvertFrom-Json
            } catch {
                Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "PREFLIGHT" -Category "PREFLIGHT_PARSE_ERROR" -Feedback $preflightJson
                $reviewCycle++
                $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)
                continue
            }

            if (-not $preflight.passed) {
                $blockerText = ($preflight.blockers | ForEach-Object {
                    $entry = "- [$($_.check)] $($_.file)"
                    if ($_.line) { $entry += " L$($_.line)" }
                    $entry += ": $($_.message)"
                    if ($_.suggestion) { $entry += " -> $($_.suggestion)" }
                    $entry
                }) -join "`n"
                Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "PREFLIGHT" -Category "PREFLIGHT_FAILED" -Feedback $blockerText
                Add-TimelineEvent -Phase "PREFLIGHT" -Message "Preflight fehlgeschlagen." -Category "PREFLIGHT_FAILED"
                if ($reviewCycle -ge $CONST_REMEDIATION_ATTEMPTS) {
                    $finalStatus = "FAILED"
                    $finalCategory = "PREFLIGHT_FAILED"
                    $finalSummary = "Preflight-Blocker konnten nicht innerhalb des Remediation-Budgets behoben werden."
                    $finalFeedback = $blockerText
                    throw [System.Exception]::new("TERMINAL_PREFLIGHT_FAILED")
                }
                $reviewCycle++
                $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)

                $fixPrompt = @"
Behebe ausschliesslich die folgenden deterministischen Blocker im bestehenden Worktree.

BLOCKER:
$blockerText

AUSGABEFORMAT AM ENDE:
RESULT: CHANGE_APPLIED | NO_CHANGE_BLOCKED
SUMMARY:
<Kurze Begruendung>
"@
                $preflightFixModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $blockerText -TaskText $taskPrompt
                $fixResult = Invoke-ClaudeImplement -Prompt $fixPrompt -Model $preflightFixModel -Attempt (100 + $implementAttempt * 10 + $reviewCycle)
                if (-not $fixResult.success) {
                    Add-FeedbackEntry -Attempt $reviewCycle -Source "REMEDIATE" -Category "NO_CHANGE_TOOL_FAILURE" -Feedback $fixResult.output
                }
                $changedFiles = Get-ChangedFiles
                continue
            }

            $warningText = if ($preflight.warnings -and $preflight.warnings.Count -gt 0) {
                ($preflight.warnings | ForEach-Object {
                    $entry = "- [$($_.check)] $($_.file)"
                    if ($_.line) { $entry += " L$($_.line)" }
                    $entry += ": $($_.message)"
                    $entry
                }) -join "`n"
            } else { "" }

            $currentPhase = "REVIEW"
            $attemptsByPhase.review = [Math]::Max($attemptsByPhase.review, $reviewCycle + 1)
            $diffForReview = (Invoke-NativeCommand git @("diff", "HEAD")).output
            Save-Artifact -Name "git-diff-$cycleLabel.patch" -Content $diffForReview | Out-Null
            $historyForReview = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 4
            $reviewPrompt = @"
$reviewerContent

---

PLAN (v$planVersion):
$planOutput

---

INVESTIGATION:
$investigationBlock

---

GIT DIFF DER AENDERUNGEN:
$diffForReview

---

URSPRUENGLICHER TASK:
$taskPrompt

---

PREFLIGHT WARNINGS:
$warningText

---

BISHERIGES FEEDBACK:
$historyForReview
"@
            $reviewResult = Invoke-ClaudeReview -Prompt $reviewPrompt -AttemptLabel $cycleLabel
            if (-not $reviewResult.success) {
                Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "REVIEW" -Category "REVIEW_CALL_FAILED" -Feedback $reviewResult.output
                $reviewCycle++
                $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)
                continue
            }

            $verdict = Get-ReviewVerdict -ReviewOutput $reviewResult.output
            Add-TimelineEvent -Phase "REVIEW" -Message "Review-Verdict: $($verdict.verdict)" -Category $verdict.severity
            if ($verdict.verdict -eq "ACCEPTED") {
                $finalVerdict = "ACCEPTED"
                $finalFeedback = $verdict.feedback
                $finalSeverity = ""
                $finalCategory = "ACCEPTED"
                $finalStatus = "ACCEPTED"
                $finalSummary = "Implementierung, Preflight und Review wurden erfolgreich abgeschlossen."
                $accepted = $true
                break
            }

            $finalSeverity = $verdict.severity
            $reviewFeedback = "REVIEW DENIED ($($verdict.severity)):`n$($verdict.feedback)"
            Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "REVIEW" -Category "REVIEW_DENIED_$($verdict.severity)" -Feedback $reviewFeedback
            if ($reviewCycle -ge $CONST_REMEDIATION_ATTEMPTS) {
                if ($verdict.severity -eq "MINOR" -and (Test-HasActionableSignal -Text $verdict.feedback)) {
                    $minorRescuePrompt = @"
$(Get-RepairBlock -FailureCode "REVIEW_DENIED_MINOR" -Reasons @("Das Review meldet nur kleinere, aber konkrete Probleme.") -PreviousOutput $verdict.feedback)

BEHEBE JETZT AUSSCHLIESSLICH DIESE MINOR-PUNKTE IM BESTEHENDEN WORKTREE.

FEEDBACK:
$($verdict.feedback)
"@
                    $minorRescueModel = Get-ModelForRepair -PhaseName "REVIEW_MINOR" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $verdict.feedback -TaskText $taskPrompt
                    $minorRescue = Invoke-ClaudeRepair -PhaseName "IMPLEMENT" -Prompt $minorRescuePrompt -Model $minorRescueModel -Attempt (500 + $implementAttempt * 10 + $reviewCycle) -CanWrite
                    if ($minorRescue.success) {
                        $changedFiles = Get-ChangedFiles
                        $reviewCycle = 0
                        continue
                    }
                }
                $finalStatus = "FAILED"
                $finalCategory = "REVIEW_DENIED_$($verdict.severity)"
                $finalSummary = "Review-Feedback konnte nicht innerhalb des Remediation-Budgets aufgeloest werden."
                $finalFeedback = $verdict.feedback
                throw [System.Exception]::new("TERMINAL_REVIEW_DENIED")
            }

            $reviewCycle++
            $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)
            $fixPrompt = @"
Behebe ausschliesslich das folgende Review-Feedback im bestehenden Worktree.

FEEDBACK:
$($verdict.feedback)

AUSGABEFORMAT AM ENDE:
RESULT: CHANGE_APPLIED | NO_CHANGE_BLOCKED
SUMMARY:
<Kurze Begruendung>
"@
            $reviewFixModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $verdict.feedback -TaskText $taskPrompt
            $fixResult = Invoke-ClaudeImplement -Prompt $fixPrompt -Model $reviewFixModel -Attempt (200 + $implementAttempt * 10 + $reviewCycle)
            if (-not $fixResult.success) {
                Add-FeedbackEntry -Attempt $reviewCycle -Source "REMEDIATE" -Category "NO_CHANGE_TOOL_FAILURE" -Feedback $fixResult.output
            }
            $changedFiles = Get-ChangedFiles
        }

        if ($accepted) { break }
    }

    if (-not $accepted -and -not $finalCategory) {
        $finalStatus = "FAILED"
        $finalCategory = if ($lastNoChangeReason) { $lastNoChangeReason } else { "NO_CHANGE_UNCERTAIN" }
        $finalSummary = "Implementierung erzeugte keine akzeptierten Aenderungen innerhalb des Budgets."
        $finalFeedback = if ($lastImplementOutput) { $lastImplementOutput } else { Format-FeedbackHistory -History $feedbackHistory }
    }

    Write-Host "[FINALIZE] $finalCategory"
    Set-Location $originalDir

    $failureReasons = @($feedbackHistory | ForEach-Object { $_.category } | Where-Object { $_ } | Select-Object -Unique)
    Write-TimelineArtifact
    Write-PipelineLog -RepoRoot $repoRoot -Task $taskLine -Status $finalStatus -FinalCategory $finalCategory -FailureReasons $failureReasons -Files $changedFiles

    if ($finalStatus -eq "ACCEPTED") {
        Invoke-NativeCommand git @("-C", $worktreePath, "add", "-A") | Out-Null
        Invoke-NativeCommand git @("-C", $worktreePath, "commit", "-m", "auto: $TaskName") | Out-Null
        Invoke-NativeCommand git @("worktree", "remove", $worktreePath) | Out-Null
        $worktreePath = $null
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -branch $branchName -files $changedFiles -verdict $finalVerdict -feedback $finalFeedback -severity $finalSeverity -phase "FINALIZE" -investigationConclusion $investigationConclusion
    } else {
        Invoke-NativeCommand git @("worktree", "remove", $worktreePath, "--force") | Out-Null
        Invoke-NativeCommand git @("branch", "-D", $branchName) | Out-Null
        $worktreePath = $null
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -branch "" -files $changedFiles -verdict $finalVerdict -feedback $finalFeedback -severity $finalSeverity -phase "FINALIZE" -investigationConclusion $investigationConclusion -noChangeReason $lastNoChangeReason
    }
} catch {
    Set-Location $originalDir -ErrorAction SilentlyContinue
    $errMsg = $_.Exception.Message
    if ($errMsg -match "^TERMINAL_") {
        if ($repoRoot) {
            $failureReasons = @($feedbackHistory | ForEach-Object { $_.category } | Where-Object { $_ } | Select-Object -Unique)
            Write-TimelineArtifact
            Write-PipelineLog -RepoRoot $repoRoot -Task $taskLine -Status $finalStatus -FinalCategory $finalCategory -FailureReasons $failureReasons -Files $changedFiles
        }
        if ($worktreePath -and (Test-Path $worktreePath -ErrorAction SilentlyContinue)) {
            Invoke-NativeCommand git @("worktree", "remove", $worktreePath, "--force") | Out-Null
            Invoke-NativeCommand git @("branch", "-D", $branchName) | Out-Null
            $worktreePath = $null
        }
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -branch "" -files $changedFiles -verdict $finalVerdict -feedback $finalFeedback -severity $finalSeverity -phase $currentPhase -investigationConclusion $investigationConclusion -noChangeReason $lastNoChangeReason
    } else {
        Write-Host "[ERROR] $errMsg"
        $finalStatus = "ERROR"
        $finalCategory = "UNEXPECTED_ERROR"
        $finalSummary = "Unerwarteter Fehler in Phase $currentPhase."
        $finalFeedback = $errMsg
        Write-TimelineArtifact
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -error "Unerwarteter Fehler in Phase $currentPhase`: $errMsg" -feedback $finalFeedback -phase $currentPhase -investigationConclusion $investigationConclusion
    }
} finally {
    Set-Location $originalDir -ErrorAction SilentlyContinue
    if ($worktreePath -and (Test-Path $worktreePath -ErrorAction SilentlyContinue)) {
        Invoke-NativeCommand git @("worktree", "remove", $worktreePath, "--force") | Out-Null
        Invoke-NativeCommand git @("branch", "-D", $branchName) | Out-Null
    }
}
