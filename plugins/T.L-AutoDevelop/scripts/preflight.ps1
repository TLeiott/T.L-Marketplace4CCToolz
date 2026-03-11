# preflight.ps1 — Deterministische Code-Pruefungen fuer auto-develop Pipeline
param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [string[]]$ChangedFiles,
    [switch]$SkipRun,
    [switch]$AllowNuget,
    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)
    $output = & {
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1
    }
    return @{ output = ($output | Out-String).Trim(); exitCode = $LASTEXITCODE }
}

# Geaenderte Dateien ermitteln falls nicht uebergeben
if (-not $ChangedFiles -or $ChangedFiles.Count -eq 0) {
    $ChangedFiles = @((Invoke-NativeCommand git @("diff","--name-only","HEAD")).output -split "`n" | Where-Object { $_.Trim() -ne "" })
}

$blockers = [System.Collections.ArrayList]::new()
$warnings = [System.Collections.ArrayList]::new()

# Phase 3.3: Add-Blocker/Add-Warning mit optionalen line + suggestion Parametern
function Add-Blocker($check, $file, $message, [int]$line = 0, [string]$suggestion = "") {
    $entry = @{ check = $check; file = $file; message = $message }
    if ($line -gt 0) { $entry.line = $line }
    if ($suggestion) { $entry.suggestion = $suggestion }
    [void]$blockers.Add($entry)
}

function Add-Warning($check, $file, $message, [int]$line = 0, [string]$suggestion = "") {
    $entry = @{ check = $check; file = $file; message = $message }
    if ($line -gt 0) { $entry.line = $line }
    if ($suggestion) { $entry.suggestion = $suggestion }
    [void]$warnings.Add($entry)
}

# --- BLOCKER 1: Build ---
$buildOutput = dotnet build $SolutionPath --no-restore 2>&1
if ($LASTEXITCODE -ne 0) {
    $errLines = ($buildOutput | Select-String "error " | Select-Object -First 5) -join "`n"
    Add-Blocker "build" $SolutionPath "Build fehlgeschlagen: $errLines"
}

# Phase 5.4: Fruehes Return nach Build-Fehler — restliche Checks ueberspringen
if ($blockers.Count -gt 0 -and $blockers[0].check -eq "build") {
    $result = @{
        passed   = $false
        blockers = @($blockers)
        warnings = @($warnings)
    }
    $result | ConvertTo-Json -Depth 5
    return
}

# --- BLOCKER 2: Run startet ---
if (-not $SkipRun -and $ProjectPath -and (Test-Path $ProjectPath)) {
    $runProc = Start-Process dotnet -ArgumentList "run","--project",$ProjectPath,"--no-build" `
        -PassThru -NoNewWindow -RedirectStandardError "$env:TEMP\preflight-runerr.txt" 2>$null
    Start-Sleep -Seconds 5
    if ($runProc.HasExited -and $runProc.ExitCode -ne 0) {
        $runErr = Get-Content "$env:TEMP\preflight-runerr.txt" -ErrorAction SilentlyContinue | Select-Object -First 3
        $errText = ($runErr -join " ").Trim()
        if ($errText -notmatch "address already in use|port.*in use") {
            Add-Blocker "run_starts" $ProjectPath "Prozess beendet mit Code $($runProc.ExitCode): $errText"
        } else {
            Add-Warning "run_starts" $ProjectPath "Port belegt (parallel): $errText"
        }
    }
    if (-not $runProc.HasExited) {
        Stop-Process -Id $runProc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "$env:TEMP\preflight-runerr.txt" -ErrorAction SilentlyContinue
}

# Phase 5.1: dotnet test (nur wenn Test-Projekte vorhanden)
$slnDir = Split-Path $SolutionPath -Parent
$testProjects = @(Get-ChildItem -Path $slnDir -Recurse -Filter "*.csproj" -ErrorAction SilentlyContinue |
    Where-Object {
        $csprojContent = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $csprojContent -match 'Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest'
    })

if ($testProjects.Count -gt 0) {
    $testResult = Invoke-NativeCommand dotnet @("test",$SolutionPath,"--no-build","--verbosity","quiet")
    if ($testResult.exitCode -ne 0) {
        $failedTests = ($testResult.output -split "`n" | Select-String "Failed\s+" | Select-Object -First 5) -join "`n"
        if (-not $failedTests) { $failedTests = ($testResult.output -split "`n" | Select-Object -Last 5) -join "`n" }
        Add-Blocker "tests" $SolutionPath "Tests fehlgeschlagen: $failedTests"
    }
}

$changedCs = $ChangedFiles | Where-Object { $_ -match '\.cs$' -and (Test-Path $_) }
$changedCsproj = $ChangedFiles | Where-Object { $_ -match '\.csproj$' -and (Test-Path $_) }
# Phase 5.3: XAML-Dateien
$changedXaml = $ChangedFiles | Where-Object { $_ -match '\.xaml$' -and (Test-Path $_) }

foreach ($file in $changedCs) {
    try {
        $content = [System.IO.File]::ReadAllText((Resolve-Path $file).Path, [System.Text.Encoding]::UTF8)
    } catch { continue }
    if (-not $content) { continue }
    $lines = $content -split "`n"

    # --- BLOCKER 3: Verbotene Kommentare (Phase 3.3: mit Zeilennummern) ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -imatch '//\s*(Fix:|TODO|FIXME|HACK|Note:|Hinweis\s*\(DE\))') {
            $lineText = $lines[$i].Trim()
            if ($lineText.Length -gt 80) { $lineText = $lineText.Substring(0, 80) + "..." }
            Add-Blocker "forbidden_comments" $file "L$($i+1): $lineText" -line ($i+1) -suggestion "Kommentar entfernen oder umformulieren"
        }
    }

    # --- BLOCKER 4: Stub-Patterns (Phase 3.3: mit Zeilennummern) ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'throw\s+new\s+NotImplementedException\s*\(\s*\)') {
            Add-Blocker "stub_pattern" $file "L$($i+1): throw new NotImplementedException()" -line ($i+1) -suggestion "Implementierung vervollstaendigen"
        }
    }

    # --- BLOCKER 5: Klasse-pro-Datei (Phase 5.2: indentation-aware, distinct names) ---
    $typeMatches = @($lines | Select-String -Pattern '^\s{0,4}(public|internal|private|protected)?\s*(sealed|abstract|static|partial)?\s*(class|record|struct|interface)\s+(\w+)' -AllMatches)
    $typeNames = @($typeMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[4].Value } | Sort-Object -Unique)
    if ($typeNames.Count -gt 1) {
        Add-Blocker "class_per_file" $file "$($typeNames.Count) Top-Level Typen: $($typeNames -join ', ')" -suggestion "Jeden Typ in eigene Datei verschieben"
    }

    # --- WARNING 7: Try-Catch Spam ---
    $catchCount = ([regex]::Matches($content, '\bcatch\s*[\({]')).Count
    if ($catchCount -gt 3) {
        Add-Warning "try_catch_spam" $file "$catchCount catch-Bloecke" -suggestion "Fehlerbehandlung vereinfachen"
    }

    # --- WARNING 8: Datei zu lang ---
    if ($lines -and $lines.Count -gt 500) {
        Add-Warning "file_length" $file "$($lines.Count) Zeilen" -suggestion "Datei aufteilen"
    }

    # --- WARNING 9: Dispatcher-Nutzung ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Dispatcher\.(Invoke|BeginInvoke)') {
            Add-Warning "dispatcher_usage" $file "Dispatcher.Invoke/BeginInvoke" -line ($i+1) -suggestion "Dispatcher vermeiden"
            break  # nur einmal pro Datei warnen
        }
    }

    # --- WARNING 10: MessageBox Missbrauch ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'MessageBox\.Show' -and $content -notmatch 'MessageService') {
            Add-Warning "messagebox_misuse" $file "MessageBox.Show ohne MessageService" -line ($i+1) -suggestion "MessageService.ShowMessageBox verwenden"
            break
        }
    }

    # --- WARNING 11: Secret Patterns ---
    if ($content -match '(connectionstring|password|apikey|secret)\s*=\s*"[^"]{8,}"') {
        Add-Warning "secret_pattern" $file "Moeglicherweise hartcodierte Zugangsdaten"
    }
}

# --- BLOCKER 6: NuGet Audit (uebersprungen wenn AllowNuget gesetzt) ---
if (-not $AllowNuget) { foreach ($csproj in $changedCsproj) {
    $currentPkgs = (Select-String -Path $csproj -Pattern '<PackageReference\s+Include="([^"]+)"' -AllMatches).Matches |
        ForEach-Object { $_.Groups[1].Value }
    $basePkgs = @()
    try {
        $baseContent = (Invoke-NativeCommand git @("show","HEAD:$csproj")).output
        if ($baseContent) {
            $basePkgs = ($baseContent | Select-String -Pattern '<PackageReference\s+Include="([^"]+)"' -AllMatches).Matches |
                ForEach-Object { $_.Groups[1].Value }
        }
    } catch {}
    $newPkgs = $currentPkgs | Where-Object { $_ -notin $basePkgs }
    foreach ($pkg in $newPkgs) {
        Add-Blocker "nuget_audit" $csproj "Neues NuGet-Paket ohne Freigabe: $pkg" -suggestion "NuGet-Paket entfernen"
    }
} }  # Ende foreach + Ende if AllowNuget

# Phase 5.3: XAML-Validierung
foreach ($file in $changedXaml) {
    try {
        $xamlContent = [System.IO.File]::ReadAllText((Resolve-Path $file).Path, [System.Text.Encoding]::UTF8)
        [void][xml]$xamlContent
    } catch {
        $errMsg = $_.Exception.Message
        $xamlLine = 0
        if ($errMsg -match '(?:Zeile|[Ll]ine)\s+(\d+)') {
            $xamlLine = [int]$Matches[1]
        }
        Add-Blocker "xaml_parse" $file "XAML Parse-Fehler: $errMsg" -line $xamlLine
    }
}

# Ergebnis als JSON ausgeben
$result = @{
    passed   = ($blockers.Count -eq 0)
    blockers = @($blockers)
    warnings = @($warnings)
}
$result | ConvertTo-Json -Depth 5
