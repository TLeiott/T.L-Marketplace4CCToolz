. (Join-Path $PSScriptRoot "providers\provider-claude-code.ps1")

$script:AutoDevelopCliProfileCache = $null

function Get-AutoDevelopConfigPath {
    param([string]$RepoRoot)

    if (-not $RepoRoot) { return "" }
    return (Join-Path $RepoRoot ".claude\autodevelop.json")
}

function Get-AutoDevelopSessionStatePath {
    param([string]$RepoRoot)

    if (-not $RepoRoot) { return "" }
    return (Join-Path $RepoRoot ".claude-develop-logs\session.json")
}

function ConvertTo-AutoDevelopStringArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        $single = ([string]$Value).Trim()
        if (-not $single) { return @() }
        return @($single)
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Value)) {
        $text = ([string]$entry).Trim()
        if ($text) {
            [void]$result.Add($text)
        }
    }
    return @($result.ToArray())
}

function Test-AutoDevelopConfigObject {
    param($Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    return $Value -is [pscustomobject]
}

function Get-AutoDevelopConfigPropertyNames {
    param($Object)

    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-AutoDevelopConfigPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Name) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-AutoDevelopConfigPropertyDefined {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object -or -not $Name) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function New-AutoDevelopConfigWarning {
    param(
        [string]$Path,
        [string]$Scope,
        [string]$Message
    )

    return [pscustomobject]@{
        path = $Path
        scope = $Scope
        message = $Message
    }
}

function Add-AutoDevelopConfigWarning {
    param(
        [System.Collections.ArrayList]$Warnings,
        [string]$Path,
        [string]$Scope,
        [string]$Message
    )

    if ($null -eq $Warnings -or -not $Scope -or -not $Message) { return }
    $alreadyExists = @($Warnings | Where-Object { [string]$_.scope -eq $Scope -and [string]$_.message -eq $Message }).Count -gt 0
    if ($alreadyExists) { return }
    [void]$Warnings.Add((New-AutoDevelopConfigWarning -Path $Path -Scope $Scope -Message $Message))
}

function Get-AutoDevelopTrimmedString {
    param($Value)

    if ($null -eq $Value) { return "" }
    return ([string]$Value).Trim()
}

function Test-AutoDevelopScalarValue {
    param($Value)

    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return $true }
    if ($Value -is [ValueType]) { return $true }
    return $false
}

function Read-AutoDevelopJsonFile {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            exists = $false
            path = $Path
            loaded = $false
            warning = ""
            config = $null
        }
    }

    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $parsed = $raw | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{
            exists = $true
            path = $Path
            loaded = $false
            warning = "AutoDevelop JSON could not be parsed: $($_.Exception.Message)"
            config = $null
        }
    }

    if (-not (Test-AutoDevelopConfigObject -Value $parsed)) {
        return [pscustomobject]@{
            exists = $true
            path = $Path
            loaded = $false
            warning = "AutoDevelop JSON root must be a JSON object."
            config = $null
        }
    }

    return [pscustomobject]@{
        exists = $true
        path = $Path
        loaded = $true
        warning = ""
        config = $parsed
    }
}

function Read-AutoDevelopConfigFile {
    param([string]$Path)

    return (Read-AutoDevelopJsonFile -Path $Path)
}

function Read-AutoDevelopSessionStateFile {
    param([string]$Path)

    return (Read-AutoDevelopJsonFile -Path $Path)
}

function Resolve-AutoDevelopNativeCommandName {
    param([string]$Command)

    $normalizedCommand = if ($Command) { $Command.ToLowerInvariant() } else { "" }
    switch ($normalizedCommand) {
        "git" {
            if ($env:AUTODEV_GIT_COMMAND) { return $env:AUTODEV_GIT_COMMAND }
            break
        }
        "dotnet" {
            if ($env:AUTODEV_DOTNET_COMMAND) { return $env:AUTODEV_DOTNET_COMMAND }
            break
        }
        "taskkill" {
            if ($env:AUTODEV_TASKKILL_COMMAND) { return $env:AUTODEV_TASKKILL_COMMAND }
            break
        }
    }

    return $Command
}

function Get-AutoDevelopCliProfilesDirectory {
    return (Join-Path $PSScriptRoot "cli-profiles")
}

function Get-AutoDevelopCliProfiles {
    if ($script:AutoDevelopCliProfileCache) {
        return $script:AutoDevelopCliProfileCache
    }

    $profilesDir = Get-AutoDevelopCliProfilesDirectory
    $profiles = [ordered]@{}
    if (Test-Path -LiteralPath $profilesDir) {
        foreach ($file in Get-ChildItem -LiteralPath $profilesDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name) {
            $state = Read-AutoDevelopJsonFile -Path $file.FullName
            if (-not $state.loaded) {
                throw "CLI profile manifest '$($file.FullName)' is invalid: $($state.warning)"
            }

            $profile = $state.config
            $profileId = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $profile -Name "id")
            if (-not $profileId) {
                throw "CLI profile manifest '$($file.FullName)' is missing 'id'."
            }

            $profiles[$profileId] = $profile
        }
    }

    $script:AutoDevelopCliProfileCache = [pscustomobject]$profiles
    return $script:AutoDevelopCliProfileCache
}

function Resolve-AutoDevelopCliProfile {
    param(
        [Parameter(Mandatory)][string]$ProfileId,
        [string]$ConfigPath = "",
        [System.Collections.ArrayList]$Warnings = $null,
        [string]$Scope = ""
    )

    $profiles = Get-AutoDevelopCliProfiles
    $profile = Get-AutoDevelopConfigPropertyValue -Object $profiles -Name $ProfileId
    if ($profile) {
        return $profile
    }

    if ($Warnings) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope $Scope -Message "CLI profile '$ProfileId' is not supported by this plugin build."
        return $null
    }

    throw "CLI profile '$ProfileId' is not supported by this plugin build."
}

function Resolve-AutoDevelopStringValue {
    param(
        $ExplicitObject,
        $DefaultObject,
        [string]$PropertyName,
        [string]$FallbackValue,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    if (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitObject -Name $PropertyName) {
        $explicitValue = Get-AutoDevelopConfigPropertyValue -Object $ExplicitObject -Name $PropertyName
        if ($null -ne $explicitValue -and -not (Test-AutoDevelopScalarValue -Value $explicitValue)) {
            Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be a string. Falling back to the default value."
        } else {
            $explicitText = Get-AutoDevelopTrimmedString -Value $explicitValue
            if ($explicitText) {
                return $explicitText
            }
        }
    }

    if (Test-AutoDevelopConfigPropertyDefined -Object $DefaultObject -Name $PropertyName) {
        $defaultText = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $DefaultObject -Name $PropertyName)
        if ($defaultText) {
            return $defaultText
        }
    }

    return $FallbackValue
}

function Resolve-AutoDevelopStringArrayValue {
    param(
        $ExplicitObject,
        $DefaultObject,
        [string]$PropertyName,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    if (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitObject -Name $PropertyName) {
        $explicitValue = Get-AutoDevelopConfigPropertyValue -Object $ExplicitObject -Name $PropertyName
        if ($null -ne $explicitValue -and ($explicitValue -is [System.Collections.IDictionary] -or $explicitValue -is [pscustomobject])) {
            Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be a string or string array. Falling back to the default value."
        } else {
            $result = New-Object System.Collections.Generic.List[string]
            foreach ($entry in @($explicitValue)) {
                if ($null -eq $entry) { continue }
                if ($entry -is [System.Collections.IDictionary] -or $entry -is [pscustomobject]) {
                    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Entries must be strings. Invalid entries are ignored."
                    continue
                }

                $text = Get-AutoDevelopTrimmedString -Value $entry
                if ($text) {
                    [void]$result.Add($text)
                }
            }
            return @($result.ToArray())
        }
    }

    return @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $DefaultObject -Name $PropertyName))
}

function Resolve-AutoDevelopPositiveIntValue {
    param(
        $ExplicitObject,
        $DefaultObject,
        [string]$PropertyName,
        [int]$FallbackValue,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings,
        [switch]$AllowZero
    )

    $defaultValue = $FallbackValue
    if (Test-AutoDevelopConfigPropertyDefined -Object $DefaultObject -Name $PropertyName) {
        $defaultText = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $DefaultObject -Name $PropertyName)
        $defaultParsed = 0
        if ([int]::TryParse($defaultText, [ref]$defaultParsed)) {
            $defaultValue = $defaultParsed
        }
    }

    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitObject -Name $PropertyName)) {
        return $defaultValue
    }

    $text = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitObject -Name $PropertyName)
    if (-not $text) { return $defaultValue }

    $parsed = 0
    $valid = [int]::TryParse($text, [ref]$parsed)
    if ($valid -and (($AllowZero -and $parsed -ge 0) -or (-not $AllowZero -and $parsed -gt 0))) {
        return $parsed
    }

    $expected = if ($AllowZero) { "a non-negative integer" } else { "a positive integer" }
    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be $expected. Falling back to the default value."
    return $defaultValue
}

function Resolve-AutoDevelopBooleanValue {
    param(
        $ExplicitObject,
        $DefaultObject,
        [string]$PropertyName,
        [bool]$FallbackValue,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaultValue = $FallbackValue
    if (Test-AutoDevelopConfigPropertyDefined -Object $DefaultObject -Name $PropertyName) {
        $defaultValue = [bool](Get-AutoDevelopConfigPropertyValue -Object $DefaultObject -Name $PropertyName)
    }

    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitObject -Name $PropertyName)) {
        return $defaultValue
    }

    $rawValue = Get-AutoDevelopConfigPropertyValue -Object $ExplicitObject -Name $PropertyName
    if ($rawValue -is [bool]) { return [bool]$rawValue }

    $text = (Get-AutoDevelopTrimmedString -Value $rawValue).ToLowerInvariant()
    switch ($text) {
        { $_ -in @("true", "1", "yes", "y") } { return $true }
        { $_ -in @("false", "0", "no", "n") } { return $false }
    }

    if ($text) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be true or false. Falling back to the default value."
    }
    return $defaultValue
}

function Resolve-AutoDevelopOptionsValue {
    param(
        $ExplicitRole,
        $DefaultRole,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $base = [ordered]@{}
    $defaultOptions = Get-AutoDevelopConfigPropertyValue -Object $DefaultRole -Name "options"
    if (Test-AutoDevelopConfigObject -Value $defaultOptions) {
        foreach ($name in Get-AutoDevelopConfigPropertyNames -Object $defaultOptions) {
            $base[$name] = Get-AutoDevelopConfigPropertyValue -Object $defaultOptions -Name $name
        }
    }

    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name "options")) {
        return [pscustomobject]$base
    }

    $explicitOptions = Get-AutoDevelopConfigPropertyValue -Object $ExplicitRole -Name "options"
    if (-not (Test-AutoDevelopConfigObject -Value $explicitOptions)) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.options" -Message "Options must be a JSON object. Falling back to the default options."
        return [pscustomobject]$base
    }

    foreach ($name in Get-AutoDevelopConfigPropertyNames -Object $explicitOptions) {
        $base[$name] = Get-AutoDevelopConfigPropertyValue -Object $explicitOptions -Name $name
    }

    return [pscustomobject]$base
}

function Resolve-AutoDevelopCapabilitiesValue {
    param(
        $ExplicitRole,
        $DefaultRole,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $capabilities = Resolve-AutoDevelopStringArrayValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "capabilities" -Scope $Scope -ConfigPath $ConfigPath -Warnings $Warnings
    return @($capabilities | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
}

function Resolve-AutoDevelopUsageModelClassesValue {
    param(
        $ExplicitRole,
        $DefaultRole,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    if (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name "usageModelClasses") {
        $explicitUsageModelClasses = Resolve-AutoDevelopStringArrayValue -ExplicitObject $ExplicitRole -DefaultObject ([pscustomobject]@{}) -PropertyName "usageModelClasses" -Scope $Scope -ConfigPath $ConfigPath -Warnings $Warnings
        return @($explicitUsageModelClasses | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    }

    if (Test-AutoDevelopConfigPropertyDefined -Object $DefaultRole -Name "usageModelClasses") {
        return @(Resolve-AutoDevelopStringArrayValue -ExplicitObject ([pscustomobject]@{}) -DefaultObject $DefaultRole -PropertyName "usageModelClasses" -Scope $Scope -ConfigPath $ConfigPath -Warnings $Warnings | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    }

    return @()
}

function Get-DefaultAutoDevelopConfig {
    return [pscustomobject]@{
        version = 4
        defaultExecutionProfile = "default"
        executionProfiles = [pscustomobject]@{
            default = [pscustomobject]@{
                roles = [pscustomobject]@{
                    discover = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus")
                        maxTurns = 12
                        capabilities = @("read", "search")
                        options = [pscustomobject]@{}
                        extraArgs = @()
                    }
                    plan = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus", "sonnet")
                        maxTurns = 18
                        capabilities = @("read", "search")
                        options = [pscustomobject]@{}
                        extraArgs = @()
                    }
                    fixPlan = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus", "sonnet")
                        maxTurns = 18
                        capabilities = @("read", "search")
                        options = [pscustomobject]@{}
                        extraArgs = @()
                    }
                    directionCheck = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "sonnet"
                        usageModelClasses = @("sonnet")
                        maxTurns = 8
                        capabilities = @("read", "search")
                        options = [pscustomobject]@{}
                        extraArgs = @()
                    }
                    investigate = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus", "sonnet")
                        maxTurns = 14
                        capabilities = @("read", "search")
                        options = [pscustomobject]@{}
                        extraArgs = @()
                    }
                    reproduce = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus", "sonnet")
                        maxTurns = 24
                        capabilities = @("read", "search", "edit", "write", "shell")
                        options = [pscustomobject]@{
                            dangerouslySkipPermissions = $true
                        }
                        extraArgs = @()
                    }
                    implement = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus", "sonnet")
                        maxTurns = 24
                        capabilities = @("read", "search", "edit", "write", "shell")
                        options = [pscustomobject]@{
                            dangerouslySkipPermissions = $true
                        }
                        extraArgs = @()
                    }
                    reviewer = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus", "sonnet")
                        maxTurns = 12
                        capabilities = @("read", "search")
                        options = [pscustomobject]@{}
                        promptTemplatePath = "agents/reviewer.md"
                        extraArgs = @()
                    }
                    scheduler = [pscustomobject]@{
                        cliProfile = "claude-code-vanilla"
                        provider = "anthropic"
                        modelClass = "opus"
                        usageModelClasses = @("opus")
                        maxTurns = 18
                        capabilities = @("read", "search", "shell")
                        options = [pscustomobject]@{}
                        promptTemplatePath = "agents/scheduler-agent.md"
                        extraArgs = @()
                    }
                }
            }
        }
    }
}

function Get-AutoDevelopExecutionProfileNames {
    param($Config)

    if ($null -eq $Config) { return @() }
    return @(Get-AutoDevelopConfigPropertyNames -Object (Get-AutoDevelopConfigPropertyValue -Object $Config -Name "executionProfiles"))
}

function Get-AutoDevelopRoleNames {
    param($ExecutionProfile)

    if ($null -eq $ExecutionProfile) { return @() }
    return @(Get-AutoDevelopConfigPropertyNames -Object (Get-AutoDevelopConfigPropertyValue -Object $ExecutionProfile -Name "roles"))
}

function Get-NormalizedAutoDevelopRoleConfig {
    param(
        [string]$RoleName,
        $ExplicitRole,
        $DefaultRole,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $scope = "executionProfiles.<active>.roles.$RoleName"
    $modelClass = Resolve-AutoDevelopStringValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "modelClass" -FallbackValue "" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
    $cliProfile = Resolve-AutoDevelopStringValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "cliProfile" -FallbackValue "claude-code-vanilla" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
    $provider = Resolve-AutoDevelopStringValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "provider" -FallbackValue "anthropic" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
    $promptTemplatePath = Resolve-AutoDevelopStringValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "promptTemplatePath" -FallbackValue "" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings

    return [pscustomobject]@{
        roleName = $RoleName
        cliProfile = $cliProfile
        provider = $provider
        modelClass = $modelClass
        modelClassPinned = [bool](Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name "modelClass")
        maxTurns = Resolve-AutoDevelopPositiveIntValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "maxTurns" -FallbackValue 0 -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        timeoutSeconds = Resolve-AutoDevelopPositiveIntValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "timeoutSeconds" -FallbackValue 0 -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings -AllowZero
        promptTemplatePath = $promptTemplatePath
        capabilities = Resolve-AutoDevelopCapabilitiesValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        usageModelClasses = Resolve-AutoDevelopUsageModelClassesValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        extraArgs = Resolve-AutoDevelopStringArrayValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "extraArgs" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        fallbackCliProfiles = Resolve-AutoDevelopStringArrayValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "fallbackCliProfiles" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        options = Resolve-AutoDevelopOptionsValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
    }
}

function Get-NormalizedAutoDevelopExecutionProfile {
    param(
        [string]$ExecutionProfileName,
        $ExplicitExecutionProfile,
        $DefaultExecutionProfile,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaultRoles = Get-AutoDevelopConfigPropertyValue -Object $DefaultExecutionProfile -Name "roles"
    $explicitRoles = if (Test-AutoDevelopConfigObject -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitExecutionProfile -Name "roles")) { Get-AutoDevelopConfigPropertyValue -Object $ExplicitExecutionProfile -Name "roles" } else { $null }
    if (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitExecutionProfile -Name "roles" -and -not (Test-AutoDevelopConfigObject -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitExecutionProfile -Name "roles"))) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "executionProfiles.$ExecutionProfileName.roles" -Message "Roles must be a JSON object. Falling back to the default execution profile roles."
    }

    $roleNames = [ordered]@{}
    foreach ($roleName in Get-AutoDevelopConfigPropertyNames -Object $defaultRoles) {
        $roleNames[$roleName] = $true
    }
    foreach ($roleName in Get-AutoDevelopConfigPropertyNames -Object $explicitRoles) {
        $roleNames[$roleName] = $true
    }

    $normalizedRoles = [ordered]@{}
    foreach ($roleName in $roleNames.Keys) {
        $defaultRole = Get-AutoDevelopConfigPropertyValue -Object $defaultRoles -Name $roleName
        $explicitRole = $null
        if (Test-AutoDevelopConfigPropertyDefined -Object $explicitRoles -Name $roleName) {
            $candidateRole = Get-AutoDevelopConfigPropertyValue -Object $explicitRoles -Name $roleName
            if ($null -eq $candidateRole) {
                $explicitRole = $null
            } elseif (Test-AutoDevelopConfigObject -Value $candidateRole) {
                $explicitRole = $candidateRole
            } else {
                Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "executionProfiles.$ExecutionProfileName.roles.$roleName" -Message "Role definition must be a JSON object. Falling back to the default role configuration."
            }
        }

        $normalizedRoles[$roleName] = Get-NormalizedAutoDevelopRoleConfig -RoleName $roleName -ExplicitRole $explicitRole -DefaultRole $defaultRole -ConfigPath $ConfigPath -Warnings $Warnings
    }

    return [pscustomobject]@{
        name = $ExecutionProfileName
        roles = [pscustomobject]$normalizedRoles
    }
}

function Get-NormalizedAutoDevelopConfig {
    param(
        $OverrideConfig,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaults = Get-DefaultAutoDevelopConfig
    if (Test-AutoDevelopConfigPropertyDefined -Object $OverrideConfig -Name "version") {
        $versionText = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "version")
        if ($versionText -and $versionText -ne "4") {
            Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "version" -Message "Only config version 4 is supported. Falling back to the v4 defaults and semantics."
        }
    }

    $defaultExecutionProfile = Resolve-AutoDevelopStringValue -ExplicitObject $OverrideConfig -DefaultObject $defaults -PropertyName "defaultExecutionProfile" -FallbackValue "default" -Scope "root" -ConfigPath $ConfigPath -Warnings $Warnings
    $defaultProfileTemplate = Get-AutoDevelopConfigPropertyValue -Object (Get-AutoDevelopConfigPropertyValue -Object $defaults -Name "executionProfiles") -Name "default"
    $explicitProfiles = if (Test-AutoDevelopConfigObject -Value (Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "executionProfiles")) { Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "executionProfiles" } else { $null }
    if (Test-AutoDevelopConfigPropertyDefined -Object $OverrideConfig -Name "executionProfiles" -and -not (Test-AutoDevelopConfigObject -Value (Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "executionProfiles"))) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "executionProfiles" -Message "Execution profiles must be a JSON object. Falling back to the built-in profiles."
    }

    $profileNames = [ordered]@{ default = $true }
    foreach ($profileName in Get-AutoDevelopConfigPropertyNames -Object $explicitProfiles) {
        $profileNames[$profileName] = $true
    }

    $normalizedProfiles = [ordered]@{}
    foreach ($profileName in $profileNames.Keys) {
        $explicitProfile = Get-AutoDevelopConfigPropertyValue -Object $explicitProfiles -Name $profileName
        if ($null -ne $explicitProfile -and -not (Test-AutoDevelopConfigObject -Value $explicitProfile)) {
            Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "executionProfiles.$profileName" -Message "Execution profile must be a JSON object. Falling back to the built-in default profile."
            $explicitProfile = $null
        }
        $normalizedProfiles[$profileName] = Get-NormalizedAutoDevelopExecutionProfile -ExecutionProfileName $profileName -ExplicitExecutionProfile $explicitProfile -DefaultExecutionProfile $defaultProfileTemplate -ConfigPath $ConfigPath -Warnings $Warnings
    }

    if (-not $normalizedProfiles.Contains($defaultExecutionProfile)) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "defaultExecutionProfile" -Message "Default execution profile '$defaultExecutionProfile' is not defined. Falling back to 'default'."
        $defaultExecutionProfile = "default"
    }

    return [pscustomobject]@{
        version = 4
        defaultExecutionProfile = $defaultExecutionProfile
        executionProfiles = [pscustomobject]$normalizedProfiles
    }
}

function Resolve-AutoDevelopSessionSelection {
    param(
        $Config,
        $SessionState,
        [string]$SessionPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaultExecutionProfile = [string](Get-AutoDevelopConfigPropertyValue -Object $Config -Name "defaultExecutionProfile")
    if (-not (Test-AutoDevelopConfigObject -Value $SessionState)) {
        return [pscustomobject]@{
            activeExecutionProfile = $defaultExecutionProfile
            source = "default"
        }
    }

    $activeExecutionProfile = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $SessionState -Name "activeExecutionProfile")
    if (-not $activeExecutionProfile) {
        return [pscustomobject]@{
            activeExecutionProfile = $defaultExecutionProfile
            source = "default"
        }
    }

    $executionProfiles = Get-AutoDevelopConfigPropertyValue -Object $Config -Name "executionProfiles"
    if (-not (Get-AutoDevelopConfigPropertyValue -Object $executionProfiles -Name $activeExecutionProfile)) {
        Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $SessionPath -Scope "session.activeExecutionProfile" -Message "Execution profile '$activeExecutionProfile' is not defined. Falling back to the default execution profile."
        return [pscustomobject]@{
            activeExecutionProfile = $defaultExecutionProfile
            source = "default"
        }
    }

    return [pscustomobject]@{
        activeExecutionProfile = $activeExecutionProfile
        source = "session"
    }
}

function Get-AutoDevelopConfigState {
    param([string]$RepoRoot)

    $configPath = Get-AutoDevelopConfigPath -RepoRoot $RepoRoot
    $sessionPath = Get-AutoDevelopSessionStatePath -RepoRoot $RepoRoot
    $configFileState = Read-AutoDevelopConfigFile -Path $configPath
    $sessionFileState = Read-AutoDevelopSessionStateFile -Path $sessionPath
    $warnings = [System.Collections.ArrayList]::new()
    if ($configFileState.warning) {
        Add-AutoDevelopConfigWarning -Warnings $warnings -Path $configPath -Scope "config.file" -Message $configFileState.warning
    }
    if ($sessionFileState.warning) {
        Add-AutoDevelopConfigWarning -Warnings $warnings -Path $sessionPath -Scope "session.file" -Message $sessionFileState.warning
    }

    $effectiveConfig = Get-NormalizedAutoDevelopConfig -OverrideConfig $configFileState.config -ConfigPath $configPath -Warnings $warnings
    $sessionSelection = Resolve-AutoDevelopSessionSelection -Config $effectiveConfig -SessionState $sessionFileState.config -SessionPath $sessionPath -Warnings $warnings

    return [pscustomobject]@{
        path = $configPath
        file = $configFileState
        explicit = $configFileState.config
        sessionPath = $sessionPath
        sessionFile = $sessionFileState
        activeExecutionProfile = $sessionSelection.activeExecutionProfile
        activeExecutionProfileSource = $sessionSelection.source
        warnings = @($warnings.ToArray())
        effective = $effectiveConfig
        cliProfiles = Get-AutoDevelopCliProfiles
    }
}

function Resolve-AutoDevelopModelToken {
    param(
        $CliProfile,
        [string]$Provider,
        [string]$ModelClass,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings,
        [string]$Scope
    )

    if (-not $ModelClass) { return "" }
    $modelResolution = Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "modelResolution"
    $providerMap = Get-AutoDevelopConfigPropertyValue -Object $modelResolution -Name $Provider
    if ($providerMap) {
        $resolvedModel = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $providerMap -Name $ModelClass)
        if ($resolvedModel) {
            return $resolvedModel
        }
    }

    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope $Scope -Message "Provider '$Provider' with modelClass '$ModelClass' is not supported by cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))'. Falling back to the modelClass token itself."
    return $ModelClass
}

function Resolve-AutoDevelopAllowedTools {
    param(
        $CliProfile,
        [string[]]$Capabilities
    )

    $capabilityToolMap = Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "capabilityToolMap"
    $tools = New-Object System.Collections.Generic.List[string]
    foreach ($capability in @($Capabilities)) {
        foreach ($tool in @(Get-AutoDevelopConfigPropertyValue -Object $capabilityToolMap -Name $capability)) {
            $toolName = Get-AutoDevelopTrimmedString -Value $tool
            if ($toolName -and -not $tools.Contains($toolName)) {
                [void]$tools.Add($toolName)
            }
        }
    }
    return @($tools.ToArray())
}

function Test-AutoDevelopProfileSupportsRoleConfig {
    param(
        $CliProfile,
        $RoleConfig,
        [ref]$FailureReason
    )

    $supportedProviders = @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "supportedProviders"))
    if ($supportedProviders.Count -gt 0 -and $supportedProviders -notcontains [string]$RoleConfig.provider) {
        $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support provider '$([string]$RoleConfig.provider)'."
        return $false
    }

    $supportedModelClasses = @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "supportedModelClasses"))
    if ([string]$RoleConfig.modelClass -and $supportedModelClasses.Count -gt 0 -and $supportedModelClasses -notcontains [string]$RoleConfig.modelClass) {
        $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support modelClass '$([string]$RoleConfig.modelClass)'."
        return $false
    }

    $supportedCapabilities = @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "supportedCapabilities")) | ForEach-Object { ([string]$_).ToLowerInvariant() }
    foreach ($capability in @($RoleConfig.capabilities)) {
        if ($supportedCapabilities.Count -gt 0 -and $supportedCapabilities -notcontains ([string]$capability).ToLowerInvariant()) {
            $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support capability '$capability'."
            return $false
        }
    }

    $supportedOptions = Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "supportedOptions"
    $reasoningEffort = [string]$RoleConfig.reasoningEffort
    if ($reasoningEffort) {
        $supportedReasoning = @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $supportedOptions -Name "reasoningEffort"))
        if ($supportedReasoning.Count -gt 0 -and $supportedReasoning -notcontains $reasoningEffort) {
            $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support reasoningEffort '$reasoningEffort'."
            return $false
        }
    }

    if ($RoleConfig.dangerouslySkipPermissions -and -not [bool](Get-AutoDevelopConfigPropertyValue -Object $supportedOptions -Name "dangerouslySkipPermissions")) {
        $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support dangerouslySkipPermissions."
        return $false
    }

    if ([int]$RoleConfig.maxTurns -gt 0 -and -not [bool](Get-AutoDevelopConfigPropertyValue -Object $supportedOptions -Name "maxTurns")) {
        $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support maxTurns."
        return $false
    }

    if (@($RoleConfig.extraArgs).Count -gt 0 -and -not [bool](Get-AutoDevelopConfigPropertyValue -Object $supportedOptions -Name "extraArgs")) {
        $FailureReason.Value = "cliProfile '$([string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name 'id'))' does not support extraArgs."
        return $false
    }

    return $true
}

function ConvertTo-AutoDevelopResolvedRoleConfig {
    param(
        [Parameter(Mandatory)]$RoleConfig,
        [Parameter(Mandatory)]$CliProfile,
        [string]$OverrideCliProfileId = ""
    )

    $failureReason = ""
    if (-not (Test-AutoDevelopProfileSupportsRoleConfig -CliProfile $CliProfile -RoleConfig $RoleConfig -FailureReason ([ref]$failureReason))) {
        throw $failureReason
    }

    $resolvedCliProfileId = if ($OverrideCliProfileId) { $OverrideCliProfileId } else { [string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "id") }
    return [pscustomobject]@{
        roleName = $RoleConfig.roleName
        executionProfile = $RoleConfig.executionProfile
        executionProfileSource = $RoleConfig.executionProfileSource
        cliProfile = $resolvedCliProfileId
        cliFamily = [string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "family")
        provider = $RoleConfig.provider
        command = [string](Get-AutoDevelopConfigPropertyValue -Object $CliProfile -Name "command")
        modelClass = $RoleConfig.modelClass
        modelClassPinned = $RoleConfig.modelClassPinned
        modelSource = $RoleConfig.modelSource
        model = Resolve-AutoDevelopModelToken -CliProfile $CliProfile -Provider $RoleConfig.provider -ModelClass $RoleConfig.modelClass -ConfigPath "" -Warnings ([System.Collections.ArrayList]::new()) -Scope ""
        reasoningEffort = $RoleConfig.reasoningEffort
        maxTurns = $RoleConfig.maxTurns
        timeoutSeconds = $RoleConfig.timeoutSeconds
        promptTemplatePath = $RoleConfig.promptTemplatePath
        capabilities = @($RoleConfig.capabilities)
        usageModelClasses = @($RoleConfig.usageModelClasses)
        extraArgs = @($RoleConfig.extraArgs)
        fallbackCliProfiles = @($RoleConfig.fallbackCliProfiles)
        options = $RoleConfig.options
        dangerouslySkipPermissions = $RoleConfig.dangerouslySkipPermissions
        allowedTools = Resolve-AutoDevelopAllowedTools -CliProfile $CliProfile -Capabilities @($RoleConfig.capabilities)
    }
}

function Get-AutoDevelopFallbackCliProfiles {
    param([Parameter(Mandatory)]$RoleConfig)

    $cliProfile = Resolve-AutoDevelopCliProfile -ProfileId ([string]$RoleConfig.cliProfile)
    $fallbacks = New-Object System.Collections.Generic.List[string]
    foreach ($profileId in @($RoleConfig.fallbackCliProfiles + @(ConvertTo-AutoDevelopStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $cliProfile -Name "fallbackCliProfiles")))) {
        $trimmed = Get-AutoDevelopTrimmedString -Value $profileId
        if ($trimmed -and $trimmed -ne [string]$RoleConfig.cliProfile -and -not $fallbacks.Contains($trimmed)) {
            [void]$fallbacks.Add($trimmed)
        }
    }

    return @($fallbacks.ToArray())
}

function Resolve-AutoDevelopRoleConfigForCliProfile {
    param(
        [Parameter(Mandatory)]$RoleConfig,
        [Parameter(Mandatory)][string]$CliProfileId
    )

    $cliProfile = Resolve-AutoDevelopCliProfile -ProfileId $CliProfileId
    return (ConvertTo-AutoDevelopResolvedRoleConfig -RoleConfig $RoleConfig -CliProfile $cliProfile -OverrideCliProfileId $CliProfileId)
}

function Resolve-AutoDevelopRoleConfig {
    param(
        [Parameter(Mandatory)]$ConfigState,
        [Parameter(Mandatory)][string]$RoleName,
        [string]$ModelOverride = ""
    )

    $executionProfile = Get-AutoDevelopConfigPropertyValue -Object (Get-AutoDevelopConfigPropertyValue -Object $ConfigState.effective -Name "executionProfiles") -Name $ConfigState.activeExecutionProfile
    if (-not $executionProfile) {
        throw "AutoDevelop execution profile '$($ConfigState.activeExecutionProfile)' is not defined."
    }

    $roleConfig = Get-AutoDevelopConfigPropertyValue -Object (Get-AutoDevelopConfigPropertyValue -Object $executionProfile -Name "roles") -Name $RoleName
    if (-not $roleConfig) {
        throw "AutoDevelop role '$RoleName' is not defined in execution profile '$($ConfigState.activeExecutionProfile)'."
    }

    $cliProfileId = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "cliProfile")
    $cliProfile = Resolve-AutoDevelopCliProfile -ProfileId $cliProfileId -ConfigPath $ConfigState.path -Warnings ([System.Collections.ArrayList]::new()) -Scope "executionProfiles.$($ConfigState.activeExecutionProfile).roles.$RoleName.cliProfile"
    if (-not $cliProfile) {
        throw "CLI profile '$cliProfileId' for role '$RoleName' is not supported."
    }

    $provider = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "provider")
    $modelClass = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "modelClass")
    $modelClassPinned = [bool](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "modelClassPinned")
    $modelSource = if ($modelClassPinned) { "explicit" } elseif ($ModelOverride) { "runtime" } elseif ($modelClass) { "default" } else { "unset" }
    if (-not $modelClassPinned -and $ModelOverride) {
        $modelClass = $ModelOverride
    }

    $options = Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "options"
    $reasoningEffort = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $options -Name "reasoningEffort")
    if ($reasoningEffort -and $reasoningEffort -notin @("low", "medium", "high")) {
        $reasoningEffort = ""
    }

    $baseRole = [pscustomobject]@{
        roleName = $RoleName
        executionProfile = $ConfigState.activeExecutionProfile
        executionProfileSource = $ConfigState.activeExecutionProfileSource
        cliProfile = $cliProfileId
        provider = $provider
        modelClass = $modelClass
        modelClassPinned = $modelClassPinned
        modelSource = $modelSource
        reasoningEffort = $reasoningEffort
        maxTurns = [int](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "maxTurns")
        timeoutSeconds = [int](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "timeoutSeconds")
        promptTemplatePath = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "promptTemplatePath")
        capabilities = @((Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "capabilities"))
        usageModelClasses = @((Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "usageModelClasses"))
        extraArgs = @((Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "extraArgs"))
        fallbackCliProfiles = @((Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "fallbackCliProfiles"))
        options = $options
        dangerouslySkipPermissions = [bool](Get-AutoDevelopConfigPropertyValue -Object $options -Name "dangerouslySkipPermissions")
    }

    return (ConvertTo-AutoDevelopResolvedRoleConfig -RoleConfig $baseRole -CliProfile $cliProfile)
}

function Get-AutoDevelopResolvedTimeoutSeconds {
    param(
        $RoleConfig,
        [int]$FallbackTimeoutSeconds
    )

    if ($RoleConfig -and [int]$RoleConfig.timeoutSeconds -gt 0) {
        return [int]$RoleConfig.timeoutSeconds
    }

    return [int]$FallbackTimeoutSeconds
}

function Get-AutoDevelopRoleUsageCombos {
    param(
        [Parameter(Mandatory)]$ConfigState,
        [string[]]$RoleNames = @()
    )

    $executionProfile = Get-AutoDevelopConfigPropertyValue -Object (Get-AutoDevelopConfigPropertyValue -Object $ConfigState.effective -Name "executionProfiles") -Name $ConfigState.activeExecutionProfile
    $roles = Get-AutoDevelopConfigPropertyValue -Object $executionProfile -Name "roles"
    if (@($RoleNames).Count -eq 0) {
        $RoleNames = Get-AutoDevelopConfigPropertyNames -Object $roles
    }

    $seen = [ordered]@{}
    $combos = New-Object System.Collections.Generic.List[object]
    foreach ($roleName in @($RoleNames)) {
        $resolvedRole = Resolve-AutoDevelopRoleConfig -ConfigState $ConfigState -RoleName $roleName
        $candidateModelClasses = if ($resolvedRole.modelClassPinned -or -not @($resolvedRole.usageModelClasses).Count) { @($resolvedRole.modelClass) } else { @($resolvedRole.usageModelClasses) }
        foreach ($modelClass in @($candidateModelClasses | Where-Object { $_ })) {
            $key = "$($resolvedRole.cliProfile)|$($resolvedRole.provider)|$modelClass"
            if ($seen.Contains($key)) { continue }
            $seen[$key] = $true
            $combos.Add([pscustomobject]@{
                cliProfile = $resolvedRole.cliProfile
                cliFamily = $resolvedRole.cliFamily
                provider = $resolvedRole.provider
                modelClass = [string]$modelClass
                roles = @($roleName)
            }) | Out-Null
        }
    }

    return @($combos.ToArray())
}

function Get-AutoDevelopCliProfileUsageSupport {
    param(
        [Parameter(Mandatory)][string]$CliProfileId,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$ModelClass
    )

    $cliProfile = Resolve-AutoDevelopCliProfile -ProfileId $CliProfileId
    $usageSupport = Get-AutoDevelopConfigPropertyValue -Object $cliProfile -Name "usageSupport"
    $usageKey = "${Provider}:${ModelClass}"
    $usageEntry = Get-AutoDevelopConfigPropertyValue -Object $usageSupport -Name $usageKey
    if ($usageEntry) {
        return $usageEntry
    }
    return [pscustomobject]@{ mode = "none" }
}

function Set-AutoDevelopSessionState {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ExecutionProfile
    )

    $configState = Get-AutoDevelopConfigState -RepoRoot $RepoRoot
    $profiles = Get-AutoDevelopConfigPropertyValue -Object $configState.effective -Name "executionProfiles"
    if (-not (Get-AutoDevelopConfigPropertyValue -Object $profiles -Name $ExecutionProfile)) {
        throw "Execution profile '$ExecutionProfile' is not defined."
    }

    $sessionPath = Get-AutoDevelopSessionStatePath -RepoRoot $RepoRoot
    $parent = Split-Path -Path $sessionPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $sessionObject = [ordered]@{
        activeExecutionProfile = $ExecutionProfile
        setAt = (Get-Date).ToString("o")
    }
    [System.IO.File]::WriteAllText($sessionPath, ($sessionObject | ConvertTo-Json -Depth 8), [System.Text.Encoding]::UTF8)
    return $sessionObject
}

function Clear-AutoDevelopSessionState {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $sessionPath = Get-AutoDevelopSessionStatePath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $sessionPath) {
        Remove-Item -LiteralPath $sessionPath -Force
        return $true
    }

    return $false
}

function Get-AutoDevelopPromptTemplateBody {
    param(
        [string]$BasePath,
        [string]$RelativePath
    )

    if (-not $BasePath -or -not $RelativePath) { return "" }
    $fullPath = Join-Path $BasePath $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath)) { return "" }
    $content = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    if ($content -match "(?s)^---\r?\n.*?\r?\n---\r?\n(.*)$") {
        return $Matches[1].TrimStart()
    }
    return $content
}

function Get-ClaudeRoleArguments {
    param([Parameter(Mandatory)]$RoleConfig)

    return @((Get-ClaudeCodeInvocationForRole -RoleConfig $RoleConfig).arguments)
}

function Get-ClaudeExecutablePath {
    param([Parameter(Mandatory)]$RoleConfig)

    return (Resolve-ClaudeCodeExecutablePath -RoleConfig $RoleConfig)
}
