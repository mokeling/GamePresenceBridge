@echo off
setlocal
set "NXAPI_ROOT=%~dp0nxapi"

if not exist "%NXAPI_ROOT%\dist\cli-entry.js" (
    echo nxapi has not been built. Run Setup-Nxapi.cmd first. 1>&2
    exit /b 1
)

node "%NXAPI_ROOT%\bin\nxapi.js" %*
exit /b %ERRORLEVEL%
