@echo off
rem Double-click friendly wrapper. Extra args are passed through (e.g. -Json report.json).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0envcheck.ps1" %*
set RC=%ERRORLEVEL%
if "%~1"=="" pause
exit /b %RC%
