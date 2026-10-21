@echo off
echo === Step 1: Detach (User) ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0detach.ps1"

echo.
echo === Step 2: Unbind (Admin) ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0unbind.ps1\"' -Wait"

echo.
echo === Result ===
echo --- usbipd list ---
usbipd list
echo.
pause
