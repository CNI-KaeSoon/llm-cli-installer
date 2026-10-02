@echo off
rem Double-click launcher: runs files\install.ps1 with a process-only ExecutionPolicy Bypass.
rem No arguments shows the component menu; any arguments are passed to install.ps1 as-is.
rem Everything except this launcher lives in the files folder next to it.
rem PowerShell is started by absolute path so an extra powershell.exe in this folder is never run.
rem No parenthesized blocks: a ")" in a message or in the folder path would end the block early.
setlocal EnableExtensions DisableDelayedExpansion
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "INSTALL_PS1=%~dp0files\install.ps1"
if not exist "%PS_EXE%" goto no_powershell
if not exist "%INSTALL_PS1%" goto no_files
if "%~1"=="" goto run_menu
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%" %*
goto finish
:run_menu
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%"
:finish
set "EXITCODE=%ERRORLEVEL%"
echo.
echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
:no_powershell
echo Windows PowerShell 5.1 was not found: %PS_EXE%
pause
exit /b 90
:no_files
echo files\install.ps1 was not found. Extract the whole ZIP and keep installer-win.bat next to the files folder.
pause
exit /b 24
