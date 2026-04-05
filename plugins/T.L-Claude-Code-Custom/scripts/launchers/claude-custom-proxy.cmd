@echo off
setlocal enabledelayedexpansion

set "CONFIG_DIR=%USERPROFILE%\.claude"
set "CONFIG_FILE=%CONFIG_DIR%\claude-custom.json"
set "PROXY_DIR=%CONFIG_DIR%\claude-custom"
set "PROXY_EXE=%PROXY_DIR%\OpenRouterProxy.exe"
set "LOCK_FILE=%PROXY_DIR%\proxy.lock"

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

REM --- Parse arguments ---
set "MODEL="
set "PROVIDER="
set "PROFILE="
set "PASSTHROUGH="
set "STOP_PROXY=0"

:parse
if "%~1"=="" goto :after_parse
if "%~1"=="--stop-proxy" (
    set "STOP_PROXY=1"
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
set "PASSTHROUGH=!PASSTHROUGH! %1"
shift
goto :parse
:after_parse

REM --- Handle --stop-proxy ---
if !STOP_PROXY!==0 goto :after_stop

if not exist "%LOCK_FILE%" (
    echo Proxy is not running.
    exit /b 0
)
for /f "tokens=2 delims==" %%a in ('findstr /b "pid=" "%LOCK_FILE%"') do set "LOCK_PID=%%a"
if defined LOCK_PID taskkill /PID !LOCK_PID! /F >nul 2>&1
del "%LOCK_FILE%" 2>nul
echo Proxy stopped.
exit /b 0

:after_stop

REM --- Resolve config ---
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%CONFIG_FILE%" -Profile "%PROFILE%" -Model "%MODEL%" -Provider "%PROVIDER%"') do (
    set "RESOLVED=%%i"
)

for /f "tokens=1 delims=|" %%a in ("!RESOLVED!") do set "RESOLVED_MODEL=%%a"
for /f "tokens=2 delims=|" %%b in ("!RESOLVED!") do set "RESOLVED_PROVIDER=%%b"
for /f "tokens=3 delims=|" %%c in ("!RESOLVED!") do set "PROXY_PORT=%%c"

if not defined RESOLVED_MODEL (
    echo Error: Could not resolve model from config.
    exit /b 1
)

if not defined PROXY_PORT set "PROXY_PORT=18080"

REM --- Check if proxy daemon is running ---
set "PROXY_RUNNING=0"
if not exist "%LOCK_FILE%" goto :lock_checked

for /f "tokens=2 delims==" %%a in ('findstr /b "pid=" "%LOCK_FILE%"') do set "LOCK_PID=%%a"
for /f "tokens=2 delims==" %%a in ('findstr /b "port=" "%LOCK_FILE%"') do set "PROXY_PORT=%%a"

REM Check if PID is alive
tasklist /FI "PID eq !LOCK_PID!" /NH 2>nul | findstr /i "OpenRouterProxy" >nul 2>&1
if !errorlevel! neq 0 goto :lock_stale

REM PID alive, check health
powershell -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:!PROXY_PORT!/health' -TimeoutSec 2 -UseBasicParsing; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }"
if !errorlevel!==0 (
    set "PROXY_RUNNING=1"
    goto :lock_checked
)

:lock_stale
del "%LOCK_FILE%" 2>nul

:lock_checked

REM --- Start proxy if not running ---
if !PROXY_RUNNING!==1 goto :proxy_ready

start /b "" "%PROXY_EXE%" --port !PROXY_PORT! >nul 2>&1
set "RETRIES=0"

:health_loop
if !RETRIES! geq 50 (
    echo Error: Proxy failed to start within 10 seconds.
    echo Check if port !PROXY_PORT! is in use. Set PROXY_PORT=NNNN for a different port.
    exit /b 1
)
powershell -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri 'http://127.0.0.1:!PROXY_PORT!/health' -TimeoutSec 1 -UseBasicParsing | Out-Null; exit 0 } catch { exit 1 }"
if !errorlevel!==0 goto :proxy_ready
timeout /t 0 /nobreak >nul
set /a RETRIES+=1
goto :health_loop

:proxy_ready

REM --- Build ANTHROPIC_BASE_URL with provider routing ---
set "ENCODED_PROVIDER=!RESOLVED_PROVIDER:/=%%2F!"

if not defined RESOLVED_PROVIDER goto :no_provider
if "!RESOLVED_PROVIDER!"=="" goto :no_provider
set "ANTHROPIC_BASE_URL=http://127.0.0.1:!PROXY_PORT!/route/!ENCODED_PROVIDER!"
goto :url_set

:no_provider
set "ANTHROPIC_BASE_URL=http://127.0.0.1:!PROXY_PORT!"

:url_set
set "ANTHROPIC_AUTH_TOKEN=local"
set "ANTHROPIC_API_KEY="

claude --dangerously-skip-permissions --model !RESOLVED_MODEL!!PASSTHROUGH!
