. (Join-Path $PSScriptRoot "providers\provider-claude-code.ps1")
. (Join-Path $PSScriptRoot "providers\provider-codex.ps1")
. (Join-Path $PSScriptRoot "providers\provider-opencode.ps1")

function Get-AutoDevelopRoleInvocation {
    param(
        $RoleConfig,
        [string]$LastMessageFile = ""
    )

    $family = [string]$RoleConfig.cliFamily
    switch ($family) {
        "claude-code" {
            return (Get-ClaudeCodeInvocationForRole -RoleConfig $RoleConfig)
        }
        "codex" {
            return (Get-CodexInvocationForRole -RoleConfig $RoleConfig -LastMessageFile $LastMessageFile)
        }
        "opencode" {
            return (Get-OpenCodeInvocationForRole -RoleConfig $RoleConfig)
        }
        default {
            throw "Unsupported AutoDevelop CLI family '$family' for role '$($RoleConfig.roleName)'."
        }
    }
}

function Get-AutoDevelopRolePrompt {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)]$RoleConfig
    )

    $family = [string]$RoleConfig.cliFamily
    switch ($family) {
        "codex" {
            return (Get-CodexPromptForRole -Prompt $Prompt -RoleConfig $RoleConfig)
        }
        default {
            return $Prompt
        }
    }
}

function ConvertTo-AutoDevelopSerializableEnvironmentOverrides {
    param($EnvironmentOverrides)

    if ($null -eq $EnvironmentOverrides) {
        return @()
    }

    $entries = New-Object System.Collections.Generic.List[object]
    if ($EnvironmentOverrides -is [System.Collections.IDictionary]) {
        foreach ($entry in @($EnvironmentOverrides.GetEnumerator())) {
            [void]$entries.Add([pscustomobject]@{
                Key = [string]$entry.Key
                Value = [string]$entry.Value
            })
        }
        return @($entries.ToArray())
    }

    foreach ($property in @($EnvironmentOverrides.PSObject.Properties)) {
        [void]$entries.Add([pscustomobject]@{
            Key = [string]$property.Name
            Value = [string]$property.Value
        })
    }

    return @($entries.ToArray())
}

function ConvertTo-AutoDevelopSerializedArgumentList {
    param($Arguments)

    return ((@($Arguments) | ForEach-Object { [string]$_ }) | ConvertTo-Json -Compress)
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

    foreach ($candidateRole in @($candidateRoleConfigs.ToArray())) {
        try {
            $tempPromptFile = Join-Path $env:TEMP ("$DebugTempPrefix-input-" + [guid]::NewGuid().ToString("N") + ".md")
            $tempOutputFile = Join-Path $env:TEMP ("$DebugTempPrefix-output-" + [guid]::NewGuid().ToString("N") + ".txt")
            $tempResultFile = Join-Path $env:TEMP ("$DebugTempPrefix-result-" + [guid]::NewGuid().ToString("N") + ".txt")
            $invocation = Get-AutoDevelopRoleInvocation -RoleConfig $candidateRole -LastMessageFile $tempResultFile
        } catch {
            if ($candidateRole -eq $candidateRoleConfigs[$candidateRoleConfigs.Count - 1]) { throw }
            continue
        }

        $tempDir = Split-Path -Path $tempPromptFile -Parent
        if (-not (Test-Path -LiteralPath $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }

        $effectivePrompt = Get-AutoDevelopRolePrompt -Prompt $Prompt -RoleConfig $candidateRole
        [System.IO.File]::WriteAllText($tempPromptFile, $effectivePrompt, [System.Text.Encoding]::UTF8)
        $startedAt = Get-Date
        $serializedEnvironmentOverrides = @(ConvertTo-AutoDevelopSerializableEnvironmentOverrides -EnvironmentOverrides $invocation.env)
        $serializedArgumentList = ConvertTo-AutoDevelopSerializedArgumentList -Arguments $invocation.arguments

        $jobArgumentList = @(
            $invocation.executable,
            $tempPromptFile,
            $serializedArgumentList,
            $tempOutputFile,
            $WorkingDirectory,
            [string]$invocation.promptInput,
            (, $serializedEnvironmentOverrides)
        )

        $job = Start-Job -ScriptBlock {
            param($Executable, $PromptFile, $CommandArgumentsJson, $OutFile, $Location, $PromptInput, $EnvironmentOverrides)
            Set-Location $Location
            Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE -ErrorAction SilentlyContinue
            Remove-Item Env:CODEX_SHELL -ErrorAction SilentlyContinue
            foreach ($entry in @($EnvironmentOverrides)) {
                if (-not $entry) { continue }
                if (-not [string]$entry.Key) { continue }
                    [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
            }
            $content = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
            $allArgs = @((ConvertFrom-Json -InputObject ([string]$CommandArgumentsJson)) | ForEach-Object { [string]$_ })
            try {
                if ($PromptInput -eq "stdin") {
                    $output = $content | & $Executable @allArgs 2>&1 | Out-String
                } else {
                    $output = & $Executable @allArgs $content 2>&1 | Out-String
                }
                $exitCode = $LASTEXITCODE
            } catch {
                $output = "JOB_EXCEPTION: $_"
                $exitCode = 99
            }
            [System.IO.File]::WriteAllText($OutFile, "$exitCode`n$output", [System.Text.Encoding]::UTF8)
        } -ArgumentList $jobArgumentList

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
            $resultSource = [string]$invocation.resultSource
            if ($resultSource -eq "last-message-file" -and (Test-Path -LiteralPath $tempResultFile)) {
                $fileOutput = [System.IO.File]::ReadAllText($tempResultFile, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($fileOutput)) {
                    $output = $fileOutput
                }
            }
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
            Remove-Item -LiteralPath $tempPromptFile, $tempOutputFile, $tempResultFile -ErrorAction SilentlyContinue
        }
    }

    throw "No usable CLI profile was available for role '$($RoleConfig.roleName)'."
}
