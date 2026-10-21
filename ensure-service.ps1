Set-ExecutionPolicy Bypass -Scope Process -Force

$ServiceName = "usbipd"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if (-not $svc) {
    Write-Host "WARNING: '$ServiceName' service not found. Is usbipd-win installed?"
    exit 1
}

if ($svc.Status -eq 'Running') {
    Write-Host "OK: $ServiceName service is already running."
    exit 0
}

Write-Host "$ServiceName service is $($svc.Status). Starting (admin required)..."
Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Start-Service -Name '$ServiceName'`"" -Wait

$svc.Refresh()
if ($svc.Status -eq 'Running') {
    Write-Host "OK: $ServiceName service started."
} else {
    Write-Host "WARNING: Failed to start $ServiceName service. You may need to start it manually via services.msc."
    exit 1
}
