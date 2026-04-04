#Requires -Version 5.1
<#
.SYNOPSIS
    T.L-Benchmark orchestrator — runs the benchmark suite against a CLI+model combo.
.DESCRIPTION
    Invokes the specified CLI for each benchmark, extracts solutions, evaluates them,
    and writes a detailed results JSON file.
.PARAMETER CliName
    CLI to benchmark: "claude" or "opencode"
.PARAMETER Model
    Model identifier (e.g. "opus", "sonnet", "anthropic/claude-sonnet-4-20250514")
.PARAMETER Mode
    "quick" (3 per category, 12 total) or "full" (all benchmarks)
.PARAMETER Executable
    Full path to the CLI executable
.PARAMETER ResultDir
    Directory to write results JSON
.PARAMETER TimeoutSec
    Per-benchmark timeout in seconds
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("claude", "opencode")]
    [string]$CliName,

    [Parameter(Mandatory)]
    [string]$Model,

    [ValidateSet("quick", "full")]
    [string]$Mode = "full",

    [Parameter(Mandatory)]
    [string]$Executable,

    [string]$ResultDir = "",

    [int]$TimeoutSec = 300,

    [int]$Parallel = 1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── Constants ──────────────────────────────────────────────────────────────────

$CONST_SCRIPT_DIR    = Split-Path -Parent $MyInvocation.MyCommand.Path
$CONST_DATA_DIR      = Join-Path $CONST_SCRIPT_DIR "data"
$CONST_QUICK_PER_CAT = 3
$CONST_SANDBOX_BASE  = Join-Path ([System.IO.Path]::GetTempPath()) "tl-benchmark-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"

if ([string]::IsNullOrWhiteSpace($ResultDir)) {
    $ResultDir = Join-Path (Join-Path $env:USERPROFILE ".claude") "benchmark-results"
}

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "FAIL"  { "Red" }
        "PROG"  { "White" }
        default { "Gray" }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Load-BenchmarkData {
    param([string]$Category, [string]$Language = "")
    $fileName = if ($Language) { "$Category-$Language.json" } else { "$Category.json" }
    $path = Join-Path $CONST_DATA_DIR $fileName
    if (-not (Test-Path $path)) {
        Write-Log "Benchmark data not found: $path" "FAIL"
        return @()
    }
    $raw = Get-Content $path -Raw | ConvertFrom-Json
    return @($raw.benchmarks)
}

function Select-Benchmarks {
    param([array]$Benchmarks, [int]$Count)
    if ($Count -ge $Benchmarks.Count) { return $Benchmarks }
    # Take evenly distributed subset
    $step = [Math]::Max(1, [Math]::Floor($Benchmarks.Count / $Count))
    $selected = @()
    for ($i = 0; $i -lt $Benchmarks.Count -and $selected.Count -lt $Count; $i += $step) {
        $selected += $Benchmarks[$i]
    }
    return $selected
}

# ── Code Extraction ────────────────────────────────────────────────────────────

function Extract-PythonCode {
    param([string]$Output, [string]$EntryPoint)
    
    # Strategy 1: Extract from ```python code blocks
    $pattern = '(?s)```(?:python|py)?\s*\n(.*?)```'
    $matches = [regex]::Matches($Output, $pattern)
    if ($matches.Count -gt 0) {
        foreach ($m in $matches) {
            $code = $m.Groups[1].Value.Trim()
            if ($code -match [regex]::Escape($EntryPoint)) {
                return $code
            }
        }
        # Return the largest code block if entry point not found in any
        $longest = ($matches | Sort-Object { $_.Groups[1].Value.Length } -Descending | Select-Object -First 1).Groups[1].Value.Trim()
        return $longest
    }
    
    # Strategy 2: Look for def entryPoint at line start
    $lines = $Output -split "`n"
    $codeLines = @()
    $inFunction = $false
    foreach ($line in $lines) {
        if ($line -match "^def\s+$([regex]::Escape($EntryPoint))") {
            $inFunction = $true
        }
        if ($inFunction) {
            $codeLines += $line
            # Stop when we hit a non-indented, non-empty line after the function started
            if ($codeLines.Count -gt 1 -and $line -match "^\S" -and $line.Trim() -ne "" -and $line -notmatch "^def\s+") {
                $codeLines = $codeLines[0..($codeLines.Count - 2)]
                break
            }
        }
    }
    if ($codeLines.Count -gt 0) {
        return ($codeLines -join "`n").Trim()
    }
    
    # Strategy 3: Return all text, hope it's pure code
    return $Output.Trim()
}

function Extract-CSharpCode {
    param([string]$Output, [string]$EntryPoint)
    
    # Strategy 1: Extract from ```csharp or ```cs code blocks
    $pattern = '(?s)```(?:csharp|cs)?\s*\n(.*?)```'
    $matches = [regex]::Matches($Output, $pattern)
    if ($matches.Count -gt 0) {
        foreach ($m in $matches) {
            $code = $m.Groups[1].Value.Trim()
            if ($code -match [regex]::Escape($EntryPoint)) {
                return $code
            }
        }
        $longest = ($matches | Sort-Object { $_.Groups[1].Value.Length } -Descending | Select-Object -First 1).Groups[1].Value.Trim()
        return $longest
    }
    
    # Strategy 2: Look for class Solution or method signature
    if ($Output -match "(?s)(public\s+static\s+class\s+Solution.*?}\s*})") {
        return $Matches[1].Trim()
    }
    
    return $Output.Trim()
}

function Extract-ShellCommands {
    param([string]$Output)
    
    # Strategy 1: Extract from ```bash or ```sh code blocks
    $pattern = '(?s)```(?:bash|sh|shell)?\s*\n(.*?)```'
    $matches = [regex]::Matches($Output, $pattern)
    if ($matches.Count -gt 0) {
        $allCommands = @()
        foreach ($m in $matches) {
            $block = $m.Groups[1].Value.Trim()
            # Filter out comment-only lines and empty lines
            $blockLines = @($block -split "`n" | Where-Object { $_.Trim() -ne "" -and $_.Trim() -notmatch "^\s*#" })
            $allCommands += $blockLines
        }
        return ($allCommands -join "`n").Trim()
    }
    
    # Strategy 2: Extract lines that look like commands (start with common commands)
    $cmdPattern = '^\s*(mkdir|touch|echo|cat|cp|mv|rm|ls|find|grep|sed|awk|tar|git|cd|chmod|python|dotnet|write|New-Item|Set-Content|Get-Content)\b'
    $lines = @($Output -split "`n" | Where-Object { $_ -match $cmdPattern })
    if ($lines.Count -gt 0) {
        return ($lines -join "`n").Trim()
    }
    
    return $Output.Trim()
}

function Merge-CSharpSources {
    param([string]$AiCode, [string]$TestCode)
    # Extract using statements from both sources, deduplicate, place at top
    $allLines = ("$AiCode`n$TestCode") -split "`n"
    $usings = @($allLines | Where-Object { $_ -match '^\s*using\s+' } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $codeNoUsings = (($AiCode -split "`n") | Where-Object { $_ -notmatch '^\s*using\s+' }) -join "`n"
    $testNoUsings = (($TestCode -split "`n") | Where-Object { $_ -notmatch '^\s*using\s+' }) -join "`n"
    return (($usings -join "`n") + "`n`n" + $codeNoUsings.Trim() + "`n`n" + $testNoUsings.Trim())
}

function Extract-Answer {
    param([string]$Output, [string]$AnswerType)
    
    # Strategy 1: Look for "ANSWER: <value>" pattern
    if ($Output -match "(?i)ANSWER:\s*(.+)") {
        $answer = $Matches[1].Trim()
        # Clean up common suffixes
        $answer = $answer -replace '\s*\([^)]*\)\s*$', ''
        $answer = $answer.TrimEnd('.', ',', '!')
        return $answer.Trim()
    }
    
    # Strategy 2: For number type, find the last number in the output
    if ($AnswerType -eq "number") {
        $numbers = [regex]::Matches($Output, '-?\d+(?:\.\d+)?')
        if ($numbers.Count -gt 0) {
            return $numbers[$numbers.Count - 1].Value
        }
    }
    
    # Strategy 3: For letter type, find a standalone A/B/C/D
    if ($AnswerType -eq "letter") {
        if ($Output -match '\b([A-D])\)') { return $Matches[1] }
        if ($Output -match '(?i)answer\s*(?:is|=|:)\s*([A-D])\b') { return $Matches[1] }
    }
    
    return ""
}

# ── CLI Invocation ─────────────────────────────────────────────────────────────

function Invoke-CliPrompt {
    param(
        [string]$Prompt,
        [string]$WorkDir,
        [int]$TimeoutSeconds
    )
    
    $tempPromptFile = Join-Path $WorkDir "prompt_$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $tempOutputFile = Join-Path $WorkDir "output_$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    
    [System.IO.File]::WriteAllText($tempPromptFile, $Prompt, [System.Text.Encoding]::UTF8)
    
    $result = [pscustomobject]@{
        success       = $false
        exitCode      = -1
        output        = ""
        timedOut      = $false
        durationSec   = 0
    }
    
    try {
        $startedAt = Get-Date
        
        $job = Start-Job -ScriptBlock {
            param($Exe, $CliKind, $ModelName, $PromptFile, $OutFile, $WorkDir)
            
            Set-Location $WorkDir
            
            $prompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
            
            try {
                if ($CliKind -eq "claude") {
                    $args = @("-p", "--model", $ModelName, "--max-turns", "8", "--dangerously-skip-permissions")
                    $output = $prompt | & $Exe @args 2>&1 | Out-String
                    $exitCode = $LASTEXITCODE
                }
                elseif ($CliKind -eq "opencode") {
                    $args = @("run", "--model", $ModelName, $prompt)
                    $output = & $Exe @args 2>&1 | Out-String
                    $exitCode = $LASTEXITCODE
                }
                else {
                    $output = "Unknown CLI: $CliKind"
                    $exitCode = 1
                }
            }
            catch {
                $output = "Exception: $($_.Exception.Message)"
                $exitCode = 1
            }
            
            if ($null -eq $exitCode) { $exitCode = 0 }
            [System.IO.File]::WriteAllText($OutFile, "$exitCode`n$output", [System.Text.Encoding]::UTF8)
            
        } -ArgumentList $Executable, $CliName, $Model, $tempPromptFile, $tempOutputFile, $WorkDir
        
        $completed = Wait-Job $job -Timeout $TimeoutSeconds
        
        if (-not $completed -or $job.State -eq "Running") {
            Stop-Job $job -ErrorAction SilentlyContinue
            $result.timedOut = $true
            $result.output = "TIMEOUT after $TimeoutSeconds seconds"
        }
        else {
            $result.exitCode = if ($job.State -eq "Completed") { 0 } else { 1 }
            
            if (Test-Path $tempOutputFile) {
                $rawOutput = [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8)
                $parts = $rawOutput -split "`n", 2
                if ($parts[0] -match '^\d+$') {
                    $result.exitCode = [int]$parts[0]
                    $result.output = if ($parts.Count -ge 2) { $parts[1].Trim() } else { "" }
                }
                else {
                    $result.output = $rawOutput.Trim()
                }
            }
            
            $result.success = ($result.exitCode -eq 0 -and $result.output.Length -gt 0)
        }
        
        $result.durationSec = ((Get-Date) - $startedAt).TotalSeconds
    }
    finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item $tempPromptFile -ErrorAction SilentlyContinue
        Remove-Item $tempOutputFile -ErrorAction SilentlyContinue
    }
    
    return $result
}

# ── Evaluation Functions ───────────────────────────────────────────────────────

function Evaluate-Coding {
    param(
        [object]$Benchmark,
        [string]$AiOutput,
        [string]$Language,
        [string]$WorkDir
    )
    
    $result = [pscustomobject]@{
        passed       = $false
        score        = 0
        maxScore     = $Benchmark.scoreValue
        testsPassed  = 0
        testsTotal   = 0
        extractedCode = ""
        error        = $null
    }
    
    try {
        if ($Language -eq "python") {
            $code = Extract-PythonCode -Output $AiOutput -EntryPoint $Benchmark.entryPoint
            $result.extractedCode = $code
            if ([string]::IsNullOrWhiteSpace($code)) {
                $result.error = "Could not extract Python code from output"
                return $result
            }
            
            $code = $code -replace "`r`n", "`n"  # Normalize CRLF to LF
            $testCodeClean = $Benchmark.testCode -replace "`r`n", "`n"
            $combinedCode = "$code`n`n$testCodeClean"
            $testFile = Join-Path $WorkDir "test.py"
            [System.IO.File]::WriteAllText($testFile, $combinedCode, [System.Text.Encoding]::UTF8)
            
            $stdoutFile = Join-Path $WorkDir "stdout.txt"
            $stderrFile = Join-Path $WorkDir "stderr.txt"
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c python `"$testFile`" > `"$stdoutFile`" 2> `"$stderrFile`"" `
                -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) } else { "" }

            if ($stdout -match "ALL TESTS PASSED") {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
                $result.testsPassed = 1
                $result.testsTotal = 1
            }
            else {
                $result.error = if ($stderr) { $stderr.Trim() } else { "Tests did not pass. Output: $($stdout.Trim())" }
                # Partial scoring: count assert statements
                $assertCount = ([regex]::Matches($Benchmark.testCode, 'assert\s')).Count
                $result.testsTotal = [Math]::Max(1, $assertCount)
            }
        }
        elseif ($Language -eq "csharp") {
            $code = Extract-CSharpCode -Output $AiOutput -EntryPoint $Benchmark.entryPoint
            $result.extractedCode = $code
            if ([string]::IsNullOrWhiteSpace($code)) {
                $result.error = "Could not extract C# code from output"
                return $result
            }
            
            # Build a complete C# program: using statements first, then classes
            $fullProgram = Merge-CSharpSources -AiCode $code -TestCode $Benchmark.testCode
            $csFile = Join-Path $WorkDir "Program.cs"
            $csprojFile = Join-Path $WorkDir "test.csproj"

            [System.IO.File]::WriteAllText($csFile, $fullProgram, [System.Text.Encoding]::UTF8)

            $csproj = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
  </PropertyGroup>
</Project>
"@
            [System.IO.File]::WriteAllText($csprojFile, $csproj, [System.Text.Encoding]::UTF8)

            $stdoutFile = Join-Path $WorkDir "stdout.txt"
            $stderrFile = Join-Path $WorkDir "stderr.txt"
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c dotnet run --project `"$csprojFile`" > `"$stdoutFile`" 2> `"$stderrFile`"" `
                -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) } else { "" }

            if ($stdout -match "ALL TESTS PASSED") {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
                $result.testsPassed = 1
                $result.testsTotal = 1
            }
            else {
                $result.error = if ($stderr) { $stderr.Trim() } else { "Tests did not pass. Output: $($stdout.Trim())" }
            }
        }
    }
    catch {
        $result.error = "Evaluation exception: $($_.Exception.Message)"
    }
    
    return $result
}

function Evaluate-BugTracing {
    param(
        [object]$Benchmark,
        [string]$AiOutput,
        [string]$Language,
        [string]$WorkDir
    )
    
    $result = [pscustomobject]@{
        passed       = $false
        score        = 0
        maxScore     = $Benchmark.scoreValue
        testsPassed  = 0
        testsTotal   = 1
        extractedCode = ""
        error        = $null
    }
    
    try {
        if ($Language -eq "python") {
            $code = Extract-PythonCode -Output $AiOutput -EntryPoint $Benchmark.entryPoint
            $result.extractedCode = $code
            if ([string]::IsNullOrWhiteSpace($code)) {
                $result.error = "Could not extract fixed Python code from output"
                return $result
            }
            
            $code = $code -replace "`r`n", "`n"  # Normalize CRLF to LF
            $testCodeClean = $Benchmark.testCode -replace "`r`n", "`n"
            $combinedCode = "$code`n`n$testCodeClean"
            $testFile = Join-Path $WorkDir "test_fix.py"
            [System.IO.File]::WriteAllText($testFile, $combinedCode, [System.Text.Encoding]::UTF8)
            
            $stdoutFile = Join-Path $WorkDir "stdout.txt"
            $stderrFile = Join-Path $WorkDir "stderr.txt"
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c python `"$testFile`" > `"$stdoutFile`" 2> `"$stderrFile`"" `
                -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) } else { "" }

            if ($stdout -match "ALL TESTS PASSED") {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
            }
            else {
                $result.error = if ($stderr) { $stderr.Trim() } else { "Fix verification failed: $($stdout.Trim())" }
            }
        }
        elseif ($Language -eq "csharp") {
            $code = Extract-CSharpCode -Output $AiOutput -EntryPoint $Benchmark.entryPoint
            $result.extractedCode = $code
            if ([string]::IsNullOrWhiteSpace($code)) {
                $result.error = "Could not extract fixed C# code from output"
                return $result
            }
            
            $fullProgram = Merge-CSharpSources -AiCode $code -TestCode $Benchmark.testCode
            $csFile = Join-Path $WorkDir "Program.cs"
            $csprojFile = Join-Path $WorkDir "test.csproj"

            [System.IO.File]::WriteAllText($csFile, $fullProgram, [System.Text.Encoding]::UTF8)
            $csproj = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
  </PropertyGroup>
</Project>
"@
            [System.IO.File]::WriteAllText($csprojFile, $csproj, [System.Text.Encoding]::UTF8)

            $stdoutFile = Join-Path $WorkDir "stdout.txt"
            $stderrFile = Join-Path $WorkDir "stderr.txt"
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c dotnet run --project `"$csprojFile`" > `"$stdoutFile`" 2> `"$stderrFile`"" `
                -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) } else { "" }

            if ($stdout -match "ALL TESTS PASSED") {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
            }
            else {
                $result.error = if ($stderr) { $stderr.Trim() } else { "Fix verification failed: $($stdout.Trim())" }
            }
        }
    }
    catch {
        $result.error = "Evaluation exception: $($_.Exception.Message)"
    }
    
    return $result
}

function Evaluate-Terminal {
    param(
        [object]$Benchmark,
        [string]$AiOutput,
        [string]$WorkDir
    )
    
    $result = [pscustomobject]@{
        passed       = $false
        score        = 0
        maxScore     = $Benchmark.scoreValue
        testsPassed  = 0
        testsTotal   = 1
        extractedCode = ""
        error        = $null
    }
    
    try {
        $commands = Extract-ShellCommands -Output $AiOutput
        $result.extractedCode = $commands
        
        if ([string]::IsNullOrWhiteSpace($commands)) {
            $result.error = "Could not extract shell commands from output"
            return $result
        }
        
        # Run the extracted commands in the sandbox
        $cmdFile = Join-Path $WorkDir "commands.sh"
        # Normalize to LF line endings so bash doesn't choke on \r
        $cmdContent = ("#!/bin/bash`nset -e`n$commands`n") -replace "`r`n", "`n" -replace "`r", "`n"
        [System.IO.File]::WriteAllBytes($cmdFile, [System.Text.Encoding]::UTF8.GetBytes($cmdContent))

        function Run-BashScript {
            param([string]$ScriptPath, [string]$WorkDirPath, [int]$TimeoutMs)
            $fileName = Split-Path -Leaf $ScriptPath
            $stdoutFile = Join-Path $WorkDirPath "bash_stdout.txt"
            $stderrFile = Join-Path $WorkDirPath "bash_stderr.txt"
            $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c bash ./$fileName > `"$stdoutFile`" 2> `"$stderrFile`"" `
                -WorkingDirectory $WorkDirPath -NoNewWindow -Wait -PassThru
            $stdout = if (Test-Path $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
            $stderr = if (Test-Path $stderrFile) { [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) } else { "" }
            # Clean up capture files to avoid collision between command and verify runs
            Remove-Item $stdoutFile -ErrorAction SilentlyContinue
            Remove-Item $stderrFile -ErrorAction SilentlyContinue
            return @{ exitCode = $proc.ExitCode; stdout = $stdout; stderr = $stderr }
        }

        $cmdResult = Run-BashScript -ScriptPath $cmdFile -WorkDirPath $WorkDir -TimeoutMs 60000

        if ($cmdResult.exitCode -eq -1) {
            $result.error = "Command execution timed out (60s)"
            return $result
        }

        # Now run the verification script
        if ($Benchmark.verificationScript) {
            $verifyFile = Join-Path $WorkDir "verify.sh"
            $verifyContent = ("#!/bin/bash`n$($Benchmark.verificationScript)`n") -replace "`r`n", "`n" -replace "`r", "`n"
            [System.IO.File]::WriteAllBytes($verifyFile, [System.Text.Encoding]::UTF8.GetBytes($verifyContent))
            
            $vResult = Run-BashScript -ScriptPath $verifyFile -WorkDirPath $WorkDir -TimeoutMs 30000
            
            if ($vResult.exitCode -eq 0) {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
            }
            else {
                $result.error = "Verification failed (exit $($vResult.exitCode)). $($vResult.stderr.Trim()) $($vResult.stdout.Trim())"
            }
        }
        else {
            if ($cmdResult.exitCode -eq 0) {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
            }
            else {
                $result.error = "Commands failed (exit $($cmdResult.exitCode)): $($cmdResult.stderr.Trim())"
            }
        }
    }
    catch {
        $result.error = "Evaluation exception: $($_.Exception.Message)"
    }
    
    return $result
}

function Evaluate-Intelligence {
    param(
        [object]$Benchmark,
        [string]$AiOutput
    )
    
    $result = [pscustomobject]@{
        passed       = $false
        score        = 0
        maxScore     = $Benchmark.scoreValue
        testsPassed  = 0
        testsTotal   = 1
        extractedCode = ""
        error        = $null
    }
    
    try {
        $extracted = Extract-Answer -Output $AiOutput -AnswerType $Benchmark.answerType
        $result.extractedCode = $extracted
        
        if ([string]::IsNullOrWhiteSpace($extracted)) {
            $result.error = "Could not extract answer from output"
            return $result
        }
        
        $expected = $Benchmark.expectedAnswer.ToString().Trim()
        $tolerance = if ($Benchmark.tolerance) { [double]$Benchmark.tolerance } else { 0 }
        
        if ($Benchmark.answerType -eq "number") {
            $extractedNum = 0.0
            $expectedNum = 0.0
            if ([double]::TryParse($extracted, [ref]$extractedNum) -and [double]::TryParse($expected, [ref]$expectedNum)) {
                if ([Math]::Abs($extractedNum - $expectedNum) -le $tolerance) {
                    $result.passed = $true
                    $result.score = $Benchmark.scoreValue
                }
                else {
                    $result.error = "Expected $expected, got $extracted (tolerance $tolerance)"
                }
            }
            else {
                $result.error = "Could not parse numbers: expected=$expected, got=$extracted"
            }
        }
        elseif ($Benchmark.answerType -eq "letter") {
            if ($extracted.ToUpper().Trim() -eq $expected.ToUpper().Trim()) {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
            }
            else {
                $result.error = "Expected '$expected', got '$extracted'"
            }
        }
        else {
            # word / multiword: case-insensitive compare
            if ($extracted.ToLower().Trim() -eq $expected.ToLower().Trim()) {
                $result.passed = $true
                $result.score = $Benchmark.scoreValue
            }
            else {
                $result.error = "Expected '$expected', got '$extracted'"
            }
        }
    }
    catch {
        $result.error = "Evaluation exception: $($_.Exception.Message)"
    }
    
    return $result
}

# ── Prompt Templates ───────────────────────────────────────────────────────────

function Build-CodingPrompt {
    param([object]$Benchmark, [string]$Language)
    $langLabel = if ($Language -eq "python") { "Python" } else { "C#" }
    return @"
You are a coding assistant. Solve this $langLabel programming problem.

$($Benchmark.prompt)

IMPORTANT: Return ONLY the code, inside a code block. No explanations, no test code, no main function — just the implementation.
"@
}

function Build-BugTracingPrompt {
    param([object]$Benchmark, [string]$Language)
    return @"
You are a debugging assistant. Find and fix the bug in this code.

$($Benchmark.prompt)

IMPORTANT: Return ONLY the corrected code, inside a code block. Do not include the original buggy code, tests, or explanations — just the fixed code.
"@
}

function Build-TerminalPrompt {
    param([object]$Benchmark)
    return @"
You are a terminal assistant. You are currently in a working directory. Execute the following task using shell commands.

$($Benchmark.prompt)

IMPORTANT: Return ONLY the shell commands inside a code block. No explanations. Commands will be executed directly.
"@
}

function Build-IntelligencePrompt {
    param([object]$Benchmark)
    return @"
$($Benchmark.prompt)

IMPORTANT: You MUST end your response with a line starting with "ANSWER: " followed by your answer. For example: "ANSWER: 42" or "ANSWER: B".
"@
}

# ── Main Flow ──────────────────────────────────────────────────────────────────

Write-Log "T.L-Benchmark starting" "INFO"
Write-Log "CLI: $CliName | Model: $Model | Mode: $Mode | Parallel: $Parallel" "INFO"
Write-Log "Executable: $Executable" "INFO"
Write-Log "Timeout per benchmark: ${TimeoutSec}s" "INFO"
Write-Log "Sandbox: $CONST_SANDBOX_BASE" "INFO"

# Verify executable exists
if (-not (Test-Path $Executable)) {
    $exeOnPath = (Get-Command $Executable -ErrorAction SilentlyContinue).Source
    if ($exeOnPath) {
        $Executable = $exeOnPath
        Write-Log "Found executable on PATH: $Executable" "OK"
    }
    else {
        Write-Log "Executable not found: $Executable" "FAIL"
        exit 1
    }
}

# Load all benchmark data
Write-Log "Loading benchmark data..." "INFO"
$allBenchmarks = @()

$codingPython = Load-BenchmarkData -Category "coding" -Language "python"
$codingCsharp = Load-BenchmarkData -Category "coding" -Language "csharp"
$bugPython = Load-BenchmarkData -Category "bug-tracing" -Language "python"
$bugCsharp = Load-BenchmarkData -Category "bug-tracing" -Language "csharp"
$terminal = Load-BenchmarkData -Category "terminal"
$intel = Load-BenchmarkData -Category "intelligence"
$advancedCsharp = Load-BenchmarkData -Category "advanced" -Language "csharp"

Write-Log "Loaded: coding-py=$($codingPython.Count) coding-cs=$($codingCsharp.Count) bug-py=$($bugPython.Count) bug-cs=$($bugCsharp.Count) terminal=$($terminal.Count) intel=$($intel.Count) adv-cs=$($advancedCsharp.Count)" "INFO"

# Select benchmarks based on mode
if ($Mode -eq "quick") {
    $codingPython = Select-Benchmarks -Benchmarks $codingPython -Count $CONST_QUICK_PER_CAT
    $codingCsharp = Select-Benchmarks -Benchmarks $codingCsharp -Count $CONST_QUICK_PER_CAT
    $bugPython = Select-Benchmarks -Benchmarks $bugPython -Count $CONST_QUICK_PER_CAT
    $bugCsharp = Select-Benchmarks -Benchmarks $bugCsharp -Count $CONST_QUICK_PER_CAT
    $terminal = Select-Benchmarks -Benchmarks $terminal -Count $CONST_QUICK_PER_CAT
    $intel = Select-Benchmarks -Benchmarks $intel -Count $CONST_QUICK_PER_CAT
    $advancedCsharp = Select-Benchmarks -Benchmarks $advancedCsharp -Count $CONST_QUICK_PER_CAT
}

# Build flat benchmark list with metadata
$benchmarkList = @()
foreach ($b in $codingPython) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "coding"; language = "python" } }
foreach ($b in $codingCsharp) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "coding"; language = "csharp" } }
foreach ($b in $bugPython) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "bug-tracing"; language = "python" } }
foreach ($b in $bugCsharp) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "bug-tracing"; language = "csharp" } }
foreach ($b in $terminal) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "terminal"; language = "shell" } }
foreach ($b in $intel) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "intelligence"; language = "text" } }
foreach ($b in $advancedCsharp) { $benchmarkList += [pscustomobject]@{ benchmark = $b; category = "advanced"; language = "csharp" } }

$totalBenchmarks = $benchmarkList.Count
Write-Log "Total benchmarks to run: $totalBenchmarks" "INFO"

# Create sandbox
Ensure-Dir $CONST_SANDBOX_BASE
Ensure-Dir $ResultDir

# ── Benchmark Runner Function ─────────────────────────────────────────────────

function Run-SingleBenchmark {
    param(
        [object]$Item,
        [string]$SandboxBase,
        [string]$ExePath,
        [string]$CliKind,
        [string]$ModelName,
        [int]$Timeout
    )

    $bm = $Item.benchmark
    $bmSandbox = Join-Path $SandboxBase $bm.id
    Ensure-Dir $bmSandbox
    $bmStart = Get-Date

    # Build prompt
    $prompt = ""
    if ($Item.category -eq "coding") {
        $langLabel = if ($Item.language -eq "python") { "Python" } else { "C#" }
        $prompt = "You are a coding assistant. Solve this $langLabel programming problem.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the code, inside a code block. No explanations, no test code, no main function - just the implementation."
    }
    elseif ($Item.category -eq "bug-tracing") {
        $prompt = "You are a debugging assistant. Find and fix the bug in this code.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the corrected code, inside a code block. Do not include the original buggy code, tests, or explanations - just the fixed code."
    }
    elseif ($Item.category -eq "terminal") {
        $prompt = "You are a terminal assistant. You are currently in a working directory. Execute the following task using shell commands.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the shell commands inside a code block. No explanations. Commands will be executed directly."
    }
    elseif ($Item.category -eq "intelligence") {
        $prompt = "$($bm.prompt)`n`nIMPORTANT: You MUST end your response with a line starting with `"ANSWER: `" followed by your answer. For example: `"ANSWER: 42`" or `"ANSWER: B`"."
    }
    elseif ($Item.category -eq "advanced") {
        $prompt = "You are an expert C# developer. Solve this advanced programming challenge.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the code, inside a code block. No explanations, no test code, no main function - just the implementation. The solution must be efficient and handle edge cases."
    }

    # Invoke CLI
    $cliResult = Invoke-CliPrompt -Prompt $prompt -WorkDir $bmSandbox -TimeoutSeconds $Timeout

    if ($cliResult.timedOut) {
        $evalResult = [pscustomobject]@{ passed = $false; score = 0; maxScore = $bm.scoreValue; testsPassed = 0; testsTotal = 1; extractedCode = ""; error = "CLI timed out after $Timeout seconds" }
    }
    elseif ([string]::IsNullOrWhiteSpace($cliResult.output)) {
        $evalResult = [pscustomobject]@{ passed = $false; score = 0; maxScore = $bm.scoreValue; testsPassed = 0; testsTotal = 1; extractedCode = ""; error = "CLI returned empty output (exit $($cliResult.exitCode))" }
    }
    else {
        if ($Item.category -eq "coding" -or $Item.category -eq "advanced") {
            $evalResult = Evaluate-Coding -Benchmark $bm -AiOutput $cliResult.output -Language $Item.language -WorkDir $bmSandbox
        }
        elseif ($Item.category -eq "bug-tracing") {
            $evalResult = Evaluate-BugTracing -Benchmark $bm -AiOutput $cliResult.output -Language $Item.language -WorkDir $bmSandbox
        }
        elseif ($Item.category -eq "terminal") {
            $evalResult = Evaluate-Terminal -Benchmark $bm -AiOutput $cliResult.output -WorkDir $bmSandbox
        }
        elseif ($Item.category -eq "intelligence") {
            $evalResult = Evaluate-Intelligence -Benchmark $bm -AiOutput $cliResult.output
        }
    }

    $bmDuration = ((Get-Date) - $bmStart).TotalSeconds

    $bmResult = [pscustomobject]@{
        id            = $bm.id
        category      = $Item.category
        name          = $bm.name
        difficulty    = $bm.difficulty
        language      = $Item.language
        score         = $evalResult.score
        maxScore      = $evalResult.maxScore
        passed        = $evalResult.passed
        testsPassed   = $evalResult.testsPassed
        testsTotal    = $evalResult.testsTotal
        durationSec   = [Math]::Round($bmDuration, 1)
        rawOutput     = $cliResult.output
        extractedCode = $evalResult.extractedCode
        error         = $evalResult.error
    }

    # Cleanup sandbox
    Remove-Item $bmSandbox -Recurse -Force -ErrorAction SilentlyContinue

    return $bmResult
}

# ── Run Benchmarks ────────────────────────────────────────────────────────────

$results = @()
$overallStart = Get-Date

if ($Parallel -le 1) {
    # ── Sequential execution ──────────────────────────────────────────────────
    $counter = 0
    foreach ($item in $benchmarkList) {
        $counter++
        $bm = $item.benchmark
        $pct = [Math]::Round(($counter / $totalBenchmarks) * 100)
        Write-Log "[$counter/$totalBenchmarks ($pct%)] $($bm.id): $($bm.name)" "PROG"

        $bmResult = Run-SingleBenchmark -Item $item -SandboxBase $CONST_SANDBOX_BASE -ExePath $Executable -CliKind $CliName -ModelName $Model -Timeout $TimeoutSec
        $results += $bmResult

        $status = if ($bmResult.passed) { "OK" } else { "FAIL" }
        $scoreStr = "$($bmResult.score)/$($bmResult.maxScore)"
        Write-Log "  -> $status ($scoreStr) in $([Math]::Round($bmResult.durationSec))s" $(if ($bmResult.passed) { "OK" } else { "FAIL" })
        if (-not $bmResult.passed -and $bmResult.error) {
            Write-Log "     Error: $($bmResult.error.Substring(0, [Math]::Min(120, $bmResult.error.Length)))" "WARN"
        }
    }
}
else {
    # ── Parallel execution ────────────────────────────────────────────────────
    Write-Log "Running $totalBenchmarks benchmarks with parallelism=$Parallel" "INFO"

    # Write helper functions to a temp file that jobs can dot-source
    # (InitializationScript is too large for Windows command line limit)
    $scriptPath = $MyInvocation.MyCommand.Path
    $scriptContent = Get-Content $scriptPath -Raw

    $funcMatch = [regex]::Match($scriptContent, '(?s)(# ── Helpers ──.*?)(# ── Main Flow ──)')
    if (-not $funcMatch.Success) {
        Write-Log "FATAL: Could not extract function block from script" "FAIL"
        exit 1
    }
    $functionBlock = $funcMatch.Groups[1].Value
    $funcTempFile = Join-Path $CONST_SANDBOX_BASE "_benchmark_functions.ps1"
    [System.IO.File]::WriteAllText($funcTempFile, $functionBlock, [System.Text.Encoding]::UTF8)

    $completed = 0
    $runningJobs = @{}
    $pendingIdx = 0

    while ($pendingIdx -lt $benchmarkList.Count -or $runningJobs.Count -gt 0) {
        # Spawn jobs up to limit
        while ($runningJobs.Count -lt $Parallel -and $pendingIdx -lt $benchmarkList.Count) {
            $item = $benchmarkList[$pendingIdx]
            $bm = $item.benchmark
            $pendingIdx++

            # Pre-create sandbox so job doesn't race on directory creation
            $bmSandbox = Join-Path $CONST_SANDBOX_BASE $bm.id
            Ensure-Dir $bmSandbox

            $job = Start-Job -ScriptBlock {
                param($ItemJson, $SandboxBase, $ExePath, $CliKind, $ModelName, $Timeout, $FuncFile)

                try {

                # Load all helper functions from temp file
                . $FuncFile

                $item = $ItemJson | ConvertFrom-Json
                $bm = $item.benchmark
                $bmSandbox = Join-Path $SandboxBase $bm.id
                $bmStart = Get-Date

                # Build prompt
                $prompt = ""
                if ($item.category -eq "coding") {
                    $langLabel = if ($item.language -eq "python") { "Python" } else { "C#" }
                    $prompt = "You are a coding assistant. Solve this $langLabel programming problem.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the code, inside a code block. No explanations, no test code, no main function - just the implementation."
                }
                elseif ($item.category -eq "bug-tracing") {
                    $prompt = "You are a debugging assistant. Find and fix the bug in this code.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the corrected code, inside a code block. Do not include the original buggy code, tests, or explanations - just the fixed code."
                }
                elseif ($item.category -eq "terminal") {
                    $prompt = "You are a terminal assistant. You are currently in a working directory. Execute the following task using shell commands.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the shell commands inside a code block. No explanations. Commands will be executed directly."
                }
                elseif ($item.category -eq "intelligence") {
                    $prompt = "$($bm.prompt)`n`nIMPORTANT: You MUST end your response with a line starting with `"ANSWER: `" followed by your answer. For example: `"ANSWER: 42`" or `"ANSWER: B`"."
                }
                elseif ($item.category -eq "advanced") {
                    $prompt = "You are an expert C# developer. Solve this advanced programming challenge.`n`n$($bm.prompt)`n`nIMPORTANT: Return ONLY the code, inside a code block. No explanations, no test code, no main function - just the implementation. The solution must be efficient and handle edge cases."
                }

                # ── Direct CLI invocation (& operator, no nested jobs) ───────
                $cliOutput = ""
                $cliExitCode = -1
                $cliTimedOut = $false

                try {
                    Set-Location $bmSandbox
                    if ($CliKind -eq "claude") {
                        $cliOutput = $prompt | & $ExePath -p --model $ModelName --max-turns 8 --dangerously-skip-permissions 2>&1 | Out-String
                        $cliExitCode = $LASTEXITCODE
                    }
                    elseif ($CliKind -eq "opencode") {
                        $cliOutput = & $ExePath run --model $ModelName $prompt 2>&1 | Out-String
                        $cliExitCode = $LASTEXITCODE
                    }
                    if ($null -eq $cliExitCode) { $cliExitCode = 0 }
                    $cliOutput = $cliOutput.Trim()
                }
                catch {
                    $cliOutput = "CLI exception: $($_.Exception.Message)"
                    $cliExitCode = 1
                }

                # Evaluate
                if ($cliTimedOut) {
                    $evalResult = [pscustomobject]@{ passed = $false; score = 0; maxScore = $bm.scoreValue; testsPassed = 0; testsTotal = 1; extractedCode = ""; error = "CLI timed out" }
                }
                elseif ([string]::IsNullOrWhiteSpace($cliOutput)) {
                    $evalResult = [pscustomobject]@{ passed = $false; score = 0; maxScore = $bm.scoreValue; testsPassed = 0; testsTotal = 1; extractedCode = ""; error = "CLI returned empty output (exit $cliExitCode)" }
                }
                else {
                    if ($item.category -eq "coding" -or $item.category -eq "advanced") {
                        $evalResult = Evaluate-Coding -Benchmark $bm -AiOutput $cliOutput -Language $item.language -WorkDir $bmSandbox
                    }
                    elseif ($item.category -eq "bug-tracing") {
                        $evalResult = Evaluate-BugTracing -Benchmark $bm -AiOutput $cliOutput -Language $item.language -WorkDir $bmSandbox
                    }
                    elseif ($item.category -eq "terminal") {
                        $evalResult = Evaluate-Terminal -Benchmark $bm -AiOutput $cliOutput -WorkDir $bmSandbox
                    }
                    elseif ($item.category -eq "intelligence") {
                        $evalResult = Evaluate-Intelligence -Benchmark $bm -AiOutput $cliOutput
                    }
                }

                $bmDuration = ((Get-Date) - $bmStart).TotalSeconds

                # Cleanup sandbox
                Remove-Item $bmSandbox -Recurse -Force -ErrorAction SilentlyContinue

                return [pscustomobject]@{
                    id            = $bm.id
                    category      = $item.category
                    name          = $bm.name
                    difficulty    = $bm.difficulty
                    language      = $item.language
                    score         = if ($null -ne $evalResult) { $evalResult.score } else { 0 }
                    maxScore      = if ($null -ne $evalResult) { $evalResult.maxScore } else { $bm.scoreValue }
                    passed        = if ($null -ne $evalResult) { $evalResult.passed } else { $false }
                    testsPassed   = if ($null -ne $evalResult) { $evalResult.testsPassed } else { 0 }
                    testsTotal    = if ($null -ne $evalResult) { $evalResult.testsTotal } else { 1 }
                    durationSec   = [Math]::Round($bmDuration, 1)
                    rawOutput     = $cliOutput
                    extractedCode = if ($null -ne $evalResult) { $evalResult.extractedCode } else { "" }
                    error         = if ($null -ne $evalResult) { $evalResult.error } else { "Evaluation returned null" }
                }

                } catch {
                    # Catch-all: return error result so the job never returns null
                    return [pscustomobject]@{
                        id = "unknown"; category = "unknown"; name = "unknown"; difficulty = "unknown"
                        language = "unknown"; score = 0; maxScore = 10; passed = $false
                        testsPassed = 0; testsTotal = 1; durationSec = 0; rawOutput = ""
                        extractedCode = ""; error = "Job exception: $($_.Exception.Message)"
                    }
                }
            } -ArgumentList ($item | ConvertTo-Json -Depth 10 -Compress), $CONST_SANDBOX_BASE, $Executable, $CliName, $Model, $TimeoutSec, $funcTempFile

            $runningJobs[$job.Id] = @{ job = $job; bmId = $bm.id; bmName = $bm.name; startTime = Get-Date }
            Write-Log "[queued] $($bm.id): $($bm.name)" "PROG"
        }

        # Kill jobs that exceeded timeout
        foreach ($entry in @($runningJobs.GetEnumerator())) {
            $elapsed = ((Get-Date) - $entry.Value.startTime).TotalSeconds
            if ($elapsed -gt ($TimeoutSec + 30)) {
                Stop-Job $entry.Value.job -ErrorAction SilentlyContinue
            }
        }

        # Wait briefly for any job to complete
        $doneJobs = @($runningJobs.Values | ForEach-Object { $_.job } | Where-Object { $_.State -ne "Running" })

        if ($doneJobs.Count -eq 0) {
            Start-Sleep -Milliseconds 3000
            continue
        }

        foreach ($doneJob in $doneJobs) {
            $completed++
            $meta = $runningJobs[$doneJob.Id]

            try {
                $bmResult = Receive-Job $doneJob -ErrorAction Stop
                if ($null -eq $bmResult) {
                    $bmResult = [pscustomobject]@{
                        id = $meta.bmId; category = "unknown"; name = $meta.bmName; difficulty = "unknown"
                        language = "unknown"; score = 0; maxScore = 10; passed = $false
                        testsPassed = 0; testsTotal = 1; durationSec = 0; rawOutput = ""
                        extractedCode = ""; error = "Job returned null"
                    }
                }
            }
            catch {
                $bmResult = [pscustomobject]@{
                    id = $meta.bmId; category = "unknown"; name = $meta.bmName; difficulty = "unknown"
                    language = "unknown"; score = 0; maxScore = 10; passed = $false
                    testsPassed = 0; testsTotal = 1; durationSec = ((Get-Date) - $meta.startTime).TotalSeconds
                    rawOutput = ""; extractedCode = ""; error = "Job error: $($_.Exception.Message)"
                }
            }

            $results += $bmResult
            $pct = [Math]::Round(($completed / $totalBenchmarks) * 100)
            $status = if ($bmResult.passed) { "OK" } else { "FAIL" }
            $scoreStr = "$($bmResult.score)/$($bmResult.maxScore)"
            Write-Log "[$completed/$totalBenchmarks ($pct%)] $($bmResult.id): $($bmResult.name) -> $status ($scoreStr) in $([Math]::Round($bmResult.durationSec))s" $(if ($bmResult.passed) { "OK" } else { "FAIL" })
            if (-not $bmResult.passed -and $bmResult.error) {
                Write-Log "     Error: $($bmResult.error.Substring(0, [Math]::Min(120, $bmResult.error.Length)))" "WARN"
            }

            $runningJobs.Remove($doneJob.Id)
            Remove-Job $doneJob -Force -ErrorAction SilentlyContinue
        }
    }
}

$overallDuration = ((Get-Date) - $overallStart).TotalSeconds

# ── Calculate Scores ───────────────────────────────────────────────────────────

Write-Log "Calculating scores..." "INFO"

function Get-CategoryScore {
    param([string]$Category)
    $catResults = @($results | Where-Object { $_.category -eq $Category })
    if ($catResults.Count -eq 0) { return @{ score = 0; max = 100; count = 0; raw = 0; rawMax = 0 } }
    $totalScore = ($catResults | Measure-Object -Property score -Sum).Sum
    $maxPossible = ($catResults | Measure-Object -Property maxScore -Sum).Sum
    # Normalize to /100
    $normalized = if ($maxPossible -gt 0) { [Math]::Round(($totalScore / $maxPossible) * 100, 1) } else { 0 }
    return @{ score = $normalized; max = 100; raw = $totalScore; rawMax = $maxPossible; count = $catResults.Count }
}

$bugScore = Get-CategoryScore "bug-tracing"
$termScore = Get-CategoryScore "terminal"
$intelScore = Get-CategoryScore "intelligence"
$advScore = Get-CategoryScore "advanced"

# Recalculate coding properly (combines python + csharp)
$codingAll = @($results | Where-Object { $_.category -eq "coding" })
$codingTotal = ($codingAll | Measure-Object -Property score -Sum).Sum
$codingMax = ($codingAll | Measure-Object -Property maxScore -Sum).Sum
$codingNormalized = if ($codingMax -gt 0) { [Math]::Round(($codingTotal / $codingMax) * 100, 1) } else { 0 }

$overallScore = [Math]::Round(($codingNormalized + $bugScore.score + $termScore.score + $intelScore.score + $advScore.score) / 5, 1)

# ── Build Result JSON ──────────────────────────────────────────────────────────

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeModel = $Model -replace '[/\\:*?"<>|]', '-'
$resultFile = Join-Path $ResultDir "$CliName-$safeModel-$timestamp.json"

$resultJson = [pscustomobject]@{
    meta = [pscustomobject]@{
        cli              = $CliName
        model            = $Model
        mode             = $Mode
        executable       = $Executable
        timestamp        = (Get-Date).ToUniversalTime().ToString("o")
        durationSeconds  = [Math]::Round($overallDuration, 1)
        totalBenchmarks  = $totalBenchmarks
        timeoutPerBench  = $TimeoutSec
    }
    scores = [pscustomobject]@{
        coding       = [pscustomobject]@{ score = $codingNormalized; max = 100; rawScore = $codingTotal; rawMax = $codingMax; benchmarks = $codingAll.Count }
        bugTracing   = [pscustomobject]@{ score = $bugScore.score; max = 100; rawScore = $bugScore.raw; rawMax = $bugScore.rawMax; benchmarks = $bugScore.count }
        terminal     = [pscustomobject]@{ score = $termScore.score; max = 100; rawScore = $termScore.raw; rawMax = $termScore.rawMax; benchmarks = $termScore.count }
        intelligence = [pscustomobject]@{ score = $intelScore.score; max = 100; rawScore = $intelScore.raw; rawMax = $intelScore.rawMax; benchmarks = $intelScore.count }
        advanced     = [pscustomobject]@{ score = $advScore.score; max = 100; rawScore = $advScore.raw; rawMax = $advScore.rawMax; benchmarks = $advScore.count }
        overall      = [pscustomobject]@{ score = $overallScore; max = 100 }
    }
    benchmarks = $results
}

$resultJson | ConvertTo-Json -Depth 10 | Out-File -FilePath $resultFile -Encoding UTF8

# ── Summary ────────────────────────────────────────────────────────────────────

Write-Log "══════════════════════════════════════════════" "INFO"
Write-Log "BENCHMARK COMPLETE - $CliName / $Model ($($Mode) mode)" "INFO"
Write-Log "Duration: $([Math]::Round($overallDuration / 60, 1)) minutes" "INFO"
Write-Log "══════════════════════════════════════════════" "INFO"
Write-Log "Category Scores:" "INFO"
function Score-Level { param([double]$s); if ($s -ge 70) { "OK" } elseif ($s -ge 40) { "WARN" } else { "FAIL" } }
Write-Log "  Coding:        $($codingNormalized)/100" (Score-Level $codingNormalized)
Write-Log "  Bug-Tracing:   $($bugScore.score)/100" (Score-Level $bugScore.score)
Write-Log "  Terminal:      $($termScore.score)/100" (Score-Level $termScore.score)
Write-Log "  Intelligence:  $($intelScore.score)/100" (Score-Level $intelScore.score)
Write-Log "  Advanced:      $($advScore.score)/100" (Score-Level $advScore.score)
Write-Log "----------------------------------------------" "INFO"
Write-Log "  Overall:       $overallScore/100" (Score-Level $overallScore)
Write-Log "══════════════════════════════════════════════" "INFO"
Write-Log "Results saved to: $resultFile" "INFO"

# Show failed benchmarks for debugging
$failed = @($results | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) {
    Write-Log "Failed benchmarks ($($failed.Count)):" "WARN"
    foreach ($f in $failed) {
        $errPreview = if ($f.error) { $f.error.Substring(0, [Math]::Min(80, $f.error.Length)) } else { "unknown" }
        Write-Log "  $($f.id): $($f.name) - $errPreview" "WARN"
    }
}

# Cleanup sandbox
Remove-Item $CONST_SANDBOX_BASE -Recurse -Force -ErrorAction SilentlyContinue

Write-Log "Done." "OK"
[Console]::Out.Flush()
[Console]::Error.Flush()
exit 0
