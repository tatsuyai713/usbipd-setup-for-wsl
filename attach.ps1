Set-ExecutionPolicy Bypass -Scope Process -Force

$UsbTargets = Invoke-Expression (Get-Content "$PSScriptRoot\devices.psd1" -Raw)
$UsbList = usbipd list
$attachCount = 0

foreach ($t in $UsbTargets) {
    $line = $UsbList | Select-String $t.VidPid
    if ($line) {
        Write-Host "Attaching $($t.Name) ($($t.VidPid))..."
        Start-Process -FilePath "usbipd" `
            -ArgumentList "attach --wsl --auto-attach --hardware-id $($t.VidPid)" `
            -WindowStyle Hidden
        $attachCount++
        Start-Sleep -Seconds 3
    } else {
        Write-Host "SKIP: $($t.Name) ($($t.VidPid)) - Not connected"
    }
}

if ($attachCount -eq 0) {
    Write-Host "WARNING: No devices to attach."
} else {
    Start-Sleep -Seconds 5
    Write-Host "Verifying in WSL..."
    $lsusb = wsl -- lsusb 2>&1
    Write-Host $lsusb

    $procs = Get-Process -Name "usbipd" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host ""
        Write-Host "OK: $($procs.Count) usbipd auto-attach process(es) running."
    } else {
        Write-Host ""
        Write-Host "WARNING: No usbipd process found. Check manually."
    }
}

Write-Host ""
Write-Host "Completed."