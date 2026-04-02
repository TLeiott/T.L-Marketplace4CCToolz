@echo off
setlocal enabledelayedexpansion

set "CONFIG_DIR=%USERPROFILE%\.claude"
set "CONFIG_FILE=%CONFIG_DIR%\claude-custom.json"
set "PROXY_DIR=%CONFIG_DIR%\claude-custom"
set "PROXY_EXE=%PROXY_DIR%\OpenRouterProxy.exe"

if not exist "%PROXY_EXE%" (
    echo Error: Proxy binary not found at %PROXY_EXE%
    echo Run the init skill to install: claude --plugin-dir "path\to\T.L-Claude-Code-Custom"
    exit /b 1
)

if not exist "%CONFIG_FILE%" (
    echo Error: Config file not found at %CONFIG_FILE%
    echo Run the init skill to install.
    exit /b 1
)

if not defined OPENROUTER_API_KEY (
    echo Error: OPENROUTER_API_KEY environment variable is not set.
    exit /b 1
)

set "MODEL="
set "PROVIDER="
set "PROFILE="
set "PASSTHROUGH="
set "IN_PASSTHROUGH=0"

:parse
if "%~1"=="" goto :after_parse
if "%~1"=="--" (
    set "IN_PASSTHROUGH=1"
    shift
    goto :parse
)
if !IN_PASSTHROUGH!==1 (
    set "PASSTHROUGH=!PASSTHROUGH! %~1"
    shift
    goto :parse
)
if "%~1"=="--model" (
    set "MODEL=%~2"
    shift
    shift
    goto :parse
)
if "%~1"=="--provider" (
    set "PROVIDER=%~2"
    shift
    shift
    goto :parse
)
if "%~1"=="--profile" (
    set "PROFILE=%~2"
    shift
    shift
    goto :parse
)
echo Unknown argument: %~1
exit /b 1
:after_parse

for /f "tokens=*" %%i in ('powershell -Command "$p='%PROFILE%'; $m='%MODEL%'; $pr='%PROVIDER%'; $c=Get-Content '%CONFIG_FILE%' -Raw | ConvertFrom-Json; if($p){ $prof=$c.profiles.$p; if(-not $prof){ Write-Error 'Profile not found: $p'; exit 1 }; $m=if($m){$m}else{$prof.model}; $pr=if($pr){$pr}else{$prof.provider} }; if(-not $m){ $def=$c.profiles.$($c.defaultProfile); $m=$def.model; $pr=$def.provider }; Write-Output \"$m|$pr\""') do (
    set "RESOLVED=%%i"
)

for /f "tokens=1 delims=|" %%a in ("%RESOLVED%") do set "RESOLVED_MODEL=%%a"
for /f "tokens=2 delims=|" %%b in ("%RESOLVED%") do set "RESOLVED_PROVIDER=%%b"

if not defined RESOLVED_MODEL (
    echo Error: Could not resolve model from config.
    exit /b 1
)

if not defined RESOLVED_PROVIDER (
    echo Error: Could not resolve provider from config.
    exit /b 1
)

for /f "tokens=*" %%p in ('powershell -Command "$port=0; $listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $listener.Start(); $port=([System.Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop(); Write-Output $port"') do (
    set "PROXY_PORT=%%p"
)

set "PROXY_URL=http://127.0.0.1:%PROXY_PORT%"

start /b "" "%PROXY_EXE%" --urls "%PROXY_URL%"

timeout /t 2 /nobreak >nul

set "ANTHROPIC_BASE_URL=%PROXY_URL%"
set "ANTHROPIC_AUTH_TOKEN=local"
set "ANTHROPIC_API_KEY="
set "DEFAULT_PROVIDER=%RESOLVED_PROVIDER%"

claude --model %RESOLVED_MODEL%%PASSTHROUGH%
