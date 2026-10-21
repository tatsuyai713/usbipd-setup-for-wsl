Set-ExecutionPolicy Bypass -Scope Process -Force

$UsbTargets = Invoke-Expression (Get-Content "$PSScriptRoot\devices.psd1" -Raw)
$UsbList = usbipd list
$detachCount = 0

foreach ($t in $UsbTargets) {
    $lines = @($UsbList | Select-String $t.VidPid)
    if ($lines.Count -eq 0) {
        Write-Host "SKIP: $($t.Name) ($($t.VidPid)) - Not connected"
        continue
    }
    foreach ($line in $lines) {
        $lineStr = $line.Line
        $busid = (($lineStr.Trim()) -split "\s+")[0]
        if ($lineStr -cmatch "Attached") {
            Write-Host "Detaching $($t.Name) (busid=$busid)..."
            usbipd detach --busid $busid
            $detachCount++
        } else {
            Write-Host "SKIP: $($t.Name) (busid=$busid) - Not attached"
        }
    }
}

if ($detachCount -eq 0) {
    Write-Host ""
    Write-Host "No devices were attached."
}

Write-Host ""
Write-Host "Detach step completed."
