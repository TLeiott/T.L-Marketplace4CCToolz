param(
    [string]$ConfigFile,
    [string]$Profile,
    [string]$Model,
    [string]$Provider
)

$c = Get-Content $ConfigFile -Raw | ConvertFrom-Json

if ($Profile) {
    $prof = $c.profiles.$Profile
    if (-not $prof) {
        Write-Error "Profile not found: $Profile"
        exit 1
    }
    if (-not $Model)    { $Model    = $prof.model }
    if (-not $Provider) { $Provider = $prof.provider }
}

if (-not $Model) {
    $def = $c.profiles.$($c.defaultProfile)
    $Model    = $def.model
    if (-not $Provider) { $Provider = $def.provider }
}

if (-not $Model) {
    Write-Error "Could not resolve model from config."
    exit 1
}

Write-Output "$Model|$Provider"
