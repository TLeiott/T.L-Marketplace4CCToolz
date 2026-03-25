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

function Normalize-RepoRelativePath {
    param([string]$Path)
    if (-not $Path) { return "" }
    $value = $Path.Trim().Replace("/", "\")
    if (-not $value) { return "" }
    try {
        if ([System.IO.Path]::IsPathRooted($value)) {
            $fullPath = [System.IO.Path]::GetFullPath($value)
            $fullRoot = [System.IO.Path]::GetFullPath((Get-Location).Path)
            if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = $fullPath.Substring($fullRoot.Length).TrimStart('\')
            } else {
                $value = $fullPath
            }
        }
    } catch {
    }
    while ($value.StartsWith(".\")) {
        $value = $value.Substring(2)
    }
    return $value.TrimStart('\')
}

function Get-CanonicalPathKey {
    param([string]$Path)
    $normalized = Normalize-RepoRelativePath -Path $Path
    if (-not $normalized) { return "" }
    return $normalized.ToLowerInvariant()
}

function Read-FileTextUtf8 {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return "" }
    try {
        return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8)
    } catch {
        return ""
    }
}

function Read-HeadFileTextUtf8 {
    param([string]$Path)
    $normalized = Normalize-RepoRelativePath -Path $Path
    if (-not $normalized) { return "" }
    $gitPath = $normalized.Replace("\", "/")
    $output = & {
        $ErrorActionPreference = 'Continue'
        & git show "HEAD:$gitPath" 2>$null
    }
    if ($LASTEXITCODE -ne 0) { return "" }
    return ($output | Out-String)
}

function Get-RepoFilesByExtension {
    param([string[]]$Extensions)
    if (-not $Extensions -or $Extensions.Count -eq 0) { return @() }
    $allowed = @($Extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    return @(
        Get-ChildItem -Path $slnDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $ext = ([string]$_.Extension).ToLowerInvariant()
                ($allowed -contains $ext) -and
                $_.FullName -notmatch '[\\/](bin|obj|\.git)[\\/]'
            } |
            ForEach-Object { Normalize-RepoRelativePath -Path $_.FullName } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Get-LineNumberFromIndex {
    param(
        [string]$Text,
        [int]$Index
    )
    if (-not $Text) { return 0 }
    if ($Index -le 0) { return 1 }
    $safeIndex = [Math]::Min($Index, $Text.Length)
    $prefix = $Text.Substring(0, $safeIndex)
    return ([regex]::Matches($prefix, "`r?`n").Count + 1)
}

function Get-ComponentParameterRecords {
    param([string]$Text)
    if (-not $Text) { return @() }
    $pattern = '(?is)\[Parameter(?:Attribute)?[^\]]*\]\s*(?:\[[^\]]+\]\s*)*(?<signature>(?:public|protected|internal|private|static|sealed|virtual|override|new|required|\s)+(?<type>[A-Za-z_][A-Za-z0-9_<>\.\?,\[\]]+)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\{)'
    return @(
        [regex]::Matches($Text, $pattern) | ForEach-Object {
            [pscustomobject]@{
                type = [string]$_.Groups['type'].Value
                name = [string]$_.Groups['name'].Value
                line = Get-LineNumberFromIndex -Text $Text -Index $_.Index
            }
        }
    )
}

function Get-EventCallbackParameterRecords {
    param([string]$Text)
    return @(
        Get-ComponentParameterRecords -Text $Text |
            Where-Object {
                ([string]$_.type) -match '^(?:Microsoft\.AspNetCore\.Components\.)?EventCallback(?:<.+>)?$'
            }
    )
}

function Get-EventCallbackInvokeNames {
    param([string]$Text)
    if (-not $Text) { return @() }
    return @(
        [regex]::Matches($Text, '\b(?<name>[A-Za-z_][A-Za-z0-9_]*)\.InvokeAsync\s*\(') |
            ForEach-Object { [string]$_.Groups['name'].Value } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
}

function Get-ChangedComponentPaths {
    param([string[]]$Paths)
    $items = [System.Collections.ArrayList]::new()
    foreach ($path in @($Paths)) {
        if (-not $path) { continue }
        $normalized = Normalize-RepoRelativePath -Path $path
        if (-not $normalized) { continue }
        if ($normalized -match '\.razor$') {
            [void]$items.Add($normalized)
            continue
        }
        if ($normalized -match '\.razor\.cs$') {
            $componentPath = $normalized.Substring(0, $normalized.Length - 3)
            if (Test-Path -LiteralPath $componentPath) {
                [void]$items.Add($componentPath)
            }
        }
    }
    return @($items | Select-Object -Unique)
}

function Get-ComponentCombinedText {
    param(
        [string]$ComponentPath,
        [switch]$FromHead
    )
    if (-not $ComponentPath) { return "" }
    $codeBehindPath = "$ComponentPath.cs"
    $razorText = if ($FromHead) { Read-HeadFileTextUtf8 -Path $ComponentPath } else { Read-FileTextUtf8 -Path $ComponentPath }
    $codeBehindText = if ($FromHead) { Read-HeadFileTextUtf8 -Path $codeBehindPath } else { Read-FileTextUtf8 -Path $codeBehindPath }
    return ((@($razorText, $codeBehindText) | Where-Object { $_ }) -join "`n")
}

function Get-NamespaceDirectiveValue {
    param([string]$Text)
    if (-not $Text) { return "" }
    $match = [regex]::Match($Text, '(?im)^\s*@namespace\s+(?<value>[A-Za-z_][A-Za-z0-9_\.]*)\s*$')
    if (-not $match.Success) { return "" }
    return ([string]$match.Groups['value'].Value).Trim()
}

function Get-RazorFileNamespace {
    param([string]$Path)
    if (-not $Path) { return "" }
    $fileText = Read-FileTextUtf8 -Path $Path
    $directNamespace = Get-NamespaceDirectiveValue -Text $fileText
    if ($directNamespace) { return $directNamespace }

    $searchDirs = [System.Collections.ArrayList]::new()
    $currentDir = Split-Path -Path $Path -Parent
    if ($currentDir) {
        while ($true) {
            [void]$searchDirs.Add($currentDir)
            $parentDir = Split-Path -Path $currentDir -Parent
            if (-not $parentDir -or $parentDir -eq $currentDir) { break }
            $currentDir = $parentDir
        }
    }
    [void]$searchDirs.Add("")
    foreach ($dir in @($searchDirs | Select-Object -Unique)) {
        $importsPath = if ($dir) { Join-Path $dir "_Imports.razor" } else { "_Imports.razor" }
        $importsText = Read-FileTextUtf8 -Path $importsPath
        $importsNamespace = Get-NamespaceDirectiveValue -Text $importsText
        if ($importsNamespace) { return $importsNamespace }
    }
    return ""
}

function Get-ComponentUsageRecords {
    param(
        [string]$ComponentName,
        [string]$ExcludePath,
        [string[]]$RazorFiles,
        [string]$ComponentNamespace = "",
        [bool]$RequireNamespaceMatch = $false,
        [hashtable]$NamespaceCache = $null
    )
    if (-not $ComponentName -or -not $RazorFiles) { return @() }
    $pattern = "<(?<tag>(?:[A-Za-z_][A-Za-z0-9_]*\.)*" + [regex]::Escape($ComponentName) + ")\b(?<attrs>[^>]*)>"
    $excludedKey = Get-CanonicalPathKey -Path $ExcludePath
    $results = [System.Collections.ArrayList]::new()
    $expectedQualifiedTag = if ($ComponentNamespace) { "$ComponentNamespace.$ComponentName" } else { "" }
    foreach ($path in @($RazorFiles)) {
        if ((Get-CanonicalPathKey -Path $path) -eq $excludedKey) { continue }
        $text = Read-FileTextUtf8 -Path $path
        if (-not $text) { continue }
        foreach ($match in [regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            $tagValue = [string]$match.Groups['tag'].Value
            $tagIsQualified = $tagValue.Contains('.')
            if ($ComponentNamespace -and $tagIsQualified -and (-not $tagValue.Equals($expectedQualifiedTag, [System.StringComparison]::OrdinalIgnoreCase))) {
                continue
            }
            if ($RequireNamespaceMatch -and -not $tagIsQualified) {
                $pathKey = Get-CanonicalPathKey -Path $path
                $parentNamespace = ""
                if ($NamespaceCache -and $NamespaceCache.ContainsKey($pathKey)) {
                    $parentNamespace = [string]$NamespaceCache[$pathKey]
                } else {
                    $parentNamespace = Get-RazorFileNamespace -Path $path
                    if ($NamespaceCache) { $NamespaceCache[$pathKey] = $parentNamespace }
                }
                if (-not $ComponentNamespace -or -not $parentNamespace.Equals($ComponentNamespace, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
            }
            [void]$results.Add([pscustomobject]@{
                file = $path
                line = Get-LineNumberFromIndex -Text $text -Index $match.Index
                attrs = [string]$match.Groups['attrs'].Value
            })
        }
    }
    return @($results)
}

function Test-UsageHasBindingEvidence {
    param(
        [string]$Attrs,
        [string]$CallbackName
    )
    if (-not $Attrs -or -not $CallbackName) { return $false }
    $explicitPattern = '(?is)(?:^|\s)' + [regex]::Escape($CallbackName) + '\s*='
    if ([regex]::IsMatch($Attrs, $explicitPattern)) { return $true }
    if ($CallbackName -match '^(?<base>[A-Za-z_][A-Za-z0-9_]*)Changed$') {
        $bindPattern = '(?is)(?:^|\s)@bind-' + [regex]::Escape([string]$Matches['base']) + '(?::[\w-]+)?\s*='
        if ([regex]::IsMatch($Attrs, $bindPattern)) { return $true }
    }
    return $false
}

function Test-LikelyDotNetInteropHandle {
    param([string]$ObjectName)
    if (-not $ObjectName) { return $false }
    return (([string]$ObjectName) -match '(?i)dotnet')
}

function Get-LocalProjectIdentifiers {
    $identifiers = [System.Collections.ArrayList]::new()
    foreach ($project in @(Get-ChildItem -Path $slnDir -Recurse -Filter "*.csproj" -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' })) {
        $content = Read-FileTextUtf8 -Path $project.FullName
        if (-not $content) { continue }
        $values = [System.Collections.ArrayList]::new()
        foreach ($pattern in @('<AssemblyName>\s*(?<value>[^<]+)\s*</AssemblyName>', '<PackageId>\s*(?<value>[^<]+)\s*</PackageId>')) {
            foreach ($match in [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $value = ([string]$match.Groups['value'].Value).Trim()
                if ($value) { [void]$values.Add($value) }
            }
        }
        [void]$values.Add($project.BaseName)
        foreach ($value in @($values | Where-Object { $_ } | Select-Object -Unique)) {
            [void]$identifiers.Add($value)
        }
    }
    return @($identifiers | Select-Object -Unique)
}

function Get-JSInvokableRecords {
    param([string[]]$Paths)
    $results = [System.Collections.ArrayList]::new()
    $pattern = '(?is)\[JSInvokable(?:Attribute)?(?:\s*\(\s*"(?<identifier>[^"]+)"\s*\))?\]\s*(?<signature>(?:\[[^\]]+\]\s*)*(?:public|protected|internal|private|static|async|sealed|virtual|override|partial|extern|new|\s)+[A-Za-z0-9_<>\.\?,\[\]\s]+\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\()'
    foreach ($path in @($Paths)) {
        $text = Read-FileTextUtf8 -Path $path
        if (-not $text) { continue }
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $identifier = ([string]$match.Groups['identifier'].Value).Trim()
            $methodName = ([string]$match.Groups['name'].Value).Trim()
            if (-not $identifier) { $identifier = $methodName }
            if (-not $identifier) { continue }
            $signature = [string]$match.Groups['signature'].Value
            [void]$results.Add([pscustomobject]@{
                identifier = $identifier
                methodName = $methodName
                isStatic = ($signature -match '\bstatic\b')
                file = $path
                line = Get-LineNumberFromIndex -Text $text -Index $match.Index
            })
        }
    }
    return @($results)
}

function Get-JSInteropCallRecords {
    param([string]$Text)
    if (-not $Text) { return @() }
    $results = [System.Collections.ArrayList]::new()
    $staticPattern = 'DotNet\.(?<method>invokeMethod(?:Async)?)\s*\(\s*["''](?<assembly>[^"'']+)["'']\s*,\s*["''](?<identifier>[^"'']+)["'']'
    foreach ($match in [regex]::Matches($Text, $staticPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$results.Add([pscustomobject]@{
            kind = "static"
            method = ([string]$match.Groups['method'].Value)
            assembly = ([string]$match.Groups['assembly'].Value)
            identifier = ([string]$match.Groups['identifier'].Value)
            objectName = ""
            line = Get-LineNumberFromIndex -Text $Text -Index $match.Index
            key = ("static|{0}|{1}|{2}" -f ([string]$match.Groups['method'].Value).ToLowerInvariant(), ([string]$match.Groups['assembly'].Value).ToLowerInvariant(), ([string]$match.Groups['identifier'].Value).ToLowerInvariant())
        })
    }
    $instancePattern = '\b(?<object>[A-Za-z_][A-Za-z0-9_]*)\.(?<method>invokeMethod(?:Async)?)\s*\(\s*["''](?<identifier>[^"'']+)["'']'
    foreach ($match in [regex]::Matches($Text, $instancePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $objectName = [string]$match.Groups['object'].Value
        if ($objectName -eq 'DotNet') { continue }
        if (-not (Test-LikelyDotNetInteropHandle -ObjectName $objectName)) { continue }
        [void]$results.Add([pscustomobject]@{
            kind = "instance"
            method = ([string]$match.Groups['method'].Value)
            assembly = ""
            identifier = ([string]$match.Groups['identifier'].Value)
            objectName = $objectName
            line = Get-LineNumberFromIndex -Text $Text -Index $match.Index
            key = ("instance|{0}|{1}" -f ([string]$match.Groups['method'].Value).ToLowerInvariant(), ([string]$match.Groups['identifier'].Value).ToLowerInvariant())
        })
    }
    return @($results)
}

function Get-NewJsInteropCallRecords {
    param([string]$Path)
    $currentCalls = @(Get-JSInteropCallRecords -Text (Read-FileTextUtf8 -Path $Path))
    if ($currentCalls.Count -eq 0) { return @() }
    $baseKeys = @{}
    foreach ($call in @(Get-JSInteropCallRecords -Text (Read-HeadFileTextUtf8 -Path $Path))) {
        $baseKeys[[string]$call.key] = $true
    }
    return @(
        $currentCalls | Where-Object { -not $baseKeys.ContainsKey([string]$_.key) }
    )
}

function Invoke-WiringAnalysis {
    param([string[]]$ChangedFiles)
    $summary = [ordered]@{
        triggered = $false
        changedComponentCount = 0
        changedScriptCount = 0
        projectIdentifiers = @()
        eventCallbackFindings = @()
        jsInteropFindings = @()
    }

    $changedComponentPaths = @(Get-ChangedComponentPaths -Paths $ChangedFiles)
    $changedScriptPaths = @(
        $ChangedFiles |
            Where-Object { $_ -and $_ -match '\.(js|ts)$' -and (Test-Path -LiteralPath $_) } |
            ForEach-Object { Normalize-RepoRelativePath -Path $_ } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    if ($changedComponentPaths.Count -eq 0 -and $changedScriptPaths.Count -eq 0) {
        return [pscustomobject]$summary
    }

    $summary.triggered = $true
    $summary.changedComponentCount = $changedComponentPaths.Count
    $summary.changedScriptCount = $changedScriptPaths.Count

    $allRazorFiles = if ($changedComponentPaths.Count -gt 0) { @(Get-RepoFilesByExtension -Extensions @('.razor')) } else { @() }
    $componentNameCounts = @{}
    if ($allRazorFiles.Count -gt 0) {
        foreach ($razorFile in $allRazorFiles) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($razorFile)
            if (-not $name) { continue }
            $nameKey = $name.ToLowerInvariant()
            if (-not $componentNameCounts.ContainsKey($nameKey)) {
                $componentNameCounts[$nameKey] = 0
            }
            $componentNameCounts[$nameKey] = [int]$componentNameCounts[$nameKey] + 1
        }
    }
    $namespaceCache = @{}
    foreach ($componentPath in $changedComponentPaths) {
        $componentText = Get-ComponentCombinedText -ComponentPath $componentPath
        if (-not $componentText) { continue }
        $razorText = Read-FileTextUtf8 -Path $componentPath
        if ($razorText -match '(?im)^\s*@page\b') { continue }

        $currentCallbacks = @(Get-EventCallbackParameterRecords -Text $componentText)
        if ($currentCallbacks.Count -eq 0) { continue }
        $baseCallbacks = @(Get-EventCallbackParameterRecords -Text (Get-ComponentCombinedText -ComponentPath $componentPath -FromHead))
        $baseNames = @($baseCallbacks | ForEach-Object { [string]$_.name } | Select-Object -Unique)
        $parameterNames = @((Get-ComponentParameterRecords -Text $componentText) | ForEach-Object { [string]$_.name } | Select-Object -Unique)
        $invokedNames = @(Get-EventCallbackInvokeNames -Text $componentText)
        $componentName = [System.IO.Path]::GetFileNameWithoutExtension($componentPath)
        $componentNamespace = Get-RazorFileNamespace -Path $componentPath
        $componentNameKey = if ($componentName) { $componentName.ToLowerInvariant() } else { "" }
        $requireNamespaceMatch = $false
        if ($componentNameKey -and $componentNameCounts.ContainsKey($componentNameKey) -and [int]$componentNameCounts[$componentNameKey] -gt 1) {
            $requireNamespaceMatch = $true
        }
        $usageRecords = @(Get-ComponentUsageRecords -ComponentName $componentName -ExcludePath $componentPath -RazorFiles $allRazorFiles -ComponentNamespace $componentNamespace -RequireNamespaceMatch $requireNamespaceMatch -NamespaceCache $namespaceCache)
        if ($usageRecords.Count -eq 0) { continue }

        foreach ($callback in $currentCallbacks) {
            $callbackName = [string]$callback.name
            if (-not $callbackName -or ($baseNames -contains $callbackName)) { continue }
            $intentReason = ""
            if ($invokedNames -contains $callbackName) {
                $intentReason = "invoked"
            } elseif ($callbackName -match '^(?<base>[A-Za-z_][A-Za-z0-9_]*)Changed$' -and ($parameterNames -contains [string]$Matches['base'])) {
                $intentReason = "bind_pair"
            }
            if (-not $intentReason) { continue }
            $boundUsages = @($usageRecords | Where-Object { Test-UsageHasBindingEvidence -Attrs ([string]$_.attrs) -CallbackName $callbackName })
            if ($boundUsages.Count -gt 0) { continue }

            $usageFiles = @($usageRecords | ForEach-Object { [string]$_.file } | Select-Object -Unique)
            $message = "Possible EventCallback wiring gap: component '$componentName' introduced '$callbackName' but no parent usage binds it. Existing usages: $($usageFiles -join ', ')."
            $suggestion = "Bind the callback from a parent usage or leave clear evidence that the callback is intentionally optional."
            Add-Warning "eventcallback_wiring" $componentPath $message -line ([int]$callback.line) -suggestion $suggestion
            $summary.eventCallbackFindings += [ordered]@{
                component = $componentName
                componentPath = $componentPath
                callback = $callbackName
                line = [int]$callback.line
                intentReason = $intentReason
                usageFiles = @($usageFiles)
                severity = "warning"
            }
        }
    }

    if ($changedScriptPaths.Count -gt 0) {
        $projectIdentifiers = @(Get-LocalProjectIdentifiers)
        $summary.projectIdentifiers = @($projectIdentifiers)
        $jsInvokableFiles = @(Get-RepoFilesByExtension -Extensions @('.cs', '.razor'))
        $jsInvokables = @(Get-JSInvokableRecords -Paths $jsInvokableFiles)
        foreach ($path in $changedScriptPaths) {
            foreach ($call in @(Get-NewJsInteropCallRecords -Path $path)) {
                $identifier = [string]$call.identifier
                if (-not $identifier) { continue }
                if ([string]$call.kind -eq 'static') {
                    $assembly = [string]$call.assembly
                    $resolvedLocalAssembly = @($projectIdentifiers | Where-Object { ([string]$_).Equals($assembly, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                    if (-not $resolvedLocalAssembly) { continue }
                    $matches = @($jsInvokables | Where-Object {
                        ([string]$_.identifier).Equals($identifier, [System.StringComparison]::OrdinalIgnoreCase) -and
                        [bool]$_.isStatic
                    })
                    if ($matches.Count -gt 0) { continue }
                    $message = "Static JS interop call '$assembly.$identifier' has no matching local static [JSInvokable] target."
                    $suggestion = "Add a matching public static [JSInvokable] method or update the invoked identifier."
                    Add-Blocker "jsinterop_wiring" $path $message -line ([int]$call.line) -suggestion $suggestion
                    $summary.jsInteropFindings += [ordered]@{
                        file = $path
                        line = [int]$call.line
                        kind = "static"
                        assembly = $assembly
                        identifier = $identifier
                        severity = "blocker"
                    }
                    continue
                }

                $matches = @($jsInvokables | Where-Object {
                    ([string]$_.identifier).Equals($identifier, [System.StringComparison]::OrdinalIgnoreCase) -and
                    (-not [bool]$_.isStatic)
                })
                if ($matches.Count -gt 0) { continue }
                $message = "Instance JS interop call '$identifier' has no matching local instance [JSInvokable] target."
                $suggestion = "Add a matching [JSInvokable] instance method or update the invoked identifier."
                Add-Warning "jsinterop_wiring" $path $message -line ([int]$call.line) -suggestion $suggestion
                $summary.jsInteropFindings += [ordered]@{
                    file = $path
                    line = [int]$call.line
                    kind = "instance"
                    assembly = ""
                    identifier = $identifier
                    severity = "warning"
                }
            }
        }
    }

    return [pscustomobject]$summary
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

$ChangedFiles = @($ChangedFiles | ForEach-Object { Normalize-RepoRelativePath -Path $_ } | Where-Object { $_ } | Select-Object -Unique)
$runSummary.changedFiles = @($ChangedFiles)
$changedCs = $ChangedFiles | Where-Object { $_ -match '\.cs$' -and (Test-Path -LiteralPath $_) }
$changedCsproj = $ChangedFiles | Where-Object { $_ -match '\.csproj$' -and (Test-Path -LiteralPath $_) }
$changedXaml = $ChangedFiles | Where-Object { $_ -match '\.xaml$' -and (Test-Path -LiteralPath $_) }

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

$wiringSummary = Invoke-WiringAnalysis -ChangedFiles $ChangedFiles
$runSummary.wiringChecks = $wiringSummary
Save-DebugJson -Object $wiringSummary -Name 'wiring-analysis.json' | Out-Null

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
