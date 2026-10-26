@echo off
setlocal
chcp 65001 >nul
title Create-HashManifest
where pwsh.exe >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh.exe^) was not found in PATH.
    pause
    exit /b 2
)
pwsh.exe -NoProfile -File "%~dp0Create-HashManifest.ps1" -Interactive
set "result=%ERRORLEVEL%"
echo.
echo Exit code: %result%
pause
exit /b %result%
