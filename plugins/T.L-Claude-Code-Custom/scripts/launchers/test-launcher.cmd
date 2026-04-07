@echo off
setlocal enabledelayedexpansion
REM ============================================================
REM  Test procedure for claude-custom-proxy launcher (v2 daemon model)
REM  Tests config resolution, URL encoding, and lock file logic
REM  Does NOT start proxy or claude
REM ============================================================

set "PASS=0"
set "FAIL=0"
set "SCRIPT_DIR=%~dp0"
set "PROXY_DIR=%USERPROFILE%\.claude\claude-custom"

REM --- Setup: create temp configs ---
set "TEMP_CONFIG=%TEMP%\claude-custom-test.json"
set "TEMP_CONFIG_V2=%TEMP%\claude-custom-test-v2.json"
(
echo {
echo   "version": 1,
echo   "defaultProfile": "default",
echo   "profiles": {
echo     "default": {
echo       "model": "anthropic/claude-sonnet-4.6",
echo       "provider": "anthropic"
echo     },
echo     "minimax": {
echo       "model": "minimax/minimax-m2.7",
echo       "provider": "minimax/fp8"
echo     }
echo   }
echo }
) > "%TEMP_CONFIG%"

(
echo {
echo   "version": 2,
echo   "proxy": { "port": 19090 },
echo   "defaultProfile": "default",
echo   "profiles": {
echo     "default": {
echo       "model": "anthropic/claude-sonnet-4.6",
echo       "provider": "anthropic"
echo     }
echo   }
echo }
) > "%TEMP_CONFIG_V2%"

echo.
echo === claude-custom-proxy launcher tests (v2 daemon model) ===
echo.

REM --- Test 0: deployment check ---
if exist "%USERPROFILE%\.local\bin\claude-custom-proxy.cmd" (
    if exist "%PROXY_DIR%\resolve-config.ps1" (
        echo [PASS] Test 0: launcher and helper deployed correctly
        set /a PASS+=1
    ) else (
        echo [FAIL] Test 0: resolve-config.ps1 missing from %PROXY_DIR%
        set /a FAIL+=1
    )
) else (
    echo [SKIP] Test 0: claude-custom-proxy.cmd not installed
)

REM --- Test 1: default profile (no args) ---
set "EXPECTED_MODEL=anthropic/claude-sonnet-4.6"
set "EXPECTED_PROVIDER=anthropic"
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "" -Model "" -Provider ""') do set "RESULT=%%i"
for /f "tokens=1 delims=|" %%a in ("!RESULT!") do set "GOT_MODEL=%%a"
for /f "tokens=2 delims=|" %%b in ("!RESULT!") do set "GOT_PROVIDER=%%b"
if "!GOT_MODEL!"=="%EXPECTED_MODEL%" if "!GOT_PROVIDER!"=="%EXPECTED_PROVIDER%" (
    echo [PASS] Test 1: default profile resolves correctly
    set /a PASS+=1
) else (
    echo [FAIL] Test 1: default profile
    echo        expected: %EXPECTED_MODEL% / %EXPECTED_PROVIDER%
    echo        got:      !GOT_MODEL! / !GOT_PROVIDER!
    set /a FAIL+=1
)

REM --- Test 2: named profile ---
set "EXPECTED_MODEL=minimax/minimax-m2.7"
set "EXPECTED_PROVIDER=minimax/fp8"
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "minimax" -Model "" -Provider ""') do set "RESULT=%%i"
for /f "tokens=1 delims=|" %%a in ("!RESULT!") do set "GOT_MODEL=%%a"
for /f "tokens=2 delims=|" %%b in ("!RESULT!") do set "GOT_PROVIDER=%%b"
if "!GOT_MODEL!"=="%EXPECTED_MODEL%" if "!GOT_PROVIDER!"=="%EXPECTED_PROVIDER%" (
    echo [PASS] Test 2: named profile "minimax" resolves correctly
    set /a PASS+=1
) else (
    echo [FAIL] Test 2: named profile "minimax"
    echo        expected: %EXPECTED_MODEL% / %EXPECTED_PROVIDER%
    echo        got:      !GOT_MODEL! / !GOT_PROVIDER!
    set /a FAIL+=1
)

REM --- Test 3: CLI model/provider override ---
set "EXPECTED_MODEL=google/gemini-pro"
set "EXPECTED_PROVIDER=google"
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "" -Model "google/gemini-pro" -Provider "google"') do set "RESULT=%%i"
for /f "tokens=1 delims=|" %%a in ("!RESULT!") do set "GOT_MODEL=%%a"
for /f "tokens=2 delims=|" %%b in ("!RESULT!") do set "GOT_PROVIDER=%%b"
if "!GOT_MODEL!"=="%EXPECTED_MODEL%" if "!GOT_PROVIDER!"=="%EXPECTED_PROVIDER%" (
    echo [PASS] Test 3: CLI override resolves correctly
    set /a PASS+=1
) else (
    echo [FAIL] Test 3: CLI override
    echo        expected: %EXPECTED_MODEL% / %EXPECTED_PROVIDER%
    echo        got:      !GOT_MODEL! / !GOT_PROVIDER!
    set /a FAIL+=1
)

REM --- Test 4: profile with CLI model override ---
set "EXPECTED_MODEL=override/model"
set "EXPECTED_PROVIDER=minimax/fp8"
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "minimax" -Model "override/model" -Provider ""') do set "RESULT=%%i"
for /f "tokens=1 delims=|" %%a in ("!RESULT!") do set "GOT_MODEL=%%a"
for /f "tokens=2 delims=|" %%b in ("!RESULT!") do set "GOT_PROVIDER=%%b"
if "!GOT_MODEL!"=="%EXPECTED_MODEL%" if "!GOT_PROVIDER!"=="%EXPECTED_PROVIDER%" (
    echo [PASS] Test 4: profile + CLI model override
    set /a PASS+=1
) else (
    echo [FAIL] Test 4: profile + CLI model override
    echo        expected: %EXPECTED_MODEL% / %EXPECTED_PROVIDER%
    echo        got:      !GOT_MODEL! / !GOT_PROVIDER!
    set /a FAIL+=1
)

REM --- Test 5: nonexistent profile should fail ---
powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "doesnotexist" -Model "" -Provider "" >nul 2>&1
if !errorlevel! neq 0 (
    echo [PASS] Test 5: nonexistent profile returns error
    set /a PASS+=1
) else (
    echo [FAIL] Test 5: nonexistent profile should have failed
    set /a FAIL+=1
)

REM --- Test 6: v1 config defaults port to 18080 ---
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "" -Model "" -Provider ""') do set "RESULT=%%i"
for /f "tokens=3 delims=|" %%c in ("!RESULT!") do set "GOT_PORT=%%c"
if "!GOT_PORT!"=="18080" (
    echo [PASS] Test 6: v1 config defaults port to 18080
    set /a PASS+=1
) else (
    echo [FAIL] Test 6: v1 config port default
    echo        expected: 18080
    echo        got:      !GOT_PORT!
    set /a FAIL+=1
)

REM --- Test 7: v2 config reads custom port ---
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%PROXY_DIR%\resolve-config.ps1" -ConfigFile "%TEMP_CONFIG_V2%" -Profile "" -Model "" -Provider ""') do set "RESULT=%%i"
for /f "tokens=3 delims=|" %%c in ("!RESULT!") do set "GOT_PORT=%%c"
if "!GOT_PORT!"=="19090" (
    echo [PASS] Test 7: v2 config reads custom port 19090
    set /a PASS+=1
) else (
    echo [FAIL] Test 7: v2 config custom port
    echo        expected: 19090
    echo        got:      !GOT_PORT!
    set /a FAIL+=1
)

REM --- Test 8: URL encoding (/ -> %%2F) ---
set "TEST_PROVIDER=minimax/fp8"
set "ENCODED=!TEST_PROVIDER:/=%%2F!"
if "!ENCODED!"=="minimax%%2Ffp8" (
    echo [PASS] Test 8: URL encoding minimax/fp8 -^> minimax%%2Ffp8
    set /a PASS+=1
) else (
    echo [FAIL] Test 8: URL encoding
    echo        expected: minimax%%2Ffp8
    echo        got:      !ENCODED!
    set /a FAIL+=1
)

REM --- Test 9: lock file parsing ---
set "TEMP_LOCK=%TEMP%\proxy-test.lock"
(
echo pid=99999
echo port=19999
echo started=2026-04-05T14:30:00Z
echo version=2
) > "%TEMP_LOCK%"
set "LOCK_PID="
set "LOCK_PORT="
for /f "tokens=2 delims==" %%a in ('findstr /b "pid=" "%TEMP_LOCK%"') do set "LOCK_PID=%%a"
for /f "tokens=2 delims==" %%a in ('findstr /b "port=" "%TEMP_LOCK%"') do set "LOCK_PORT=%%a"
if "!LOCK_PID!"=="99999" if "!LOCK_PORT!"=="19999" (
    echo [PASS] Test 9: lock file parsing (pid=99999, port=19999^)
    set /a PASS+=1
) else (
    echo [FAIL] Test 9: lock file parsing
    echo        expected: pid=99999, port=19999
    echo        got:      pid=!LOCK_PID!, port=!LOCK_PORT!
    set /a FAIL+=1
)
del "%TEMP_LOCK%" 2>nul

REM --- Cleanup ---
del "%TEMP_CONFIG%" 2>nul
del "%TEMP_CONFIG_V2%" 2>nul

echo.
echo === Results: !PASS! passed, !FAIL! failed ===
if !FAIL! gtr 0 exit /b 1
exit /b 0
