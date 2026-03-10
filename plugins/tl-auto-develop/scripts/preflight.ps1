# preflight.ps1 — Deterministische Code-Pruefungen fuer auto-develop Pipeline
param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [string[]]$ChangedFiles,
    [switch]$SkipRun,
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
    $ChangedFiles = (Invoke-NativeCommand git @("diff","--name-only","HEAD")).output -split "`n" | Where-Object { $_.Trim() -ne "" }
    if (-not $ChangedFiles) { $ChangedFiles = @() }
    if ($ChangedFiles -is [string]) { $ChangedFiles = @($ChangedFiles) }
}

$blockers = [System.Collections.ArrayList]::new()
$warnings = [System.Collections.ArrayList]::new()

function Add-Blocker($check, $file, $message) {
    [void]$blockers.Add(@{ check = $check; file = $file; message = $message })
}

function Add-Warning($check, $file, $message) {
    [void]$warnings.Add(@{ check = $check; file = $file; message = $message })
}

# --- BLOCKER 1: Build ---
$buildOutput = dotnet build $SolutionPath --no-restore 2>&1
if ($LASTEXITCODE -ne 0) {
    $errLines = ($buildOutput | Select-String "error " | Select-Object -First 5) -join "`n"
    Add-Blocker "build" $SolutionPath "Build fehlgeschlagen: $errLines"
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

$changedCs = $ChangedFiles | Where-Object { $_ -match '\.cs$' -and (Test-Path $_) }
$changedCsproj = $ChangedFiles | Where-Object { $_ -match '\.csproj$' -and (Test-Path $_) }

foreach ($file in $changedCs) {
    try {
        $content = [System.IO.File]::ReadAllText((Resolve-Path $file).Path, [System.Text.Encoding]::UTF8)
    } catch { continue }
    if (-not $content) { continue }
    $lines = $content -split "`n"

    # --- BLOCKER 3: Verbotene Kommentare ---
    if ($content -imatch '//\s*(Fix:|TODO|FIXME|HACK|Note:|Hinweis\s*\(DE\))') {
        Add-Blocker "forbidden_comments" $file "Verbotene Kommentare gefunden"
    }

    # --- BLOCKER 4: Stub-Patterns ---
    if ($content -match 'throw\s+new\s+NotImplementedException\s*\(\s*\)') {
        Add-Blocker "stub_pattern" $file "NotImplementedException gefunden"
    }

    # --- BLOCKER 5: Klasse-pro-Datei ---
    $typeDecls = ($content | Select-String -Pattern '^\s*(public|internal|private|protected)?\s*(sealed|abstract|static|partial)?\s*(class|record|struct|interface)\s+\w+' -AllMatches).Matches.Count
    if ($typeDecls -gt 1) {
        Add-Blocker "class_per_file" $file "$typeDecls Typdeklarationen in einer Datei"
    }

    # --- WARNING 7: Try-Catch Spam ---
    $catchCount = ([regex]::Matches($content, '\bcatch\s*[\({]')).Count
    if ($catchCount -gt 3) {
        Add-Warning "try_catch_spam" $file "$catchCount catch-Bloecke"
    }

    # --- WARNING 8: Datei zu lang ---
    if ($lines -and $lines.Count -gt 500) {
        Add-Warning "file_length" $file "$($lines.Count) Zeilen"
    }

    # --- WARNING 9: Dispatcher-Nutzung ---
    if ($content -match 'Dispatcher\.(Invoke|BeginInvoke)') {
        Add-Warning "dispatcher_usage" $file "Dispatcher.Invoke/BeginInvoke gefunden"
    }

    # --- WARNING 10: MessageBox Missbrauch ---
    if ($content -match 'MessageBox\.Show' -and $content -notmatch 'MessageService') {
        Add-Warning "messagebox_misuse" $file "MessageBox.Show ohne MessageService"
    }

    # --- WARNING 11: Secret Patterns ---
    if ($content -match '(connectionstring|password|apikey|secret)\s*=\s*"[^"]{8,}"' -or
        $content -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        # GUID-Format pruefen: nur warnen wenn es kein bekanntes Framework-GUID ist
        if ($content -match '(connectionstring|password|apikey|secret)\s*=\s*"[^"]{8,}"') {
            Add-Warning "secret_pattern" $file "Moeglicherweise hartcodierte Zugangsdaten"
        }
    }
}

# --- BLOCKER 6: NuGet Audit ---
foreach ($csproj in $changedCsproj) {
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
        Add-Blocker "nuget_audit" $csproj "Neues NuGet-Paket ohne Freigabe: $pkg"
    }
}

# Ergebnis als JSON ausgeben
$result = @{
    passed   = ($blockers.Count -eq 0)
    blockers = @($blockers)
    warnings = @($warnings)
}
$result | ConvertTo-Json -Depth 5
