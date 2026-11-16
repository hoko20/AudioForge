@echo off
setlocal EnableExtensions
cd /d "%~dp0"

where git >nul 2>nul
if errorlevel 1 (
    echo [ERROR] git was not found in PATH.
    goto :fail
)

echo ============================================
echo  WQtool - one-click GitHub Actions IPA build
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scripts\build-ipa.ps1" %*
if errorlevel 1 goto :fail

echo.
echo Done. The IPA is in the dist folder.
pause
exit /b 0

:fail
echo.
echo Build failed. Read the messages above.
pause
exit /b 1
