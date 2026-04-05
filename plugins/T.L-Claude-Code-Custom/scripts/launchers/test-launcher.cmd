@echo off
setlocal enabledelayedexpansion
REM ============================================================
REM  Test procedure for claude-custom.cmd launcher
REM  Tests config resolution only — does NOT start proxy or claude
REM ============================================================

set "PASS=0"
set "FAIL=0"
set "SCRIPT_DIR=%~dp0"

REM --- Setup: create a temp config ---
set "TEMP_CONFIG=%TEMP%\claude-custom-test.json"
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

REM --- Test 0: deployment check ---
set "INSTALL_DIR=%USERPROFILE%\.local\bin"
set "PROXY_DIR=%USERPROFILE%\.claude\claude-custom"
echo.
echo === claude-custom launcher tests ===
echo Config: %TEMP_CONFIG%
echo.

if exist "%INSTALL_DIR%\claude-custom.cmd" (
    if exist "%PROXY_DIR%\resolve-config.ps1" (
        echo [PASS] Test 0: launcher in %INSTALL_DIR%, helper in %PROXY_DIR%
        set /a PASS+=1
    ) else (
        echo [FAIL] Test 0: resolve-config.ps1 missing from %PROXY_DIR%
        echo        claude-custom.cmd will fail at runtime!
        set /a FAIL+=1
    )
) else (
    echo [SKIP] Test 0: claude-custom.cmd not installed to %INSTALL_DIR%
)

REM --- Test 1: default profile (no args) ---
set "EXPECTED_MODEL=anthropic/claude-sonnet-4.6"
set "EXPECTED_PROVIDER=anthropic"
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "" -Model "" -Provider ""') do set "RESULT=%%i"
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
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "minimax" -Model "" -Provider ""') do set "RESULT=%%i"
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
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "" -Model "google/gemini-pro" -Provider "google"') do set "RESULT=%%i"
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
for /f "tokens=*" %%i in ('powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "minimax" -Model "override/model" -Provider ""') do set "RESULT=%%i"
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
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%resolve-config.ps1" -ConfigFile "%TEMP_CONFIG%" -Profile "doesnotexist" -Model "" -Provider "" >nul 2>&1
if !errorlevel! neq 0 (
    echo [PASS] Test 5: nonexistent profile returns error
    set /a PASS+=1
) else (
    echo [FAIL] Test 5: nonexistent profile should have failed
    set /a FAIL+=1
)

REM --- Cleanup ---
del "%TEMP_CONFIG%" 2>nul

echo.
echo === Results: !PASS! passed, !FAIL! failed ===
if !FAIL! gtr 0 exit /b 1
exit /b 0
