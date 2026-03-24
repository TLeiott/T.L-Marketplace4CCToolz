# auto-develop.ps1 -- Deterministic pipeline with investigation, artifacts, and explicit no-op handling
param(
    [Parameter(Mandatory)][string]$PromptFile,
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$PlannerContextFile = "",
    [string]$TaskName = "develop-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [string]$SchedulerTaskId = "",
    [string]$CommandType = "",
    [switch]$SkipRun,
    [switch]$AllowNuget
)

$CONST_MODEL_PLAN = "claude-opus-4-6"
$CONST_MODEL_INVESTIGATE = "claude-opus-4-6"
$CONST_MODEL_IMPLEMENT = "claude-opus-4-6"
$CONST_MODEL_REVIEW = "claude-opus-4-6"
$CONST_MODEL_FAST = "claude-sonnet-4-6"
$CONST_MAX_TURNS_DISCOVER = 12
$CONST_MAX_TURNS_PLAN = 18
$CONST_MAX_TURNS_INVESTIGATE = 14
$CONST_MAX_TURNS_IMPL = 24
$CONST_MAX_TURNS_REVIEW = 12
$CONST_TIMEOUT_SECONDS = 900
$CONST_DISCOVER_ATTEMPTS = 2
$CONST_PLAN_ATTEMPTS = 2
$CONST_INVESTIGATION_ATTEMPTS = 2
$CONST_REPRODUCE_ATTEMPTS = 2
$CONST_IMPLEMENT_ATTEMPTS = 2
$CONST_REMEDIATION_ATTEMPTS = 2
$CONST_REPAIR_ATTEMPTS = 2
$CONST_CONTEXT_MAX_CHARS = 3500
$CONST_FEEDBACK_MAX_CHARS = 2000
$CONST_TEST_PROJECTS_MAX_CHARS = 1200
$CONST_REVIEW_DIFF_LITE_CHARS = 3500
$CONST_REVIEW_DIFF_FULL_CHARS = 14000
$CONST_REVIEW_FULL_PRESERVE_MAX_FILES = 3
$CONST_REVIEW_FULL_PRESERVE_MAX_DIFF_CHARS = 18000
$CONST_REVIEW_PLAN_MAX_CHARS = 2200
$CONST_REVIEW_HISTORY_MAX_CHARS = 1400
$CONST_REVIEW_FAST_MAX_FILES = 3
$CONST_REVIEW_FAST_MAX_DIFF_CHARS = 7000
$CONST_TARGET_HINTS_MAX = 5

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
$phaseMetrics = [System.Collections.ArrayList]::new()
$feedbackHistory = [System.Collections.ArrayList]::new()
$attemptsByPhase = [ordered]@{
    discover = 0
    plan = 0
    fixPlan = 0
    investigate = 0
    reproduce = 0
    verifyRepro = 0
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
$discoverConclusion = ""
$routeDecision = "UNCERTAIN"
$testability = "UNKNOWN"
$testProjects = @()
$plannerEffortClass = "UNKNOWN"
$pipelineProfile = "COMPLEX"
$reproductionAttempted = $false
$reproductionConfirmed = $false
$reproductionOutput = ""
$reproductionBaselinePatch = ""
$reproductionBaselineFiles = @()
$reproductionTests = [ordered]@{
    testProjects = @()
    testFiles = @()
    testNames = @()
    testFilter = ""
    bugBehavior = ""
    rationale = ""
    verificationOutput = ""
}
$targetedVerificationPassed = $false
$taskPrompt = ""
$taskLine = ""
$planTargets = @()
$implementationScopeCheck = $null
$discoverVerdict = [ordered]@{
    route = "UNCERTAIN"
    bugConfidence = "LOW"
    testability = "UNKNOWN"
    targetHints = @()
    rationale = ""
    nextPhase = "INVESTIGATE"
    summary = ""
}
$investigationVerdict = [ordered]@{
    result = "INCONCLUSIVE"
    targets = @()
    testability = "UNKNOWN"
    nextPhase = "FIX_PLAN"
    summary = ""
}

Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue

function Invoke-NativeCommand {
    param([string]$Command, [string[]]$Arguments)
    $output = & {
        $ErrorActionPreference = "Continue"
        & $Command @Arguments 2>&1
    }
    return @{ output = ($output | Out-String).Trim(); exitCode = $LASTEXITCODE }
}

function Get-CanonicalPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    } catch {
        $fullPath = $Path
    }
    try {
        return (Get-Item -LiteralPath $fullPath -ErrorAction Stop).FullName
    } catch {
        return $fullPath
    }
}

function Read-JsonFileBestEffort {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        try {
            return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        } catch {
            return $null
        }
    }
}

function Normalize-RepoRelativePath {
    param([string]$Path)
    if (-not $Path) { return "" }
    $normalized = $Path.Trim().Replace("/", "\")
    while ($normalized.StartsWith(".\")) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized.TrimStart('\')
}

function Get-NormalizedPlannerEffortClass {
    param([string]$EffortClass)
    $value = ([string]$EffortClass).Trim().ToUpperInvariant()
    if ($value -in @("LOW", "MEDIUM", "HIGH")) { return $value }
    return "UNKNOWN"
}

function Get-PipelineProfile {
    param([string]$PlannerEffortClass)
    if ((Get-NormalizedPlannerEffortClass -EffortClass $PlannerEffortClass) -eq "LOW") {
        return "SIMPLE"
    }
    return "COMPLEX"
}

function Get-NormalizedPathSet {
    param([string[]]$Paths)
    return @(
        @($Paths | ForEach-Object {
            $value = Normalize-RepoRelativePath -Path ([string]$_)
            if ($value) { $value }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-CanonicalComparisonPath {
    param([string]$Path)
    if (-not $Path) { return "" }
    return (([string]$Path).Trim().Replace("/", "\").TrimStart('\')).ToLowerInvariant()
}

function Get-PathComparisonProfile {
    param([string]$Path)

    $canonical = Get-CanonicalComparisonPath -Path $Path
    if (-not $canonical) {
        return [pscustomobject]@{
            original = [string]$Path
            canonical = ""
            baseName = ""
            isFileLike = $false
            hasWildcard = $false
            segments = @()
        }
    }

    $segments = @($canonical -split '[\\/]')
    $baseName = if ($segments.Count -gt 0) { [string]$segments[-1] } else { "" }
    $hasWildcard = ($canonical -match '[\*\?]')
    $isFileLike = (-not $hasWildcard) -and ($baseName -match '\.') -and ($segments.Count -gt 0)
    return [pscustomobject]@{
        original = [string]$Path
        canonical = $canonical
        baseName = $baseName
        isFileLike = $isFileLike
        hasWildcard = $hasWildcard
        segments = @($segments)
    }
}

function Get-TargetPathMatches {
    param(
        [string]$TargetPath,
        [string[]]$ActualPaths
    )

    $target = Get-PathComparisonProfile -Path $TargetPath
    $actualProfiles = @($ActualPaths | ForEach-Object { Get-PathComparisonProfile -Path ([string]$_) } | Where-Object { $_.canonical })
    if (-not $target.canonical -or $actualProfiles.Count -eq 0) {
        return [pscustomobject]@{ kind = "none"; actuals = @() }
    }

    if ($target.hasWildcard) {
        $wildcardMatches = @($actualProfiles | Where-Object { $_.canonical -like $target.canonical } | ForEach-Object { [string]$_.original } | Select-Object -Unique)
        if ($wildcardMatches.Count -gt 0) {
            return [pscustomobject]@{ kind = "wildcard"; actuals = @($wildcardMatches) }
        }
        return [pscustomobject]@{ kind = "none"; actuals = @() }
    }

    $exactMatches = @($actualProfiles | Where-Object { $_.canonical -eq $target.canonical } | ForEach-Object { [string]$_.original } | Select-Object -Unique)
    if ($exactMatches.Count -gt 0) {
        return [pscustomobject]@{ kind = "exact"; actuals = @($exactMatches) }
    }

    if ($target.isFileLike) {
        $suffixCandidates = @($actualProfiles | Where-Object { $_.baseName -eq $target.baseName } | ForEach-Object { [string]$_.original } | Select-Object -Unique)
        if ($suffixCandidates.Count -eq 1) {
            return [pscustomobject]@{ kind = "suffix"; actuals = @($suffixCandidates) }
        }

        $suffixByEnding = @($actualProfiles | Where-Object { $_.canonical.EndsWith("\" + $target.canonical) } | ForEach-Object { [string]$_.original } | Select-Object -Unique)
        if ($suffixByEnding.Count -eq 1) {
            return [pscustomobject]@{ kind = "suffix"; actuals = @($suffixByEnding) }
        }
    }

    if (-not $target.isFileLike -and $target.segments.Count -gt 0) {
        $directoryPrefix = $target.canonical.TrimEnd('\')
        $directoryCandidates = @($actualProfiles | Where-Object { $_.canonical.StartsWith($directoryPrefix + "\") -or $_.canonical -eq $directoryPrefix } | ForEach-Object { [string]$_.original } | Select-Object -Unique)
        if ($directoryCandidates.Count -gt 0) {
            return [pscustomobject]@{ kind = "directory"; actuals = @($directoryCandidates) }
        }
    }

    return [pscustomobject]@{ kind = "none"; actuals = @() }
}

function Match-AllowedTargetPaths {
    param(
        [string[]]$TargetPaths,
        [string[]]$ActualPaths
    )

    $matchedTargets = [System.Collections.ArrayList]::new()
    $matchedActualFiles = [System.Collections.ArrayList]::new()
    $usedActuals = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $unmatchedTargets = [System.Collections.ArrayList]::new()
    $matchKinds = [ordered]@{ exact = 0; suffix = 0; directory = 0; wildcard = 0 }

    foreach ($target in @($TargetPaths | Where-Object { $_ } | Select-Object -Unique)) {
        $match = Get-TargetPathMatches -TargetPath ([string]$target) -ActualPaths $ActualPaths
        if ($match.kind -eq "none" -or @($match.actuals).Count -eq 0) {
            [void]$unmatchedTargets.Add([string]$target)
            continue
        }

        [void]$matchedTargets.Add([string]$target)
        foreach ($actual in @($match.actuals | Where-Object { $_ } | Select-Object -Unique)) {
            [void]$matchedActualFiles.Add([string]$actual)
            [void]$usedActuals.Add(([string]$actual))
        }
        if ($matchKinds.Contains($match.kind)) {
            $matchKinds[$match.kind] = [int]$matchKinds[$match.kind] + 1
        }
    }

    $outOfScopeFiles = @(
        @($ActualPaths | Where-Object { $_ -and -not $usedActuals.Contains([string]$_) } | Select-Object -Unique)
    )

    return [pscustomobject]@{
        matchedTargets = @($matchedTargets | Select-Object -Unique)
        matchedActualFiles = @($matchedActualFiles | Select-Object -Unique)
        unmatchedTargets = @($unmatchedTargets | Select-Object -Unique)
        outOfScopeFiles = @($outOfScopeFiles)
        matchKinds = [pscustomobject]$matchKinds
    }
}

function Get-ImplementationScopeCheck {
    param(
        [string[]]$PlanTargets,
        [string[]]$ChangedFiles
    )

    $normalizedTargets = @(Get-NormalizedPathSet -Paths $PlanTargets)
    $normalizedFiles = @(Get-NormalizedPathSet -Paths $ChangedFiles)
    if ($normalizedFiles.Count -eq 0) {
        return [pscustomobject]@{
            evaluated = $false
            classification = "unknown"
            planTargets = @($normalizedTargets)
            changedFiles = @($normalizedFiles)
            matchedTargets = @()
            matchedFiles = @()
            unmatchedTargets = @()
            outOfScopeFiles = @()
            matchKindsSummary = [pscustomobject]@{ exact = 0; suffix = 0; directory = 0; wildcard = 0 }
            notes = "No changed files were available for scope validation."
            shouldWarn = $false
            shouldEscalateReview = $false
        }
    }
    if ($normalizedTargets.Count -eq 0) {
        return [pscustomobject]@{
            evaluated = $false
            classification = "unknown"
            planTargets = @($normalizedTargets)
            changedFiles = @($normalizedFiles)
            matchedTargets = @()
            matchedFiles = @()
            unmatchedTargets = @()
            outOfScopeFiles = @()
            matchKindsSummary = [pscustomobject]@{ exact = 0; suffix = 0; directory = 0; wildcard = 0 }
            notes = "No validated plan targets were available for scope validation."
            shouldWarn = $false
            shouldEscalateReview = $false
        }
    }

    $matchResult = Match-AllowedTargetPaths -TargetPaths $normalizedTargets -ActualPaths $normalizedFiles
    $classification = if ($matchResult.outOfScopeFiles.Count -gt 0) {
        "drifted"
    } elseif ($matchResult.matchKinds.directory -gt 0 -or $matchResult.matchKinds.wildcard -gt 0) {
        "broad"
    } elseif ($matchResult.matchKinds.suffix -gt 0) {
        "acceptable"
    } else {
        "tight"
    }

    $notes = "Plan targets $($normalizedTargets.Count), changed files $($normalizedFiles.Count), matched files $(@($matchResult.matchedActualFiles).Count), out-of-scope files $(@($matchResult.outOfScopeFiles).Count)."
    if (@($matchResult.unmatchedTargets).Count -gt 0) {
        $notes += " Unmatched targets: " + ((@($matchResult.unmatchedTargets) | Select-Object -First 3) -join ", ") + "."
    }

    return [pscustomobject]@{
        evaluated = $true
        classification = $classification
        planTargets = @($normalizedTargets)
        changedFiles = @($normalizedFiles)
        matchedTargets = @($matchResult.matchedTargets)
        matchedFiles = @($matchResult.matchedActualFiles)
        unmatchedTargets = @($matchResult.unmatchedTargets)
        outOfScopeFiles = @($matchResult.outOfScopeFiles)
        matchKindsSummary = $matchResult.matchKinds
        notes = $notes
        shouldWarn = ($classification -in @("broad", "drifted"))
        shouldEscalateReview = ($classification -in @("broad", "drifted"))
    }
}

function Format-ImplementationScopeWarningText {
    param($ScopeCheck)
    if (-not $ScopeCheck -or -not $ScopeCheck.evaluated -or -not $ScopeCheck.shouldWarn) { return "" }

    $lines = [System.Collections.ArrayList]::new()
    [void]$lines.Add("IMPLEMENTATION SCOPE: $([string]$ScopeCheck.classification)")
    if (@($ScopeCheck.outOfScopeFiles).Count -gt 0) {
        [void]$lines.Add("- Out-of-scope files: " + ((@($ScopeCheck.outOfScopeFiles) | Select-Object -First 5) -join ", "))
    }
    if (@($ScopeCheck.unmatchedTargets).Count -gt 0) {
        [void]$lines.Add("- Unmatched plan targets: " + ((@($ScopeCheck.unmatchedTargets) | Select-Object -First 5) -join ", "))
    }
    if ($ScopeCheck.notes) {
        [void]$lines.Add("- Notes: $([string]$ScopeCheck.notes)")
    }
    return ($lines -join "`n")
}

function Update-ImplementationScopeCheck {
    param(
        [string]$ArtifactLabel = "",
        [string]$Phase = "CHANGE_VALIDATE"
    )

    $script:implementationScopeCheck = Get-ImplementationScopeCheck -PlanTargets $planTargets -ChangedFiles $changedFiles
    if ($ArtifactLabel) {
        Save-JsonArtifact -Name "$ArtifactLabel-scope-check.json" -Object $script:implementationScopeCheck | Out-Null
    }
    if ($script:implementationScopeCheck.evaluated) {
        Add-TimelineEvent -Phase $Phase -Message "Deterministic implementation scope check completed." -Category ("IMPLEMENT_SCOPE_" + ([string]$script:implementationScopeCheck.classification).ToUpperInvariant()) -Data @{
            classification = [string]$script:implementationScopeCheck.classification
            matchedFiles = @($script:implementationScopeCheck.matchedFiles)
            outOfScopeFiles = @($script:implementationScopeCheck.outOfScopeFiles)
            unmatchedTargets = @($script:implementationScopeCheck.unmatchedTargets)
        }
    }
}

function Test-LikelyRepoRelativePath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $value = ([string]$Path).Trim()
    if (-not $value) { return $false }
    if ($value -match '^(?i)(fatal:|warning:|usage:|error:|git(?:\.exe)?\s*:|at line:|categoryinfo|fullyqualifiederrorid|parsererror:|exception:)') { return $false }
    if ($value -match '^(?i)(use --help|see ''git .*--help''|the most similar command is|did you mean)') { return $false }
    if ($value -match '[\*\?<>\|"`]') { return $false }
    if ($value -match '^\s*-{1,2}[a-z]') { return $false }
    if ($value -match '^[A-Za-z]:\\$') { return $false }
    return $true
}

function ConvertTo-StructuredPathList {
    param([string]$Text)
    if (-not $Text) { return @() }

    return @(
        @(($Text -split "`0|`r?`n") | ForEach-Object {
            $candidate = $_.Trim()
            if (Test-LikelyRepoRelativePath -Path $candidate) {
                $normalized = Normalize-RepoRelativePath -Path $candidate
                if ($normalized) { $normalized }
            }
        } | Where-Object { $_ } | Select-Object -Unique)
    )
}

function Get-ChangedFilesResult {
    $diffResult = Invoke-NativeCommand git @("diff", "--name-only", "-z", "HEAD")
    $untrackedResult = Invoke-NativeCommand git @("ls-files", "--others", "--exclude-standard", "-z")
    $errors = [System.Collections.ArrayList]::new()
    if ($diffResult.exitCode -ne 0) {
        [void]$errors.Add([pscustomobject]@{ command = "git diff --name-only -z HEAD"; exitCode = [int]$diffResult.exitCode; output = [string]$diffResult.output })
    }
    if ($untrackedResult.exitCode -ne 0) {
        [void]$errors.Add([pscustomobject]@{ command = "git ls-files --others --exclude-standard -z"; exitCode = [int]$untrackedResult.exitCode; output = [string]$untrackedResult.output })
    }

    return [pscustomobject]@{
        ok = ($errors.Count -eq 0)
        files = if ($errors.Count -eq 0) {
            @((ConvertTo-StructuredPathList -Text $diffResult.output) + (ConvertTo-StructuredPathList -Text $untrackedResult.output) | Where-Object { $_ } | Select-Object -Unique)
        } else {
            @()
        }
        sourceErrors = @($errors)
    }
}

function Get-TaskClaimGuardrail {
    param(
        [string]$TaskText,
        [bool]$ReproductionConfirmed
    )
    if ($ReproductionConfirmed -or -not $TaskText) { return "" }
    if ($TaskText -notmatch '(?i)root cause|pflicht-?tests|bekannte review-blocker|nonexistent object|update-ref') { return "" }
    return @"
IMPORTANT GUARDRAIL:
- Treat root-cause, mandatory-test, or review-blocker claims from the task only as claims until local reproduction confirms them.
- Do not force a negative test that is not deterministically reproducible locally.
- If a claimed negative test conflicts with the local git or test reality, say so briefly and plan or implement only reliable locally green tests.
"@
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

function Test-WorktreeEnvironment {
    param(
        [string]$WorktreePath,
        [string]$SolutionPath,
        [string]$RepoRoot = "",
        [string]$Phase = ""
    )

    $worktreeExists = [bool]($WorktreePath -and (Test-Path -LiteralPath $WorktreePath -ErrorAction SilentlyContinue))
    $gitMarkerPath = if ($WorktreePath) { Join-Path $WorktreePath ".git" } else { "" }
    $gitMarkerExists = [bool]($gitMarkerPath -and (Test-Path -LiteralPath $gitMarkerPath -ErrorAction SilentlyContinue))
    $solutionExists = [bool]($SolutionPath -and (Test-Path -LiteralPath $SolutionPath -ErrorAction SilentlyContinue))
    $currentLocation = (Get-Location).Path
    $cwdInsideWorktree = $false
    if ($WorktreePath) {
        try {
            $fullWorktreePath = [System.IO.Path]::GetFullPath($WorktreePath)
            $fullCurrentLocation = [System.IO.Path]::GetFullPath($currentLocation)
            $cwdInsideWorktree = $fullCurrentLocation.StartsWith($fullWorktreePath, [System.StringComparison]::OrdinalIgnoreCase)
        } catch {
            $cwdInsideWorktree = $false
        }
    }

    $topLevelEntries = @()
    if ($worktreeExists) {
        try {
            $topLevelEntries = @(Get-ChildItem -LiteralPath $WorktreePath -Force -ErrorAction Stop | Select-Object -ExpandProperty Name)
        } catch {
            $topLevelEntries = @()
        }
    }
    $nonGitTopLevelEntries = @($topLevelEntries | Where-Object { $_ -ne ".git" })
    $looksEmpty = $worktreeExists -and $nonGitTopLevelEntries.Count -eq 0

    $isValid = $worktreeExists -and $gitMarkerExists -and $solutionExists -and ($looksEmpty -eq $false)
    return [pscustomobject]@{
        isValid = [bool]$isValid
        phase = [string]$Phase
        repoRoot = [string]$RepoRoot
        worktreePath = [string]$WorktreePath
        solutionPath = [string]$SolutionPath
        gitMarkerPath = [string]$gitMarkerPath
        worktreeExists = [bool]$worktreeExists
        gitMarkerExists = [bool]$gitMarkerExists
        solutionExists = [bool]$solutionExists
        worktreeLooksEmpty = [bool]$looksEmpty
        currentLocation = [string]$currentLocation
        cwdInsideWorktree = [bool]$cwdInsideWorktree
        topLevelEntries = @($topLevelEntries | Select-Object -First 12)
    }
}

function Resolve-WorktreeEnvironmentFailureCategory {
    param($Validation)

    if (-not $Validation.worktreeExists -or -not $Validation.gitMarkerExists -or [bool]$Validation.worktreeLooksEmpty) {
        return "WORKTREE_INVALID"
    }
    if (-not $Validation.solutionExists) {
        return "SOLUTION_PATH_MISSING"
    }
    return "WORKTREE_ENVIRONMENT_ERROR"
}

function Fail-WorktreeEnvironment {
    param(
        $Validation,
        [string]$Phase,
        [string]$Summary = ""
    )

    $script:currentPhase = if ($Phase) { $Phase } else { $script:currentPhase }
    $category = Resolve-WorktreeEnvironmentFailureCategory -Validation $Validation
    $message = if ($Summary) { $Summary } else { "The worker environment is invalid for phase $Phase." }
    $details = ($Validation | ConvertTo-Json -Depth 6)
    Add-TimelineEvent -Phase $script:currentPhase -Message "Worktree environment validation failed." -Category $category -Data @{
        worktreePath = [string]$Validation.worktreePath
        solutionPath = [string]$Validation.solutionPath
        worktreeExists = [bool]$Validation.worktreeExists
        gitMarkerExists = [bool]$Validation.gitMarkerExists
        solutionExists = [bool]$Validation.solutionExists
        worktreeLooksEmpty = [bool]$Validation.worktreeLooksEmpty
    }
    $script:finalStatus = "ERROR"
    $script:finalCategory = $category
    $script:finalSummary = $message
    $script:finalFeedback = $details
    throw [System.Exception]::new("TERMINAL_$category")
}

function New-EmptyReproductionTests {
    return [ordered]@{
        testProjects = @()
        testFiles = @()
        testNames = @()
        testFilter = ""
        bugBehavior = ""
        rationale = ""
        verificationOutput = ""
    }
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

function Clip-Text {
    param(
        [string]$Text,
        [int]$MaxChars,
        [string]$Marker = "Content trimmed"
    )
    if (-not $Text) { return "" }
    if ($MaxChars -le 0 -or $Text.Length -le $MaxChars) { return $Text.Trim() }
    $safeLength = [Math]::Max(0, $MaxChars - ($Marker.Length + 24))
    $clipped = $Text.Substring(0, $safeLength).TrimEnd()
    return "$clipped`n...[${Marker}; originalChars=$($Text.Length)]"
}

function Estimate-TokenCount {
    param([string]$Text)
    if (-not $Text) { return 0 }
    return [int][Math]::Ceiling($Text.Length / 4.0)
}

function Get-PhaseMetricKey {
    param([string]$PhaseName)
    if (-not $PhaseName) { return "unknown" }
    $phase = $PhaseName.ToLowerInvariant()
    if ($phase -match '^(discover|plan|fix-plan|investigate|implement|reproduce|review)') {
        return $Matches[1]
    }
    return $phase
}

function Add-PhaseMetric {
    param(
        [string]$PhaseName,
        [int]$Attempt,
        [string]$Model,
        [string]$Prompt,
        [string]$Output,
        [double]$DurationSeconds,
        [bool]$Success,
        [bool]$TimedOut,
        [int]$ExitCode
    )
    [void]$phaseMetrics.Add([ordered]@{
        phase = $PhaseName
        phaseKey = Get-PhaseMetricKey -PhaseName $PhaseName
        attempt = $Attempt
        model = $Model
        durationSeconds = [Math]::Round($DurationSeconds, 2)
        promptChars = if ($Prompt) { $Prompt.Length } else { 0 }
        outputChars = if ($Output) { $Output.Length } else { 0 }
        estimatedPromptTokens = Estimate-TokenCount -Text $Prompt
        estimatedOutputTokens = Estimate-TokenCount -Text $Output
        success = [bool]$Success
        timedOut = [bool]$TimedOut
        exitCode = $ExitCode
    })
}

function Get-PhaseMetricsSummary {
    $tokensByPhase = [ordered]@{}
    $durationByPhase = [ordered]@{}
    $callsByPhase = [ordered]@{}
    $modelEscalations = 0
    $lastModelByKey = @{}
    $totalPromptTokens = 0
    $totalOutputTokens = 0

    foreach ($metric in $phaseMetrics) {
        $phaseKey = [string]$metric.phaseKey
        if (-not $tokensByPhase.Contains($phaseKey)) {
            $tokensByPhase[$phaseKey] = 0
            $durationByPhase[$phaseKey] = 0.0
            $callsByPhase[$phaseKey] = 0
        }
        $tokensByPhase[$phaseKey] += ([int]$metric.estimatedPromptTokens + [int]$metric.estimatedOutputTokens)
        $durationByPhase[$phaseKey] = [Math]::Round(([double]$durationByPhase[$phaseKey] + [double]$metric.durationSeconds), 2)
        $callsByPhase[$phaseKey] += 1
        $totalPromptTokens += [int]$metric.estimatedPromptTokens
        $totalOutputTokens += [int]$metric.estimatedOutputTokens

        if ($lastModelByKey.ContainsKey($phaseKey) -and
            $lastModelByKey[$phaseKey] -ne $metric.model -and
            $metric.model -in @($CONST_MODEL_PLAN, $CONST_MODEL_INVESTIGATE, $CONST_MODEL_IMPLEMENT, $CONST_MODEL_REVIEW)) {
            $modelEscalations++
        }
        $lastModelByKey[$phaseKey] = $metric.model
    }

    return [ordered]@{
        totalEstimatedTokens = ($totalPromptTokens + $totalOutputTokens)
        estimatedPromptTokens = $totalPromptTokens
        estimatedOutputTokens = $totalOutputTokens
        tokensByPhase = $tokensByPhase
        durationByPhase = $durationByPhase
        callsByPhase = $callsByPhase
        modelEscalations = $modelEscalations
    }
}

function Format-BulletList {
    param(
        [string[]]$Items,
        [int]$MaxItems = 0,
        [string]$EmptyText = "- None"
    )
    $values = @($Items | Where-Object { $_ })
    if ($values.Count -eq 0) { return $EmptyText }
    if ($MaxItems -gt 0) {
        $values = @($values | Select-Object -First $MaxItems)
    }
    return (($values | ForEach-Object { "- $_" }) -join "`n")
}

function Get-TextTokens {
    param([string]$Text)
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text.ToLowerInvariant(), '[a-z0-9][a-z0-9_-]{2,}') |
        ForEach-Object { $_.Value.Trim('_-') } |
        Where-Object { $_ -and $_.Length -ge 3 } |
        Select-Object -Unique)
}

function Test-LikelyTestPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    return $Path -match '(?i)(^|[\\/._-])(test|tests|spec|specs|integration|functional|e2e|fixture)([\\/._-]|$)'
}

function Get-RelevanceScore {
    param(
        [string]$Candidate,
        [string[]]$SearchTokens
    )
    if (-not $Candidate) { return 0 }
    $lower = $Candidate.ToLowerInvariant()
    $score = 0
    foreach ($token in @($SearchTokens | Select-Object -Unique)) {
        if (-not $token) { continue }
        $escaped = [regex]::Escape($token)
        if ($lower -match "(^|[\\/_\.\-])$escaped([\\/_\.\-]|$)") {
            $score += 12
            continue
        }
        if ($lower.Contains($token)) {
            $score += 4
        }
    }
    return $score
}

function Select-RelevantItems {
    param(
        [string[]]$Items,
        [string]$TaskText = "",
        [string[]]$Targets = @(),
        [int]$MaxChars = 0,
        [int]$MinItems = 1
    )
    $searchTokens = @(
        @(Get-TextTokens -Text $TaskText) +
        @(Get-TextTokens -Text (($Targets | Where-Object { $_ }) -join " "))
    ) | Select-Object -Unique

    $ranked = @($Items | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
        [pscustomobject]@{
            text = [string]$_
            score = Get-RelevanceScore -Candidate ([string]$_) -SearchTokens $searchTokens
            length = ([string]$_).Length
        }
    }) | Sort-Object @{ Expression = 'score'; Descending = $true }, @{ Expression = 'length'; Descending = $false }, @{ Expression = 'text'; Descending = $false }

    $selected = [System.Collections.ArrayList]::new()
    $usedChars = 0
    foreach ($entry in $ranked) {
        $candidate = [string]$entry.text
        $requiredChars = if ($selected.Count -gt 0) { $candidate.Length + 1 } else { $candidate.Length }
        if ($MaxChars -gt 0 -and $selected.Count -ge $MinItems -and ($usedChars + $requiredChars) -gt $MaxChars) {
            continue
        }
        [void]$selected.Add($candidate)
        $usedChars += $requiredChars
    }

    if ($selected.Count -eq 0 -and $ranked.Count -gt 0) {
        [void]$selected.Add([string]$ranked[0].text)
    }

    return [ordered]@{
        selected = @($selected)
        omitted = [Math]::Max(0, $ranked.Count - $selected.Count)
        total = $ranked.Count
    }
}

function Format-RelevantList {
    param(
        [string[]]$Items,
        [string]$TaskText = "",
        [string[]]$Targets = @(),
        [int]$MaxChars = 0,
        [string]$EmptyText = "- None"
    )
    $selection = Select-RelevantItems -Items $Items -TaskText $TaskText -Targets $Targets -MaxChars $MaxChars
    if ($selection.selected.Count -eq 0) { return $EmptyText }
    $lines = @($selection.selected | ForEach-Object { "- $_" })
    if ($selection.omitted -gt 0) {
        $lines += "- ... $($selection.omitted) additional entries omitted"
    }
    return ($lines -join "`n")
}

function Get-CompactClaudeContext {
    param([string]$RepoRoot)
    $claudeMdPath = Join-Path $RepoRoot "CLAUDE.md"
    if (-not (Test-Path $claudeMdPath)) { return "" }
    try {
        $claudeText = [System.IO.File]::ReadAllText($claudeMdPath, [System.Text.Encoding]::UTF8)
    } catch {
        return ""
    }
    $lines = @($claudeText -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    $headings = @($lines | Where-Object { $_ -match '^\s*#' } | Select-Object -First 8)
    $body = @($lines | Where-Object { $_ -notmatch '^\s*#' } | Select-Object -First 14)
    return Clip-Text -Text (($headings + $body) -join "`n") -MaxChars 1800 -Marker "CLAUDE.md trimmed"
}

function Get-CodebaseInventory {
    param(
        [string]$RepoRoot,
        [string]$SolutionPath
    )
    $slnDir = Split-Path $SolutionPath -Parent
    $slnListResult = Invoke-NativeCommand dotnet @("sln", $SolutionPath, "list")
    $projectLines = if ($slnListResult.exitCode -eq 0) {
        @($slnListResult.output -split "`r?`n" |
            Where-Object { $_.Trim() -and $_ -notmatch '^Project\(s\)$|^-+$' })
    } else {
        @()
    }
    $directoryLines = @(Get-ChildItem -Path $slnDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(?i)[\\/](bin|obj|node_modules|packages|\.git|\.vs)([\\/]|$)' } |
        ForEach-Object { Get-RelativePath -BasePath $slnDir -TargetPath $_.FullName } |
        Select-Object -Unique)

    return [ordered]@{
        claudeContext = Get-CompactClaudeContext -RepoRoot $RepoRoot
        projects = @($projectLines)
        directories = @($directoryLines)
    }
}

function Build-CompactCodebaseContext {
    param(
        $Inventory,
        [string]$TaskText = "",
        [string[]]$Targets = @()
    )
    $parts = [System.Collections.ArrayList]::new()
    if ($Inventory.claudeContext) {
        [void]$parts.Add("CLAUDE_MD_SUMMARY:`n$($Inventory.claudeContext)")
    }
    if ($Inventory.projects.Count -gt 0) {
        [void]$parts.Add("PROJECTS:`n" + (Format-RelevantList -Items $Inventory.projects -TaskText $TaskText -Targets $Targets -MaxChars 1200 -EmptyText "- No projects"))
    }
    if ($Inventory.directories.Count -gt 0) {
        [void]$parts.Add("MODULES:`n" + (Format-RelevantList -Items $Inventory.directories -TaskText $TaskText -Targets $Targets -MaxChars 1000 -EmptyText "- No modules"))
    }
    return Clip-Text -Text (($parts -join "`n`n").Trim()) -MaxChars $CONST_CONTEXT_MAX_CHARS -Marker "Codebase context trimmed"
}

function Get-ScopedCodebaseContext {
    param(
        $Inventory,
        [string]$TaskText = "",
        [string[]]$Targets = @(),
        [string[]]$ChangedFiles = @()
    )
    $relevantTargets = @($Targets | Where-Object { $_ } | Select-Object -Unique)
    $baseContext = Build-CompactCodebaseContext -Inventory $Inventory -TaskText $TaskText -Targets $relevantTargets
    return Format-ScopedContext -BaseContext $baseContext -Targets $relevantTargets -ChangedFiles $ChangedFiles
}

function Format-ScopedContext {
    param(
        [string]$BaseContext,
        [string[]]$Targets = @(),
        [string[]]$ChangedFiles = @()
    )
    $parts = [System.Collections.ArrayList]::new()
    if ($BaseContext) {
        [void]$parts.Add("CODEBASE SUMMARY:`n$BaseContext")
    }
    $targetHints = @($Targets | Where-Object { $_ } | Select-Object -Unique -First $CONST_TARGET_HINTS_MAX)
    if ($targetHints.Count -gt 0) {
        [void]$parts.Add("TARGET HINTS:`n" + (Format-BulletList -Items $targetHints -EmptyText "- No target hints"))
    }
    $changed = @($ChangedFiles | Where-Object { $_ } | Select-Object -Unique -First 6)
    if ($changed.Count -gt 0) {
        [void]$parts.Add("AFFECTED FILES:`n" + (Format-BulletList -Items $changed -EmptyText "- No files"))
    }
    return ($parts -join "`n`n").Trim()
}

function Get-NoChangeAssessment {
    param(
        [string]$Output,
        [string[]]$Targets = @()
    )
    $trimmed = if ($Output) { $Output.Trim() } else { "" }
    if (-not $trimmed) {
        return [ordered]@{
            explicitSatisfied = $false
            explicitNoChange = $false
            hasStrongLanguage = $false
            evidenceTargets = @()
            hasEvidence = $false
            usable = $false
            shouldVerify = $false
        }
    }

    $explicitSatisfied = $trimmed -match '(?im)^RESULT\s*:\s*NO_CHANGE_ALREADY_SATISFIED\s*$'
    $explicitNoChange = $explicitSatisfied -or ($trimmed -match '(?im)^RESULT\s*:\s*NO_CHANGE\b')
    $hasStrongLanguage = $trimmed -match '(?im)bereits implementiert|bereits umgesetzt|already implemented|already satisfied'
    $evidenceTargets = @($Targets + (Get-ActionableItems -Text $trimmed) | Where-Object { $_ } | Select-Object -Unique)
    $nonEmptyLines = @($trimmed -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
    $hasReasonSection = $trimmed -match '(?im)^(REASON|ROOT_CAUSE|SUMMARY|NEXT_ACTION)\s*:'
    $usable = ($nonEmptyLines.Count -ge 2) -or $hasReasonSection -or ($evidenceTargets.Count -gt 0)
    $shouldVerify = (($explicitSatisfied -or $explicitNoChange -or $hasStrongLanguage) -and $usable)

    return [ordered]@{
        explicitSatisfied = $explicitSatisfied
        explicitNoChange = $explicitNoChange
        hasStrongLanguage = $hasStrongLanguage
        evidenceTargets = @($evidenceTargets)
        hasEvidence = ($evidenceTargets.Count -gt 0)
        usable = $usable
        shouldVerify = $shouldVerify
    }
}

function Get-ReviewFileKind {
    param([string]$Path)
    if (-not $Path) { return "unknown" }
    if ($Path -match '(?i)\.(csproj|props|targets|sln|slnx|json|ya?ml|config)$') { return "config" }
    if (Test-LikelyTestPath -Path $Path) { return "test" }
    if ($Path -match '(?i)\.(md|txt)$') { return "docs" }
    if ($Path -match '(?i)\.(css|scss|sass|less|svg|png|jpe?g|gif|resx)$') { return "resource" }
    return "production"
}

function Test-LowRiskReview {
    param(
        [string[]]$ChangedFiles,
        [string]$DiffText,
        [string]$WarningText,
        [bool]$ReproductionConfirmed,
        [string]$TaskClass
    )
    $files = @($ChangedFiles | Where-Object { $_ })
    if ($files.Count -eq 0) { return $false }
    if ($files.Count -gt $CONST_REVIEW_FAST_MAX_FILES) { return $false }
    if ($DiffText.Length -gt $CONST_REVIEW_FAST_MAX_DIFF_CHARS) { return $false }
    if ($WarningText) { return $false }
    if ($TaskClass -eq "INVESTIGATIVE") { return $false }
    $kinds = @($files | ForEach-Object { Get-ReviewFileKind -Path $_ })
    if (@($kinds | Where-Object { $_ -eq "config" }).Count -gt 0) { return $false }
    $productionCount = @($kinds | Where-Object { $_ -eq "production" }).Count
    if ($productionCount -gt 0) {
        if ($files.Count -ne 1) { return $false }
        if ($TaskClass -ne "DIRECT_EDIT") { return $false }
        if ($ReproductionConfirmed) { return $false }
        if ($DiffText.Length -gt 4500) { return $false }
    }
    return $true
}

function Get-DiffBlocksByFile {
    param([string]$DiffText)
    $blocks = [System.Collections.ArrayList]::new()
    if (-not $DiffText) { return @($blocks) }

    $matches = [regex]::Matches($DiffText, '(?m)^diff --git a/(?<a>[^\r\n]+?) b/(?<b>[^\r\n]+?)\r?$')
    if ($matches.Count -eq 0) {
        [void]$blocks.Add([ordered]@{ path = "(patch)"; diff = $DiffText.Trim() })
        return @($blocks)
    }

    for ($i = 0; $i -lt $matches.Count; $i++) {
        $start = $matches[$i].Index
        $end = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $DiffText.Length }
        $path = Normalize-RepoRelativePath -Path $matches[$i].Groups['b'].Value
        $blockText = $DiffText.Substring($start, $end - $start).Trim()
        [void]$blocks.Add([ordered]@{
            path = $path
            diff = $blockText
        })
    }

    return @($blocks)
}

function Get-DiffTextForFile {
    param(
        $Blocks,
        [string]$Path
    )
    if (-not $Path) { return "" }
    $normalized = Normalize-RepoRelativePath -Path $Path
    $exact = @($Blocks | Where-Object { (Normalize-RepoRelativePath -Path ([string]$_.path)) -ieq $normalized })
    if ($exact.Count -gt 0) { return [string]$exact[0].diff }
    $suffix = @($Blocks | Where-Object {
        $candidate = Normalize-RepoRelativePath -Path ([string]$_.path)
        if (-not $candidate) { return $false }
        $candidate.EndsWith($normalized, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalized.EndsWith($candidate, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($suffix.Count -gt 0) { return [string]$suffix[0].diff }
    return ""
}

function Get-SyntheticReviewContentForFile {
    param([string]$Path)
    $normalized = Normalize-RepoRelativePath -Path $Path
    if (-not $normalized) { return "" }
    $fullPath = Join-Path (Get-Location).Path $normalized
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return "" }
    try {
        $content = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    } catch {
        try {
            $content = [System.IO.File]::ReadAllText($fullPath)
        } catch {
            return ""
        }
    }
    $body = $content.TrimEnd()
    if (-not $body) { $body = "(leere Datei)" }
    return @"
NEW / UNTRACKED DATEI: $normalized
DATEIINHALT:
$body
"@.Trim()
}

function Get-DiffHunks {
    param([string]$DiffText)
    $trimmed = if ($DiffText) { $DiffText.Trim() } else { "" }
    if (-not $trimmed) {
        return [ordered]@{
            header = ""
            hunks = @()
        }
    }

    $matches = [regex]::Matches($trimmed, '(?m)^@@ .* @@.*$')
    if ($matches.Count -eq 0) {
        return [ordered]@{
            header = $trimmed
            hunks = @()
        }
    }

    $hunks = [System.Collections.ArrayList]::new()
    $header = $trimmed.Substring(0, $matches[0].Index).Trim()
    for ($i = 0; $i -lt $matches.Count; $i++) {
        $start = $matches[$i].Index
        $end = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $trimmed.Length }
        [void]$hunks.Add($trimmed.Substring($start, $end - $start).Trim())
    }

    return [ordered]@{
        header = $header
        hunks = @($hunks)
    }
}

function Get-ReviewDiffExcerpt {
    param(
        [string]$DiffText,
        [int]$MaxChars
    )
    $trimmed = if ($DiffText) { $DiffText.Trim() } else { "" }
    if (-not $trimmed) {
        return [ordered]@{
            text = ""
            totalHunks = 0
            includedHunks = 0
            omittedHunks = 0
            wasTruncated = $false
        }
    }
    if ($MaxChars -le 0 -or $trimmed.Length -le $MaxChars) {
        return [ordered]@{
            text = $trimmed
            totalHunks = 0
            includedHunks = 0
            omittedHunks = 0
            wasTruncated = $false
        }
    }

    $parsed = Get-DiffHunks -DiffText $trimmed
    if ($parsed.hunks.Count -eq 0) {
        return [ordered]@{
            text = Clip-Text -Text $trimmed -MaxChars $MaxChars -Marker "Diff for file trimmed"
            totalHunks = 0
            includedHunks = 0
            omittedHunks = 1
            wasTruncated = $true
        }
    }

    $parts = [System.Collections.ArrayList]::new()
    if ($parsed.header) {
        $headerBudget = [Math]::Min($parsed.header.Length, [Math]::Max(220, [int][Math]::Floor($MaxChars * 0.22)))
        $headerBudget = [Math]::Min($headerBudget, [Math]::Max(0, $MaxChars - 240))
        if ($headerBudget -gt 0) {
            $headerText = if ($parsed.header.Length -le $headerBudget) {
                $parsed.header
            } else {
                Clip-Text -Text $parsed.header -MaxChars $headerBudget -Marker "Diff header trimmed"
            }
            if ($headerText) {
                [void]$parts.Add($headerText)
            }
        }
    }

    $priorityIndexes = [System.Collections.ArrayList]::new()
    [void]$priorityIndexes.Add(0)
    if ($parsed.hunks.Count -gt 1) {
        [void]$priorityIndexes.Add($parsed.hunks.Count - 1)
    }
    for ($i = 1; $i -lt $parsed.hunks.Count - 1; $i++) {
        [void]$priorityIndexes.Add($i)
    }

    $includedIndexes = [System.Collections.ArrayList]::new()
    $wasTruncated = $false
    foreach ($index in @($priorityIndexes | Select-Object -Unique)) {
        $hunk = [string]$parsed.hunks[$index]
        $currentText = ($parts -join "`n`n")
        $separatorChars = if ($parts.Count -gt 0) { 2 } else { 0 }
        $availableChars = $MaxChars - $currentText.Length - $separatorChars
        if ($availableChars -le 0) {
            $wasTruncated = $true
            continue
        }

        $tentativeText = if ($parts.Count -gt 0) { "$currentText`n`n$hunk" } else { $hunk }
        if ($tentativeText.Length -le $MaxChars) {
            [void]$parts.Add($hunk)
            [void]$includedIndexes.Add($index)
            continue
        }

        $isAnchorHunk = ($index -eq 0) -or ($index -eq ($parsed.hunks.Count - 1))
        if (($includedIndexes.Count -eq 0 -or $isAnchorHunk) -and $availableChars -gt 180) {
            [void]$parts.Add((Clip-Text -Text $hunk -MaxChars $availableChars -Marker "Hunk trimmed"))
            [void]$includedIndexes.Add($index)
        }
        $wasTruncated = $true
        if ($availableChars -gt 180) {
            break
        }
    }

    $includedCount = (@($includedIndexes | Select-Object -Unique)).Count
    $omittedHunks = [Math]::Max(0, $parsed.hunks.Count - $includedCount)
    if ($omittedHunks -gt 0) {
        $wasTruncated = $true
    }

    $text = ($parts -join "`n`n").Trim()
    if ($wasTruncated) {
        $summaryLine = "...[Diff-Auszug; includedHunks=$includedCount/$($parsed.hunks.Count)]"
        if (($text.Length + $summaryLine.Length + 1) -le $MaxChars) {
            $text = "$text`n$summaryLine"
        } else {
            $safeBudget = [Math]::Max(0, $MaxChars - $summaryLine.Length - 1)
            $text = (Clip-Text -Text $text -MaxChars $safeBudget -Marker "Diff for file trimmed")
            $text = "$text`n$summaryLine"
        }
    }

    return [ordered]@{
        text = $text
        totalHunks = $parsed.hunks.Count
        includedHunks = $includedCount
        omittedHunks = $omittedHunks
        wasTruncated = $wasTruncated
    }
}

function Get-CompactReviewPayload {
    param(
        [string]$PlanText,
        [string]$InvestigationText,
        [string]$ReproductionText,
        [string]$DiffText,
        [string]$DiffStat,
        [string[]]$ChangedFiles,
        [string]$WarningText,
        [string]$HistoryText,
        [bool]$LowRiskReview
    )
    $maxDiffChars = if ($LowRiskReview) { $CONST_REVIEW_DIFF_LITE_CHARS } else { $CONST_REVIEW_DIFF_FULL_CHARS }
    $parts = [System.Collections.ArrayList]::new()
    $omittedProductionHunks = $false
    $truncatedFiles = [System.Collections.ArrayList]::new()
    [void]$parts.Add("FIX PLAN:`n" + (Clip-Text -Text $PlanText -MaxChars $CONST_REVIEW_PLAN_MAX_CHARS -Marker "Fix plan trimmed"))
    if ($InvestigationText) {
        [void]$parts.Add("INVESTIGATION:`n" + (Clip-Text -Text $InvestigationText -MaxChars 1800 -Marker "Investigation trimmed"))
    }
    if ($ReproductionText) {
        [void]$parts.Add("REPRODUCTION:`n" + (Clip-Text -Text $ReproductionText -MaxChars 1400 -Marker "Reproduction trimmed"))
    }
    $reviewFiles = if ($ChangedFiles.Count -gt 0) {
        @($ChangedFiles | Select-Object -Unique)
    } else {
        @(Get-DiffBlocksByFile -DiffText $DiffText | ForEach-Object { $_.path } | Select-Object -Unique)
    }
    if ($reviewFiles.Count -gt 0) {
        [void]$parts.Add("CHANGED FILES:`n" + (Format-BulletList -Items $reviewFiles -MaxItems 8 -EmptyText "- No files"))
    }
    if ($DiffStat) {
        [void]$parts.Add("DIFF STAT:`n" + (Clip-Text -Text $DiffStat -MaxChars 1200 -Marker "Diff stat trimmed"))
    }
    $diffBlocks = Get-DiffBlocksByFile -DiffText $DiffText
    $missingDirectDiffs = @($reviewFiles | Where-Object { -not (Get-DiffTextForFile -Blocks $diffBlocks -Path $_) })
    $preserveFullDiffs = (-not $LowRiskReview) -and $reviewFiles.Count -gt 0 -and $reviewFiles.Count -le $CONST_REVIEW_FULL_PRESERVE_MAX_FILES -and $DiffText.Length -le $CONST_REVIEW_FULL_PRESERVE_MAX_DIFF_CHARS -and $missingDirectDiffs.Count -eq 0
    if ($reviewFiles.Count -gt 0) {
        $perFileBudget = if ($preserveFullDiffs) { 0 } else { [Math]::Max(1, [int][Math]::Floor($maxDiffChars / [Math]::Max(1, $reviewFiles.Count))) }
        $fileSections = foreach ($file in $reviewFiles) {
            $fileDiff = Get-DiffTextForFile -Blocks $diffBlocks -Path $file
            if (-not $fileDiff) { $fileDiff = Get-SyntheticReviewContentForFile -Path $file }
            if (-not $fileDiff) { $fileDiff = "Kein Diffblock oder Dateitext fuer diese Datei gefunden." }
            $fileKind = Get-ReviewFileKind -Path $file
            if ($preserveFullDiffs) {
                "DATEI: $file`n$fileDiff"
                continue
            }

            $diffExcerpt = Get-ReviewDiffExcerpt -DiffText $fileDiff -MaxChars $perFileBudget
            if ($diffExcerpt.wasTruncated) {
                [void]$truncatedFiles.Add($file)
                if ($fileKind -eq "production") {
                    $omittedProductionHunks = $true
                }
            }
            "DATEI: $file`n$($diffExcerpt.text)"
        }
        [void]$parts.Add("DATEIWEISE DIFFS:`n" + (($fileSections | Where-Object { $_ }) -join "`n`n"))
    } else {
        [void]$parts.Add("GIT DIFF EXCERPT:`n" + (Clip-Text -Text $DiffText -MaxChars $maxDiffChars -Marker "Diff trimmed"))
    }
    if ($WarningText) {
        [void]$parts.Add("PREFLIGHT WARNINGS:`n" + (Clip-Text -Text $WarningText -MaxChars 1000 -Marker "Warnings trimmed"))
    }
    if ($HistoryText) {
        [void]$parts.Add("PRIOR FEEDBACK:`n" + (Clip-Text -Text $HistoryText -MaxChars $CONST_REVIEW_HISTORY_MAX_CHARS -Marker "Feedback trimmed"))
    }
    return [ordered]@{
        payload = ($parts -join "`n`n").Trim()
        omittedProductionHunks = $omittedProductionHunks
        truncatedFiles = @($truncatedFiles | Select-Object -Unique)
    }
}

function Ensure-ArtifactDir {
    param([string]$Root)
    if (-not $artifactRunDir) {
        $logDir = Join-Path $Root ".claude-develop-logs\runs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:artifactRunDir = Join-Path $logDir $TaskName
    }
    if ($artifactRunDir -and -not (Test-Path $artifactRunDir)) { New-Item -ItemType Directory -Path $artifactRunDir -Force | Out-Null }
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
    $targetDir = Ensure-ArtifactDir -Root $repoRoot
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
        schedulerTaskId = $SchedulerTaskId
        commandType = $CommandType
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
        routeDecision = $routeDecision
        testability = $testability
        reproductionConfirmed = [bool]$reproductionConfirmed
    }
    Save-DebugJson -Name "manifest.json" -Object $manifest | Out-Null
}

function Write-SchedulerSnapshot {
    if (-not $artifactRunDir -or -not $repoRoot) { return }
    $snapshot = [ordered]@{
        version = 1
        schedulerTaskId = $SchedulerTaskId
        commandType = $CommandType
        taskName = $TaskName
        repoRoot = $repoRoot
        solutionPath = $SolutionPath
        promptFile = $PromptFile
        resultFile = $ResultFile
        branchName = $branchName
        worktreePath = $worktreePath
        currentPhase = $currentPhase
        updatedAt = (Get-Date).ToString("o")
        processId = $PID
        taskLine = $taskLine
        taskClass = $taskClass
        route = $routeDecision
        testability = $testability
        discoverConclusion = $discoverConclusion
        investigationConclusion = $investigationConclusion
        discoverTargetHints = @(Get-NormalizedPathSet -Paths $discoverVerdict.targetHints)
        investigationTargets = @(Get-NormalizedPathSet -Paths $investigationVerdict.targets)
        planTargets = @(Get-NormalizedPathSet -Paths $planTargets)
        changedFiles = @(Get-NormalizedPathSet -Paths $changedFiles)
        implementationScopeCheck = $implementationScopeCheck
        finalStatus = $finalStatus
        finalCategory = $finalCategory
        artifacts = [ordered]@{
            runDir = $artifactRunDir
            debugDir = $debugRunDir
        }
    }
    Save-JsonArtifact -Name "scheduler-snapshot.json" -Object $snapshot | Out-Null
    Save-DebugJson -Name "scheduler-snapshot.json" -Object $snapshot | Out-Null
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

function Get-RelativePath {
    param([string]$BasePath, [string]$TargetPath)
    if (-not $BasePath -or -not $TargetPath) { return $TargetPath }
    $baseResolved = Get-CanonicalPath -Path $BasePath
    $targetResolved = Get-CanonicalPath -Path $TargetPath
    $baseUri = [System.Uri]::new($baseResolved.TrimEnd('\') + "\")
    $targetUri = [System.Uri]::new($targetResolved)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
}

function Get-SectionLines {
    param([string]$Text, [string]$Header)
    $lines = [System.Collections.ArrayList]::new()
    if (-not $Text -or -not $Header) { return @($lines) }
    $capture = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match ("^\s*" + [regex]::Escape($Header) + "\s*:\s*$")) {
            $capture = $true
            continue
        }
        if ($capture -and $line -match '^[A-Z_]+\s*:') {
            break
        }
        if ($capture) {
            [void]$lines.Add($line)
        }
    }
    return @($lines)
}

function Get-BulletSectionValues {
    param([string]$Text, [string]$Header)
    return @(Get-SectionLines -Text $Text -Header $Header |
        ForEach-Object {
            if ($_ -match '^\s*-\s+(.+?)\s*$') { $Matches[1].Trim() }
        } |
        Where-Object { $_ } |
        Select-Object -Unique)
}

function Get-ScalarSectionText {
    param([string]$Text, [string]$Header)
    $sectionLines = Get-SectionLines -Text $Text -Header $Header
    return (($sectionLines | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n").Trim()
}

function Get-TestProjectInventory {
    param(
        [string]$SolutionPath,
        [string]$WorktreeRoot
    )
    $slnDir = Split-Path $SolutionPath -Parent
    if (-not $WorktreeRoot) { $WorktreeRoot = (Get-Location).Path }
    $listedProjects = @{}
    $slnListResult = Invoke-NativeCommand dotnet @("sln", $SolutionPath, "list")
    if ($slnListResult.exitCode -eq 0) {
        foreach ($line in ($slnListResult.output -split "`r?`n")) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed -match '^Project\(s\)$|^-+$') { continue }
            $listedProjects[$trimmed.Replace("/", "\").ToLowerInvariant()] = $true
        }
    }

    $inventory = [System.Collections.ArrayList]::new()
    $projectFiles = Get-ChildItem -Path $slnDir -Recurse -Filter "*.csproj" -File -ErrorAction SilentlyContinue
    foreach ($project in $projectFiles) {
        try {
            $content = [System.IO.File]::ReadAllText($project.FullName, [System.Text.Encoding]::UTF8)
        } catch {
            continue
        }
        if ($content -notmatch 'Microsoft\.NET\.Test\.Sdk|xunit|NUnit|MSTest') { continue }

        $solutionRelPath = Get-RelativePath -BasePath $slnDir -TargetPath $project.FullName
        $solutionDirRelPath = Get-RelativePath -BasePath $slnDir -TargetPath $project.Directory.FullName
        $worktreeRelPath = Get-RelativePath -BasePath $WorktreeRoot -TargetPath $project.FullName
        $worktreeDirRelPath = Get-RelativePath -BasePath $WorktreeRoot -TargetPath $project.Directory.FullName
        $testFiles = @(Get-ChildItem -Path $project.Directory.FullName -Recurse -Include "*.cs" -File -ErrorAction SilentlyContinue)
        $likelyType = if ($project.FullName -match '(?i)integration|functional|e2e') { "integration" } else { "unit" }
        [void]$inventory.Add([ordered]@{
            name = $project.BaseName
            relPath = $worktreeRelPath
            fullPath = $project.FullName
            directoryRelPath = $worktreeDirRelPath
            solutionRelativePath = $solutionRelPath
            solutionRelativeDirectory = $solutionDirRelPath
            worktreeRelativePath = $worktreeRelPath
            worktreeRelativeDirectory = $worktreeDirRelPath
            listedInSolution = [bool]$listedProjects.ContainsKey($solutionRelPath.ToLowerInvariant())
            testFileCount = $testFiles.Count
            likelyType = $likelyType
        })
    }
    return @($inventory)
}

function Format-TestProjectsForPrompt {
    param(
        $Projects,
        [string]$TaskText = "",
        [string[]]$Targets = @()
    )
    if (-not $Projects -or $Projects.Count -eq 0) { return "- No test projects detected." }
    $items = @($Projects | ForEach-Object {
        "$($_.relPath) [listed=$($_.listedInSolution); type=$($_.likelyType); files=$($_.testFileCount)]"
    })
    return Format-RelevantList -Items $items -TaskText $TaskText -Targets $Targets -MaxChars $CONST_TEST_PROJECTS_MAX_CHARS -EmptyText "- No test projects detected."
}

function Get-DiscoveryVerdict {
    param(
        [string]$Output,
        $TestProjects
    )

    $route = "UNCERTAIN"
    if ($Output -match '(?im)^ROUTE\s*:\s*(DIRECT_EDIT|BUGFIX_TESTABLE|BUGFIX_NONTESTABLE|UNCERTAIN)\s*$') {
        $route = $Matches[1].ToUpperInvariant()
    }

    $bugConfidence = "LOW"
    if ($Output -match '(?im)^BUG_CONFIDENCE\s*:\s*(HIGH|MEDIUM|LOW)\s*$') {
        $bugConfidence = $Matches[1].ToUpperInvariant()
    }

    $parsedTestability = if ($Output -match '(?im)^TESTABILITY\s*:\s*(YES|NO|UNKNOWN)\s*$') {
        $Matches[1].ToUpperInvariant()
    } elseif ($TestProjects.Count -eq 0) {
        "NO"
    } else {
        "UNKNOWN"
    }

    $targetHints = Get-BulletSectionValues -Text $Output -Header "TARGET_HINTS"
    if ($targetHints.Count -eq 0) {
        $targetHints = @(Get-ActionableItems -Text $Output | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' })
    }

    $rationale = Get-ScalarSectionText -Text $Output -Header "RATIONALE"
    $nextPhase = if ($Output -match '(?im)^NEXT_PHASE\s*:\s*(FIX_PLAN|INVESTIGATE|REPRODUCE)\s*$') {
        $Matches[1].ToUpperInvariant()
    } else {
        ""
    }

    if ($TestProjects.Count -eq 0) {
        if ($route -eq "BUGFIX_TESTABLE") { $route = "BUGFIX_NONTESTABLE" }
        if ($parsedTestability -eq "YES") { $parsedTestability = "NO" }
    }

    if (-not $nextPhase) {
        switch ($route) {
            "DIRECT_EDIT" { $nextPhase = "FIX_PLAN" }
            "BUGFIX_TESTABLE" { $nextPhase = "INVESTIGATE" }
            "BUGFIX_NONTESTABLE" { $nextPhase = "INVESTIGATE" }
            default { $nextPhase = "INVESTIGATE" }
        }
    }

    return [ordered]@{
        route = $route
        bugConfidence = $bugConfidence
        testability = $parsedTestability
        targetHints = @($targetHints | Select-Object -Unique)
        rationale = $rationale
        nextPhase = $nextPhase
        summary = $Output.Trim()
    }
}

function Test-ReproductionChangeSet {
    param(
        [string[]]$ChangedFiles,
        $TestProjects
    )

    $allowedPrefixes = @($TestProjects | ForEach-Object {
        $prefix = Normalize-RepoRelativePath -Path $_.directoryRelPath
        if ($prefix) { $prefix.TrimEnd('\') + "\" }
    } | Where-Object { $_ } | Select-Object -Unique)
    $allowedProjectFiles = @($TestProjects | ForEach-Object {
        Normalize-RepoRelativePath -Path $_.relPath
    } | Where-Object { $_ } | Select-Object -Unique)
    $invalidFiles = [System.Collections.ArrayList]::new()

    foreach ($file in @($ChangedFiles)) {
        $normalized = Normalize-RepoRelativePath -Path $file
        $allowed = $allowedProjectFiles -contains $normalized
        if (-not $allowed) {
            foreach ($prefix in $allowedPrefixes) {
                if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $allowed = $true
                    break
                }
            }
        }
        if (-not $allowed) {
            [void]$invalidFiles.Add($file)
        }
    }

    return [ordered]@{
        valid = ($invalidFiles.Count -eq 0 -and @($ChangedFiles).Count -gt 0)
        invalidFiles = @($invalidFiles)
    }
}

function Get-TestFilterFromNames {
    param([string[]]$TestNames)
    $clauses = @()
    foreach ($name in @($TestNames | Select-Object -First 6)) {
        $fragment = $name.Trim()
        if ($fragment -match '^[^(]+') { $fragment = $Matches[0].Trim() }
        $fragment = $fragment.Replace('"', '').Trim()
        if (-not $fragment) { continue }
        $clauses += "FullyQualifiedName~$fragment"
    }
    return ($clauses -join "|")
}

function Invoke-TargetedTestRun {
    param(
        [string]$SolutionPath,
        [string[]]$ProjectPaths = @(),
        [string]$TestFilter = "",
        [bool]$ExpectFailure = $false,
        [switch]$NoBuild
    )

    $targets = if ($ProjectPaths -and $ProjectPaths.Count -gt 0) { @($ProjectPaths) } else { @($SolutionPath) }
    $outputs = [System.Collections.ArrayList]::new()
    $failureObserved = $false
    $allPassed = $true
    $matchedNoTests = $false
    $commandError = $false
    $testFailureObserved = $false

    foreach ($target in $targets) {
        $args = @("test", $target, "--verbosity", "quiet")
        if ($NoBuild) {
            $args += "--no-build"
        }
        if ($TestFilter) {
            $args += @("--filter", $TestFilter)
        }
        $result = Invoke-NativeCommand dotnet $args
        $header = "> dotnet " + ($args -join " ")
        [void]$outputs.Add(($header + "`n" + $result.output).Trim())
        if ($result.output -match '(?im)matched no test|no test is available') {
            $matchedNoTests = $true
        }
        if ($result.output -match '(?im)project file does not exist|msbuild\s*: error|unknown switch|invalid argument') {
            $commandError = $true
        }
        if ($result.output -match '(?im)\bfailed!\b|\bfailed:\s*[1-9]') {
            $testFailureObserved = $true
        }
        if ($result.exitCode -ne 0) {
            $failureObserved = $true
            $allPassed = $false
        }
    }

    if ($matchedNoTests -or $commandError) {
        $allPassed = $false
    }

    return [ordered]@{
        targets = @($targets)
        testFilter = $TestFilter
        output = (($outputs -join "`n`n").Trim())
        failureObserved = [bool]$failureObserved
        allPassed = [bool]$allPassed
        matchedNoTests = [bool]$matchedNoTests
        commandError = [bool]$commandError
        testFailureObserved = [bool]$testFailureObserved
        exitCode = if ($allPassed) { 0 } else { 1 }
        expectFailure = [bool]$ExpectFailure
    }
}

function Get-WorktreeFileSnapshot {
    param([string[]]$Files)
    $snapshot = [System.Collections.ArrayList]::new()
    foreach ($file in @($Files | Where-Object { $_ })) {
        $normalized = $file.Replace("/", "\")
        $entry = [ordered]@{
            path = $normalized
            exists = (Test-Path $normalized)
            content = ""
        }
        if ($entry.exists) {
            $entry.content = [System.IO.File]::ReadAllText((Resolve-Path $normalized).Path, [System.Text.Encoding]::UTF8)
        }
        [void]$snapshot.Add($entry)
    }
    return @($snapshot)
}

function Restore-WorktreeBaseline {
    param(
        [string]$PatchContent,
        $FileSnapshot = @()
    )
    Reset-Worktree
    if ($PatchContent -and $PatchContent.Trim()) {
        $tempDir = Join-Path $env:TEMP "claude-develop"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
        $patchFile = Join-Path $tempDir "repro-baseline-$([guid]::NewGuid()).patch"
        [System.IO.File]::WriteAllText($patchFile, $PatchContent, [System.Text.Encoding]::UTF8)
        try {
            $applyResult = Invoke-NativeCommand git @("apply", "--whitespace=nowarn", $patchFile)
            if ($applyResult.exitCode -ne 0) {
                throw [System.Exception]::new("REPRO_BASELINE_APPLY_FAILED: $($applyResult.output)")
            }
        } finally {
            Remove-Item $patchFile -ErrorAction SilentlyContinue
        }
    }
    foreach ($entry in @($FileSnapshot)) {
        $targetPath = Join-Path (Get-Location).Path $entry.path
        if ($entry.exists) {
            $targetDir = Split-Path $targetPath -Parent
            if ($targetDir -and -not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($targetPath, [string]$entry.content, [System.Text.Encoding]::UTF8)
        } elseif (Test-Path $targetPath) {
            Remove-Item $targetPath -Force -ErrorAction SilentlyContinue
        }
    }
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

function Test-ConcreteTestTargets {
    param([string[]]$Targets)
    $concreteTargets = @($Targets | Where-Object {
        $_ -and
        $_ -notmatch '^<' -and
        $_ -match '(\*|\\|/|\.(cs|csproj)\b)' -and
        (Test-LikelyTestPath -Path $_)
    })
    return $concreteTargets.Count -gt 0
}

function Get-ModelForPlan {
    param(
        [string]$TaskClass,
        [string[]]$Targets,
        [string]$PipelineProfile = "COMPLEX"
    )
    if ($PipelineProfile -eq "SIMPLE") { return $CONST_MODEL_FAST }
    if ($TaskClass -eq "DIRECT_EDIT") { return $CONST_MODEL_FAST }
    if (Test-ConcreteTargets -Targets $Targets) { return $CONST_MODEL_FAST }
    return $CONST_MODEL_PLAN
}

function Get-ModelForInvestigate {
    param(
        [string]$TaskClass,
        [string[]]$Targets,
        [int]$Attempt = 1,
        [string]$PreviousOutput = ""
    )
    $hasConcreteTargets = Test-ConcreteTargets -Targets $Targets
    if ($Attempt -gt 1 -and -not $hasConcreteTargets -and -not (Test-HasActionableSignal -Text $PreviousOutput)) {
        return $CONST_MODEL_INVESTIGATE
    }
    if ($hasConcreteTargets) { return $CONST_MODEL_FAST }
    if ($TaskClass -eq "DIRECT_EDIT" -and ($Attempt -eq 1 -or (Test-HasActionableSignal -Text $PreviousOutput))) { return $CONST_MODEL_FAST }
    return $CONST_MODEL_INVESTIGATE
}

function Get-ModelForReproduce {
    param(
        [string]$TaskText = "",
        [string[]]$Targets = @(),
        [int]$Attempt = 1,
        [string]$LastFailureCategory = ""
    )
    if ($Attempt -gt 1 -and $LastFailureCategory -and $LastFailureCategory -ne "REPRO_CALL_FAILED") {
        return $CONST_MODEL_INVESTIGATE
    }
    if (Test-ConcreteTestTargets -Targets $Targets) {
        return $CONST_MODEL_FAST
    }
    $taskTestTargets = @(Get-ActionableItems -Text $TaskText | Where-Object { Test-LikelyTestPath -Path $_ })
    if ($taskTestTargets.Count -gt 0) {
        return $CONST_MODEL_FAST
    }
    return $CONST_MODEL_INVESTIGATE
}

function Get-ModelForImplement {
    param(
        [string]$TaskClass,
        [bool]$InvestigationRequired,
        [string[]]$Targets,
        [string]$TaskText = "",
        [string]$PhaseContext = "",
        [string]$PipelineProfile = "COMPLEX"
    )
    if ($PipelineProfile -eq "SIMPLE" -and (Test-ConcreteTargets -Targets $Targets) -and $Targets.Count -le 3) {
        return $CONST_MODEL_FAST
    }
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
        [string]$TaskText = "",
        [string]$PipelineProfile = "COMPLEX"
    )
    if ($PhaseName -in @("PLAN", "FIX_PLAN")) {
        return Get-ModelForPlan -TaskClass $TaskClass -Targets $Targets -PipelineProfile $PipelineProfile
    }
    if ($PhaseName -eq "INVESTIGATE") {
        if (Test-HasActionableSignal -Text $PreviousOutput) { return $CONST_MODEL_FAST }
        return $CONST_MODEL_INVESTIGATE
    }
    if ($PhaseName -eq "IMPLEMENT") {
        return Get-ModelForImplement -TaskClass $TaskClass -InvestigationRequired $InvestigationRequired -Targets $Targets -TaskText $TaskText -PhaseContext $PreviousOutput -PipelineProfile $PipelineProfile
    }
    if ($PhaseName -eq "REVIEW_MINOR") { return $CONST_MODEL_FAST }
    return $CONST_MODEL_IMPLEMENT
}

function Get-ModelForReview {
    param(
        [string[]]$ChangedFiles,
        [string]$DiffText,
        [string]$WarningText,
        [bool]$ReproductionConfirmed,
        [string]$TaskClass,
        [bool]$ForceFullReview = $false
    )
    if (-not $ForceFullReview -and (Test-LowRiskReview -ChangedFiles $ChangedFiles -DiffText $DiffText -WarningText $WarningText -ReproductionConfirmed $ReproductionConfirmed -TaskClass $TaskClass)) {
        return $CONST_MODEL_FAST
    }
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
        "- No details available."
    }
    $salvageText = if ($salvaged.Count -gt 0) {
        ($salvaged | Select-Object -First 8 | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "- No actionable signal was detected."
    }
    return @"
YOUR PREVIOUS ATTEMPT WAS INVALID.

FAILURE CATEGORY: $FailureCode
WHY IT WAS INVALID:
$reasonText

WHAT IS ALREADY USABLE:
$salvageText

WHAT YOU MUST DO NOW:
- Fix exactly the problems listed above.
- If you mention files, provide concrete paths or search patterns.
- If you are expected to return a RESULT marker, write the RESULT line exactly.
- If the previous output already contains actionable clues, use them instead of staying vague again.

IF YOU DO NOT FOLLOW THIS FORMAT, THE ATTEMPT WILL BE TREATED AS FAILED.
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
    if ($PhaseName -eq "FIX_PLAN") {
        return Invoke-ClaudeFixPlan -Prompt $Prompt -Model $Model -Attempt $Attempt
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
    param(
        [System.Collections.ArrayList]$History,
        [int]$MaxEntries = 0,
        [int]$MaxChars = $CONST_FEEDBACK_MAX_CHARS
    )
    if ($History.Count -eq 0) { return "" }
    $entries = if ($MaxEntries -gt 0 -and $History.Count -gt $MaxEntries) {
        $History | Select-Object -Last $MaxEntries
    } else {
        $History
    }
    $entryBudget = if ($entries.Count -gt 0) { [Math]::Max(220, [int][Math]::Floor($MaxChars / $entries.Count)) } else { $MaxChars }
    $parts = foreach ($entry in $entries) {
        $feedbackText = Clip-Text -Text $entry.feedback -MaxChars $entryBudget -Marker "Feedback trimmed"
        "--- Attempt $($entry.attempt) [$($entry.source)/$($entry.category)] ---`n$feedbackText"
    }
    return Clip-Text -Text ($parts -join "`n`n") -MaxChars $MaxChars -Marker "Feedback history trimmed"
}

function Get-TotalAttempts {
    $effectiveAttempts = [ordered]@{}
    foreach ($entry in $attemptsByPhase.GetEnumerator()) {
        $effectiveAttempts[$entry.Key] = $entry.Value
    }
    if ($effectiveAttempts.Contains("fixPlan") -and $effectiveAttempts["fixPlan"] -gt 0 -and $effectiveAttempts.Contains("plan")) {
        $effectiveAttempts["plan"] = 0
    }
    return (($effectiveAttempts.Values | Measure-Object -Sum).Sum)
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
        [string]$noChangeReason = "",
        [string]$discoverConclusion = "",
        [string]$route = "",
        [string]$testability = "",
        $testProjects = @(),
        [bool]$reproductionAttempted = $false,
        [bool]$reproductionConfirmed = $false,
        $reproductionTests = $null,
        [bool]$targetedVerificationPassed = $false,
        [string]$plannerEffortClass = "UNKNOWN",
        [string]$pipelineProfile = "COMPLEX"
    )
    $metricsSummary = Get-PhaseMetricsSummary
    if ($artifactRunDir) {
        Save-JsonArtifact -Name "phase-metrics.json" -Object @($phaseMetrics) | Out-Null
        Save-JsonArtifact -Name "metrics-summary.json" -Object $metricsSummary | Out-Null
    }
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
        attempts = Get-TotalAttempts
        attemptsByPhase = $attemptsByPhase
        artifacts = [ordered]@{
            runDir = $artifactRunDir
            timeline = if ($artifactRunDir) { Join-Path $artifactRunDir "timeline.json" } else { "" }
            debugDir = $debugRunDir
        }
        planVersion = $planVersion
        investigationRequired = $investigationRequired
        discoverConclusion = $discoverConclusion
        route = $route
        testability = $testability
        testProjects = @($testProjects)
        investigationConclusion = $investigationConclusion
        reproductionAttempted = [bool]$reproductionAttempted
        reproductionConfirmed = [bool]$reproductionConfirmed
        reproductionTests = if ($reproductionTests) { $reproductionTests } else { [ordered]@{} }
        targetedVerificationPassed = [bool]$targetedVerificationPassed
        noChangeReason = $noChangeReason
        taskClass = $taskClass
        plannerEffortClass = $plannerEffortClass
        pipelineProfile = $pipelineProfile
        metrics = $metricsSummary
    } | ConvertTo-Json -Depth 8

    $resultDir = Split-Path $ResultFile -Parent
    if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }
    $tempResultFile = Join-Path $resultDir ([System.IO.Path]::GetFileName($ResultFile) + ".tmp")
    try {
        [System.IO.File]::WriteAllText($tempResultFile, $result, [System.Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $ResultFile) {
            [System.IO.File]::Replace($tempResultFile, $ResultFile, $null, $true)
        } else {
            [System.IO.File]::Move($tempResultFile, $ResultFile)
        }
    } finally {
        Remove-Item -LiteralPath $tempResultFile -ErrorAction SilentlyContinue
    }
    Save-DebugText -Name "result.json" -Content $result | Out-Null
    Write-DebugManifest
    Write-SchedulerSnapshot
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
    $startedAt = Get-Date
    $tempPromptFile = Join-Path $env:TEMP "claude-develop\claude-input-$([guid]::NewGuid()).md"
    $tempOutputFile = Join-Path $env:TEMP "claude-develop\claude-output-$([guid]::NewGuid()).txt"
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
        $durationSeconds = ((Get-Date) - $startedAt).TotalSeconds
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
        Add-PhaseMetric -PhaseName $PhaseName -Attempt $Attempt -Model $Model -Prompt $Prompt -Output "TIMEOUT nach $TimeoutSec Sekunden" -DurationSeconds $durationSeconds -Success $false -TimedOut $true -ExitCode -1
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
    $durationSeconds = ((Get-Date) - $startedAt).TotalSeconds

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
    Add-PhaseMetric -PhaseName $PhaseName -Attempt $Attempt -Model $Model -Prompt $Prompt -Output $output -DurationSeconds $durationSeconds -Success ($exitCode -eq 0) -TimedOut $false -ExitCode $exitCode

    Remove-Item $tempPromptFile -ErrorAction SilentlyContinue
    Remove-Item $tempOutputFile -ErrorAction SilentlyContinue

    return @{ success = ($exitCode -eq 0); output = $output; timedOut = $false; exitCode = $exitCode }
}

function Invoke-ClaudeDiscover {
    param([string]$Prompt, [string]$Model, [int]$Attempt)
    Add-TimelineEvent -Phase "MODEL" -Message "DISCOVER nutzt $Model" -Category "DISCOVER_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "discover-v$Attempt" -Prompt $Prompt -Model $Model -Attempt $Attempt -ExtraArgs @(
        "--model", $Model,
        "--allowedTools", "Read,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_DISCOVER.ToString()
    )
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

function Invoke-ClaudeFixPlan {
    param([string]$Prompt, [string]$Model, [int]$Attempt)
    Add-TimelineEvent -Phase "MODEL" -Message "FIX_PLAN nutzt $Model" -Category "FIX_PLAN_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "fix-plan-v$Attempt" -Prompt $Prompt -Model $Model -Attempt $Attempt -ExtraArgs @(
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

function Invoke-ClaudeReproduce {
    param([string]$Prompt, [string]$Model, [int]$Attempt)
    Add-TimelineEvent -Phase "MODEL" -Message "REPRODUCE nutzt $Model" -Category "REPRODUCE_MODEL"
    return Invoke-ClaudeWithTimeout -PhaseName "reproduce-v$Attempt" -Prompt $Prompt -Model $Model -Attempt $Attempt -TimeoutSec ($CONST_TIMEOUT_SECONDS * 2) -ExtraArgs @(
        "--model", $Model,
        "--dangerously-skip-permissions",
        "--allowedTools", "Read,Edit,Write,Bash,Glob,Grep",
        "--max-turns", $CONST_MAX_TURNS_IMPL.ToString()
    )
}

function Invoke-ClaudeReview {
    param(
        [string]$Prompt,
        [string]$AttemptLabel,
        [string]$Model
    )
    $model = if ($Model) { $Model } else { $CONST_MODEL_REVIEW }
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
    if ($lines.Count -eq 0) { return @{ verdict = "INFRA_FAILURE"; severity = ""; feedback = "Empty review response" } }

    $firstLineRaw = $lines[0].Trim()
    $firstLine = $firstLineRaw.ToUpperInvariant()
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
    if ($firstLineRaw -match '(?i)^error:\s*' -or $firstLineRaw -match '(?i)\bmax turns\b' -or $firstLineRaw -match '(?i)\btimeout\b' -or $firstLineRaw -match '(?i)\btimed out\b') {
        return @{ verdict = "INFRA_FAILURE"; severity = ""; feedback = $ReviewOutput.Trim() }
    }
    return @{ verdict = "DENIED"; severity = "MAJOR"; feedback = "Reviewer response is unclear (first line: '$($lines[0])')`n$ReviewOutput" }
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
        [void]$issues.Add("Plan contains UI or approval text.")
    }
    if ($Plan -notmatch "##\s*(Goal|Ziel)") { [void]$issues.Add("Section ## Goal is missing.") }
    if ($Plan -notmatch "##\s*(Files|Dateien)") { [void]$issues.Add("Section ## Files is missing.") }
    if ($Plan -notmatch "##\s*(Order|Reihenfolge)") { [void]$issues.Add("Section ## Order is missing.") }
    if ($Plan -match "<relative path>|<relativer Pfad>|<step>|<Schritt>|<relevant rules>|<relevante Regeln") {
        [void]$issues.Add("Plan still contains template placeholders.")
    }

    $nonEmpty = @($Plan -split "`n" | Where-Object { $_.Trim() -ne "" })
    if ($nonEmpty.Count -lt 10) { [void]$issues.Add("Plan is too short.") }

    $pathMatches = [regex]::Matches($Plan, "(?im)^\s*-\s*(Path|Pfad)\s*:\s*(.+)$")
    foreach ($match in $pathMatches) {
        $value = $match.Groups[2].Value.Trim()
        if ($value -and $value -notmatch "^<" -and $value -match "(\\|/|\*|\.[A-Za-z0-9]{1,8}\b)") {
            [void]$targets.Add($value)
        }
    }
    if ($targets.Count -eq 0) {
        [void]$issues.Add("Plan does not name any concrete file or search targets.")
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

    $targets = Get-BulletSectionValues -Text $Output -Header "TARGET_FILES"
    if ($targets.Count -eq 0) {
        $targets = @(Get-ActionableItems -Text $Output | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' })
    }
    return [ordered]@{
        result = $result
        targets = @($targets | Select-Object -Unique)
        testability = if ($Output -match '(?im)^TESTABILITY_REASSESSMENT\s*:\s*(YES|NO|UNKNOWN)\s*$') {
            $Matches[1].ToUpperInvariant()
        } else {
            "UNKNOWN"
        }
        nextPhase = if ($Output -match '(?im)^RECOMMENDED_NEXT_PHASE\s*:\s*(FIX_PLAN|REPRODUCE)\s*$') {
            $Matches[1].ToUpperInvariant()
        } else {
            "FIX_PLAN"
        }
        summary = $Output.Trim()
    }
}

function Get-ReproductionVerdict {
    param([string]$Output)
    $result = "INCONCLUSIVE"
    if ($Output -match '(?im)^RESULT\s*:\s*(REPRODUCED|NOT_REPRODUCED|INCONCLUSIVE)\s*$') {
        $result = $Matches[1].ToUpperInvariant()
    }

    $testNames = Get-BulletSectionValues -Text $Output -Header "TEST_NAMES"
    $testProjects = Get-BulletSectionValues -Text $Output -Header "TEST_PROJECTS"
    $testFiles = Get-BulletSectionValues -Text $Output -Header "TEST_FILES"
    $testFilter = ""
    if ($Output -match '(?im)^TEST_FILTER\s*:\s*(.+)$') {
        $testFilter = $Matches[1].Trim()
    }
    if (-not $testFilter -and $testNames.Count -gt 0) {
        $testFilter = Get-TestFilterFromNames -TestNames $testNames
    }

    return [ordered]@{
        result = $result
        testProjects = @($testProjects | Select-Object -Unique)
        testFiles = @($testFiles | Select-Object -Unique)
        testNames = @($testNames | Select-Object -Unique)
        testFilter = $testFilter
        bugBehavior = Get-ScalarSectionText -Text $Output -Header "BUG_BEHAVIOR"
        rationale = Get-ScalarSectionText -Text $Output -Header "RATIONALE"
        summary = $Output.Trim()
    }
}

function Resolve-TestProjectPaths {
    param(
        [string[]]$RequestedProjects,
        $TestProjects
    )

    $resolved = [System.Collections.ArrayList]::new()
    foreach ($requested in @($RequestedProjects | Where-Object { $_ })) {
        $normalized = $requested.Replace("/", "\").Trim()
        if (-not $normalized) { continue }

        $exactMatches = @($TestProjects | Where-Object {
            $candidates = @(
                $_.relPath,
                $_.worktreeRelativePath,
                $_.solutionRelativePath,
                $_.fullPath
            ) | Where-Object { $_ }
            ($candidates | ForEach-Object { $_.Replace("/", "\").Trim() }) -contains $normalized
        })
        if ($exactMatches.Count -eq 1) {
            [void]$resolved.Add($exactMatches[0].relPath)
            continue
        }

        $nameMatches = @($TestProjects | Where-Object {
            $requestedFile = [System.IO.Path]::GetFileName($normalized)
            $_.name -eq $normalized -or
            [System.IO.Path]::GetFileName($_.relPath) -eq $requestedFile -or
            [System.IO.Path]::GetFileName($_.fullPath) -eq $requestedFile
        })
        if ($nameMatches.Count -eq 1) {
            [void]$resolved.Add($nameMatches[0].relPath)
        }
    }

    return @($resolved | Select-Object -Unique)
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
    return @((Get-ChangedFilesResult).files)
}

function Fail-ChangedFilesDetection {
    param(
        $ChangedFilesResult,
        [string]$Phase = ""
    )

    $script:currentPhase = if ($Phase) { $Phase } else { $script:currentPhase }
    $details = [ordered]@{
        phase = [string]$script:currentPhase
        sourceErrors = @($ChangedFilesResult.sourceErrors)
    }
    Add-TimelineEvent -Phase $script:currentPhase -Message "Changed-files detection failed." -Category "WORKTREE_ENVIRONMENT_ERROR" -Data $details
    $script:finalStatus = "ERROR"
    $script:finalCategory = "WORKTREE_ENVIRONMENT_ERROR"
    $script:finalSummary = "The worker could not determine changed files reliably."
    $script:finalFeedback = ($details | ConvertTo-Json -Depth 8)
    throw [System.Exception]::new("TERMINAL_CHANGED_FILES_DETECTION_FAILED")
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
        attempts = Get-TotalAttempts
        attemptsByPhase = $attemptsByPhase
        failureReasons = @($FailureReasons)
        changedFiles = @($Files)
        artifacts = $artifactRunDir
    } | ConvertTo-Json -Compress -Depth 8
    Add-Content -Path $logFile -Value $entry -Encoding UTF8
}

try {
    Write-Host "[VALIDATE] Checking git status..."
    $r = Invoke-NativeCommand git @("rev-parse", "--is-inside-work-tree")
    if ($r.output -ne "true") {
        Write-ResultJson -status "ERROR" -finalCategory "VALIDATION_ERROR" -summary "No git repository was found." -error "No git repository was found." -phase "VALIDATE"
        exit 1
    }
    $r = Invoke-NativeCommand git @("status", "--porcelain")
    if ($r.output) {
        Write-ResultJson -status "ERROR" -finalCategory "DIRTY_WORKTREE" -summary "The working tree is not clean." -error "The working tree is not clean.`nDirty files:`n$($r.output)" -phase "VALIDATE"
        exit 1
    }
    if (-not (Test-Path $SolutionPath)) {
        Write-ResultJson -status "ERROR" -finalCategory "MISSING_SOLUTION" -summary "The solution was not found." -error "Solution not found: $SolutionPath" -phase "VALIDATE"
        exit 1
    }

    $currentPhase = "WORKTREE"
    Ensure-DebugDir | Out-Null
    $repoRoot = (Invoke-NativeCommand git @("rev-parse", "--show-toplevel")).output
    Ensure-ArtifactDir -Root $repoRoot | Out-Null
    Write-DebugManifest

    $taskPrompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    $taskLine = ($taskPrompt -split "`n" | Where-Object { $_ -notmatch "^\s*$|^##" } | Select-Object -First 1).Trim()
    $plannerContext = if ($PlannerContextFile) { Read-JsonFileBestEffort -Path $PlannerContextFile } else { $null }
    if ($plannerContext -and $plannerContext.plannerMetadata) {
        $plannerEffortClass = Get-NormalizedPlannerEffortClass -EffortClass ([string]$plannerContext.plannerMetadata.effortClass)
    } else {
        $plannerEffortClass = "UNKNOWN"
    }
    $pipelineProfile = Get-PipelineProfile -PlannerEffortClass $plannerEffortClass
    $taskClass = Get-TaskClass -TaskText $taskPrompt
    $investigationRequired = Test-InvestigationRequired -TaskText $taskPrompt -TaskClass $taskClass
    Save-Artifact -Name "input-task.txt" -Content $taskPrompt | Out-Null
    Save-DebugText -Name "input-task.txt" -Content $taskPrompt | Out-Null
    Add-TimelineEvent -Phase "VALIDATE" -Message "Prompt eingelesen und Task klassifiziert." -Category $taskClass -Data @{ investigationRequired = $investigationRequired; plannerEffortClass = $plannerEffortClass; pipelineProfile = $pipelineProfile; plannerContextLoaded = [bool]$plannerContext }
    if ($PlannerContextFile -and -not $plannerContext) {
        Add-TimelineEvent -Phase "VALIDATE" -Message "Planner context file could not be read. Falling back to default pipeline profile." -Category "PLANNER_CONTEXT_INVALID" -Data @{ plannerContextFile = $PlannerContextFile }
    } elseif ($plannerContext) {
        Add-TimelineEvent -Phase "VALIDATE" -Message "Planner context loaded for worker startup." -Category "PLANNER_CONTEXT_LOADED" -Data @{ plannerEffortClass = $plannerEffortClass; pipelineProfile = $pipelineProfile }
    }
    Write-SchedulerSnapshot

    $worktreeBase = Join-Path $env:TEMP "claude-worktrees"
    $worktreePath = Join-Path $worktreeBase $TaskName
    if (-not (Test-Path $worktreeBase)) { New-Item -ItemType Directory -Path $worktreeBase -Force | Out-Null }
    Write-DebugManifest
    Write-SchedulerSnapshot

    Write-Host "[WORKTREE] Erstelle $branchName..."
    $r = Invoke-NativeCommand git @("worktree", "add", $worktreePath, "-b", $branchName)
    if ($r.exitCode -ne 0) {
        Write-ResultJson -status "ERROR" -finalCategory "WORKTREE_ERROR" -summary "The worktree could not be created." -error $r.output -phase "WORKTREE"
        exit 1
    }

    $baseUri = [System.Uri]::new($repoRoot.TrimEnd('\') + "\")
    $targetUri = [System.Uri]::new($SolutionPath)
    $relSln = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", "\")
    $worktreeSln = Join-Path $worktreePath $relSln
    $initialWorktreeValidation = Test-WorktreeEnvironment -WorktreePath $worktreePath -SolutionPath $worktreeSln -RepoRoot $repoRoot -Phase "WORKTREE"
    if (-not $initialWorktreeValidation.isValid) {
        Fail-WorktreeEnvironment -Validation $initialWorktreeValidation -Phase "WORKTREE" -Summary "The created worktree is invalid before the pipeline can continue."
    }
    Write-DebugManifest
    Write-SchedulerSnapshot

    Write-Host "[CONTEXT] Sammle Codebase-Kontext..."
    $codebaseInventory = Get-CodebaseInventory -RepoRoot $repoRoot -SolutionPath $SolutionPath
    Save-JsonArtifact -Name "codebase-inventory.json" -Object $codebaseInventory | Out-Null
    $codebaseContext = Build-CompactCodebaseContext -Inventory $codebaseInventory -TaskText $taskPrompt
    Save-Artifact -Name "context-summary.txt" -Content $codebaseContext | Out-Null
    Add-TimelineEvent -Phase "CONTEXT_SNAPSHOT" -Message "Codebase-Kontext erfasst." -Data @{ solution = $worktreeSln }

    $restoreJob = Start-Job -ScriptBlock {
        param($sln)
        & dotnet restore $sln 2>&1 | Out-String
    } -ArgumentList $worktreeSln

    Set-Location $worktreePath
    $effectiveModelPlan = Get-ModelForPlan -TaskClass $taskClass -Targets @() -PipelineProfile $pipelineProfile
    $effectiveModelImplement = $CONST_MODEL_IMPLEMENT
    $nugetRule = if ($AllowNuget) { "- New NuGet packages are allowed only when required" } else { "- No new NuGet packages" }

    $testProjects = @(Get-TestProjectInventory -SolutionPath $worktreeSln -WorktreeRoot $worktreePath)
    Save-JsonArtifact -Name "test-projects.json" -Object $testProjects | Out-Null
    Add-TimelineEvent -Phase "DISCOVER" -Message "Testprojekt-Inventar erfasst." -Category "TEST_PROJECTS" -Data @{ count = $testProjects.Count }

    $planValidation = $null
    $planOutput = ""
    $planTargets = @()
    $replanReason = ""
    $salvagedPlanTargets = @()
    $discoverOutput = ""
    $discoverVerdict = [ordered]@{
        route = if ($taskClass -eq "DIRECT_EDIT") { "DIRECT_EDIT" } else { "UNCERTAIN" }
        bugConfidence = if ($taskClass -eq "DIRECT_EDIT") { "LOW" } else { "MEDIUM" }
        testability = if ($testProjects.Count -gt 0) { "UNKNOWN" } else { "NO" }
        targetHints = @()
        rationale = ""
        nextPhase = if ($taskClass -eq "DIRECT_EDIT") { "FIX_PLAN" } else { "INVESTIGATE" }
        summary = ""
    }
    $discoverCritique = ""
    for ($discoverAttempt = 1; $discoverAttempt -le $CONST_DISCOVER_ATTEMPTS; $discoverAttempt++) {
        $currentPhase = "DISCOVER"
        $attemptsByPhase.discover = $discoverAttempt
        Write-Host "[DISCOVER] Attempt $discoverAttempt/$CONST_DISCOVER_ATTEMPTS..."
        $discoverCritiqueBlock = if ($discoverCritique) { "`nCRITIQUE OF THE PREVIOUS DISCOVER RESULT:`n$discoverCritique`n" } else { "" }
        $discoverContext = Get-ScopedCodebaseContext -Inventory $codebaseInventory -TaskText $taskPrompt -Targets $planTargets
        $discoverTestProjectText = Format-TestProjectsForPrompt -Projects $testProjects -TaskText $taskPrompt -Targets $planTargets
        $discoverPrompt = @"
Analyze the task read-only and decide the next pipeline step. Do NOT produce an implementation plan.
Be concise. Maximum 10 lines. TARGET_HINTS may contain at most 3 entries. RATIONALE must be exactly 1-2 sentences.

TASK:
$taskPrompt

SOLUTION: $worktreeSln
TASK_CLASS: $taskClass

DETECTED TEST PROJECTS:
$discoverTestProjectText

CONTEXT:
$discoverContext
$discoverCritiqueBlock
OUTPUT FORMAT:
ROUTE: DIRECT_EDIT | BUGFIX_TESTABLE | BUGFIX_NONTESTABLE | UNCERTAIN
BUG_CONFIDENCE: HIGH | MEDIUM | LOW
TESTABILITY: YES | NO | UNKNOWN
TARGET_HINTS:
- <concrete path or search pattern>
RATIONALE:
<short evidence-based explanation>
NEXT_PHASE: FIX_PLAN | INVESTIGATE | REPRODUCE
"@
        $discoverModel = Get-ModelForPlan -TaskClass $taskClass -Targets @() -PipelineProfile $pipelineProfile
        $discoverResult = Invoke-ClaudeDiscover -Prompt $discoverPrompt -Model $discoverModel -Attempt $discoverAttempt
        if (-not $discoverResult.success) {
            $discoverCritique = "Discover call failed: $($discoverResult.output)"
            Add-FeedbackEntry -Attempt $discoverAttempt -Source "DISCOVER" -Category "DISCOVER_CALL_FAILED" -Feedback $discoverResult.output
            continue
        }

        $discoverOutput = $discoverResult.output.Trim()
        Save-Artifact -Name "discover-v$discoverAttempt.txt" -Content $discoverOutput | Out-Null
        $discoverVerdict = Get-DiscoveryVerdict -Output $discoverOutput -TestProjects $testProjects
        $routeDecision = $discoverVerdict.route
        $testability = $discoverVerdict.testability
        $discoverConclusion = "$routeDecision/$testability"
        if ($discoverVerdict.targetHints.Count -gt 0) {
            $planTargets = @($planTargets + $discoverVerdict.targetHints | Select-Object -Unique)
        }
        Add-TimelineEvent -Phase "DISCOVER" -Message "Discover routing determined." -Category $routeDecision -Data @{ testability = $testability; nextPhase = $discoverVerdict.nextPhase }
        Write-SchedulerSnapshot
        break
    }

    Write-Host "[RESTORE] Waiting for dotnet restore..."
    Wait-Job $restoreJob -Timeout 120 | Out-Null
    $restoreOutput = Receive-Job $restoreJob -ErrorAction SilentlyContinue | Out-String
    Remove-Job $restoreJob -Force -ErrorAction SilentlyContinue
    Save-Artifact -Name "restore-output.txt" -Content $restoreOutput | Out-Null

    $investigationOutput = ""
    $investigationVerdict = [ordered]@{ result = "CHANGE_NEEDED"; targets = @(); testability = "UNKNOWN"; nextPhase = "FIX_PLAN"; summary = "" }
    $investigationHashes = [System.Collections.ArrayList]::new()
    $needsInvestigation = ($discoverVerdict.nextPhase -ne "FIX_PLAN")
    $investigationRequired = $needsInvestigation
    if ($needsInvestigation) {
        for ($investigateAttempt = 1; $investigateAttempt -le $CONST_INVESTIGATION_ATTEMPTS; $investigateAttempt++) {
            $currentPhase = "INVESTIGATE"
            $attemptsByPhase.investigate = $investigateAttempt
            Write-Host "[INVESTIGATE] Attempt $investigateAttempt/$CONST_INVESTIGATION_ATTEMPTS..."
            $historyText = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 2 -MaxChars 1200
            $discoverBlock = if ($discoverOutput) { $discoverOutput } else { "ROUTE: $routeDecision`nTESTABILITY: $testability" }
            $investigationTargets = @($planTargets + $discoverVerdict.targetHints | Select-Object -Unique)
            $investigationContext = Get-ScopedCodebaseContext -Inventory $codebaseInventory -TaskText $taskPrompt -Targets $investigationTargets
            $investigationTestProjectText = Format-TestProjectsForPrompt -Projects $testProjects -TaskText $taskPrompt -Targets $investigationTargets
            $investigatePrompt = @"
Investigate the task read-only and decide whether a code change is required. Also assess whether an automated bug reproduction through tests is worthwhile.
Be concise. TARGET_FILES may contain at most 5 entries. ROOT_CAUSE and NEXT_ACTION may each use at most 2 sentences.

TASK:
$taskPrompt

SOLUTION: $worktreeSln
TASK_CLASS: $taskClass

DISCOVER:
$discoverBlock

DETECTED TEST PROJECTS:
$investigationTestProjectText

CONTEXT:
$investigationContext

PRIOR FEEDBACK:
$historyText

OUTPUT FORMAT:
RESULT: CHANGE_NEEDED | NO_CHANGE | INCONCLUSIVE
TARGET_FILES:
- <concrete path or search pattern>
ROOT_CAUSE:
<concrete analysis>
TESTABILITY_REASSESSMENT: YES | NO | UNKNOWN
RECOMMENDED_NEXT_PHASE: FIX_PLAN | REPRODUCE
NEXT_ACTION:
<concrete next change or rationale>
"@
            $investigateModel = Get-ModelForInvestigate -TaskClass $taskClass -Targets @($planTargets + $discoverVerdict.targetHints) -Attempt $investigateAttempt -PreviousOutput $investigationOutput
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
            if ($investigationVerdict.testability -ne "UNKNOWN") {
                $testability = $investigationVerdict.testability
            }
            Add-TimelineEvent -Phase "INVESTIGATE" -Message "Investigation result: $($investigationVerdict.result)" -Category $investigationVerdict.result -Data @{ targets = $investigationVerdict.targets; nextPhase = $investigationVerdict.nextPhase }
            Write-SchedulerSnapshot

            if ($investigationVerdict.result -eq "INCONCLUSIVE" -and (Test-HasActionableSignal -Text $investigationOutput)) {
                $investigationVerdict.result = "CHANGE_NEEDED"
                $investigationConclusion = "CHANGE_NEEDED_SALVAGED"
                $investigationVerdict.targets = @(Get-ActionableItems -Text $investigationOutput | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' } | Select-Object -Unique)
                Add-TimelineEvent -Phase "INVESTIGATE" -Message "Investigation was salvaged from actionable evidence." -Category "CHANGE_NEEDED_SALVAGED" -Data @{ targets = $investigationVerdict.targets }
                Write-SchedulerSnapshot
            }

            if ($investigationVerdict.result -eq "NO_CHANGE") {
                $noChangeAssessment = Get-NoChangeAssessment -Output $investigationOutput -Targets $investigationVerdict.targets
                if (-not $noChangeAssessment.shouldVerify) {
                    Add-FeedbackEntry -Attempt $investigateAttempt -Source "INVESTIGATE" -Category "NO_CHANGE_LOW_CONFIDENCE" -Feedback "The NO_CHANGE claim was too weak or unusable, so the verification call was skipped."
                    $investigationVerdict.result = "INCONCLUSIVE"
                    $investigationConclusion = "NO_CHANGE_LOW_CONFIDENCE"
                } else {
                    $verifyPrompt = @"
Check the following claim strictly in read-only mode: the task is already implemented.

TASK:
$taskPrompt

INVESTIGATION:
$investigationOutput

RESPOND EXACTLY:
RESULT: CONFIRMED | NOT_CONFIRMED
REASON:
<short rationale with concrete files or missing evidence>
"@
                    $verifyTargets = if ($noChangeAssessment.evidenceTargets.Count -gt 0) { @($noChangeAssessment.evidenceTargets) } else { @($investigationVerdict.targets) }
                    $verifyResult = Invoke-ClaudeInvestigate -Prompt $verifyPrompt -Model (Get-ModelForInvestigate -TaskClass $taskClass -Targets $verifyTargets -Attempt 2 -PreviousOutput $investigationOutput) -Attempt (80 + $investigateAttempt)
                    if ($verifyResult.success -and $verifyResult.output -match '(?im)^RESULT\s*:\s*CONFIRMED\s*$') {
                        $finalStatus = "NO_CHANGE"
                        $finalCategory = "NO_CHANGE_ALREADY_SATISFIED"
                        $finalSummary = "Investigation confirmed that no code change is required."
                        $finalFeedback = $investigationOutput
                        throw [System.Exception]::new("TERMINAL_NO_CHANGE")
                    }
                    Add-FeedbackEntry -Attempt $investigateAttempt -Source "INVESTIGATE" -Category "NO_CHANGE_NOT_CONFIRMED" -Feedback ($verifyResult.output)
                    $investigationVerdict.result = "CHANGE_NEEDED"
                    $investigationConclusion = "NO_CHANGE_REJECTED"
                }
            }
            if ($investigationVerdict.result -eq "CHANGE_NEEDED") {
                if ($investigationVerdict.targets.Count -gt 0) {
                    $planTargets = @($planTargets + $investigationVerdict.targets | Select-Object -Unique)
                }
                break
            }

            Add-FeedbackEntry -Attempt $investigateAttempt -Source "INVESTIGATE" -Category "INVESTIGATION_INCONCLUSIVE" -Feedback $investigationOutput
            for ($repairAttempt = 1; $repairAttempt -le $CONST_REPAIR_ATTEMPTS; $repairAttempt++) {
                $repairBlock = Get-RepairBlock -FailureCode "INVESTIGATION_INCONCLUSIVE" -Reasons @("Your output was not specific enough for the pipeline to continue automatically.") -PreviousOutput $investigationOutput
                $repairTargets = @($planTargets + $discoverVerdict.targetHints + $investigationVerdict.targets | Select-Object -Unique)
                $repairContext = Get-ScopedCodebaseContext -Inventory $codebaseInventory -TaskText $taskPrompt -Targets $repairTargets
                $repairTestProjectText = Format-TestProjectsForPrompt -Projects $testProjects -TaskText $taskPrompt -Targets $repairTargets
                $repairPrompt = @"
$repairBlock

PRODUCE A USABLE INVESTIGATION RESULT NOW.

TASK:
$taskPrompt

DISCOVER:
$discoverBlock

DETECTED TEST PROJECTS:
$repairTestProjectText

CONTEXT:
$repairContext

OUTPUT FORMAT:
RESULT: CHANGE_NEEDED | NO_CHANGE | INCONCLUSIVE
TARGET_FILES:
- <concrete path or search pattern>
ROOT_CAUSE:
<concrete analysis>
TESTABILITY_REASSESSMENT: YES | NO | UNKNOWN
RECOMMENDED_NEXT_PHASE: FIX_PLAN | REPRODUCE
NEXT_ACTION:
<concrete next change or rationale>
"@
                $repairModel = Get-ModelForRepair -PhaseName "INVESTIGATE" -TaskClass $taskClass -InvestigationRequired $needsInvestigation -Targets $repairTargets -PreviousOutput $investigationOutput -TaskText $taskPrompt
                $repairResult = Invoke-ClaudeRepair -PhaseName "INVESTIGATE" -Prompt $repairPrompt -Model $repairModel -Attempt (90 + $investigateAttempt * 10 + $repairAttempt)
                if (-not $repairResult.success) { continue }
                $investigationOutput = $repairResult.output.Trim()
                Save-Artifact -Name "investigation-v$investigateAttempt-repair-$repairAttempt.txt" -Content $investigationOutput | Out-Null
                $investigationVerdict = Get-InvestigationVerdict -Output $investigationOutput
                if ($investigationVerdict.testability -ne "UNKNOWN") {
                    $testability = $investigationVerdict.testability
                }
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
            $finalSummary = "Investigation could not determine a reliable change path."
            $finalFeedback = $investigationOutput
            throw [System.Exception]::new("TERMINAL_INVESTIGATION_INCONCLUSIVE")
        }
    }

    $shouldAttemptReproduction = ($testProjects.Count -gt 0) -and ($routeDecision -eq "BUGFIX_TESTABLE" -or $testability -eq "YES" -or $investigationVerdict.nextPhase -eq "REPRODUCE")
    if ($shouldAttemptReproduction) {
        $reproductionConfirmed = $false
        $reproductionOutput = ""
        $reproductionBaselinePatch = ""
        $reproductionBaselineFiles = @()
        $reproductionTests = New-EmptyReproductionTests
        $lastReproFailureCategory = ""
        for ($reproAttempt = 1; $reproAttempt -le $CONST_REPRODUCE_ATTEMPTS; $reproAttempt++) {
            $currentPhase = "REPRODUCE"
            $attemptsByPhase.reproduce = $reproAttempt
            $reproductionAttempted = $true
            $reproductionOutput = ""
            $reproductionBaselinePatch = ""
            $reproductionBaselineFiles = @()
            $reproductionTests = New-EmptyReproductionTests
            Reset-Worktree
            Write-Host "[REPRODUCE] Attempt $reproAttempt/$CONST_REPRODUCE_ATTEMPTS..."
            $historyText = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 3 -MaxChars 1000
            $discoverBlock = if ($discoverOutput) { $discoverOutput } else { "ROUTE: $routeDecision`nTESTABILITY: $testability" }
            $investigationBlock = if ($investigationOutput) { $investigationOutput } else { "RESULT: CHANGE_NEEDED`nTARGET_FILES:`n- " + (($planTargets | Select-Object -First 5) -join "`n- ") }
            $reproductionTargets = @($planTargets + $discoverVerdict.targetHints + $investigationVerdict.targets | Select-Object -Unique)
            $reproTestProjectText = Format-TestProjectsForPrompt -Projects $testProjects -TaskText $taskPrompt -Targets $reproductionTargets
            $taskClaimGuardrail = Get-TaskClaimGuardrail -TaskText $taskPrompt -ReproductionConfirmed $false
            $reproPrompt = @"
Try to reproduce the bug with automated tests. In this phase you may modify ONLY test files or test project files.

TASK:
$taskPrompt

$taskClaimGuardrail

SOLUTION: $worktreeSln
TASK_CLASS: $taskClass

DISCOVER:
$discoverBlock

INVESTIGATION:
$investigationBlock

DETECTED TEST PROJECTS:
$reproTestProjectText

PRIOR FEEDBACK:
$historyText

RULES:
- Do NOT modify production files.
- Do NOT add new NuGet packages.
- The goal is a reproducing test that fails before the fix.
- If no reliable reproduction is possible, say so clearly.

OUTPUT FORMAT:
RESULT: REPRODUCED | NOT_REPRODUCED | INCONCLUSIVE
TEST_PROJECTS:
- <relative project path>
TEST_FILES:
- <relative test file>
TEST_NAMES:
- <test name or fully qualified name>
TEST_FILTER: <dotnet test --filter expression>
BUG_BEHAVIOR:
<short description of the reproduced failure>
RATIONALE:
<why the test captures the bug or why reproduction was not possible>
"@
            $reproModel = Get-ModelForReproduce -TaskText $taskPrompt -Targets $reproductionTargets -Attempt $reproAttempt -LastFailureCategory $lastReproFailureCategory
            $reproResult = Invoke-ClaudeReproduce -Prompt $reproPrompt -Model $reproModel -Attempt $reproAttempt
            if (-not $reproResult.success) {
                $lastReproFailureCategory = "REPRO_CALL_FAILED"
                Add-FeedbackEntry -Attempt $reproAttempt -Source "REPRODUCE" -Category "REPRO_CALL_FAILED" -Feedback $reproResult.output
                continue
            }

            $reproductionOutput = $reproResult.output.Trim()
            Save-Artifact -Name "reproduce-v$reproAttempt.txt" -Content $reproductionOutput | Out-Null
            $reproVerdict = Get-ReproductionVerdict -Output $reproductionOutput
            $reproChangedFiles = Get-ChangedFiles
            Save-Artifact -Name "reproduce-v$reproAttempt-changed-files.txt" -Content (($reproChangedFiles -join "`n").Trim()) | Out-Null
            $changeSetValidation = Test-ReproductionChangeSet -ChangedFiles $reproChangedFiles -TestProjects $testProjects
            if (-not $changeSetValidation.valid) {
                $invalidText = if ($changeSetValidation.invalidFiles.Count -gt 0) { $changeSetValidation.invalidFiles -join ", " } else { "no test files changed" }
                $lastReproFailureCategory = "REPRO_INVALID_CHANGESET"
                Add-FeedbackEntry -Attempt $reproAttempt -Source "REPRODUCE" -Category "REPRO_INVALID_CHANGESET" -Feedback $invalidText
                Add-TimelineEvent -Phase "REPRODUCE" -Message "Reproduction rejected disallowed file changes." -Category "REPRO_INVALID_CHANGESET" -Data @{ invalidFiles = $changeSetValidation.invalidFiles }
                Reset-Worktree
                continue
            }

            if ($reproVerdict.result -ne "REPRODUCED") {
                $lastReproFailureCategory = $reproVerdict.result
                Add-FeedbackEntry -Attempt $reproAttempt -Source "REPRODUCE" -Category $reproVerdict.result -Feedback $reproductionOutput
                Reset-Worktree
                continue
            }

            if (-not $reproVerdict.testFilter) {
                $lastReproFailureCategory = "REPRO_MISSING_FILTER"
                Add-FeedbackEntry -Attempt $reproAttempt -Source "REPRODUCE" -Category "REPRO_MISSING_FILTER" -Feedback $reproductionOutput
                Reset-Worktree
                continue
            }

            $reproTestTargets = Resolve-TestProjectPaths -RequestedProjects $reproVerdict.testProjects -TestProjects $testProjects
            if ($reproVerdict.testProjects.Count -gt 0 -and $reproTestTargets.Count -eq 0) {
                $lastReproFailureCategory = "REPRO_UNKNOWN_TEST_PROJECT"
                Add-FeedbackEntry -Attempt $reproAttempt -Source "REPRODUCE" -Category "REPRO_UNKNOWN_TEST_PROJECT" -Feedback $reproductionOutput
                Reset-Worktree
                continue
            }
            $reproVerifyResult = Invoke-TargetedTestRun -SolutionPath $worktreeSln -ProjectPaths $reproTestTargets -TestFilter $reproVerdict.testFilter -ExpectFailure $true
            Save-Artifact -Name "reproduce-v$reproAttempt-verify.txt" -Content $reproVerifyResult.output | Out-Null
            if (-not $reproVerifyResult.testFailureObserved -or $reproVerifyResult.commandError -or $reproVerifyResult.matchedNoTests) {
                $lastReproFailureCategory = "REPRO_NOT_VERIFIED"
                Add-FeedbackEntry -Attempt $reproAttempt -Source "REPRODUCE" -Category "REPRO_NOT_VERIFIED" -Feedback $reproVerifyResult.output
                Reset-Worktree
                continue
            }

            $reproductionConfirmed = $true
            $reproductionTests = [ordered]@{
                testProjects = @($reproTestTargets)
                testFiles = if ($reproVerdict.testFiles.Count -gt 0) { @($reproVerdict.testFiles) } else { @($reproChangedFiles) }
                testNames = @($reproVerdict.testNames)
                testFilter = $reproVerdict.testFilter
                bugBehavior = $reproVerdict.bugBehavior
                rationale = $reproVerdict.rationale
                verificationOutput = $reproVerifyResult.output
            }
            $reproductionBaselinePatch = (Invoke-NativeCommand git @("diff", "HEAD")).output
            $reproductionBaselineFiles = Get-WorktreeFileSnapshot -Files $reproChangedFiles
            Save-Artifact -Name "reproduction-baseline.patch" -Content $reproductionBaselinePatch | Out-Null
            Add-TimelineEvent -Phase "REPRODUCE" -Message "Bug reproduction confirmed through tests." -Category "REPRODUCED" -Data @{ filter = $reproductionTests.testFilter; projects = $reproductionTests.testProjects }
            break
        }
        if (-not $reproductionConfirmed) {
            $reproductionOutput = ""
            $reproductionBaselinePatch = ""
            $reproductionBaselineFiles = @()
            $reproductionTests = New-EmptyReproductionTests
            Reset-Worktree
            Add-TimelineEvent -Phase "REPRODUCE" -Message "No reliable test reproduction was confirmed." -Category "REPRO_FAILED"
        }
    }

    for ($planAttempt = 1; $planAttempt -le $CONST_PLAN_ATTEMPTS; $planAttempt++) {
        $currentPhase = "FIX_PLAN"
        $attemptsByPhase.plan = $planAttempt
        $attemptsByPhase.fixPlan = $planAttempt
        $planVersion = $planAttempt
        Write-Host "[FIX_PLAN] Attempt $planAttempt/$CONST_PLAN_ATTEMPTS..."
        $replanBlock = if ($replanReason) { "`nCRITIQUE OF THE PREVIOUS FIX PLAN:`n$replanReason`n" } else { "" }
        $discoverBlock = if ($discoverOutput) { $discoverOutput } else { "ROUTE: $routeDecision`nTESTABILITY: $testability" }
        $investigationBlock = if ($investigationOutput) { $investigationOutput } else { "No separate investigation was performed." }
        $planContextTargets = @($planTargets + $discoverVerdict.targetHints + $investigationVerdict.targets | Select-Object -Unique)
        $planContext = Get-ScopedCodebaseContext -Inventory $codebaseInventory -TaskText $taskPrompt -Targets $planContextTargets
        $taskClaimGuardrail = Get-TaskClaimGuardrail -TaskText $taskPrompt -ReproductionConfirmed $reproductionConfirmed
        $reproductionBlock = if ($reproductionConfirmed) {
@"
RESULT: REPRODUCED
TEST_PROJECTS:
$(($reproductionTests.testProjects | ForEach-Object { "- $_" }) -join "`n")
TEST_FILES:
$(($reproductionTests.testFiles | ForEach-Object { "- $_" }) -join "`n")
TEST_NAMES:
$(($reproductionTests.testNames | ForEach-Object { "- $_" }) -join "`n")
TEST_FILTER: $($reproductionTests.testFilter)
BUG_BEHAVIOR:
$($reproductionTests.bugBehavior)
RATIONALE:
$($reproductionTests.rationale)
"@
        } else {
            "No verified test reproduction is available."
        }
        $planPrompt = @"
Create the concrete fix plan now based on the evidence already collected. Do not plan speculatively anymore.
Stay compact: at most 5 files or search areas and at most 4 ordered steps.

TASK:
$taskPrompt

$taskClaimGuardrail

SOLUTION: $worktreeSln

TASK_CLASS: $taskClass
DISCOVER_CONCLUSION: $discoverConclusion
ROUTE: $routeDecision
TESTABILITY: $testability

DISCOVER:
$discoverBlock

INVESTIGATION:
$investigationBlock

REPRODUCTION:
$reproductionBlock

CONTEXT:
$planContext
$replanBlock
RULES:
- No TODO/FIXME/HACK/Fix:/Note:/Hinweis(DE) comments
- No throw new NotImplementedException()
- Max 1 top-level type declaration per file (nested or partial is fine)
$nugetRule
- Comments must be English and minimal
- Use MessageService.ShowMessageBox instead of MessageBox.Show
- Avoid Dispatcher.Invoke/BeginInvoke when possible
- If reproduction tests exist, they must pass after the fix

OUTPUT FORMAT:
## Goal
One sentence.

## Files
For each relevant file or search area:
- Path: <concrete relative path OR search pattern>
- Action: CREATE | MODIFY | DELETE | CHECK
- Changes: <concrete expected change>

## Order
1. <concrete step>
2. <concrete step>

## Constraints
- <concrete risk>

## Reproduction Tests
- <only when present: project/file/test/expectation>

investigationRequired: true|false
Write ONLY the plan.
"@
        $effectiveModelPlan = Get-ModelForPlan -TaskClass $taskClass -Targets $planTargets -PipelineProfile $pipelineProfile
        $planResult = Invoke-ClaudeFixPlan -Prompt $planPrompt -Model $effectiveModelPlan -Attempt $planAttempt
        if (-not $planResult.success) {
            $replanReason = "Fix-plan call failed: $($planResult.output)"
            Add-FeedbackEntry -Attempt $planAttempt -Source "FIX_PLAN" -Category "FIX_PLAN_CALL_FAILED" -Feedback $planResult.output
            Add-TimelineEvent -Phase "FIX_PLAN" -Message "Fix-plan call failed." -Category "FIX_PLAN_CALL_FAILED"
            continue
        }

        $planOutput = $planResult.output.Trim()
        Save-Artifact -Name "fix-plan-v$planAttempt.txt" -Content $planOutput | Out-Null
        $planValidation = Get-PlanValidation -Plan $planOutput
        Save-JsonArtifact -Name "fix-plan-v$planAttempt-validation.json" -Object $planValidation | Out-Null
        if ($planValidation.valid) {
            $planTargets = @($planTargets + $planValidation.targets | Select-Object -Unique)
            Add-TimelineEvent -Phase "FIX_PLAN_VALIDATE" -Message "Fix-Plan akzeptiert." -Category "FIX_PLAN_VALID" -Data @{ targets = $planTargets }
            Write-SchedulerSnapshot
            break
        }

        $replanReason = ($planValidation.issues -join "`n")
        Add-FeedbackEntry -Attempt $planAttempt -Source "FIX_PLAN" -Category "FIX_PLAN_INSUFFICIENT" -Feedback $replanReason
        Add-TimelineEvent -Phase "FIX_PLAN_VALIDATE" -Message "Fix-Plan wurde verworfen." -Category "FIX_PLAN_INSUFFICIENT" -Data @{ issues = $planValidation.issues }
        for ($repairAttempt = 1; $repairAttempt -le $CONST_REPAIR_ATTEMPTS; $repairAttempt++) {
            $repairReasons = @($planValidation.issues)
            if ($reproductionConfirmed) {
                $repairReasons += "If reproduction tests exist, the plan must mention them explicitly."
            }
            $repairBlock = Get-RepairBlock -FailureCode "FIX_PLAN_INSUFFICIENT" -Reasons $repairReasons -PreviousOutput $planOutput
            $repairPrompt = @"
$repairBlock

PRODUCE A CORRECTED FIX PLAN NOW IN THE REQUIRED FORMAT.
Stay compact: at most 5 files or search areas and at most 4 ordered steps.

TASK:
$taskPrompt

$taskClaimGuardrail

SOLUTION: $worktreeSln

TASK_CLASS: $taskClass
DISCOVER_CONCLUSION: $discoverConclusion
ROUTE: $routeDecision
TESTABILITY: $testability

DISCOVER:
$discoverBlock

INVESTIGATION:
$investigationBlock

REPRODUCTION:
$reproductionBlock

CONTEXT:
$planContext

OUTPUT FORMAT:
## Goal
One sentence.

## Files
For each relevant file or search area:
- Path: <concrete relative path OR search pattern>
- Action: CREATE | MODIFY | DELETE | CHECK
- Changes: <concrete expected change>

## Order
1. <concrete step>
2. <concrete step>

## Constraints
- <concrete risk>

## Reproduction Tests
- <only when present: project/file/test/expectation>

investigationRequired: true|false
Write ONLY the plan.
"@
            $repairModel = Get-ModelForRepair -PhaseName "FIX_PLAN" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planContextTargets -PreviousOutput $planOutput -TaskText $taskPrompt -PipelineProfile $pipelineProfile
            $repairResult = Invoke-ClaudeRepair -PhaseName "FIX_PLAN" -Prompt $repairPrompt -Model $repairModel -Attempt (190 + $planAttempt * 10 + $repairAttempt)
            if (-not $repairResult.success) { continue }

            $planOutput = $repairResult.output.Trim()
            Save-Artifact -Name "fix-plan-v$planAttempt-repair-$repairAttempt.txt" -Content $planOutput | Out-Null
            $planValidation = Get-PlanValidation -Plan $planOutput
            Save-JsonArtifact -Name "fix-plan-v$planAttempt-repair-$repairAttempt-validation.json" -Object $planValidation | Out-Null
            if ($planValidation.valid) {
                $planTargets = @($planTargets + $planValidation.targets | Select-Object -Unique)
                Add-TimelineEvent -Phase "FIX_PLAN_VALIDATE" -Message "Fix-Plan nach Repair akzeptiert." -Category "FIX_PLAN_REPAIRED" -Data @{ targets = $planTargets }
                Write-SchedulerSnapshot
                break
            }

            $replanReason = ($planValidation.issues -join "`n")
            Add-FeedbackEntry -Attempt $planAttempt -Source "FIX_PLAN_REPAIR" -Category "FIX_PLAN_REPAIR_INSUFFICIENT" -Feedback $replanReason
        }
        if ($planValidation.valid) {
            break
        }
        $salvagedPlanTargets = Get-ActionableItems -Text $planOutput | Where-Object { $_ -match '\.(razor|cs|css|js|ts|xaml|csproj)\b|\*' }
        if ($salvagedPlanTargets.Count -gt 0) {
            $planTargets = @($planTargets + $salvagedPlanTargets | Select-Object -Unique)
            $planValidation.valid = $true
            Add-TimelineEvent -Phase "FIX_PLAN_VALIDATE" -Message "Fix-Plan via Salvage fortgesetzt." -Category "FIX_PLAN_SALVAGED" -Data @{ targets = $planTargets }
            Write-SchedulerSnapshot
            break
        }
    }

    if ((-not $planValidation -or -not $planValidation.valid) -and $planTargets.Count -eq 0) {
        $finalStatus = "FAILED"
        $finalCategory = "FIX_PLAN_INSUFFICIENT"
        $finalSummary = "No reliable fix plan could be produced after discovery, investigation, and optional reproduction."
        $finalFeedback = if ($planOutput) { $planOutput } else { Format-FeedbackHistory -History $feedbackHistory -MaxChars 1200 }
        throw [System.Exception]::new("TERMINAL_FIX_PLAN_INSUFFICIENT")
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
        if ($reproductionConfirmed) { $targetedVerificationPassed = $false }
        if ($reproductionConfirmed) {
            Restore-WorktreeBaseline -PatchContent $reproductionBaselinePatch -FileSnapshot $reproductionBaselineFiles
        } else {
            Reset-Worktree
        }
        Write-Host "[IMPLEMENT] Attempt $implementAttempt/$CONST_IMPLEMENT_ATTEMPTS..."

        $historyText = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 3 -MaxChars 1200
        $targetText = if ($planTargets.Count -gt 0) { ($planTargets | ForEach-Object { "- $_" }) -join "`n" } else { "- keine expliziten Ziele aus Plan" }
        $investigationBlock = if ($investigationOutput) { $investigationOutput } else { "RESULT: CHANGE_NEEDED`nTARGET_FILES:`n$targetText" }
        $reproductionBlock = if ($reproductionConfirmed) {
@"
RESULT: REPRODUCED
TEST_PROJECTS:
$(($reproductionTests.testProjects | ForEach-Object { "- $_" }) -join "`n")
TEST_FILES:
$(($reproductionTests.testFiles | ForEach-Object { "- $_" }) -join "`n")
TEST_NAMES:
$(($reproductionTests.testNames | ForEach-Object { "- $_" }) -join "`n")
TEST_FILTER: $($reproductionTests.testFilter)
BUG_BEHAVIOR:
$($reproductionTests.bugBehavior)
"@
        } else {
            "No verified test reproduction is available."
        }
        $implementPlan = Clip-Text -Text $planOutput -MaxChars 2600 -Marker "Fix plan trimmed"
        $taskClaimGuardrail = Get-TaskClaimGuardrail -TaskText $taskPrompt -ReproductionConfirmed $reproductionConfirmed
        $implPrompt = @"
Implement the change. Do not guess.
Work in a focused way. Open only files relevant to the target. At the end, output only the required short result format.

TASK:
$taskPrompt

$taskClaimGuardrail

SOLUTION: $worktreeSln
TASK_CLASS: $taskClass

VALIDATED PLAN:
$implementPlan

INVESTIGATION:
$investigationBlock

REPRODUCTION:
$reproductionBlock

ALLOWED TARGET FILES OR SEARCH PATTERNS:
$targetText

PRIOR FEEDBACK:
$historyText

RULES:
- Modify at least one repository file OR return a machine-readable NO_CHANGE result.
- If you do not change anything, you MUST use a RESULT marker.
- Open only files relevant to the target.
- Comments must be English and minimal.
- No TODO/FIXME/HACK/Fix:/Note: comments.
- If reproduction tests exist, they must pass after the fix and remain in the diff.
- After the changes: run dotnet build $worktreeSln --no-restore and fix errors immediately.

OUTPUT FORMAT AT THE END:
RESULT: CHANGE_APPLIED | NO_CHANGE_ALREADY_SATISFIED | NO_CHANGE_TARGET_NOT_FOUND | NO_CHANGE_BLOCKED | NO_CHANGE_UNCERTAIN
SUMMARY:
<Short rationale>
"@
        $effectiveModelImplement = Get-ModelForImplement -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -TaskText $taskPrompt -PhaseContext $investigationBlock -PipelineProfile $pipelineProfile
        $implResult = Invoke-ClaudeImplement -Prompt $implPrompt -Model $effectiveModelImplement -Attempt $implementAttempt
        $lastImplementOutput = $implResult.output
        if (-not $implResult.success) {
            Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "NO_CHANGE_TOOL_FAILURE" -Feedback $implResult.output
            Add-TimelineEvent -Phase "IMPLEMENT" -Message "Implementation call failed." -Category "NO_CHANGE_TOOL_FAILURE"
            continue
        }

        $implOutcome = Get-ImplementationOutcome -Output $implResult.output
        $changedFilesResult = Get-ChangedFilesResult
        if (-not $changedFilesResult.ok) {
            Fail-ChangedFilesDetection -ChangedFilesResult $changedFilesResult -Phase "CHANGE_VALIDATE"
        }
        $changedFiles = @($changedFilesResult.files)
        Save-Artifact -Name "implement-v$implementAttempt-changed-files.txt" -Content (($changedFiles -join "`n").Trim()) | Out-Null
        Update-ImplementationScopeCheck -ArtifactLabel "implement-v$implementAttempt" -Phase "CHANGE_VALIDATE"

        if ($changedFiles.Count -eq 0) {
            if ($implOutcome.category -eq "NO_CHANGE_ALREADY_SATISFIED") {
                $noChangeAssessment = Get-NoChangeAssessment -Output $implResult.output -Targets $planTargets
                if (-not $noChangeAssessment.shouldVerify) {
                    Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "NO_CHANGE_LOW_CONFIDENCE" -Feedback "The NO_CHANGE claim was too weak or unusable, so the verification call was skipped."
                    $implOutcome.category = "NO_CHANGE_UNCERTAIN"
                } else {
                    $verifyPrompt = @"
Check strictly in read-only mode whether this claim is true: the task is already implemented.

TASK:
$taskPrompt

IMPLEMENTATION OUTPUT:
$($implResult.output)

RESPOND EXACTLY:
RESULT: CONFIRMED | NOT_CONFIRMED
REASON:
<short rationale>
"@
                    $verifyTargets = if ($noChangeAssessment.evidenceTargets.Count -gt 0) { @($noChangeAssessment.evidenceTargets) } else { @($planTargets) }
                    $verifyResult = Invoke-ClaudeInvestigate -Prompt $verifyPrompt -Model (Get-ModelForInvestigate -TaskClass $taskClass -Targets $verifyTargets -Attempt 2 -PreviousOutput $implResult.output) -Attempt (300 + $implementAttempt)
                    if ($verifyResult.success -and $verifyResult.output -match '(?im)^RESULT\s*:\s*CONFIRMED\s*$') {
                        $finalStatus = "NO_CHANGE"
                        $finalCategory = "NO_CHANGE_ALREADY_SATISFIED"
                        $finalSummary = "Implementation verification confirmed that the desired state already exists."
                        $finalFeedback = $implResult.output
                        throw [System.Exception]::new("TERMINAL_NO_CHANGE")
                    }
                    Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "NO_CHANGE_NOT_CONFIRMED" -Feedback ($verifyResult.output)
                    $implOutcome.category = "NO_CHANGE_UNCERTAIN"
                }
            }

            $lastNoChangeReason = $implOutcome.category
            [void]$implementationHistoryHashes.Add("$($implOutcome.category):$($implOutcome.hash)")
            Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "No files were changed." -Category $implOutcome.category
            Write-SchedulerSnapshot
            Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category $implOutcome.category -Feedback $implResult.output

            $repairReasons = @()
            switch ($implOutcome.category) {
                "NO_CHANGE_TARGET_NOT_FOUND" { $repairReasons = @("You did not find the target.", "Use the existing clues and search directly in the referenced files.") }
                "NO_CHANGE_BLOCKED" { $repairReasons = @("You reported a blocker.", "Do not only describe the blocker. Either make the smallest viable change or provide concrete search hits.") }
                "NO_CHANGE_UNCERTAIN" { $repairReasons = @("You were uncertain.", "Uncertainty is not a terminal state when actionable evidence already exists.") }
                default { $repairReasons = @("No files were changed.", "Use the actionable clues from your last output.") }
            }
            if (Test-HasActionableSignal -Text $implResult.output) {
                $repairPrompt = @"
$(Get-RepairBlock -FailureCode $implOutcome.category -Reasons $repairReasons -PreviousOutput $implResult.output)

IMPLEMENT THE TASK NOW.

TASK:
$taskPrompt

VALIDATED PLAN:
$implementPlan

INVESTIGATION:
$investigationBlock

REPRODUCTION:
$reproductionBlock

ALLOWED TARGET FILES:
$targetText

IMPORTANT:
- Use the files, lines, or replacements already identified.
- Do not return another vague explanation.
- Modify at least one repository file or return a clearly justified RESULT.
"@
                $repairModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $implResult.output -TaskText $taskPrompt -PipelineProfile $pipelineProfile
                $repairImplResult = Invoke-ClaudeRepair -PhaseName "IMPLEMENT" -Prompt $repairPrompt -Model $repairModel -Attempt (400 + $implementAttempt) -CanWrite
                if ($repairImplResult.success) {
                    $implResult = $repairImplResult
                    $implOutcome = Get-ImplementationOutcome -Output $implResult.output
                    $changedFilesResult = Get-ChangedFilesResult
                    if (-not $changedFilesResult.ok) {
                        Fail-ChangedFilesDetection -ChangedFilesResult $changedFilesResult -Phase "CHANGE_VALIDATE"
                    }
                    $changedFiles = @($changedFilesResult.files)
                    if ($changedFiles.Count -gt 0) {
                        Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "Repair implementation changed files." -Category "CHANGE_APPLIED"
                        Write-SchedulerSnapshot
                    } else {
                        Add-FeedbackEntry -Attempt $implementAttempt -Source "IMPLEMENT" -Category "IMPLEMENT_REPAIR_NO_CHANGE" -Feedback $implResult.output
                    }
                }
            }
            if ($changedFiles.Count -gt 0) {
                Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "$($changedFiles.Count) file(s) changed." -Category "CHANGE_APPLIED" -Data @{ files = $changedFiles }
                Write-SchedulerSnapshot
            } else {
            if ($implementationHistoryHashes.Count -ge 2) {
                $lastTwo = $implementationHistoryHashes | Select-Object -Last 2
                if (($lastTwo | Sort-Object -Unique).Count -eq 1) {
                    $finalStatus = "FAILED"
                    $finalCategory = $implOutcome.category
                    $finalSummary = "Two identical no-change results contained no new information, so another retry would be blind."
                    $finalFeedback = $implResult.output
                    throw [System.Exception]::new("TERMINAL_NO_CHANGE_REPEAT")
                }
            }
                continue
            }
        }

        Add-TimelineEvent -Phase "CHANGE_VALIDATE" -Message "$($changedFiles.Count) file(s) changed." -Category "CHANGE_APPLIED" -Data @{ files = $changedFiles }
        Write-SchedulerSnapshot
        $reviewCycle = 0
        while ($reviewCycle -le $CONST_REMEDIATION_ATTEMPTS) {
            $cycleLabel = "i$implementAttempt-r$reviewCycle"
            if ($reproductionConfirmed) {
                $currentPhase = "VERIFY_REPRO"
                $attemptsByPhase.verifyRepro = [Math]::Max($attemptsByPhase.verifyRepro, $reviewCycle + 1)
                Write-Host "[VERIFY_REPRO] Cycle $cycleLabel..."
                $verifyReproTargets = if ($reproductionTests.testProjects.Count -gt 0) { @($reproductionTests.testProjects) } else { @() }
                $verifyReproResult = Invoke-TargetedTestRun -SolutionPath $worktreeSln -ProjectPaths $verifyReproTargets -TestFilter $reproductionTests.testFilter
                Save-Artifact -Name "verify-repro-$cycleLabel.txt" -Content $verifyReproResult.output | Out-Null
                if (-not $verifyReproResult.allPassed) {
                    Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "VERIFY_REPRO" -Category "REPRO_TESTS_FAILED" -Feedback $verifyReproResult.output
                    Add-TimelineEvent -Phase "VERIFY_REPRO" -Message "Reproduction tests are still failing." -Category "REPRO_TESTS_FAILED"
                    if ($reviewCycle -ge $CONST_REMEDIATION_ATTEMPTS) {
                        $finalStatus = "FAILED"
                        $finalCategory = "REPRO_TESTS_FAILED"
                    $finalSummary = "The reproducing tests could not be repaired successfully."
                        $finalFeedback = $verifyReproResult.output
                        throw [System.Exception]::new("TERMINAL_REPRO_TESTS_FAILED")
                    }
                    $reviewCycle++
                    $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)
                    $fixPrompt = @"
Fix only the following failing reproduction tests in the current worktree.

TEST FAILURES:
$($verifyReproResult.output)

OUTPUT FORMAT AT THE END:
RESULT: CHANGE_APPLIED | NO_CHANGE_BLOCKED
SUMMARY:
<Short rationale>
"@
                    $verifyFixModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $verifyReproResult.output -TaskText $taskPrompt -PipelineProfile $pipelineProfile
                    $verifyFixResult = Invoke-ClaudeImplement -Prompt $fixPrompt -Model $verifyFixModel -Attempt (90 + $implementAttempt * 10 + $reviewCycle)
                    if (-not $verifyFixResult.success) {
                        Add-FeedbackEntry -Attempt $reviewCycle -Source "REMEDIATE" -Category "VERIFY_REPRO_TOOL_FAILURE" -Feedback $verifyFixResult.output
                    }
                    $changedFiles = Get-ChangedFiles
                    continue
                }
                $targetedVerificationPassed = $true
            }
            $currentPhase = "PREFLIGHT"
            $preflightValidation = Test-WorktreeEnvironment -WorktreePath $worktreePath -SolutionPath $worktreeSln -RepoRoot $repoRoot -Phase "PREFLIGHT"
            if (-not $preflightValidation.isValid) {
                Fail-WorktreeEnvironment -Validation $preflightValidation -Phase "PREFLIGHT" -Summary "The worktree became invalid before preflight validation."
            }
            Write-Host "[PREFLIGHT] Cycle $cycleLabel..."
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
                if ($preflight.environmentFailure) {
                    $environmentCategory = if ($preflight.environmentCategory) { [string]$preflight.environmentCategory } else { "WORKTREE_ENVIRONMENT_ERROR" }
                    $environmentFeedback = if ($preflight.environmentDetails) { ($preflight.environmentDetails | ConvertTo-Json -Depth 6) } else { $preflightJson }
                    Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "PREFLIGHT" -Category $environmentCategory -Feedback $environmentFeedback
                    Add-TimelineEvent -Phase "PREFLIGHT" -Message "Preflight detected an invalid worker environment." -Category $environmentCategory
                    $finalStatus = "ERROR"
                    $finalCategory = $environmentCategory
                    $finalSummary = "Preflight could not run against a valid solution path in the current worktree."
                    $finalFeedback = $environmentFeedback
                    throw [System.Exception]::new("TERMINAL_$environmentCategory")
                }
                $blockerText = ($preflight.blockers | ForEach-Object {
                    $entry = "- [$($_.check)] $($_.file)"
                    if ($_.line) { $entry += " L$($_.line)" }
                    $entry += ": $($_.message)"
                    if ($_.suggestion) { $entry += " -> $($_.suggestion)" }
                    $entry
                }) -join "`n"
                Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "PREFLIGHT" -Category "PREFLIGHT_FAILED" -Feedback $blockerText
                Add-TimelineEvent -Phase "PREFLIGHT" -Message "Preflight failed." -Category "PREFLIGHT_FAILED"
                if ($reviewCycle -ge $CONST_REMEDIATION_ATTEMPTS) {
                    $finalStatus = "FAILED"
                    $finalCategory = "PREFLIGHT_FAILED"
                    $finalSummary = "Preflight blockers could not be resolved within the remediation budget."
                    $finalFeedback = $blockerText
                    throw [System.Exception]::new("TERMINAL_PREFLIGHT_FAILED")
                }
                $reviewCycle++
                $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)

                $fixPrompt = @"
Fix only the following deterministic blockers in the current worktree.

BLOCKERS:
$blockerText

OUTPUT FORMAT AT THE END:
RESULT: CHANGE_APPLIED | NO_CHANGE_BLOCKED
SUMMARY:
<Short rationale>
"@
                $preflightFixModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $blockerText -TaskText $taskPrompt -PipelineProfile $pipelineProfile
                $fixResult = Invoke-ClaudeImplement -Prompt $fixPrompt -Model $preflightFixModel -Attempt (100 + $implementAttempt * 10 + $reviewCycle)
                if (-not $fixResult.success) {
                    Add-FeedbackEntry -Attempt $reviewCycle -Source "REMEDIATE" -Category "NO_CHANGE_TOOL_FAILURE" -Feedback $fixResult.output
                }
                $changedFiles = Get-ChangedFiles
                Update-ImplementationScopeCheck -ArtifactLabel "preflight-remediate-$cycleLabel" -Phase "PREFLIGHT"
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
            $scopeWarningText = Format-ImplementationScopeWarningText -ScopeCheck $implementationScopeCheck
            if ($scopeWarningText) {
                $warningText = if ($warningText) { "$warningText`n$scopeWarningText" } else { $scopeWarningText }
            }

            $currentPhase = "REVIEW"
            $diffForReview = (Invoke-NativeCommand git @("diff", "HEAD")).output
            $diffStatForReview = (Invoke-NativeCommand git @("diff", "--stat", "HEAD")).output
            Save-Artifact -Name "git-diff-$cycleLabel.patch" -Content $diffForReview | Out-Null
            $historyForReview = Format-FeedbackHistory -History $feedbackHistory -MaxEntries 3 -MaxChars $CONST_REVIEW_HISTORY_MAX_CHARS
            $lowRiskReview = Test-LowRiskReview -ChangedFiles $changedFiles -DiffText $diffForReview -WarningText $warningText -ReproductionConfirmed $reproductionConfirmed -TaskClass $taskClass
            if ($implementationScopeCheck -and $implementationScopeCheck.shouldEscalateReview) {
                if ($lowRiskReview) {
                    Add-TimelineEvent -Phase "REVIEW" -Message "Compact review escalated to FULL because implementation scope drift needs stricter review." -Category "REVIEW_SCOPE_ESCALATED" -Data @{ reason = "implementation_scope"; classification = [string]$implementationScopeCheck.classification }
                }
                $lowRiskReview = $false
            }
            $reviewPayloadInfo = Get-CompactReviewPayload -PlanText $planOutput -InvestigationText $investigationBlock -ReproductionText $reproductionBlock -DiffText $diffForReview -DiffStat $diffStatForReview -ChangedFiles $changedFiles -WarningText $warningText -HistoryText $historyForReview -LowRiskReview $lowRiskReview
            if ($lowRiskReview -and $reviewPayloadInfo.omittedProductionHunks) {
                $lowRiskReview = $false
                Add-TimelineEvent -Phase "REVIEW" -Message "Compact review escalated to FULL because production diffs would have been truncated." -Category "REVIEW_SCOPE_ESCALATED"
                $reviewPayloadInfo = Get-CompactReviewPayload -PlanText $planOutput -InvestigationText $investigationBlock -ReproductionText $reproductionBlock -DiffText $diffForReview -DiffStat $diffStatForReview -ChangedFiles $changedFiles -WarningText $warningText -HistoryText $historyForReview -LowRiskReview $false
            }
            $reviewModel = Get-ModelForReview -ChangedFiles $changedFiles -DiffText $diffForReview -WarningText $warningText -ReproductionConfirmed $reproductionConfirmed -TaskClass $taskClass -ForceFullReview:(-not $lowRiskReview)
            $reviewPayload = $reviewPayloadInfo.payload
            $taskClaimGuardrail = Get-TaskClaimGuardrail -TaskText $taskPrompt -ReproductionConfirmed $reproductionConfirmed
            $reviewPrompt = @"
$reviewerContent

---

REVIEW_SCOPE: $(if ($lowRiskReview) { "LOW_RISK_COMPACT" } else { "FULL" })

$taskClaimGuardrail

$reviewPayload

---

ORIGINAL TASK:
$taskPrompt
"@
            $reviewInfraAttempt = 0
            while ($true) {
                $reviewInfraAttempt++
                $reviewAttemptNumber = (($reviewCycle * ($CONST_REMEDIATION_ATTEMPTS + 1)) + $reviewInfraAttempt)
                $attemptsByPhase.review = [Math]::Max($attemptsByPhase.review, $reviewAttemptNumber)
                $reviewAttemptLabel = if ($reviewInfraAttempt -eq 1) { $cycleLabel } else { "$cycleLabel-retry$reviewInfraAttempt" }
                $reviewResult = Invoke-ClaudeReview -Prompt $reviewPrompt -AttemptLabel $reviewAttemptLabel -Model $reviewModel
                if (-not $reviewResult.success) {
                    $infraFeedback = if ($reviewResult.output) { $reviewResult.output } else { "Review call failed." }
                    Add-FeedbackEntry -Attempt $reviewAttemptNumber -Source "REVIEW" -Category "REVIEW_INFRA_FAILURE" -Feedback $infraFeedback
                    Add-TimelineEvent -Phase "REVIEW" -Message "Review infrastructure failure during invocation." -Category "REVIEW_INFRA_FAILURE"
                    if ($reviewInfraAttempt -ge ($CONST_REMEDIATION_ATTEMPTS + 1)) {
                        $finalStatus = "FAILED"
                        $finalCategory = "REVIEW_INFRA_FAILURE"
                        $finalSummary = "Review could not complete successfully after repeated infrastructure retries."
                        $finalFeedback = $infraFeedback
                        throw [System.Exception]::new("TERMINAL_REVIEW_INFRA_FAILURE")
                    }
                    continue
                }

                $verdict = Get-ReviewVerdict -ReviewOutput $reviewResult.output
                if ($verdict.verdict -eq "INFRA_FAILURE") {
                    Add-FeedbackEntry -Attempt $reviewAttemptNumber -Source "REVIEW" -Category "REVIEW_INFRA_FAILURE" -Feedback $verdict.feedback
                    Add-TimelineEvent -Phase "REVIEW" -Message "Review infrastructure failure in the response." -Category "REVIEW_INFRA_FAILURE"
                    if ($reviewInfraAttempt -ge ($CONST_REMEDIATION_ATTEMPTS + 1)) {
                        $finalStatus = "FAILED"
                        $finalCategory = "REVIEW_INFRA_FAILURE"
                        $finalSummary = "Review could not produce a parseable verdict after repeated infrastructure retries."
                        $finalFeedback = $verdict.feedback
                        throw [System.Exception]::new("TERMINAL_REVIEW_INFRA_FAILURE")
                    }
                    continue
                }
                break
            }

            Add-TimelineEvent -Phase "REVIEW" -Message "Review verdict: $($verdict.verdict)" -Category $verdict.severity
            if ($verdict.verdict -eq "ACCEPTED") {
                $finalVerdict = "ACCEPTED"
                $finalFeedback = $verdict.feedback
                $finalSeverity = ""
                $finalCategory = "ACCEPTED"
                $finalStatus = "ACCEPTED"
                $finalSummary = "Implementation, preflight, and review completed successfully."
                $accepted = $true
                break
            }

            $finalSeverity = $verdict.severity
            $reviewFeedback = "REVIEW DENIED ($($verdict.severity)):`n$($verdict.feedback)"
            Add-FeedbackEntry -Attempt ($reviewCycle + 1) -Source "REVIEW" -Category "REVIEW_DENIED_$($verdict.severity)" -Feedback $reviewFeedback
            if ($reviewCycle -ge $CONST_REMEDIATION_ATTEMPTS) {
                if ($verdict.severity -eq "MINOR" -and (Test-HasActionableSignal -Text $verdict.feedback)) {
                    $minorRescuePrompt = @"
$(Get-RepairBlock -FailureCode "REVIEW_DENIED_MINOR" -Reasons @("The review reported only minor but concrete problems.") -PreviousOutput $verdict.feedback)

FIX ONLY THESE MINOR ISSUES IN THE CURRENT WORKTREE.

FEEDBACK:
$($verdict.feedback)
"@
                    $minorRescueModel = Get-ModelForRepair -PhaseName "REVIEW_MINOR" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $verdict.feedback -TaskText $taskPrompt -PipelineProfile $pipelineProfile
                    $minorRescue = Invoke-ClaudeRepair -PhaseName "IMPLEMENT" -Prompt $minorRescuePrompt -Model $minorRescueModel -Attempt (500 + $implementAttempt * 10 + $reviewCycle) -CanWrite
                    if ($minorRescue.success) {
                        $changedFiles = Get-ChangedFiles
                        Update-ImplementationScopeCheck -ArtifactLabel "review-minor-rescue-$cycleLabel" -Phase "REVIEW"
                        $reviewCycle = 0
                        continue
                    }
                }
                $finalStatus = "FAILED"
                $finalCategory = "REVIEW_DENIED_$($verdict.severity)"
                $finalSummary = "Review feedback could not be resolved within the remediation budget."
                $finalFeedback = $verdict.feedback
                throw [System.Exception]::new("TERMINAL_REVIEW_DENIED")
            }

            $reviewCycle++
            $attemptsByPhase.remediate = [Math]::Max($attemptsByPhase.remediate, $reviewCycle)
            $fixPrompt = @"
Fix only the following review feedback in the current worktree.

FEEDBACK:
$($verdict.feedback)

OUTPUT FORMAT AT THE END:
RESULT: CHANGE_APPLIED | NO_CHANGE_BLOCKED
SUMMARY:
<Short rationale>
"@
            $reviewFixModel = Get-ModelForRepair -PhaseName "IMPLEMENT" -TaskClass $taskClass -InvestigationRequired $investigationRequired -Targets $planTargets -PreviousOutput $verdict.feedback -TaskText $taskPrompt -PipelineProfile $pipelineProfile
            $fixResult = Invoke-ClaudeImplement -Prompt $fixPrompt -Model $reviewFixModel -Attempt (200 + $implementAttempt * 10 + $reviewCycle)
            if (-not $fixResult.success) {
                Add-FeedbackEntry -Attempt $reviewCycle -Source "REMEDIATE" -Category "NO_CHANGE_TOOL_FAILURE" -Feedback $fixResult.output
            }
            $changedFilesResult = Get-ChangedFilesResult
            if (-not $changedFilesResult.ok) {
                Fail-ChangedFilesDetection -ChangedFilesResult $changedFilesResult -Phase "CHANGE_VALIDATE"
            }
            $changedFiles = @($changedFilesResult.files)
            Update-ImplementationScopeCheck -ArtifactLabel "review-remediate-$cycleLabel" -Phase "REVIEW"
        }

        if ($accepted) { break }
    }

    if (-not $accepted -and -not $finalCategory) {
        $finalStatus = "FAILED"
        $finalCategory = if ($lastNoChangeReason) { $lastNoChangeReason } else { "NO_CHANGE_UNCERTAIN" }
        $finalSummary = "Implementation did not produce acceptable changes within the budget."
        $finalFeedback = if ($lastImplementOutput) { $lastImplementOutput } else { Format-FeedbackHistory -History $feedbackHistory -MaxChars 1200 }
    }

    Write-Host "[FINALIZE] $finalCategory"
    Set-Location $originalDir

    $failureReasons = @($feedbackHistory | ForEach-Object { $_.category } | Where-Object { $_ } | Select-Object -Unique)
    Write-TimelineArtifact
    Write-PipelineLog -RepoRoot $repoRoot -Task $taskLine -Status $finalStatus -FinalCategory $finalCategory -FailureReasons $failureReasons -Files $changedFiles

    if ($finalStatus -eq "ACCEPTED") {
        $finalizeValidation = Test-WorktreeEnvironment -WorktreePath $worktreePath -SolutionPath $worktreeSln -RepoRoot $repoRoot -Phase "FINALIZE"
        if (-not $finalizeValidation.isValid) {
            Fail-WorktreeEnvironment -Validation $finalizeValidation -Phase "FINALIZE" -Summary "The worktree became invalid before the final commit."
        }
        Invoke-NativeCommand git @("-C", $worktreePath, "add", "-A") | Out-Null
        Invoke-NativeCommand git @("-C", $worktreePath, "commit", "-m", "auto: $TaskName") | Out-Null
        Invoke-NativeCommand git @("worktree", "remove", $worktreePath) | Out-Null
        $worktreePath = $null
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -branch $branchName -files $changedFiles -verdict $finalVerdict -feedback $finalFeedback -severity $finalSeverity -phase "FINALIZE" -investigationConclusion $investigationConclusion -discoverConclusion $discoverConclusion -route $routeDecision -testability $testability -testProjects $testProjects -reproductionAttempted $reproductionAttempted -reproductionConfirmed $reproductionConfirmed -reproductionTests $reproductionTests -targetedVerificationPassed $targetedVerificationPassed -plannerEffortClass $plannerEffortClass -pipelineProfile $pipelineProfile
    } else {
        Invoke-NativeCommand git @("worktree", "remove", $worktreePath, "--force") | Out-Null
        Invoke-NativeCommand git @("branch", "-D", $branchName) | Out-Null
        $worktreePath = $null
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -branch "" -files $changedFiles -verdict $finalVerdict -feedback $finalFeedback -severity $finalSeverity -phase "FINALIZE" -investigationConclusion $investigationConclusion -noChangeReason $lastNoChangeReason -discoverConclusion $discoverConclusion -route $routeDecision -testability $testability -testProjects $testProjects -reproductionAttempted $reproductionAttempted -reproductionConfirmed $reproductionConfirmed -reproductionTests $reproductionTests -targetedVerificationPassed $targetedVerificationPassed -plannerEffortClass $plannerEffortClass -pipelineProfile $pipelineProfile
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
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -branch "" -files $changedFiles -verdict $finalVerdict -feedback $finalFeedback -severity $finalSeverity -phase $currentPhase -investigationConclusion $investigationConclusion -noChangeReason $lastNoChangeReason -discoverConclusion $discoverConclusion -route $routeDecision -testability $testability -testProjects $testProjects -reproductionAttempted $reproductionAttempted -reproductionConfirmed $reproductionConfirmed -reproductionTests $reproductionTests -targetedVerificationPassed $targetedVerificationPassed -plannerEffortClass $plannerEffortClass -pipelineProfile $pipelineProfile
    } else {
        Write-Host "[ERROR] $errMsg"
        $finalStatus = "ERROR"
        $finalCategory = "UNEXPECTED_ERROR"
        $finalSummary = "Unexpected error in phase $currentPhase."
        $finalFeedback = $errMsg
        Write-TimelineArtifact
        Write-ResultJson -status $finalStatus -finalCategory $finalCategory -summary $finalSummary -error "Unexpected error in phase $currentPhase`: $errMsg" -feedback $finalFeedback -phase $currentPhase -investigationConclusion $investigationConclusion -discoverConclusion $discoverConclusion -route $routeDecision -testability $testability -testProjects $testProjects -reproductionAttempted $reproductionAttempted -reproductionConfirmed $reproductionConfirmed -reproductionTests $reproductionTests -targetedVerificationPassed $targetedVerificationPassed -plannerEffortClass $plannerEffortClass -pipelineProfile $pipelineProfile
    }
} finally {
    Set-Location $originalDir -ErrorAction SilentlyContinue
    if ($worktreePath -and (Test-Path $worktreePath -ErrorAction SilentlyContinue)) {
        Invoke-NativeCommand git @("worktree", "remove", $worktreePath, "--force") | Out-Null
        Invoke-NativeCommand git @("branch", "-D", $branchName) | Out-Null
    }
}
