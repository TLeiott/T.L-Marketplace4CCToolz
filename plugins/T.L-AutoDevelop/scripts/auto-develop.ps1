# auto-develop.ps1 -- Pipeline-Orchestrator: Plan -> Implement -> Preflight -> Review -> Retry
param(
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$TaskName = "develop-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [switch]$SkipRun
)

# --- Konstanten ---
$CONST_MODEL_PLAN       = "claude-opus-4-6"
$CONST_MODEL_IMPLEMENT  = "claude-opus-4-6"
$CONST_MODEL_REVIEW     = "claude-opus-4-6"
$CONST_MAX_RETRIES      = 10
$CONST_MAX_TURNS_PLAN   = 30
$CONST_MAX_TURNS_IMPL   = 30
$CONST_MAX_TURNS_REVIEW = 10
$CONST_TIMEOUT_SECONDS  = 900

$ErrorActionPreference = 'Stop'
$originalDir = Get-Location
$worktreePath = $null
$branchName = "auto/$TaskName"
$attempt = 0

# --- CLAUDECODE Guard entfernen ---
Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue

# --- Hilfsfunktionen ---

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)
    $output = & {
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1
    }
    return @{ output = ($output | Out-String).Trim(); exitCode = $LASTEXITCODE }
}

function Write-ResultJson {
    param(
        [string]$status,
        [string]$branch = "",
        [string[]]$files = @(),
        [string]$verdict = "",
        [string]$feedback = "",
        [int]$attempts = 0,
        [string]$error = ""
    )
    $result = @{
        status   = $status
        branch   = $branch
        files    = @($files)
        verdict  = $verdict
        feedback = $feedback
        attempts = $attempts
        error    = $error
        taskName = $TaskName
    } | ConvertTo-Json -Depth 5

    $resultDir = Split-Path $ResultFile -Parent
    if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($ResultFile, $result, [System.Text.Encoding]::UTF8)
}

function Invoke-ClaudeWithTimeout {
    param(
        [string]$prompt,
        [string[]]$extraArgs = @(),
        [int]$timeoutSec = $CONST_TIMEOUT_SECONDS
    )
    $tempPromptFile = Join-Path $env:TEMP "claude-develop\claude-input-$(New-Guid).md"
    $tempOutputFile = Join-Path $env:TEMP "claude-develop\claude-output-$(New-Guid).txt"
    $tempDir = Split-Path $tempPromptFile -Parent
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

    [System.IO.File]::WriteAllText($tempPromptFile, $prompt, [System.Text.Encoding]::UTF8)

    $claudeExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
    if (-not $claudeExe) { $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe" }

    $job = Start-Job -ScriptBlock {
        param($exe, $promptFile, $extraArgs, $outFile, $workDir)
        Set-Location $workDir
        Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
        $promptContent = [System.IO.File]::ReadAllText($promptFile, [System.Text.Encoding]::UTF8)
        $allArgs = @("-p") + $extraArgs
        $output = $promptContent | & $exe @allArgs 2>&1 | Out-String
        [System.IO.File]::WriteAllText($outFile, $output, [System.Text.Encoding]::UTF8)
    } -ArgumentList $claudeExe, $tempPromptFile, $extraArgs, $tempOutputFile, (Get-Location).Path

    $completed = Wait-Job $job -Timeout $timeoutSec
    if (-not $completed -or $job.State -eq 'Running') {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item $tempPromptFile -ErrorAction SilentlyContinue
        return @{ success = $false; output = "TIMEOUT nach $timeoutSec Sekunden"; timedOut = $true }
    }

    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $output = ""
    if (Test-Path $tempOutputFile) {
        $output = [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8)
        Remove-Item $tempOutputFile -ErrorAction SilentlyContinue
    }
    Remove-Item $tempPromptFile -ErrorAction SilentlyContinue

    return @{ success = $true; output = $output; timedOut = $false }
}

function Invoke-ClaudePlan {
    param([string]$prompt)
    return Invoke-ClaudeWithTimeout -prompt $prompt -extraArgs @(
        "--model", $CONST_MODEL_PLAN,
        "--permission-mode", "plan",
        "--max-turns", $CONST_MAX_TURNS_PLAN.ToString()
    )
}

function Invoke-ClaudeImplement {
    param([string]$prompt)
    return Invoke-ClaudeWithTimeout -prompt $prompt -extraArgs @(
        "--model", $CONST_MODEL_IMPLEMENT,
        "--dangerously-skip-permissions",
        "--allowedTools", "Read,Edit,Write,Bash,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_IMPL.ToString()
    ) -timeoutSec ($CONST_TIMEOUT_SECONDS * 2)
}

function Invoke-ClaudeReview {
    param([string]$prompt)
    return Invoke-ClaudeWithTimeout -prompt $prompt -extraArgs @(
        "--model", $CONST_MODEL_REVIEW,
        "--permission-mode", "plan",
        "--max-turns", $CONST_MAX_TURNS_REVIEW.ToString()
    )
}

function Get-ReviewVerdict {
    param([string]$reviewOutput)
    $lines = $reviewOutput -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($lines.Count -eq 0) { return @{ verdict = "DENIED"; feedback = "Leere Review-Antwort" } }

    $firstLine = $lines[0].Trim().ToUpper()
    if ($firstLine -match '^ACCEPTED\b') {
        return @{ verdict = "ACCEPTED"; feedback = ($lines | Select-Object -Skip 1) -join "`n" }
    }
    if ($firstLine -match '^DENIED\b') {
        return @{ verdict = "DENIED"; feedback = ($lines | Select-Object -Skip 1) -join "`n" }
    }
    # Unklare Antwort = DENIED
    return @{ verdict = "DENIED"; feedback = "Reviewer-Antwort unklar (erste Zeile: '$($lines[0])')`n$reviewOutput" }
}

# --- Hauptpipeline ---
try {
    # 1. VALIDATE
    Write-Host "[VALIDATE] Pruefe Git-Status..."
    $r = Invoke-NativeCommand git @("rev-parse","--is-inside-work-tree")
    $isGit = $r.output
    if ($isGit -ne "true") {
        Write-ResultJson -status "ERROR" -error "Kein Git-Repository"
        exit 1
    }
    $r = Invoke-NativeCommand git @("status","--porcelain")
    $dirty = $r.output
    if ($dirty) {
        Write-ResultJson -status "ERROR" -error "Working Tree nicht sauber. Bitte zuerst committen oder stashen."
        exit 1
    }
    if (-not (Test-Path $SolutionPath)) {
        Write-ResultJson -status "ERROR" -error "Solution nicht gefunden: $SolutionPath"
        exit 1
    }

    # 2. WORKTREE ERSTELLEN
    Write-Host "[WORKTREE] Erstelle $branchName..."
    $repoRoot = (Invoke-NativeCommand git @("rev-parse","--show-toplevel")).output
    $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
    $worktreePath = Join-Path $worktreeBase $TaskName
    if (-not (Test-Path $worktreeBase)) {
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
    }

    $r = Invoke-NativeCommand git @("worktree","add",$worktreePath,"-b",$branchName)
    if ($r.exitCode -ne 0) {
        Write-ResultJson -status "ERROR" -error "Worktree konnte nicht erstellt werden: $($r.output)"
        exit 1
    }
    Set-Location $worktreePath
    Write-Host "[WORKTREE] OK: $worktreePath"

    # Solution-Pfad im Worktree berechnen (PS 5.1 kompatibel, kein GetRelativePath)
    $baseUri = [System.Uri]::new($repoRoot.TrimEnd('\') + '\')
    $targetUri = [System.Uri]::new($SolutionPath)
    $relSln = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', '\')
    $worktreeSln = Join-Path $worktreePath $relSln

    Write-Host "[RESTORE] dotnet restore..."
    Invoke-NativeCommand dotnet @("restore",$worktreeSln) | Out-Null

    # 3. PLAN (read-only)
    Write-Host "[PLAN] Starte Plan-Phase (timeout: ${CONST_TIMEOUT_SECONDS}s)..."
    $taskPrompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    $taskLine = ($taskPrompt -split "`n" | Where-Object { $_ -notmatch '^\s*$|^##' } | Select-Object -First 1).Trim()
    Write-Host "[TASK] $taskLine"
    $planPrompt = @"
Analysiere das Codebase und erstelle einen Implementierungsplan.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln

Erstelle einen detaillierten, aber kompakten Plan. Schreibe NUR den Plan, implementiere NICHTS.
"@
    $planResult = Invoke-ClaudePlan -prompt $planPrompt
    if (-not $planResult.success) {
        Write-ResultJson -status "ERROR" -error "Plan-Phase fehlgeschlagen: $($planResult.output)"
        exit 1
    }
    $planOutput = $planResult.output
    Write-Host "[PLAN] OK ($(($planOutput -split '\n').Count) Zeilen)"

    # Retry-Schleife: Implement -> Preflight -> Review
    $attempt = 0
    $lastFeedback = ""
    $finalVerdict = "FAILED"
    $finalFeedback = ""
    $changedFiles = @()

    while ($attempt -lt $CONST_MAX_RETRIES) {
        $attempt++
        Write-Host "[IMPL] Versuch $attempt/$CONST_MAX_RETRIES..."

        # 4. IMPLEMENT
        $implPrompt = if ($attempt -eq 1) {
            @"
Implementiere den folgenden Plan. Arbeite in: $worktreeSln

PLAN:
$planOutput

Implementiere alle Aenderungen. Halte dich exakt an den Plan.
"@
        } else {
            $diffText = (Invoke-NativeCommand git @("diff","HEAD")).output
            @"
Vorheriger Versuch war fehlerhaft. Korrigiere die Implementierung.

ORIGINALER PLAN:
$planOutput

WAS BISHER GEAENDERT WURDE (git diff):
$diffText

FEEDBACK (Preflight/Review):
$lastFeedback

Behebe die genannten Probleme. Implementiere die Korrekturen.
"@
        }

        $implResult = Invoke-ClaudeImplement -prompt $implPrompt
        if (-not $implResult.success) {
            $lastFeedback = "Implementierung fehlgeschlagen: $($implResult.output)"
            continue
        }

        # Geaenderte Dateien erfassen
        $changedFiles = @((Invoke-NativeCommand git @("diff","--name-only","HEAD")).output -split "`n" | Where-Object { $_.Trim() -ne "" })
        Write-Host "[IMPL] OK - $($changedFiles.Count) Dateien"
        if ($changedFiles.Count -eq 0) {
            $lastFeedback = "Keine Dateien geaendert. Implementierung hat nichts produziert."
            continue
        }

        # 5. PREFLIGHT
        Write-Host "[PREFLIGHT] Pruefe Build + Regeln..."
        $preflightScript = Join-Path $PSScriptRoot "preflight.ps1"
        $pfArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScript, "-SolutionPath", $worktreeSln)
        if ($SkipRun) { $pfArgs += "-SkipRun" }
        $preflightJson = & powershell.exe @pfArgs 2>&1 | Out-String
        try {
            $preflight = $preflightJson | ConvertFrom-Json
        } catch {
            $lastFeedback = "Preflight-Ausgabe nicht parsbar: $preflightJson"
            continue
        }

        if (-not $preflight.passed) {
            $blockerText = ($preflight.blockers | ForEach-Object { "- [$($_.check)] $($_.file): $($_.message)" }) -join "`n"
            Write-Host "[PREFLIGHT] FAILED: $blockerText"
            $lastFeedback = "PREFLIGHT FAILED:`n$blockerText"
            continue
        }
        Write-Host "[PREFLIGHT] OK"

        # 6. REVIEW
        Write-Host "[REVIEW] Starte Code-Review..."
        $reviewerMd = Join-Path $PSScriptRoot "..\agents\reviewer.md"
        $reviewerContent = ""
        if (Test-Path $reviewerMd) {
            $raw = [System.IO.File]::ReadAllText($reviewerMd, [System.Text.Encoding]::UTF8)
            # YAML Frontmatter entfernen
            if ($raw -match '(?s)^---\r?\n.*?\r?\n---\r?\n(.*)$') {
                $reviewerContent = $Matches[1].TrimStart()
            } else { $reviewerContent = $raw }
        }

        $diffForReview = (Invoke-NativeCommand git @("diff","HEAD")).output
        $reviewPrompt = @"
$reviewerContent

---

GIT DIFF DER AENDERUNGEN:
$diffForReview

---

URSPRUENGLICHER TASK:
$taskPrompt
"@
        $reviewResult = Invoke-ClaudeReview -prompt $reviewPrompt
        if (-not $reviewResult.success) {
            $lastFeedback = "Review fehlgeschlagen: $($reviewResult.output)"
            continue
        }

        $verdict = Get-ReviewVerdict -reviewOutput $reviewResult.output
        Write-Host "[REVIEW] Verdict: $($verdict.verdict)"

        # 7. VERDICT
        if ($verdict.verdict -eq "ACCEPTED") {
            $finalVerdict = "ACCEPTED"
            $finalFeedback = $verdict.feedback
            break
        }

        # DENIED -> naechster Retry
        $lastFeedback = "REVIEW DENIED:`n$($verdict.feedback)"
        $finalFeedback = $verdict.feedback
    }

    # 9. FINALIZE
    Write-Host "[FINALIZE] $finalVerdict nach $attempt Versuch(en)"
    Set-Location $originalDir

    if ($finalVerdict -eq "ACCEPTED") {
        Invoke-NativeCommand git @("-C",$worktreePath,"add","-A") | Out-Null
        Invoke-NativeCommand git @("-C",$worktreePath,"commit","-m","auto: $TaskName") | Out-Null
        Invoke-NativeCommand git @("worktree","remove",$worktreePath) | Out-Null
        $worktreePath = $null

        Write-ResultJson -status "ACCEPTED" -branch $branchName -files $changedFiles `
            -verdict $finalVerdict -feedback $finalFeedback -attempts $attempt
    } else {
        Invoke-NativeCommand git @("worktree","remove",$worktreePath,"--force") | Out-Null
        Invoke-NativeCommand git @("branch","-D",$branchName) | Out-Null
        $worktreePath = $null

        Write-ResultJson -status "FAILED" -branch "" -files $changedFiles `
            -verdict $finalVerdict -feedback "$lastFeedback`n---`n$finalFeedback" -attempts $attempt
    }

} catch {
    Set-Location $originalDir -ErrorAction SilentlyContinue
    $errMsg = $_.Exception.Message
    Write-Host "[ERROR] $errMsg"
    Write-ResultJson -status "ERROR" -error "Unerwarteter Fehler: $errMsg" -attempts $attempt
} finally {
    # Aufraumen bei unerwartetem Abbruch
    Set-Location $originalDir -ErrorAction SilentlyContinue
    if ($worktreePath -and (Test-Path $worktreePath -ErrorAction SilentlyContinue)) {
        Invoke-NativeCommand git @("worktree","remove",$worktreePath,"--force") | Out-Null
        Invoke-NativeCommand git @("branch","-D",$branchName) | Out-Null
    }
}
