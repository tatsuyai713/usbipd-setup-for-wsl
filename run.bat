@echo off
set SCRIPT_DIR=%~dp0
set SCRIPT_DIR=%SCRIPT_DIR:\=/%
set SCRIPT_DIR=%SCRIPT_DIR:C:/=/mnt/c/%

echo === Step 0: Ensure USBIPD Service ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-service.ps1"

echo === Step 1: Check Bind Status ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-bind.ps1"
if %ERRORLEVEL% EQU 0 (
    echo All devices already shared. Skipping bind.
    goto :attach
)
echo === Step 1: Bind (Admin) ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0bind.ps1\"' -Wait"

:attach
echo.
echo Please start WSL before proceeding.
echo Press Enter after WSL is running...
pause >nul
echo Waiting for WSL to be ready...
timeout /t 5 /nobreak >nul
echo === Step 2: Attach (User) ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0attach.ps1"

echo === Step 3: Configure Network in WSL ===
timeout /t 5 /nobreak >nul
wsl -u root -- bash "%SCRIPT_DIR%setup_interface_for_wsl.sh"

echo.
echo === Result ===
echo --- usbipd list ---
usbipd list
echo.
echo --- WSL lsusb ---
wsl -- lsusb
echo.
pause