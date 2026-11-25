<#
.SYNOPSIS
  Assembles the complete SlightDroid payload in build\payload, from the pinned downloads.

.DESCRIPTION
  Steps (each verifies its output):
    1. engine     trimmed QEMU (trim-qemu.ps1)
    2. guest      kernel, SlightDroid initrd (mkinitrd.py), raw system.img from system.sfs,
                  ext4 data template (make-data-template.ps1, reused if present)
    3. launcher   SlightDroid.exe (build-launcher.ps1)
    4. tools      envcheck, video probe, diagnostics (+ .cmd wrappers for shortcuts)
    5. licenses   NOTICE, QEMU licences, SlightDroid modification sources
  Nothing is installed on this PC.
#>
param([switch]$KeepDataTemplate = $true)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = "$root\build\payload"
$z = "$root\build\tools\7zip-msi\Files\7-Zip\7z.exe"
$dl = "$root\downloads"
function Step($m) { Write-Host "== $m" -ForegroundColor Cyan }

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force "$out\guest\lite", "$out\tools", "$out\licenses\SlightDroid-source" | Out-Null

Step 'engine'
if (-not (Test-Path "$root\build\engine-a\qemu\qemu-system-x86_64.exe")) {
    & $z x -y -bso0 -bsp0 "-o$root\build\engine-a\qemu" "$dl\qemu\qemu-w64-setup-20260811.exe"
}
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\trim-qemu.ps1" -Dest "$out\engine"
if ($LASTEXITCODE) { throw 'trim-qemu failed' }

Step 'guest (Lite, Android-x86 9.0-r2)'
$src = "$root\build\guest-src\android-x86-9"
if (-not (Test-Path "$src\system.sfs")) { & $z x -y -bso0 -bsp0 "-o$src" "$dl\android-x86-9\android-x86-9.0-r2.iso" }
Copy-Item "$src\kernel" "$out\guest\lite\kernel"
& python -I "$PSScriptRoot\mkinitrd.py" "$src\initrd.img" "$src\ramdisk.img" "$root\guest\lite\overlay" "$out\guest\lite\initrd.img"
if ($LASTEXITCODE) { throw 'mkinitrd failed' }
if (-not (Test-Path "$src\system.img")) { & $z e -y -bso0 -bsp0 "-o$src" "$src\system.sfs" system.img; if ($LASTEXITCODE) { throw 'system.img extract failed' } }
# debloated copy (no analytics, no Google apps, no taskbar shell): guest/lite/debloat.txt
for ($try = 1; $try -le 2; $try++) {   # the emulated serial console occasionally stalls; one retry
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\make-system-image.ps1" -Source "$src\system.img" -Out "$out\guest\lite\system.img" -Engine "$out\engine" -Guest "$out\guest\lite"
    if (-not $LASTEXITCODE) { break }
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
}
if ($LASTEXITCODE) { throw 'make-system-image failed' }
$tpl = "$root\build\stage\guest\lite\data-template.qcow2"
if (-not (Test-Path $tpl) -or -not $KeepDataTemplate) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\make-data-template.ps1" -Engine "$out\engine" -Out $tpl
    if ($LASTEXITCODE) { throw 'data template failed' }
}
Copy-Item $tpl "$out\guest\lite\data-template.qcow2"

Step 'launcher'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\build-launcher.ps1"
if ($LASTEXITCODE) { throw 'launcher build failed' }
Copy-Item "$root\build\stage\SlightDroid.exe" "$out\SlightDroid.exe"

Step 'tools'
Copy-Item "$root\tools\envcheck\envcheck.ps1", "$root\tools\envcheck\VideoProbe.cs", "$root\tools\envcheck\envcheck.cmd", "$root\tools\diag\diagnostics.ps1" "$out\tools\"
Set-Content -Encoding ASCII "$out\tools\diagnostics.cmd" "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0diagnostics.ps1`"`r`n"

Step 'licenses'
Copy-Item "$root\installer\NOTICE.txt" "$out\licenses\NOTICE.txt"
Copy-Item "$out\engine\licenses\*" "$out\licenses\"
Copy-Item "$PSScriptRoot\mkinitrd.py" "$out\licenses\SlightDroid-source\"
Copy-Item -Recurse "$root\guest\lite\overlay" "$out\licenses\SlightDroid-source\overlay"

$files = Get-ChildItem $out -Recurse -File
"payload: {0} files, {1:N0} MB in {2}" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $out
