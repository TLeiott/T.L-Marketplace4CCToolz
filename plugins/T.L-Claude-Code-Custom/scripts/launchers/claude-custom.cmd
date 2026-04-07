@echo off
setlocal enabledelayedexpansion

set "CONFIG_FILE=%USERPROFILE%\.claude\claude-custom.json"

if not exist "%CONFIG_FILE%" (
    echo Error: Config file not found at %CONFIG_FILE%
    echo Run the init skill to install.
    exit /b 1
)

if not defined OPENROUTER_API_KEY (
    echo Error: OPENROUTER_API_KEY environment variable is not set.
    exit /b 1
)

rem --- Parse arguments ---
set "MODEL="
set "PROVIDER="
set "PROFILE="
set "PASSTHROUGH="

:parse
if "%~1"=="" goto :after_parse
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
set "PASSTHROUGH=!PASSTHROUGH! %1"
shift
goto :parse
:after_parse

rem --- Resolve config via resolve-config.ps1 ---
set "PROXY_DIR=%USERPROFILE%\.claude\claude-custom"
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%CONFIG_FILE%" -Profile "%PROFILE%" -Model "%MODEL%" -Provider "%PROVIDER%"') do (
    set "RESOLVED=%%i"
)

for /f "tokens=1 delims=|" %%a in ("!RESOLVED!") do set "RESOLVED_MODEL=%%a"

if not defined RESOLVED_MODEL (
    echo Error: Could not resolve model from config.
    exit /b 1
)

rem --- Set environment and launch ---
set "ANTHROPIC_BASE_URL=https://openrouter.ai/api"
set "ANTHROPIC_API_KEY=%OPENROUTER_API_KEY%"
set "ANTHROPIC_AUTH_TOKEN=%OPENROUTER_API_KEY%"

claude --dangerously-skip-permissions --model !RESOLVED_MODEL!!PASSTHROUGH!
