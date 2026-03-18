# preflight.ps1 -- Deterministic validation checks for the AutoDevelop pipeline
param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [string[]]$ChangedFiles,
    [switch]$SkipRun,
    [switch]$AllowNuget,
    [string]$ProjectPath,
    [string]$DebugDir
)

$ErrorActionPreference = 'Stop'

function Ensure-DebugDir {
    if (-not $DebugDir) { return $null }
    if (-not (Test-Path $DebugDir)) { New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null }
    return $DebugDir
}

function Save-DebugText {
    param([string]$Name, [string]$Content)
    $dir = Ensure-DebugDir
    if (-not $dir) { return $null }
    $path = Join-Path $dir $Name
    [System.IO.File]::WriteAllText($path, $Content, [System.Text.Encoding]::UTF8)
    return $path
}

function Save-DebugJson {
    param($Object, [string]$Name = 'preflight-summary.json')
    $json = $Object | ConvertTo-Json -Depth 8
    return Save-DebugText -Name $Name -Content $json
}

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)
    $output = & {
        $ErrorActionPreference = 'Continue'
        & $Command @Arguments 2>&1
    }
    return @{ output = ($output | Out-String).Trim(); exitCode = $LASTEXITCODE }
}

# Determine changed files when they are not provided explicitly
if (-not $ChangedFiles -or $ChangedFiles.Count -eq 0) {
    $ChangedFiles = @((Invoke-NativeCommand git @("diff","--name-only","HEAD")).output -split "`n" | Where-Object { $_.Trim() -ne "" })
}

$blockers = [System.Collections.ArrayList]::new()
$warnings = [System.Collections.ArrayList]::new()
$runSummary = [ordered]@{
    solutionPath = $SolutionPath
    projectPath = $ProjectPath
    debugDir = (Ensure-DebugDir)
    skipRun = [bool]$SkipRun
    allowNuget = [bool]$AllowNuget
    startedAt = (Get-Date).ToString('o')
}

if (-not (Test-Path -LiteralPath $SolutionPath -ErrorAction SilentlyContinue)) {
    $blocker = @{
        check = "environment"
        file = $SolutionPath
        message = "Solution path does not exist in the current worktree."
        suggestion = "Recreate the worktree and rerun the worker."
    }
    $result = @{
        passed = $false
        blockers = @($blocker)
        warnings = @()
        environmentFailure = $true
        environmentCategory = "SOLUTION_PATH_MISSING"
        environmentDetails = @{
            solutionPath = $SolutionPath
            solutionExists = $false
            currentDirectory = (Get-Location).Path
        }
    }
    $runSummary.completedAt = (Get-Date).ToString('o')
    $runSummary.passed = $false
    $runSummary.blockers = @($blocker)
    $runSummary.warnings = @()
    $runSummary.environmentFailure = $true
    $runSummary.environmentCategory = "SOLUTION_PATH_MISSING"
    Save-DebugJson -Object $runSummary | Out-Null
    $result | ConvertTo-Json -Depth 6
    return
}

# Add blocker and warning entries with optional line and suggestion metadata
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
$buildStarted = Get-Date
$buildOutput = dotnet build $SolutionPath --no-restore 2>&1
$buildExitCode = $LASTEXITCODE
$runSummary.build = [ordered]@{
    exitCode = $buildExitCode
    elapsedSeconds = [math]::Round(((Get-Date) - $buildStarted).TotalSeconds, 2)
}
Save-DebugText -Name 'build-output.txt' -Content (($buildOutput | Out-String).Trim()) | Out-Null
if ($buildExitCode -ne 0) {
    $errLines = ($buildOutput | Select-String "error " | Select-Object -First 5) -join "`n"
    Add-Blocker "build" $SolutionPath "Build failed: $errLines"
}

# Stop early after a build failure and skip the remaining checks
if ($blockers.Count -gt 0 -and $blockers[0].check -eq "build") {
    $result = @{
        passed   = $false
        blockers = @($blockers)
        warnings = @($warnings)
    }
    $runSummary.completedAt = (Get-Date).ToString('o')
    $runSummary.passed = $false
    $runSummary.blockers = @($blockers)
    $runSummary.warnings = @($warnings)
    Save-DebugJson -Object $runSummary | Out-Null
    $result | ConvertTo-Json -Depth 5
    return
}

# --- BLOCKER 2: Application starts ---
if (-not $SkipRun -and $ProjectPath -and (Test-Path $ProjectPath)) {
    $runStarted = Get-Date
    $runErrPath = if ($DebugDir) { Join-Path (Ensure-DebugDir) 'run-stderr.txt' } else { "$env:TEMP\preflight-runerr.txt" }
    $runOutPath = if ($DebugDir) { Join-Path (Ensure-DebugDir) 'run-stdout.txt' } else { "$env:TEMP\preflight-runout.txt" }
    $runProc = Start-Process dotnet -ArgumentList "run","--project",$ProjectPath,"--no-build" `
        -PassThru -NoNewWindow -RedirectStandardError $runErrPath -RedirectStandardOutput $runOutPath 2>$null
    Start-Sleep -Seconds 5
    $runErrText = (Get-Content $runErrPath -ErrorAction SilentlyContinue | Out-String).Trim()
    $runOutText = (Get-Content $runOutPath -ErrorAction SilentlyContinue | Out-String).Trim()
    $runSummary.run = [ordered]@{
        exitCode = if ($runProc.HasExited) { $runProc.ExitCode } else { $null }
        elapsedSeconds = [math]::Round(((Get-Date) - $runStarted).TotalSeconds, 2)
        hasExited = [bool]$runProc.HasExited
        stderrPath = $runErrPath
        stdoutPath = $runOutPath
    }
    if ($runProc.HasExited -and $runProc.ExitCode -ne 0) {
        $runErr = $runErrText -split "`r?`n" | Select-Object -First 3
        $errText = ($runErr -join " ").Trim()
        if ($errText -notmatch "address already in use|port.*in use") {
            Add-Blocker "run_starts" $ProjectPath "Process exited with code $($runProc.ExitCode): $errText"
        } else {
            Add-Warning "run_starts" $ProjectPath "Port already in use (parallel run): $errText"
        }
    }
    if (-not $runProc.HasExited) {
        Stop-Process -Id $runProc.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $DebugDir) {
        Remove-Item $runErrPath -ErrorAction SilentlyContinue
        Remove-Item $runOutPath -ErrorAction SilentlyContinue
    }
}

# Run dotnet test only when test projects are present
$slnDir = Split-Path $SolutionPath -Parent
$testProjects = @(Get-ChildItem -Path $slnDir -Recurse -Filter "*.csproj" -ErrorAction SilentlyContinue |
    Where-Object {
        $csprojContent = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
        $csprojContent -match 'Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest'
    })

if ($testProjects.Count -gt 0) {
    $testStarted = Get-Date
    $testResult = Invoke-NativeCommand dotnet @("test",$SolutionPath,"--no-build","--verbosity","quiet")
    $runSummary.tests = [ordered]@{
        exitCode = $testResult.exitCode
        elapsedSeconds = [math]::Round(((Get-Date) - $testStarted).TotalSeconds, 2)
        discoveredProjects = $testProjects.Count
    }
    Save-DebugText -Name 'test-output.txt' -Content $testResult.output | Out-Null
    if ($testResult.exitCode -ne 0) {
        $failedTests = ($testResult.output -split "`n" | Select-String "Failed\s+" | Select-Object -First 5) -join "`n"
        if (-not $failedTests) { $failedTests = ($testResult.output -split "`n" | Select-Object -Last 5) -join "`n" }
        Add-Blocker "tests" $SolutionPath "Tests failed: $failedTests"
    }
} else {
    $runSummary.tests = [ordered]@{
        skipped = $true
        discoveredProjects = 0
    }
}

$changedCs = $ChangedFiles | Where-Object { $_ -match '\.cs$' -and (Test-Path $_) }
$changedCsproj = $ChangedFiles | Where-Object { $_ -match '\.csproj$' -and (Test-Path $_) }
# XAML files
$changedXaml = $ChangedFiles | Where-Object { $_ -match '\.xaml$' -and (Test-Path $_) }

foreach ($file in $changedCs) {
    try {
        $content = [System.IO.File]::ReadAllText((Resolve-Path $file).Path, [System.Text.Encoding]::UTF8)
    } catch { continue }
    if (-not $content) { continue }
    $lines = $content -split "`n"

    # --- BLOCKER 3: Forbidden comments ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -imatch '//\s*(Fix:|TODO|FIXME|HACK|Note:|Hinweis\s*\(DE\))') {
            $lineText = $lines[$i].Trim()
            if ($lineText.Length -gt 80) { $lineText = $lineText.Substring(0, 80) + "..." }
            Add-Blocker "forbidden_comments" $file "L$($i+1): $lineText" -line ($i+1) -suggestion "Remove or rewrite the comment"
        }
    }

    # --- BLOCKER 4: Stub patterns ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'throw\s+new\s+NotImplementedException\s*\(\s*\)') {
            Add-Blocker "stub_pattern" $file "L$($i+1): throw new NotImplementedException()" -line ($i+1) -suggestion "Complete the implementation"
        }
    }

    # --- BLOCKER 5: One top-level type per file ---
    $typeMatches = @($lines | Select-String -Pattern '^\s{0,4}(public|internal|private|protected)?\s*(sealed|abstract|static|partial)?\s*(class|record|struct|interface)\s+(\w+)' -AllMatches)
    $typeNames = @($typeMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[4].Value } | Sort-Object -Unique)
    if ($typeNames.Count -gt 1) {
        Add-Blocker "class_per_file" $file "$($typeNames.Count) top-level types: $($typeNames -join ', ')" -suggestion "Move each type into its own file"
    }

    # --- WARNING 7: Too many catch blocks ---
    $catchCount = ([regex]::Matches($content, '\bcatch\s*[\({]')).Count
    if ($catchCount -gt 3) {
        Add-Warning "try_catch_spam" $file "$catchCount catch blocks" -suggestion "Simplify error handling"
    }

    # --- WARNING 8: File too long ---
    if ($lines -and $lines.Count -gt 500) {
        Add-Warning "file_length" $file "$($lines.Count) lines" -suggestion "Split the file"
    }

    # --- WARNING 9: Dispatcher usage ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Dispatcher\.(Invoke|BeginInvoke)') {
            Add-Warning "dispatcher_usage" $file "Dispatcher.Invoke/BeginInvoke" -line ($i+1) -suggestion "Avoid the dispatcher when possible"
            break
        }
    }

    # --- WARNING 10: MessageBox misuse ---
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'MessageBox\.Show' -and $content -notmatch 'MessageService') {
            Add-Warning "messagebox_misuse" $file "MessageBox.Show used without MessageService" -line ($i+1) -suggestion "Use MessageService.ShowMessageBox"
            break
        }
    }

    # --- WARNING 11: Secret patterns ---
    if ($content -match '(connectionstring|password|apikey|secret)\s*=\s*"[^"]{8,}"') {
        Add-Warning "secret_pattern" $file "Potential hard-coded credential"
    }
}

# --- BLOCKER 6: NuGet audit (skipped when AllowNuget is set) ---
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
        Add-Blocker "nuget_audit" $csproj "New NuGet package without approval: $pkg" -suggestion "Remove the NuGet package"
    }
} }  # Ende foreach + Ende if AllowNuget

# XAML validation
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
        Add-Blocker "xaml_parse" $file "XAML parse error: $errMsg" -line $xamlLine
    }
}

# Emit the result as JSON
$result = @{
    passed   = ($blockers.Count -eq 0)
    blockers = @($blockers)
    warnings = @($warnings)
}
$runSummary.completedAt = (Get-Date).ToString('o')
$runSummary.passed = $result.passed
$runSummary.blockers = @($blockers)
$runSummary.warnings = @($warnings)
$runSummary.changedFilesCount = @($ChangedFiles).Count
Save-DebugJson -Object $runSummary | Out-Null
$result | ConvertTo-Json -Depth 5
