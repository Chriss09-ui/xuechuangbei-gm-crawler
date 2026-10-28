@echo off
cd /d "%~dp0"
powershell -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0crawl_gm.ps1"
echo.
pause
