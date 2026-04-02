param(
    [Parameter(Mandatory)][ValidateSet("show", "use", "clear")][string]$Mode,
    [string]$SolutionPath = "",
    [string]$RepoRoot = "",
    [string]$ExecutionProfile = ""
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

function Get-CanonicalPath {
    param([string]$Path)

    if (-not $Path) { return "" }
    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    } catch {
        return [System.IO.Path]::GetFullPath($Path)
    }
}

function Resolve-RepoRoot {
    param(
        [string]$ExplicitRepoRoot,
        [string]$ExplicitSolutionPath
    )

    if ($ExplicitRepoRoot) {
        return (Get-CanonicalPath -Path $ExplicitRepoRoot)
    }

    $anchor = if ($ExplicitSolutionPath) { Split-Path -Path (Get-CanonicalPath -Path $ExplicitSolutionPath) -Parent } else { (Get-Location).Path }
    $result = Invoke-NativeCommand -Command "git" -Arguments @("rev-parse", "--show-toplevel") -WorkingDirectory $anchor
    if ($result.exitCode -ne 0 -or -not $result.output) {
        throw "Could not resolve the repository root."
    }

    return (Get-CanonicalPath -Path $result.output)
}

$resolvedRepoRoot = Resolve-RepoRoot -ExplicitRepoRoot $RepoRoot -ExplicitSolutionPath $SolutionPath
$configState = Get-AutoDevelopConfigState -RepoRoot $resolvedRepoRoot

switch ($Mode) {
    "show" {
        [pscustomobject]@{
            repoRoot = $resolvedRepoRoot
            defaultExecutionProfile = [string]$configState.effective.defaultExecutionProfile
            activeExecutionProfile = [string]$configState.activeExecutionProfile
            activeExecutionProfileSource = [string]$configState.activeExecutionProfileSource
            sessionPath = [string]$configState.sessionPath
            sessionFileExists = [bool]$configState.sessionFile.exists
            executionProfiles = @(Get-AutoDevelopExecutionProfileNames -Config $configState.effective)
            warnings = @($configState.warnings)
        } | ConvertTo-Json -Depth 16
        break
    }
    "use" {
        if (-not $ExecutionProfile) {
            throw "ExecutionProfile is required in 'use' mode."
        }

        $session = Set-AutoDevelopSessionState -RepoRoot $resolvedRepoRoot -ExecutionProfile $ExecutionProfile
        [pscustomobject]@{
            repoRoot = $resolvedRepoRoot
            activeExecutionProfile = [string]$session.activeExecutionProfile
            sessionPath = [string](Get-AutoDevelopSessionStatePath -RepoRoot $resolvedRepoRoot)
        } | ConvertTo-Json -Depth 16
        break
    }
    "clear" {
        $cleared = Clear-AutoDevelopSessionState -RepoRoot $resolvedRepoRoot
        [pscustomobject]@{
            repoRoot = $resolvedRepoRoot
            cleared = [bool]$cleared
            defaultExecutionProfile = [string]$configState.effective.defaultExecutionProfile
        } | ConvertTo-Json -Depth 16
        break
    }
}
