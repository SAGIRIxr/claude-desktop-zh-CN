@echo off
REM ---------------------------------------------------------------------------
REM  Claude Desktop - Simplified Chinese language pack / one-click installer
REM
REM  Double-click this file. It hands off to install.ps1, which prints in
REM  Chinese and requests elevation only if it actually needs it.
REM
REM  This launcher is deliberately ASCII-only: cmd.exe parses a .bat using the
REM  console codepage that was active BEFORE the file ran, so non-ASCII bytes
REM  here get mangled and break command parsing even with `chcp 65001`.
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

if not exist "%~dp0install.ps1" (
    echo.
    echo   ERROR: install.ps1 not found next to this launcher.
    echo   Please keep all files together in the same folder.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo   [FAILED] exit code %RC%
)
echo   Press any key to close this window...
pause >nul
exit /b %RC%
