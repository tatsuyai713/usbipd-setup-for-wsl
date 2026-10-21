Set-ExecutionPolicy Bypass -Scope Process -Force

Write-Host "Stopping auto-attach background processes..."
$procs = Get-Process -Name "usbipd" -ErrorAction SilentlyContinue
if ($procs) {
    $procs | Stop-Process -Force
    Write-Host "Stopped $($procs.Count) usbipd process(es)."
} else {
    Write-Host "No usbipd background process found."
}

$UsbTargets = Invoke-Expression (Get-Content "$PSScriptRoot\devices.psd1" -Raw)
$UsbList = usbipd list

Write-Host ""
foreach ($t in $UsbTargets) {
    $lines = @($UsbList | Select-String $t.VidPid)
    if ($lines.Count -eq 0) {
        Write-Host "SKIP: $($t.Name) ($($t.VidPid)) - Not connected"
        continue
    }
    foreach ($line in $lines) {
        $lineStr = $line.Line
        $busid = (($lineStr.Trim()) -split "\s+")[0]
        if ($lineStr -cmatch "Shared|Attached") {
            Write-Host "Unbinding $($t.Name) (busid=$busid)..."
            usbipd unbind --busid $busid
        } else {
            Write-Host "SKIP: $($t.Name) (busid=$busid) - Not shared"
        }
    }
}

Write-Host ""
Write-Host "Unbinding all remaining shared/persisted devices..."
usbipd unbind --all

Write-Host ""
Write-Host "Unbind completed. Devices should now use their original Windows driver."
Read-Host "Press Enter to exit"
