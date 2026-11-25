<#
.SYNOPSIS
  Builds the minimal QEMU runtime that SlightDroid ships (engine A).

.DESCRIPTION
  From the full extracted QEMU for Windows (1.2 GB, all architectures) it copies only:
    - qemu-system-x86_64w.exe (no console window), qemu-system-x86_64.exe (console, for
      diagnostics) and qemu-img.exe
    - every DLL they import, found by walking PE import tables (PeImports.cs), plus the
      ANGLE libraries that SDL/epoxy load at runtime for GPU rendering (libEGL, libGLESv2)
    - only the x86 firmware blobs SeaBIOS + virtio need, and the licence files

  The output is checked by running qemu-system-x86_64 -version from it.

.PARAMETER Source
  Full extracted QEMU (default build\engine-a\qemu).
.PARAMETER Dest
  Output (default build\stage\engine).
#>
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\..\build\engine-a\qemu'),
    [string]$Dest = (Join-Path $PSScriptRoot '..\..\build\stage\engine')
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $PSScriptRoot 'PeImports.cs')) -ErrorAction SilentlyContinue
$Source = (Resolve-Path $Source).Path

$roots = @('qemu-system-x86_64w.exe',   # becomes SlightDroid-engine.exe below
           'qemu-system-x86_64.exe', 'qemu-img.exe',
           'libEGL.dll', 'libGLESv2.dll')          # runtime-loaded by SDL2 / libepoxy (ANGLE on D3D11)
# x86 firmware: SeaBIOS, option ROMs for direct kernel boot, VGA BIOSes, virtio-net ROM.
$shareFiles = @('bios-256k.bin', 'bios.bin', 'kvmvapic.bin', 'linuxboot_dma.bin',
                'multiboot_dma.bin', 'pvh.bin', 'vgabios.bin', 'vgabios-stdvga.bin',
                'vgabios-virtio.bin', 'vgabios-ramfb.bin', 'efi-virtio.rom')
$licenseFiles = @('COPYING', 'COPYING.LIB', 'LICENSE', 'README.rst')

$local = @{}
Get-ChildItem $Source -File | Where-Object { $_.Extension -in '.dll', '.exe' } | ForEach-Object { $local[$_.Name.ToLower()] = $_ }

$keep = @{}
$queue = New-Object System.Collections.Queue
foreach ($r in $roots) {
    if (-not $local.ContainsKey($r.ToLower())) { throw "missing in source: $r" }
    $keep[$r.ToLower()] = $local[$r.ToLower()]; $queue.Enqueue($local[$r.ToLower()].FullName)
}
while ($queue.Count) {
    foreach ($d in [PeImports]::Read($queue.Dequeue())) {
        $k = $d.ToLower()
        if ($local.ContainsKey($k) -and -not $keep.ContainsKey($k)) { $keep[$k] = $local[$k]; $queue.Enqueue($local[$k].FullName) }
    }
}

if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
New-Item -ItemType Directory -Force -Path "$Dest\share", "$Dest\licenses" | Out-Null
foreach ($f in $keep.Values) { Copy-Item $f.FullName $Dest }
foreach ($s in $shareFiles) {
    $p = Join-Path "$Source\share" $s
    if (Test-Path $p) { Copy-Item $p "$Dest\share" } else { Write-Warning "firmware not found: $s" }
}
New-Item -ItemType Directory -Force "$Dest\share\keymaps" | Out-Null   # VNC (headless display mode) needs the en-us keymap
Copy-Item "$Source\share\keymaps\en-us", "$Source\share\keymaps\common", "$Source\share\keymaps\modifiers" "$Dest\share\keymaps\" -ErrorAction SilentlyContinue
foreach ($l in $licenseFiles) { $p = Join-Path $Source $l; if (Test-Path $p) { Copy-Item $p "$Dest\licenses\QEMU-$l" } }

# SlightDroid-engine.exe = the windowed QEMU with SlightDroid's icon, name and a DPI-aware manifest
Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $PSScriptRoot 'Rebrand.cs')) -ErrorAction SilentlyContinue
$engineExe = "$Dest\SlightDroid-engine.exe"
Move-Item "$Dest\qemu-system-x86_64w.exe" $engineExe
$qver = ((& "$Dest\qemu-system-x86_64.exe" -version 2>&1)[0] -replace '^.*version (\d+\.\d+\.\d+).*$', '$1')
$strings = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$strings['CompanyName'] = 'SlightDroid'
$strings['FileDescription'] = "SlightDroid engine (based on QEMU $qver)"
$strings['FileVersion'] = $qver
$strings['InternalName'] = 'SlightDroid-engine'
$strings['LegalCopyright'] = 'QEMU: GNU GPL v2 (see licenses folder)'
$strings['OriginalFilename'] = 'SlightDroid-engine.exe'
$strings['ProductName'] = 'SlightDroid'
$strings['ProductVersion'] = '0.1.0'
$manifest = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
  </application></compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
  </windowsSettings></application>
</assembly>
"@
[Rebrand]::Apply($engineExe, (Resolve-Path (Join-Path $PSScriptRoot '..\..\launcher\SlightDroid.ico')).Path, $strings, $qver, $manifest)
"engine: " + (Get-Item $engineExe).VersionInfo.FileDescription

$out = @(& "$Dest\qemu-system-x86_64.exe" -version 2>&1); $v = $out[0]
if ($LASTEXITCODE -ne 0) { throw "trimmed QEMU does not start: $v" }
$files = Get-ChildItem $Dest -Recurse -File
"{0} files, {1:N1} MB (from {2:N0} MB). {3}" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB),
    ((Get-ChildItem $Source -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), $v
