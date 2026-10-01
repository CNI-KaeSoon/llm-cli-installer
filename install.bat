@echo off
rem Double-click launcher: runs install.ps1 with a process-only ExecutionPolicy Bypass.
rem No arguments installs all components; any arguments are passed to install.ps1 as-is.
setlocal
cd /d "%~dp0"
if "%~1"=="" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Components all
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)
set "EXITCODE=%ERRORLEVEL%"
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
