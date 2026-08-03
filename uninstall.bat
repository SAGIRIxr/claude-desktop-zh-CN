@echo off
REM ---------------------------------------------------------------------------
REM  Claude Desktop - Simplified Chinese language pack / one-click uninstaller
REM  ASCII-only on purpose; see install.bat for the reason.
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

if not exist "%~dp0install.ps1" (
    echo.
    echo   ERROR: install.ps1 not found next to this launcher.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo   [FAILED] exit code %RC%
)
echo   Press any key to close this window...
pause >nul
exit /b %RC%
