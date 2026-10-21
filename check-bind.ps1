Set-ExecutionPolicy Bypass -Scope Process -Force

$UsbTargets = Invoke-Expression (Get-Content "$PSScriptRoot\devices.psd1" -Raw)
$UsbList = usbipd list
$needBind = $false

foreach ($t in $UsbTargets) {
    $line = $UsbList | Select-String $t.VidPid
    if ($line) {
        $lineStr = $line.ToString()
        if ($lineStr -match "(?<!Not )Shared|Attached") {
            Write-Host "OK: $($t.Name) ($($t.VidPid)) - Already bound"
        } else {
            Write-Host "NEED BIND: $($t.Name) ($($t.VidPid))"
            $needBind = $true
        }
    } else {
        Write-Host "SKIP: $($t.Name) ($($t.VidPid)) - Not connected"
    }
}

if ($needBind) { exit 1 } else { exit 0 }