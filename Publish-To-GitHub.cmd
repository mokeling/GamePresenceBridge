@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Publish-To-GitHub.ps1"
if errorlevel 1 (
    echo.
    echo Publish preparation failed. See the error above.
)
pause
