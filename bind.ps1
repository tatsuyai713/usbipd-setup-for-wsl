Set-ExecutionPolicy Bypass -Scope Process -Force

$UsbTargets = Invoke-Expression (Get-Content "$PSScriptRoot\devices.psd1" -Raw)
$UsbList = usbipd list

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
            Write-Host "SKIP: $($t.Name) (busid=$busid) - Already bound"
        } else {
            Write-Host "Binding $($t.Name) (busid=$busid)..."
            usbipd bind --force --busid $busid
        }
    }
}

Write-Host ""
Write-Host "Bind completed."
Read-Host "Press Enter to exit"