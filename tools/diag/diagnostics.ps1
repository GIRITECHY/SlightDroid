<#
  SlightDroid diagnostics: collects what we need to measure SlightDroid on this PC into one zip on the
  Desktop. Shipped with SlightDroid; started from the "SlightDroid Diagnostics" Start menu shortcut.

  Contents: envcheck report (JSON + text), launcher/QEMU logs, per-boot metrics, settings.
  Hardware names (CPU, GPU, RAM, disk) are included. Your user name is removed from paths.
  Nothing is uploaded: you decide whether to send the zip.
#>
$ErrorActionPreference = 'Continue'
$inst = Split-Path -Parent $PSScriptRoot
$data = if ($env:SLIGHTDROID_DATA) { $env:SLIGHTDROID_DATA } else { Join-Path $env:LOCALAPPDATA 'SlightDroid' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp = Join-Path $env:TEMP "SlightDroid-diag-$stamp"
New-Item -ItemType Directory -Force $tmp | Out-Null
$Host.UI.RawUI.WindowTitle = 'SlightDroid Diagnostics'

Write-Host 'SlightDroid Diagnostics' -ForegroundColor Cyan
Write-Host '1/3 Checking this PC (takes a few seconds)...'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'envcheck.ps1') -Json "$tmp\envcheck.json" *> "$tmp\envcheck.txt"

Write-Host '2/3 Collecting SlightDroid logs and measurements...'
foreach ($f in 'logs\launcher.log', 'logs\qemu.log', 'logs\metrics.tsv', 'settings.ini') {
    $p = Join-Path $data $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $tmp ($f -replace '\\', '_')) }
}
[ordered]@{
    SlightDroidVersion = (Get-Item (Join-Path $inst 'SlightDroid.exe') -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    installDir = $inst
    dataDiskMB = [int]((Get-Item (Join-Path $data 'data.qcow2') -ErrorAction SilentlyContinue).Length / 1MB)
    collected = (Get-Date).ToString('o')
    uptimeHours = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalHours, 1)
    topMemoryProcesses = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 |
        ForEach-Object { '{0} {1} MB' -f $_.ProcessName, [int]($_.WorkingSet64 / 1MB) })
} | ConvertTo-Json | Set-Content -Encoding UTF8 "$tmp\summary.json"

# privacy: strip the user name / profile path from everything we collected
$userProfile = [regex]::Escape($env:USERPROFILE); $user = [regex]::Escape($env:USERNAME)
Get-ChildItem $tmp -File | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName)
    $t = [regex]::Replace($t, $userProfile, '%USERPROFILE%', 'IgnoreCase')
    $t = [regex]::Replace($t, "\\\\Users\\\\$user", '\\Users\\%USERNAME%', 'IgnoreCase')
    $t = [regex]::Replace($t, "\\Users\\$user", '\Users\%USERNAME%', 'IgnoreCase')
    [IO.File]::WriteAllText($_.FullName, $t)
}

Write-Host '3/3 Creating the zip...'
$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "SlightDroid-diagnostics-$stamp.zip"
Compress-Archive -Path "$tmp\*" -DestinationPath $zip -Force
Remove-Item -Recurse -Force $tmp
Write-Host ''
Write-Host "Done: $zip" -ForegroundColor Green
Write-Host 'It contains hardware details and SlightDroid logs only (your user name is removed).'
Write-Host 'Nothing was sent anywhere. Share the zip if you want help or benchmark numbers.'
Write-Host ''
Read-Host 'Press Enter to close'
