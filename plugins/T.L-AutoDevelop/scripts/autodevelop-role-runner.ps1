. (Join-Path $PSScriptRoot "providers\provider-claude-code.ps1")

function Get-AutoDevelopRoleInvocation {
    param($RoleConfig)

    $family = [string]$RoleConfig.cliFamily
    switch ($family) {
        "claude-code" {
            return (Get-ClaudeCodeInvocationForRole -RoleConfig $RoleConfig)
        }
        default {
            throw "Unsupported AutoDevelop CLI family '$family' for role '$($RoleConfig.roleName)'."
        }
    }
}

function Invoke-AutoDevelopRole {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)]$RoleConfig,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [string]$DebugTempPrefix = "autodevelop-role"
    )

    $resolvedTimeoutSeconds = Get-AutoDevelopResolvedTimeoutSeconds -RoleConfig $RoleConfig -FallbackTimeoutSeconds $TimeoutSeconds
    $candidateRoleConfigs = New-Object System.Collections.Generic.List[object]
    [void]$candidateRoleConfigs.Add($RoleConfig)
    foreach ($fallbackCliProfile in @(Get-AutoDevelopFallbackCliProfiles -RoleConfig $RoleConfig)) {
        try {
            [void]$candidateRoleConfigs.Add((Resolve-AutoDevelopRoleConfigForCliProfile -RoleConfig $RoleConfig -CliProfileId $fallbackCliProfile))
        } catch {
        }
    }

    foreach ($candidateRole in @($candidateRoleConfigs)) {
        try {
            $invocation = Get-AutoDevelopRoleInvocation -RoleConfig $candidateRole
        } catch {
            if ($candidateRole -eq $candidateRoleConfigs[$candidateRoleConfigs.Count - 1]) { throw }
            continue
        }

        $tempPromptFile = Join-Path $env:TEMP ("$DebugTempPrefix-input-" + [guid]::NewGuid().ToString("N") + ".md")
        $tempOutputFile = Join-Path $env:TEMP ("$DebugTempPrefix-output-" + [guid]::NewGuid().ToString("N") + ".txt")
        $tempDir = Split-Path -Path $tempPromptFile -Parent
        if (-not (Test-Path -LiteralPath $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }

        [System.IO.File]::WriteAllText($tempPromptFile, $Prompt, [System.Text.Encoding]::UTF8)
        $startedAt = Get-Date

        $job = Start-Job -ScriptBlock {
            param($Executable, $PromptFile, $Args, $OutFile, $Location)
            Set-Location $Location
            Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
            $content = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
            $allArgs = @("-p") + @($Args)
            try {
                $output = $content | & $Executable @allArgs 2>&1 | Out-String
                $exitCode = $LASTEXITCODE
            } catch {
                $output = "JOB_EXCEPTION: $_"
                $exitCode = 99
            }
            [System.IO.File]::WriteAllText($OutFile, "$exitCode`n$output", [System.Text.Encoding]::UTF8)
        } -ArgumentList $invocation.executable, $tempPromptFile, @($invocation.arguments), $tempOutputFile, $WorkingDirectory

        try {
            $completed = Wait-Job $job -Timeout $resolvedTimeoutSeconds
            if (-not $completed -or $job.State -eq "Running") {
                Stop-Job $job -ErrorAction SilentlyContinue
                return [pscustomobject]@{
                    success = $false
                    exitCode = -1
                    output = "TIMEOUT nach $resolvedTimeoutSeconds Sekunden"
                    timedOut = $true
                    executable = [string]$invocation.executable
                    arguments = @($invocation.arguments)
                    durationSeconds = ((Get-Date) - $startedAt).TotalSeconds
                    cliProfile = $candidateRole.cliProfile
                }
            }

            $jobFailed = $job.State -eq "Failed"
            $jobErrors = Receive-Job $job 2>&1 | Out-String
            $rawOutput = if (Test-Path -LiteralPath $tempOutputFile) { [System.IO.File]::ReadAllText($tempOutputFile, [System.Text.Encoding]::UTF8) } else { "" }
            $parts = $rawOutput -split "`n", 2
            $exitCode = if ($parts.Count -ge 2 -and $parts[0] -match '^\d+$') { [int]$parts[0] } else { 99 }
            $output = if ($parts.Count -ge 2) { $parts[1] } else { $rawOutput }
            if ($jobFailed) {
                $exitCode = 99
                $output = "JOB_FAILED: $jobErrors"
            }

            return [pscustomobject]@{
                success = ($exitCode -eq 0)
                exitCode = $exitCode
                output = $output.Trim()
                timedOut = $false
                executable = [string]$invocation.executable
                arguments = @($invocation.arguments)
                durationSeconds = ((Get-Date) - $startedAt).TotalSeconds
                cliProfile = $candidateRole.cliProfile
            }
        } catch {
            if ($candidateRole -eq $candidateRoleConfigs[$candidateRoleConfigs.Count - 1]) {
                throw
            }
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tempPromptFile, $tempOutputFile -ErrorAction SilentlyContinue
        }
    }

    throw "No usable CLI profile was available for role '$($RoleConfig.roleName)'."
}
