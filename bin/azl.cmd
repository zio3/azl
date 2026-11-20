@echo off
REM Thin cmd shim - delegates to azl.ps1 dispatcher.
setlocal
set "DISPATCHER=%~dp0..\azl.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DISPATCHER%" %*
exit /b %ERRORLEVEL%
