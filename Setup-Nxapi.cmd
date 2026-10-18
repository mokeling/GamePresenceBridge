@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Nxapi.ps1"
if errorlevel 1 (
    echo.
    echo nxapi setup failed. See the error above.
)
pause
