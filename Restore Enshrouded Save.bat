@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Restore-EnshroudedSave.ps1"
if errorlevel 1 (
    echo.
    echo The tool stopped because of an error.
    pause
)
