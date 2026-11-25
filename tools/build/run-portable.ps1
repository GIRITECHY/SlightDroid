<#
.SYNOPSIS
  Runs SlightDroid straight from the build, without installing it (after stage-engine.ps1).

.DESCRIPTION
  build\payload keeps the Android system image in 1 GB parts (for the installer), so this script
  prepares build\run once: SlightDroid.exe and apps copied, the engine folders linked (junctions, no
  copy), and system.img joined from its parts (~3 GB, first run only). Android's data (virtual
  device, snapshot, logs) goes to build\run-data, separate from an installed SlightDroid.

  Needs Windows Hypervisor Platform (tools\envcheck\envcheck.cmd checks it).
#>
param([switch]$Stop)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pay = "$root\build\payload"
$run = "$root\build\run"
$data = "$root\build\run-data"

if ($Stop) {
    $env:SLIGHTDROID_DATA = $data; & "$run\SlightDroid.exe" --stop; Remove-Item Env:SLIGHTDROID_DATA; return
}
if (-not (Test-Path "$pay\SlightDroid.exe")) { throw 'Build first: tools\build\setup-build.ps1, then tools\build\stage-engine.ps1' }

New-Item -ItemType Directory -Force "$run\sdk", $data | Out-Null
Copy-Item "$pay\SlightDroid.exe" "$run\SlightDroid.exe" -Force
if (Test-Path "$pay\apps") { robocopy "$pay\apps" "$run\apps" /E /NFL /NDL /NJH /NJS /NP | Out-Null }
foreach ($d in 'emulator', 'platform-tools', 'platforms') {
    if (-not (Test-Path "$run\sdk\$d")) { cmd /c mklink /J "$run\sdk\$d" "$pay\sdk\$d" | Out-Null }
}
$imgSrc = "$pay\sdk\system-images\android-30\default\x86_64"
$img = "$run\sdk\system-images\android-30\default\x86_64"
New-Item -ItemType Directory -Force $img | Out-Null
Get-ChildItem $imgSrc -File | Where-Object { $_.Name -notlike 'system.img.part*' } | Copy-Item -Destination $img -Force
$parts = Get-ChildItem $imgSrc -Filter 'system.img.part*' | Where-Object { $_.Name -match '\.part\d+$' } | Sort-Object { [int]($_.Name -replace '.*\.part', '') }
$want = ($parts | Measure-Object Length -Sum).Sum
if (-not (Test-Path "$img\system.img") -or (Get-Item "$img\system.img").Length -ne $want) {
    Write-Host "Joining the Android system image (first run only, about 3 GB)..."
    $out = [IO.File]::Create("$img\system.img")
    try { foreach ($p in $parts) { $in = [IO.File]::OpenRead($p.FullName); try { $in.CopyTo($out, 4MB) } finally { $in.Dispose() } } } finally { $out.Dispose() }
}

$env:SLIGHTDROID_DATA = $data
Start-Process "$run\SlightDroid.exe"
Remove-Item Env:SLIGHTDROID_DATA
Write-Host "SlightDroid is starting (first start ~1 min, later ones resume in seconds). Data: $data"
Write-Host "Stop it from its tray icon, or: tools\build\run-portable.ps1 -Stop"
