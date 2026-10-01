@echo off
rem Double-click launcher: runs install.ps1 with a process-only ExecutionPolicy Bypass.
rem No arguments installs all components; any arguments are passed to install.ps1 as-is.
rem PowerShell is started by absolute path so an extra powershell.exe in this folder is never run.
setlocal
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
    echo Windows PowerShell 5.1 was not found: %PS_EXE%
    pause
    exit /b 90
)
if "%~1"=="" (
    "%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Components all
) else (
    "%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)
set "EXITCODE=%ERRORLEVEL%"
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
