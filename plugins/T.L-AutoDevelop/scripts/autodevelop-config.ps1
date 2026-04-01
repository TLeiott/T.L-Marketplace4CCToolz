function Get-AutoDevelopConfigPath {
    param([string]$RepoRoot)

    if (-not $RepoRoot) { return "" }
    return (Join-Path $RepoRoot ".claude\autodevelop.json")
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

function Copy-AutoDevelopConfigValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
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

function Get-AutoDevelopConfigSectionObject {
    param(
        $ParentObject,
        [string]$PropertyName,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ParentObject -Name $PropertyName)) {
        return $null
    }

    $value = Get-AutoDevelopConfigPropertyValue -Object $ParentObject -Name $PropertyName
    if ($null -eq $value) {
        return $null
    }

    if (Test-AutoDevelopConfigObject -Value $value) {
        return $value
    }

    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope $Scope -Message "Section must be a JSON object. Falling back to defaults."
    return $null
}

function Resolve-AutoDevelopReasoningEffortValue {
    param(
        $ExplicitRole,
        $DefaultRole,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaultValue = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $DefaultRole -Name "reasoningEffort")
    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name "reasoningEffort")) {
        return $defaultValue
    }

    $text = (Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitRole -Name "reasoningEffort")).ToLowerInvariant()
    if (-not $text) { return "" }
    if ($text -in @("low", "medium", "high")) { return $text }

    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.reasoningEffort" -Message "Value must be low, medium, high, or empty. Falling back to the default role value."
    return $defaultValue
}

function Resolve-AutoDevelopPositiveIntValue {
    param(
        $ExplicitRole,
        $DefaultRole,
        [string]$PropertyName,
        [int]$FallbackValue,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings,
        [switch]$AllowZero
    )

    $defaultValue = $FallbackValue
    $defaultCandidate = Get-AutoDevelopConfigPropertyValue -Object $DefaultRole -Name $PropertyName
    $parsedDefault = 0
    if ($null -ne $defaultCandidate -and [int]::TryParse((Get-AutoDevelopTrimmedString -Value $defaultCandidate), [ref]$parsedDefault)) {
        $defaultValue = $parsedDefault
    }

    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name $PropertyName)) {
        return $defaultValue
    }

    $rawValue = Get-AutoDevelopConfigPropertyValue -Object $ExplicitRole -Name $PropertyName
    $text = Get-AutoDevelopTrimmedString -Value $rawValue
    if (-not $text) {
        return $defaultValue
    }

    $parsedValue = 0
    $isValid = [int]::TryParse($text, [ref]$parsedValue)
    if ($isValid -and (($AllowZero -and $parsedValue -ge 0) -or (-not $AllowZero -and $parsedValue -gt 0))) {
        return $parsedValue
    }

    $expected = if ($AllowZero) { "a non-negative integer" } else { "a positive integer" }
    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be $expected. Falling back to the default role value."
    return $defaultValue
}

function Resolve-AutoDevelopBooleanValue {
    param(
        $ExplicitRole,
        $DefaultRole,
        [string]$PropertyName,
        [bool]$FallbackValue,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaultValue = $FallbackValue
    if (Test-AutoDevelopConfigPropertyDefined -Object $DefaultRole -Name $PropertyName) {
        $defaultValue = [bool](Get-AutoDevelopConfigPropertyValue -Object $DefaultRole -Name $PropertyName)
    }

    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name $PropertyName)) {
        return $defaultValue
    }

    $rawValue = Get-AutoDevelopConfigPropertyValue -Object $ExplicitRole -Name $PropertyName
    if ($rawValue -is [bool]) {
        return [bool]$rawValue
    }

    $text = (Get-AutoDevelopTrimmedString -Value $rawValue).ToLowerInvariant()
    if (-not $text) {
        return $defaultValue
    }

    switch ($text) {
        { $_ -in @("true", "1", "yes", "y") } { return $true }
        { $_ -in @("false", "0", "no", "n") } { return $false }
    }

    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be true or false. Falling back to the default role value."
    return $defaultValue
}

function Resolve-AutoDevelopProviderValue {
    param(
        $ExplicitProviderDefaults,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings,
        [string]$Scope = "providerDefaults.provider"
    )

    $defaultProvider = "claude-code"
    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitProviderDefaults -Name "provider")) {
        return $defaultProvider
    }

    $provider = (Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitProviderDefaults -Name "provider")).ToLowerInvariant()
    if (-not $provider) {
        return $defaultProvider
    }
    if ($provider -eq "claude-code") {
        return $provider
    }

    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope $Scope -Message "Only 'claude-code' is currently supported. Falling back to the built-in provider."
    return $defaultProvider
}

function Resolve-AutoDevelopCommandValue {
    param(
        $ExplicitObject,
        $DefaultObject,
        [string]$PropertyName,
        [string]$FallbackValue,
        [string]$Scope = "",
        [string]$ConfigPath = "",
        [System.Collections.ArrayList]$Warnings = $null
    )

    if (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitObject -Name $PropertyName) {
        $explicitValue = Get-AutoDevelopConfigPropertyValue -Object $ExplicitObject -Name $PropertyName
        if ($null -ne $explicitValue -and -not (Test-AutoDevelopScalarValue -Value $explicitValue)) {
            if ($Scope) {
                Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "$Scope.$PropertyName" -Message "Value must be a string. Falling back to the default value."
            }
            $explicitValue = $null
        }
        $explicitText = Get-AutoDevelopTrimmedString -Value $explicitValue
        if ($explicitText) {
            return $explicitText
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

function Get-AutoDevelopValidatedStringArray {
    param(
        $Value,
        [string]$Scope,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings,
        [switch]$WarnOnInvalid
    )

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        if ($WarnOnInvalid) {
            Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope $Scope -Message "Value must be a string or an array of strings. Falling back to the default value."
        }
        return $null
    }
    if ($Value -is [string]) {
        $single = Get-AutoDevelopTrimmedString -Value $Value
        if (-not $single) { return @() }
        return @($single)
    }

    $result = New-Object System.Collections.Generic.List[string]
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in @($Value)) {
            if ($null -eq $entry) { continue }
            if ($entry -is [System.Collections.IDictionary] -or $entry -is [pscustomobject]) {
                if ($WarnOnInvalid) {
                    Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope $Scope -Message "Entries must be strings. Invalid entries are ignored."
                }
                continue
            }

            $text = Get-AutoDevelopTrimmedString -Value $entry
            if ($text) {
                [void]$result.Add($text)
            }
        }
        return @($result.ToArray())
    }

    $scalarText = Get-AutoDevelopTrimmedString -Value $Value
    if (-not $scalarText) { return @() }
    return @($scalarText)
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
        $explicitArray = Get-AutoDevelopValidatedStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitObject -Name $PropertyName) -Scope "$Scope.$PropertyName" -ConfigPath $ConfigPath -Warnings $Warnings -WarnOnInvalid
        if ($null -ne $explicitArray) {
            return $explicitArray
        }
    }

    return @(Get-AutoDevelopValidatedStringArray -Value (Get-AutoDevelopConfigPropertyValue -Object $DefaultObject -Name $PropertyName) -Scope "$Scope.$PropertyName" -ConfigPath $ConfigPath -Warnings $Warnings)
}

function Get-NormalizedAutoDevelopRoleConfig {
    param(
        [string]$RoleName,
        $ExplicitRole,
        $DefaultRole,
        $NormalizedProviderDefaults,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $scope = "roles.$RoleName"
    $defaultModel = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $DefaultRole -Name "model")
    $explicitModelDefined = Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name "model"
    $explicitModel = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $ExplicitRole -Name "model")
    $roleProvider = Resolve-AutoDevelopProviderValue -ExplicitProviderDefaults ([pscustomobject]@{ provider = (Get-AutoDevelopConfigPropertyValue -Object $ExplicitRole -Name "provider") }) -ConfigPath $ConfigPath -Warnings $Warnings -Scope "$scope.provider"
    if (-not (Test-AutoDevelopConfigPropertyDefined -Object $ExplicitRole -Name "provider")) {
        $roleProvider = [string]$NormalizedProviderDefaults.provider
    }

    $roleConfig = [ordered]@{
        roleName = $RoleName
        provider = $roleProvider
        command = Resolve-AutoDevelopCommandValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "command" -FallbackValue ([string]$NormalizedProviderDefaults.command) -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        model = if ($explicitModelDefined -and $explicitModel) { $explicitModel } else { $defaultModel }
        modelPinned = [bool]($explicitModelDefined -and $explicitModel)
        reasoningEffort = Resolve-AutoDevelopReasoningEffortValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        maxTurns = Resolve-AutoDevelopPositiveIntValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -PropertyName "maxTurns" -FallbackValue 0 -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        allowedTools = Resolve-AutoDevelopStringArrayValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "allowedTools" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        extraArgs = Resolve-AutoDevelopStringArrayValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "extraArgs" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        dangerouslySkipPermissions = Resolve-AutoDevelopBooleanValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -PropertyName "dangerouslySkipPermissions" -FallbackValue $false -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
        timeoutSeconds = Resolve-AutoDevelopPositiveIntValue -ExplicitRole $ExplicitRole -DefaultRole $DefaultRole -PropertyName "timeoutSeconds" -FallbackValue 0 -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings -AllowZero
        promptTemplatePath = Resolve-AutoDevelopCommandValue -ExplicitObject $ExplicitRole -DefaultObject $DefaultRole -PropertyName "promptTemplatePath" -FallbackValue "" -Scope $scope -ConfigPath $ConfigPath -Warnings $Warnings
    }

    return [pscustomobject]$roleConfig
}

function Get-NormalizedAutoDevelopConfig {
    param(
        $OverrideConfig,
        [string]$ConfigPath,
        [System.Collections.ArrayList]$Warnings
    )

    $defaults = Get-DefaultAutoDevelopConfig
    $explicitProviderDefaults = Get-AutoDevelopConfigSectionObject -ParentObject $OverrideConfig -PropertyName "providerDefaults" -Scope "providerDefaults" -ConfigPath $ConfigPath -Warnings $Warnings
    $explicitRoles = Get-AutoDevelopConfigSectionObject -ParentObject $OverrideConfig -PropertyName "roles" -Scope "roles" -ConfigPath $ConfigPath -Warnings $Warnings

    if (Test-AutoDevelopConfigPropertyDefined -Object $OverrideConfig -Name "version") {
        $versionText = Get-AutoDevelopTrimmedString -Value (Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "version")
        if ($versionText -and $versionText -ne "1") {
            Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "version" -Message "Only config version 1 is currently supported. Falling back to the v1 defaults and semantics."
        }
    }

    $normalizedProviderDefaults = [pscustomobject]@{
        provider = Resolve-AutoDevelopProviderValue -ExplicitProviderDefaults $explicitProviderDefaults -ConfigPath $ConfigPath -Warnings $Warnings -Scope "providerDefaults.provider"
        command = Resolve-AutoDevelopCommandValue -ExplicitObject $explicitProviderDefaults -DefaultObject $defaults.providerDefaults -PropertyName "command" -FallbackValue "claude" -Scope "providerDefaults" -ConfigPath $ConfigPath -Warnings $Warnings
    }

    $roleNames = [ordered]@{}
    foreach ($roleName in Get-AutoDevelopConfigPropertyNames -Object $defaults.roles) {
        $roleNames[$roleName] = $true
    }
    foreach ($roleName in Get-AutoDevelopConfigPropertyNames -Object $explicitRoles) {
        $roleNames[$roleName] = $true
    }

    $normalizedRoles = [ordered]@{}
    foreach ($roleName in $roleNames.Keys) {
        $defaultRole = Get-AutoDevelopConfigPropertyValue -Object $defaults.roles -Name $roleName
        $explicitRole = $null
        if (Test-AutoDevelopConfigPropertyDefined -Object $explicitRoles -Name $roleName) {
            $candidateRole = Get-AutoDevelopConfigPropertyValue -Object $explicitRoles -Name $roleName
            if ($null -eq $candidateRole) {
                $explicitRole = $null
            } elseif (Test-AutoDevelopConfigObject -Value $candidateRole) {
                $explicitRole = $candidateRole
            } else {
                Add-AutoDevelopConfigWarning -Warnings $Warnings -Path $ConfigPath -Scope "roles.$roleName" -Message "Role definition must be a JSON object. Falling back to defaults for this role."
                $explicitRole = $null
            }
        }

        $normalizedRoles[$roleName] = Get-NormalizedAutoDevelopRoleConfig -RoleName $roleName -ExplicitRole $explicitRole -DefaultRole $defaultRole -NormalizedProviderDefaults $normalizedProviderDefaults -ConfigPath $ConfigPath -Warnings $Warnings
    }

    return [pscustomobject]@{
        version = 1
        providerDefaults = $normalizedProviderDefaults
        roles = [pscustomobject]$normalizedRoles
    }
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

function Merge-AutoDevelopRoleConfig {
    param(
        $BaseRole,
        $OverrideRole
    )

    $result = [ordered]@{}
    foreach ($propertyName in @("provider", "command", "model", "reasoningEffort", "maxTurns", "dangerouslySkipPermissions", "timeoutSeconds", "promptTemplatePath")) {
        $baseValue = Get-AutoDevelopConfigPropertyValue -Object $BaseRole -Name $propertyName
        $overrideValue = Get-AutoDevelopConfigPropertyValue -Object $OverrideRole -Name $propertyName
        if ($null -ne $overrideValue -and -not ($overrideValue -is [string] -and [string]::IsNullOrWhiteSpace([string]$overrideValue))) {
            $result[$propertyName] = $overrideValue
        } elseif ($null -ne $baseValue) {
            $result[$propertyName] = $baseValue
        }
    }

    $allowedToolsOverride = Get-AutoDevelopConfigPropertyValue -Object $OverrideRole -Name "allowedTools"
    $allowedToolsBase = Get-AutoDevelopConfigPropertyValue -Object $BaseRole -Name "allowedTools"
    $result.allowedTools = if ($null -ne $allowedToolsOverride) { ConvertTo-AutoDevelopStringArray -Value $allowedToolsOverride } else { ConvertTo-AutoDevelopStringArray -Value $allowedToolsBase }

    $extraArgsOverride = Get-AutoDevelopConfigPropertyValue -Object $OverrideRole -Name "extraArgs"
    $extraArgsBase = Get-AutoDevelopConfigPropertyValue -Object $BaseRole -Name "extraArgs"
    $result.extraArgs = if ($null -ne $extraArgsOverride) { ConvertTo-AutoDevelopStringArray -Value $extraArgsOverride } else { ConvertTo-AutoDevelopStringArray -Value $extraArgsBase }

    return [pscustomobject]$result
}

function Get-DefaultAutoDevelopConfig {
    return [pscustomobject]@{
        version = 1
        providerDefaults = [pscustomobject]@{
            provider = "claude-code"
            command = "claude"
        }
        roles = [pscustomobject]@{
            discover = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 12
                allowedTools = @("Read", "Glob", "Grep")
                extraArgs = @()
            }
            plan = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 18
                allowedTools = @("Read", "Glob", "Grep")
                extraArgs = @()
            }
            fixPlan = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 18
                allowedTools = @("Read", "Glob", "Grep")
                extraArgs = @()
            }
            directionCheck = [pscustomobject]@{
                model = "claude-sonnet-4-6"
                reasoningEffort = ""
                maxTurns = 8
                allowedTools = @("Read", "Glob", "Grep")
                extraArgs = @()
            }
            investigate = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 14
                allowedTools = @("Read", "Glob", "Grep")
                extraArgs = @()
            }
            reproduce = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 24
                allowedTools = @("Read", "Edit", "Write", "Bash", "Glob", "Grep")
                dangerouslySkipPermissions = $true
                extraArgs = @()
            }
            implement = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 24
                allowedTools = @("Read", "Edit", "Write", "Bash", "Glob", "Grep")
                dangerouslySkipPermissions = $true
                extraArgs = @()
            }
            reviewer = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 12
                allowedTools = @("Read", "Glob", "Grep")
                extraArgs = @()
                promptTemplatePath = "agents/reviewer.md"
            }
            scheduler = [pscustomobject]@{
                model = "claude-opus-4-6"
                reasoningEffort = ""
                maxTurns = 18
                allowedTools = @("Read", "Glob", "Grep", "Bash")
                extraArgs = @()
                promptTemplatePath = "agents/scheduler-agent.md"
            }
        }
    }
}

function Merge-AutoDevelopConfigWithDefaults {
    param($OverrideConfig)

    $defaults = Get-DefaultAutoDevelopConfig
    if (-not $OverrideConfig) { return $defaults }

    $providerDefaults = [ordered]@{
        provider = [string](Get-AutoDevelopConfigPropertyValue -Object $defaults.providerDefaults -Name "provider")
        command = [string](Get-AutoDevelopConfigPropertyValue -Object $defaults.providerDefaults -Name "command")
    }
    foreach ($propertyName in @("provider", "command")) {
        $overrideValue = Get-AutoDevelopConfigPropertyValue -Object (Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "providerDefaults") -Name $propertyName
        if ($null -ne $overrideValue -and -not [string]::IsNullOrWhiteSpace([string]$overrideValue)) {
            $providerDefaults[$propertyName] = [string]$overrideValue
        }
    }

    $mergedRoles = [ordered]@{}
    $overrideRoles = Get-AutoDevelopConfigPropertyValue -Object $OverrideConfig -Name "roles"
    foreach ($roleName in Get-AutoDevelopConfigPropertyNames -Object $defaults.roles) {
        $baseRole = Get-AutoDevelopConfigPropertyValue -Object $defaults.roles -Name $roleName
        $overrideRole = Get-AutoDevelopConfigPropertyValue -Object $overrideRoles -Name $roleName
        $mergedRoles[$roleName] = Merge-AutoDevelopRoleConfig -BaseRole $baseRole -OverrideRole $overrideRole
    }

    foreach ($roleName in Get-AutoDevelopConfigPropertyNames -Object $overrideRoles) {
        if (-not $mergedRoles.Contains($roleName)) {
            $mergedRoles[$roleName] = Merge-AutoDevelopRoleConfig -BaseRole ([pscustomobject]@{}) -OverrideRole (Get-AutoDevelopConfigPropertyValue -Object $overrideRoles -Name $roleName)
        }
    }

    return [pscustomobject]@{
        version = 1
        providerDefaults = [pscustomobject]$providerDefaults
        roles = [pscustomobject]$mergedRoles
    }
}

function Read-AutoDevelopConfigFile {
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
            warning = "AutoDevelop config could not be parsed: $($_.Exception.Message)"
            config = $null
        }
    }

    if (-not (Test-AutoDevelopConfigObject -Value $parsed)) {
        return [pscustomobject]@{
            exists = $true
            path = $Path
            loaded = $false
            warning = "AutoDevelop config root must be a JSON object."
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

function Get-AutoDevelopConfigState {
    param([string]$RepoRoot)

    $configPath = Get-AutoDevelopConfigPath -RepoRoot $RepoRoot
    $fileState = Read-AutoDevelopConfigFile -Path $configPath
    $warnings = [System.Collections.ArrayList]::new()
    if ($fileState.warning) {
        Add-AutoDevelopConfigWarning -Warnings $warnings -Path $configPath -Scope "file" -Message ([string]$fileState.warning)
    }
    $effectiveConfig = Get-NormalizedAutoDevelopConfig -OverrideConfig $fileState.config -ConfigPath $configPath -Warnings $warnings

    return [pscustomobject]@{
        path = $configPath
        file = $fileState
        explicit = $fileState.config
        warnings = @($warnings.ToArray())
        effective = $effectiveConfig
    }
}

function Resolve-AutoDevelopRoleConfig {
    param(
        [Parameter(Mandatory)]$ConfigState,
        [Parameter(Mandatory)][string]$RoleName,
        [string]$ModelOverride = ""
    )

    $roleConfig = Get-AutoDevelopConfigPropertyValue -Object $ConfigState.effective.roles -Name $RoleName
    if (-not $roleConfig) {
        throw "AutoDevelop role '$RoleName' is not defined."
    }

    $resolvedModel = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "model")
    $modelPinned = [bool](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "modelPinned")
    $modelSource = if ($modelPinned) { "explicit" } elseif ($ModelOverride) { "runtime" } elseif ($resolvedModel) { "default" } else { "unset" }
    if (-not $modelPinned -and $ModelOverride) {
        $resolvedModel = $ModelOverride
    }

    return [pscustomobject]@{
        roleName = $RoleName
        provider = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "provider")
        command = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "command")
        model = $resolvedModel
        modelPinned = $modelPinned
        modelSource = $modelSource
        reasoningEffort = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "reasoningEffort")
        maxTurns = [int](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "maxTurns")
        allowedTools = @((Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "allowedTools"))
        extraArgs = @((Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "extraArgs"))
        dangerouslySkipPermissions = [bool](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "dangerouslySkipPermissions")
        timeoutSeconds = [int](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "timeoutSeconds")
        promptTemplatePath = [string](Get-AutoDevelopConfigPropertyValue -Object $roleConfig -Name "promptTemplatePath")
    }
}

function Get-ClaudeRoleArguments {
    param([Parameter(Mandatory)]$RoleConfig)

    if ([string]$RoleConfig.provider -and [string]$RoleConfig.provider -ne "claude-code") {
        throw "AutoDevelop role '$($RoleConfig.roleName)' uses unsupported provider '$($RoleConfig.provider)'."
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    if ($RoleConfig.model) {
        [void]$arguments.Add("--model")
        [void]$arguments.Add([string]$RoleConfig.model)
    }
    if ($RoleConfig.reasoningEffort) {
        [void]$arguments.Add("--reasoning-effort")
        [void]$arguments.Add([string]$RoleConfig.reasoningEffort)
    }
    if ($RoleConfig.dangerouslySkipPermissions) {
        [void]$arguments.Add("--dangerously-skip-permissions")
    }
    if (@($RoleConfig.allowedTools).Count -gt 0) {
        [void]$arguments.Add("--allowedTools")
        [void]$arguments.Add((@($RoleConfig.allowedTools) -join ","))
    }
    if ([int]$RoleConfig.maxTurns -gt 0) {
        [void]$arguments.Add("--max-turns")
        [void]$arguments.Add(([int]$RoleConfig.maxTurns).ToString())
    }
    foreach ($extraArg in @($RoleConfig.extraArgs)) {
        [void]$arguments.Add([string]$extraArg)
    }
    return @($arguments.ToArray())
}

function Get-ClaudeExecutablePath {
    param([Parameter(Mandatory)]$RoleConfig)

    $candidateCommand = [string]$RoleConfig.command
    if ($env:AUTODEV_CLAUDE_COMMAND) {
        $candidateCommand = [string]$env:AUTODEV_CLAUDE_COMMAND
    }
    if (-not $candidateCommand) {
        $candidateCommand = "claude"
    }

    $resolved = Get-Command -Name $candidateCommand -ErrorAction SilentlyContinue
    if ($resolved) {
        return [string]$resolved.Source
    }

    if ($candidateCommand -eq "claude") {
        $fallback = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
        if (Test-Path -LiteralPath $fallback) {
            return $fallback
        }
    }

    if (Test-Path -LiteralPath $candidateCommand) {
        return [System.IO.Path]::GetFullPath($candidateCommand)
    }

    throw "Configured Claude command '$candidateCommand' for role '$($RoleConfig.roleName)' could not be resolved."
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
