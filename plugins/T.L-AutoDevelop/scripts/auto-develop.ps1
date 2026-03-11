# auto-develop.ps1 -- Pipeline-Orchestrator: Plan -> Implement -> Preflight -> Review -> Retry
param(
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$TaskName = "develop-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [switch]$SkipRun,
    [switch]$AllowNuget
)

# --- Konstanten ---
$CONST_MODEL_PLAN       = "claude-opus-4-6"
$CONST_MODEL_IMPLEMENT  = "claude-opus-4-6"
$CONST_MODEL_REVIEW     = "claude-opus-4-6"
$CONST_MAX_RETRIES      = 6                    # Phase 4.2: reduziert von 10
$CONST_MAX_TURNS_PLAN   = 30
$CONST_MAX_TURNS_IMPL   = 30
$CONST_MAX_TURNS_REVIEW = 10
$CONST_TIMEOUT_SECONDS  = 900
$CONST_REPLAN_THRESHOLD = 3                    # Phase 4.1: Replan nach N Fehlversuchen

# Phase 6.3: Einfache-Task-Erkennung
$CONST_SIMPLE_KEYWORDS  = @("umbenennen","rename","typo","string","text","label","titel","title","kommentar","comment")
$CONST_MODEL_FAST       = "claude-sonnet-4-6"

$ErrorActionPreference = 'Stop'
$originalDir = Get-Location
$worktreePath = $null
$branchName = "auto/$TaskName"
$attempt = 0
$currentPhase = "VALIDATE"

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
        [string]$error = "",
        [string]$severity = "",
        [string]$phase = ""
    )
    $result = @{
        status   = $status
        phase    = $phase
        branch   = $branch
        files    = @($files)
        verdict  = $verdict
        feedback = $feedback
        attempts = $attempts
        error    = $error
        taskName = $TaskName
        severity = $severity
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
        try {
            $output = $promptContent | & $exe @allArgs 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } catch {
            $output = "JOB_EXCEPTION: $_"
            $exitCode = 99
        }
        # Exit-Code als erste Zeile schreiben, damit der Aufrufer ihn auslesen kann
        [System.IO.File]::WriteAllText($outFile, "$exitCode`n$output", [System.Text.Encoding]::UTF8)
    } -ArgumentList $claudeExe, $tempPromptFile, $extraArgs, $tempOutputFile, (Get-Location).Path

    $completed = Wait-Job $job -Timeout $timeoutSec
    if (-not $completed -or $job.State -eq 'Running') {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item $tempPromptFile -ErrorAction SilentlyContinue
        return @{ success = $false; output = "TIMEOUT nach $timeoutSec Sekunden"; timedOut = $true }
    }

    # Job-Fehler abfangen (z.B. exe nicht gefunden)
    $jobFailed = $job.State -eq 'Failed'
    $jobErrors = Receive-Job $job 2>&1 | Out-String
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $rawOutput = ""
    if (Test-Path $tempOutputFile) {
        $rawOutput = [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8)
        Remove-Item $tempOutputFile -ErrorAction SilentlyContinue
    }
    Remove-Item $tempPromptFile -ErrorAction SilentlyContinue

    if ($jobFailed) {
        return @{ success = $false; output = "JOB_FAILED: $jobErrors"; timedOut = $false }
    }

    # Erste Zeile = Exit-Code, Rest = eigentliche Ausgabe
    $lines = $rawOutput -split "`n", 2
    $exitCode = 0
    $output = $rawOutput
    if ($lines.Count -ge 2 -and $lines[0] -match '^\d+$') {
        $exitCode = [int]$lines[0]
        $output = $lines[1]
    }

    return @{ success = ($exitCode -eq 0); output = $output; timedOut = $false; exitCode = $exitCode }
}

function Invoke-ClaudePlan {
    param([string]$prompt, [string]$model = $CONST_MODEL_PLAN)
    return Invoke-ClaudeWithTimeout -prompt $prompt -extraArgs @(
        "--model", $model,
        "--permission-mode", "plan",
        "--max-turns", $CONST_MAX_TURNS_PLAN.ToString()
    )
}

function Invoke-ClaudeImplement {
    param([string]$prompt, [string]$model = $CONST_MODEL_IMPLEMENT)
    return Invoke-ClaudeWithTimeout -prompt $prompt -extraArgs @(
        "--model", $model,
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

# Phase 4.3: Reviewer-Schweregrade
function Get-ReviewVerdict {
    param([string]$reviewOutput)
    $lines = $reviewOutput -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($lines.Count -eq 0) { return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = "Leere Review-Antwort" } }

    $firstLine = $lines[0].Trim().ToUpper()
    $feedbackText = ($lines | Select-Object -Skip 1) -join "`n"

    if ($firstLine -match '^ACCEPTED\b') {
        return @{ verdict = "ACCEPTED"; severity = ""; feedback = $feedbackText }
    }
    # Phase 4.3: DENIED_MINOR, DENIED_MAJOR, DENIED_RETHINK parsen
    if ($firstLine -match '^DENIED_(MINOR|MAJOR|RETHINK)\b') {
        return @{ verdict = "DENIED"; severity = $Matches[1]; feedback = $feedbackText }
    }
    if ($firstLine -match '^DENIED\b') {
        return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = $feedbackText }
    }
    # Unklare Antwort = DENIED
    return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = "Reviewer-Antwort unklar (erste Zeile: '$($lines[0])')`n$reviewOutput" }
}

# Phase 3.1: Feedback-History formatieren
function Format-FeedbackHistory {
    param([System.Collections.ArrayList]$history, [int]$maxEntries = 0)
    if ($history.Count -eq 0) { return "" }
    $entries = if ($maxEntries -gt 0 -and $history.Count -gt $maxEntries) {
        $history | Select-Object -Last $maxEntries
    } else { $history }
    $parts = foreach ($entry in $entries) {
        "--- Versuch $($entry.attempt) [$($entry.source)] ---`n$($entry.feedback)"
    }
    return ($parts -join "`n`n")
}

# Phase 3.5: Progressive Strategie-Hinweise
function Get-StrategyHint {
    param([int]$attempt, [int]$max)
    switch ($attempt) {
        { $_ -le 3 } { return "Fokussiere auf die spezifischen Fehler aus dem Feedback." }
        { $_ -le 5 } { return "Vereinfache die Implementierung wenn moeglich. Weniger ist mehr." }
        default       { return "KRITISCH: Letzter Versuch. Implementiere nur das absolute Minimum." }
    }
}

# Phase 6.3: Einfache Tasks erkennen
function Test-SimpleTask {
    param([string]$taskText)
    $words = ($taskText -split '\s+').Count
    if ($words -gt 25) { return $false }
    foreach ($kw in $CONST_SIMPLE_KEYWORDS) {
        if ($taskText -imatch [regex]::Escape($kw)) { return $true }
    }
    return $false
}

# Phase 6.1: Pipeline-Log schreiben
function Write-PipelineLog {
    param(
        [string]$repoRoot,
        [string]$task,
        [string]$status,
        [int]$attempts,
        [string[]]$failureReasons,
        [string[]]$files
    )
    $logDir = Join-Path $repoRoot ".claude-develop-logs"
    $logFile = Join-Path $logDir "pipeline-history.jsonl"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $entry = @{
        timestamp      = (Get-Date -Format "o")
        taskName       = $TaskName
        task           = $task
        status         = $status
        attempts       = $attempts
        failureReasons = @($failureReasons)
        changedFiles   = @($files)
    } | ConvertTo-Json -Compress -Depth 3
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
}

# --- Hauptpipeline ---
try {
    # 1. VALIDATE
    Write-Host "[VALIDATE] Pruefe Git-Status..."
    $r = Invoke-NativeCommand git @("rev-parse","--is-inside-work-tree")
    $isGit = $r.output
    if ($isGit -ne "true") {
        Write-ResultJson -status "ERROR" -error "Kein Git-Repository" -phase "VALIDATE"
        exit 1
    }
    $r = Invoke-NativeCommand git @("status","--porcelain")
    $dirty = $r.output
    if ($dirty) {
        Write-ResultJson -status "ERROR" -phase "VALIDATE" -error "Working Tree nicht sauber.`nSchmutzige Dateien:`n$dirty`nBitte zuerst committen, stashen oder .gitignore anpassen."
        exit 1
    }
    if (-not (Test-Path $SolutionPath)) {
        Write-ResultJson -status "ERROR" -error "Solution nicht gefunden: $SolutionPath" -phase "VALIDATE"
        exit 1
    }

    # 2. WORKTREE ERSTELLEN
    $currentPhase = "WORKTREE"
    Write-Host "[WORKTREE] Erstelle $branchName..."
    $repoRoot = (Invoke-NativeCommand git @("rev-parse","--show-toplevel")).output
    $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
    $worktreePath = Join-Path $worktreeBase $TaskName
    if (-not (Test-Path $worktreeBase)) {
        New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null
    }

    # Phase 2.1: Codebase-Kontext sammeln (vor Worktree-Wechsel, aus Hauptrepo)
    Write-Host "[CONTEXT] Sammle Codebase-Kontext..."
    $codebaseContext = ""
    $claudeMdPath = Join-Path $repoRoot "CLAUDE.md"
    if (Test-Path $claudeMdPath) {
        $claudeMdContent = [System.IO.File]::ReadAllText($claudeMdPath, [System.Text.Encoding]::UTF8)
        $codebaseContext += "### CLAUDE.md:`n$claudeMdContent`n`n"
    }
    $slnListResult = Invoke-NativeCommand dotnet @("sln",$SolutionPath,"list")
    if ($slnListResult.exitCode -eq 0) {
        $codebaseContext += "### Projekte in Solution:`n$($slnListResult.output)`n`n"
    }
    $slnDir = Split-Path $SolutionPath -Parent
    $treeDirs = (Get-ChildItem -Path $slnDir -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Select-Object -First 50 | ForEach-Object { $_.FullName }) -join "`n"
    if ($treeDirs) {
        $codebaseContext += "### Verzeichnisstruktur (2 Ebenen):`n$treeDirs`n"
    }

    $r = Invoke-NativeCommand git @("worktree","add",$worktreePath,"-b",$branchName)
    if ($r.exitCode -ne 0) {
        Write-ResultJson -status "ERROR" -error "Worktree konnte nicht erstellt werden: $($r.output)" -phase "WORKTREE"
        exit 1
    }

    # Solution-Pfad im Worktree berechnen (PS 5.1 kompatibel, kein GetRelativePath)
    $baseUri = [System.Uri]::new($repoRoot.TrimEnd('\') + '\')
    $targetUri = [System.Uri]::new($SolutionPath)
    $relSln = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', '\')
    $worktreeSln = Join-Path $worktreePath $relSln

    # Phase 6.2: dotnet restore als Hintergrund-Job starten (parallel zum Plan)
    $restoreJob = Start-Job -ScriptBlock {
        param($sln)
        & dotnet restore $sln 2>&1 | Out-String
    } -ArgumentList $worktreeSln

    Set-Location $worktreePath
    Write-Host "[WORKTREE] OK: $worktreePath"

    # 3. PLAN (read-only, laeuft parallel mit restore)
    $currentPhase = "PLAN"
    Write-Host "[PLAN] Starte Plan-Phase (timeout: ${CONST_TIMEOUT_SECONDS}s)..."
    $taskPrompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    $taskLine = ($taskPrompt -split "`n" | Where-Object { $_ -notmatch '^\s*$|^##' } | Select-Object -First 1).Trim()
    Write-Host "[TASK] $taskLine"

    # Phase 6.3: Modell-Auswahl fuer einfache Tasks
    $isSimpleTask = Test-SimpleTask -taskText $taskPrompt
    $effectiveModelPlan = if ($isSimpleTask) { $CONST_MODEL_FAST } else { $CONST_MODEL_PLAN }
    $effectiveModelImpl = if ($isSimpleTask) { $CONST_MODEL_FAST } else { $CONST_MODEL_IMPLEMENT }
    if ($isSimpleTask) { Write-Host "[MODEL] Einfacher Task erkannt - verwende $CONST_MODEL_FAST" }

    # NuGet-Regel je nach AllowNuget-Parameter
    $nugetRegel = if ($AllowNuget) { "- Neue NuGet-Pakete erlaubt (nur wenn benoetigt)" } else { "$nugetRegel" }

    # Phase 1.1-1.4 + 2.1: Strukturierter Plan-Prompt mit Regeln, Format, Scope Guard, Kontext
    $planPrompt = @"
Analysiere das Codebase und erstelle einen Implementierungsplan.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln

CODEBASE KONTEXT:
$codebaseContext

REGELN (muessen im Plan beruecksichtigt werden):
- Keine TODO/FIXME/HACK/Fix:/Note:/Hinweis(DE) Kommentare
- Kein throw new NotImplementedException()
- Max 1 Top-Level Typdeklaration pro Datei (nested/partial OK)
$nugetRegel
- Kommentare auf Deutsch, minimal
- DialogService.ShowDialogHmdException() fuer Exceptions
- MessageService.ShowMessageBox statt MessageBox.Show
- Kein Dispatcher.Invoke/BeginInvoke wenn vermeidbar
- Max 3 catch-Bloecke pro Datei, Dateien unter 500 Zeilen

AUSGABEFORMAT (exakt einhalten):

## Ziel
Ein Satz der das Ziel beschreibt.

## Dateien
Fuer jede Datei:
- Pfad: <relativer Pfad>
- Aktion: ERSTELLEN | AENDERN | LOESCHEN
- Aenderungen: <konkrete Beschreibung>

## Reihenfolge
1. <Schritt>
2. <Schritt>
...

## Einschraenkungen
- <relevante Regeln/Risiken fuer diesen Task>

Schreibe NUR den Plan, implementiere NICHTS.
"@
    $planResult = Invoke-ClaudePlan -prompt $planPrompt -model $effectiveModelPlan
    if (-not $planResult.success) {
        $planErrLines = ($planResult.output -split "`n" | Select-Object -Last 20) -join "`n"
        Write-ResultJson -status "ERROR" -error "Plan-Phase fehlgeschlagen (letzte 20 Zeilen):`n$planErrLines" -phase "PLAN"
        exit 1
    }
    $planOutput = $planResult.output
    # Plan-Struktur prüfen: erwartete Abschnitte müssen vorhanden sein
    if ($planOutput -notmatch '##\s*Ziel' -or $planOutput -notmatch '##\s*Dateien') {
        $planErrLines = ($planOutput -split "`n" | Select-Object -Last 20) -join "`n"
        Write-ResultJson -status "ERROR" -error "Plan-Struktur ungueltig (## Ziel / ## Dateien fehlt). Letzte 20 Zeilen:`n$planErrLines" -phase "PLAN"
        exit 1
    }
    Write-Host "[PLAN] OK ($(($planOutput -split '\n').Count) Zeilen)"

    # Phase 6.2: Auf restore warten
    Write-Host "[RESTORE] Warte auf dotnet restore..."
    Wait-Job $restoreJob -Timeout 120 | Out-Null
    Receive-Job $restoreJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $restoreJob -Force -ErrorAction SilentlyContinue

    # Retry-Schleife: Implement -> Preflight -> Review
    $attempt = 0
    # Phase 3.1: $lastFeedback ersetzt durch $feedbackHistory
    $feedbackHistory = [System.Collections.ArrayList]::new()
    $finalVerdict = "FAILED"
    $finalFeedback = ""
    $finalSeverity = ""
    $changedFiles = @()
    $planVersion = 1
    # Phase 4.2: Feedback-Hashes fuer identische Fehler tracken
    $recentFeedbackHashes = [System.Collections.ArrayList]::new()

    while ($attempt -lt $CONST_MAX_RETRIES) {
        $attempt++
        $currentPhase = "IMPLEMENT"
        Write-Host "[IMPL] Versuch $attempt/$CONST_MAX_RETRIES (Plan v$planVersion)..."

        # Phase 4.1: Plan-Revision nach CONST_REPLAN_THRESHOLD Fehlversuchen
        if ($attempt -eq ($CONST_REPLAN_THRESHOLD + 1) -and $planVersion -eq 1) {
            Write-Host "[REPLAN] $CONST_REPLAN_THRESHOLD Fehlversuche - erstelle neuen Plan..."
            $historyText = Format-FeedbackHistory -history $feedbackHistory
            $replanPrompt = @"
Der vorherige Plan hat nach $CONST_REPLAN_THRESHOLD Versuchen nicht funktioniert. Erstelle einen NEUEN, vereinfachten Plan.

AUFGABE:
$taskPrompt

SOLUTION: $worktreeSln

CODEBASE KONTEXT:
$codebaseContext

BISHERIGE FEHLER:
$historyText

REGELN (muessen im Plan beruecksichtigt werden):
- Keine TODO/FIXME/HACK/Fix:/Note:/Hinweis(DE) Kommentare
- Kein throw new NotImplementedException()
- Max 1 Top-Level Typdeklaration pro Datei (nested/partial OK)
$nugetRegel
- Kommentare auf Deutsch, minimal
- DialogService.ShowDialogHmdException() fuer Exceptions
- MessageService.ShowMessageBox statt MessageBox.Show
- Kein Dispatcher.Invoke/BeginInvoke wenn vermeidbar
- Max 3 catch-Bloecke pro Datei, Dateien unter 500 Zeilen

Erstelle einen EINFACHEREN Plan der die bisherigen Fehler vermeidet.

AUSGABEFORMAT (exakt einhalten):

## Ziel
Ein Satz der das Ziel beschreibt.

## Dateien
Fuer jede Datei:
- Pfad: <relativer Pfad>
- Aktion: ERSTELLEN | AENDERN | LOESCHEN
- Aenderungen: <konkrete Beschreibung>

## Reihenfolge
1. <Schritt>
2. <Schritt>
...

## Einschraenkungen
- <relevante Regeln/Risiken fuer diesen Task>

Schreibe NUR den Plan, implementiere NICHTS.
"@
            # Worktree zuruecksetzen
            Invoke-NativeCommand git @("checkout","--",".") | Out-Null
            Invoke-NativeCommand git @("clean","-fd") | Out-Null

            $replanResult = Invoke-ClaudePlan -prompt $replanPrompt -model $effectiveModelPlan
            if ($replanResult.success) {
                $planOutput = $replanResult.output
                $planVersion = 2
                Write-Host "[REPLAN] OK - neuer Plan (v$planVersion)"
            } else {
                Write-Host "[REPLAN] Fehlgeschlagen - verwende alten Plan weiter"
            }
        }

        # 4. IMPLEMENT
        # Phase 1.3 + 1.5 + 2.2 + 3.1 + 3.2 + 3.5: Strukturiertes Feedback, Kontext, Build-Selbstpruefung
        $implPrompt = if ($attempt -eq 1) {
            @"
Implementiere den folgenden Plan. Arbeite in: $worktreeSln

CODEBASE KONTEXT:
$codebaseContext

PLAN:
$planOutput

WICHTIGE REGELN:
- Keine TODO/FIXME/HACK/Fix:/Note: Kommentare
- Kein throw new NotImplementedException()
- Max 1 Top-Level Typ pro Datei
- Kommentare auf Deutsch
- MessageService.ShowMessageBox statt MessageBox.Show
- Kein Dispatcher.Invoke wenn vermeidbar
- Max 3 catch-Bloecke pro Datei, Dateien unter 500 Zeilen

Implementiere alle Aenderungen. Halte dich exakt an den Plan.

Nach Abschluss aller Aenderungen: ``dotnet build $worktreeSln --no-restore``. Falls Build fehlschlaegt, sofort beheben.
"@
        } else {
            $historyText = Format-FeedbackHistory -history $feedbackHistory
            $strategyHint = Get-StrategyHint -attempt $attempt -max $CONST_MAX_RETRIES
            @"
Versuch $attempt/$CONST_MAX_RETRIES - $strategyHint

CODEBASE KONTEXT:
$codebaseContext

ORIGINALER PLAN (v$planVersion):
$planOutput

ALLE BISHERIGEN FEHLER:
$historyText

WICHTIGE REGELN:
- Keine TODO/FIXME/HACK/Fix:/Note: Kommentare
- Kein throw new NotImplementedException()
- Max 1 Top-Level Typ pro Datei
- Kommentare auf Deutsch
- MessageService.ShowMessageBox statt MessageBox.Show
- Kein Dispatcher.Invoke wenn vermeidbar
- Max 3 catch-Bloecke pro Datei, Dateien unter 500 Zeilen

Oeffne NUR die betroffenen Dateien. Behebe NUR die genannten Probleme.

Nach Abschluss: ``dotnet build $worktreeSln --no-restore``. Falls Build fehlschlaegt, sofort beheben.
"@
        }

        $implResult = Invoke-ClaudeImplement -prompt $implPrompt -model $effectiveModelImpl
        if (-not $implResult.success) {
            [void]$feedbackHistory.Add(@{
                attempt  = $attempt
                source   = "IMPL_FAIL"
                feedback = "Implementierung fehlgeschlagen: $($implResult.output)"
            })
            continue
        }

        # Geaenderte Dateien erfassen (inkl. neue, noch nicht getrackte Dateien)
        $diffFiles      = (Invoke-NativeCommand git @("diff","--name-only","HEAD")).output
        $untrackedFiles = (Invoke-NativeCommand git @("ls-files","--others","--exclude-standard")).output
        $changedFiles   = @(($diffFiles + "`n" + $untrackedFiles) -split "`n" | Where-Object { $_.Trim() -ne "" })
        if ($changedFiles.Count -eq 0) {
            $implOutSnippet = ($implResult.output -split "`n" | Select-Object -Last 30) -join "`n"
            Write-Host "[IMPL] LEER - keine Dateien geaendert"
            [void]$feedbackHistory.Add(@{
                attempt  = $attempt
                source   = "IMPL_FAIL"
                feedback = "Keine Dateien geaendert. Implementierung hat nichts produziert.`n`nClaude-Ausgabe (letzte 30 Zeilen):`n$implOutSnippet"
            })
            continue
        }
        Write-Host "[IMPL] OK - $($changedFiles.Count) Dateien"

        # 5. PREFLIGHT
        $currentPhase = "PREFLIGHT"
        Write-Host "[PREFLIGHT] Pruefe Build + Regeln..."
        $preflightScript = Join-Path $PSScriptRoot "preflight.ps1"
        $pfArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $preflightScript, "-SolutionPath", $worktreeSln)
        if ($SkipRun)    { $pfArgs += "-SkipRun" }
        if ($AllowNuget) { $pfArgs += "-AllowNuget" }
        $preflightJson = & powershell.exe @pfArgs 2>&1 | Out-String
        try {
            $preflight = $preflightJson | ConvertFrom-Json
        } catch {
            [void]$feedbackHistory.Add(@{
                attempt  = $attempt
                source   = "PARSE_ERROR"
                feedback = "Preflight-Ausgabe nicht parsbar: $preflightJson"
            })
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
            Write-Host "[PREFLIGHT] FAILED: $blockerText"

            [void]$feedbackHistory.Add(@{
                attempt  = $attempt
                source   = "PREFLIGHT"
                feedback = "PREFLIGHT FAILED:`n$blockerText"
            })

            # Phase 4.2: Sofort abbrechen bei nuget_audit (nicht behebbar) — ausser AllowNuget ist gesetzt
            $hasNugetBlocker = $preflight.blockers | Where-Object { $_.check -eq "nuget_audit" }
            if ($hasNugetBlocker -and -not $AllowNuget) {
                Write-Host "[PREFLIGHT] nuget_audit Blocker - nicht behebbar, breche ab"
                break
            }

            # Phase 4.2: Feedback-Hashes fuer identische Fehler tracken
            $feedbackHash = ($blockerText.GetHashCode()).ToString()
            [void]$recentFeedbackHashes.Add($feedbackHash)
            if ($recentFeedbackHashes.Count -ge 3) {
                $lastThree = $recentFeedbackHashes | Select-Object -Last 3
                if (($lastThree | Sort-Object -Unique).Count -eq 1) {
                    Write-Host "[PREFLIGHT] 3x identischer Fehler - breche ab"
                    break
                }
            }

            continue
        }
        Write-Host "[PREFLIGHT] OK"

        # Phase 3.4: Preflight-Warnings weiterleiten
        $warningText = ""
        if ($preflight.warnings -and $preflight.warnings.Count -gt 0) {
            $warningText = ($preflight.warnings | ForEach-Object {
                $entry = "- [$($_.check)] $($_.file)"
                if ($_.line) { $entry += " L$($_.line)" }
                $entry += ": $($_.message)"
                $entry
            }) -join "`n"
            Write-Host "[PREFLIGHT] Warnings: $($preflight.warnings.Count)"
        }

        # 6. REVIEW
        $currentPhase = "REVIEW"
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

        # Phase 4.4: Plan, Versuch-Kontext, Warnings, Feedback-History an Reviewer
        $truncatedPlan = if ($planOutput.Length -gt 2000) { $planOutput.Substring(0, 2000) + "`n[... gekuerzt]" } else { $planOutput }
        $historyForReview = Format-FeedbackHistory -history $feedbackHistory -maxEntries 3

        $reviewPrompt = @"
$reviewerContent

---

PLAN (v$planVersion):
$truncatedPlan

---

GIT DIFF DER AENDERUNGEN:
$diffForReview

---

URSPRUENGLICHER TASK:
$taskPrompt

---

VERSUCH: $attempt/$CONST_MAX_RETRIES
$(if ($warningText) { "PREFLIGHT WARNINGS:`n$warningText`n---" })
$(if ($historyForReview) { "BISHERIGES FEEDBACK:`n$historyForReview" })
"@
        $reviewResult = Invoke-ClaudeReview -prompt $reviewPrompt
        if (-not $reviewResult.success) {
            [void]$feedbackHistory.Add(@{
                attempt  = $attempt
                source   = "REVIEW"
                feedback = "Review fehlgeschlagen: $($reviewResult.output)"
            })
            continue
        }

        $verdict = Get-ReviewVerdict -reviewOutput $reviewResult.output
        $severityInfo = if ($verdict.severity) { " ($($verdict.severity))" } else { "" }
        Write-Host "[REVIEW] Verdict: $($verdict.verdict)$severityInfo"

        # 7. VERDICT
        if ($verdict.verdict -eq "ACCEPTED") {
            $finalVerdict = "ACCEPTED"
            $finalFeedback = $verdict.feedback
            break
        }

        # Phase 4.3: Schweregrad-basiertes Verhalten
        $deniedFeedback = "REVIEW DENIED ($($verdict.severity)):`n$($verdict.feedback)"
        [void]$feedbackHistory.Add(@{
            attempt  = $attempt
            source   = "REVIEW"
            feedback = $deniedFeedback
        })
        $finalFeedback = $verdict.feedback
        $finalSeverity = $verdict.severity

        # Phase 4.3: DENIED_RETHINK erzwingt sofortige Plan-Revision
        if ($verdict.severity -eq "RETHINK" -and $planVersion -eq 1) {
            Write-Host "[REVIEW] RETHINK - erzwinge sofortige Plan-Revision..."
            $attempt = $CONST_REPLAN_THRESHOLD  # Naechste Iteration loest Replan aus
        }

        # Phase 4.2: Review-Feedback-Hashes tracken
        $feedbackHash = ($verdict.feedback.GetHashCode()).ToString()
        [void]$recentFeedbackHashes.Add($feedbackHash)
        if ($recentFeedbackHashes.Count -ge 3) {
            $lastThree = $recentFeedbackHashes | Select-Object -Last 3
            if (($lastThree | Sort-Object -Unique).Count -eq 1) {
                Write-Host "[REVIEW] 3x identisches Feedback - breche ab"
                break
            }
        }
    }

    # 9. FINALIZE
    Write-Host "[FINALIZE] $finalVerdict nach $attempt Versuch(en)"
    Set-Location $originalDir

    # Phase 6.1: Pipeline-Log schreiben
    $failureReasons = @($feedbackHistory | ForEach-Object { $_.source }) | Sort-Object -Unique
    $logStatus = if ($finalVerdict -eq "ACCEPTED") { "ACCEPTED" } else { "FAILED" }
    Write-PipelineLog -repoRoot $repoRoot -task $taskLine -status $logStatus `
        -attempts $attempt -failureReasons $failureReasons -files $changedFiles

    if ($finalVerdict -eq "ACCEPTED") {
        Invoke-NativeCommand git @("-C",$worktreePath,"add","-A") | Out-Null
        Invoke-NativeCommand git @("-C",$worktreePath,"commit","-m","auto: $TaskName") | Out-Null
        Invoke-NativeCommand git @("worktree","remove",$worktreePath) | Out-Null
        $worktreePath = $null

        $currentPhase = "FINALIZE"
        Write-ResultJson -status "ACCEPTED" -branch $branchName -files $changedFiles `
            -verdict $finalVerdict -feedback $finalFeedback -attempts $attempt -severity $finalSeverity -phase "FINALIZE"
    } else {
        Invoke-NativeCommand git @("worktree","remove",$worktreePath,"--force") | Out-Null
        Invoke-NativeCommand git @("branch","-D",$branchName) | Out-Null
        $worktreePath = $null

        $allFeedback = Format-FeedbackHistory -history $feedbackHistory
        Write-ResultJson -status "FAILED" -branch "" -files $changedFiles `
            -verdict $finalVerdict -feedback "$allFeedback`n---`n$finalFeedback" -attempts $attempt -severity $finalSeverity -phase "FINALIZE"
    }

} catch {
    Set-Location $originalDir -ErrorAction SilentlyContinue
    $errMsg = $_.Exception.Message
    Write-Host "[ERROR] $errMsg"
    Write-ResultJson -status "ERROR" -error "Unerwarteter Fehler in Phase $currentPhase`: $errMsg" -attempts $attempt -phase $currentPhase
} finally {
    # Aufraumen bei unerwartetem Abbruch
    Set-Location $originalDir -ErrorAction SilentlyContinue
    if ($worktreePath -and (Test-Path $worktreePath -ErrorAction SilentlyContinue)) {
        Invoke-NativeCommand git @("worktree","remove",$worktreePath,"--force") | Out-Null
        Invoke-NativeCommand git @("branch","-D",$branchName) | Out-Null
    }
}
