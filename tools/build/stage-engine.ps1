<#
.SYNOPSIS
  Assembles the SlightDroid payload (build\payload) for the Google Android Emulator engine + Android 11 x86_64.

.DESCRIPTION
  Layout (an SDK-like tree, the engine expects it):
    SlightDroid.exe                    launcher
    sdk\emulator\                      Android Emulator 37.2.13 (x86_64 engine only: other CPU types,
                                       headless engines, network simulator and crash uploaders removed)
    sdk\platform-tools\                adb (the engine uses it for drag & drop installs)
    sdk\system-images\android-30\default\x86_64\   Android 11 image
    tools\, licenses\
  Uses the pinned downloads (downloads\android-emulator, downloads\sysimg-api30-x86_64, platform-tools).
  Nothing is installed on this PC.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = "$root\build\payload"
$tp = "$root\build\tools\toolpaths.json"
if (-not (Test-Path $tp)) { throw "Run tools\build\setup-build.ps1 first (downloads, portable tools, SDK/Java/Python detection)." }
$tools = Get-Content -Raw $tp | ConvertFrom-Json
$z = $tools.sevenZip
$dl = "$root\downloads"
$src = "$root\build\engine-a\sdk"
function Step($m) { Write-Host "== $m" -ForegroundColor Cyan }

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force "$out\sdk\platforms", "$out\sdk\platform-tools", "$out\tools", "$out\licenses" | Out-Null
Set-Content -Encoding ASCII "$out\sdk\platforms\README.txt" "Intentionally empty (the Android Emulator expects this folder)."

Step 'engine (Android Emulator)'
if (-not (Test-Path "$src\emulator\emulator.exe")) { & $z x -y -bso0 -bsp0 "-o$src" (Get-ChildItem "$dl\android-emulator\emulator-windows_x64-*.zip").FullName }
$drop = '^(qemu-system-(aarch64|armel|i386|riscv64).*|qemu-system-x86_64-headless\.exe|netsimd\.exe|nimble_bridge\.exe|crashreport\.exe|crashpad_handler\.exe)$'
robocopy "$src\emulator" "$out\sdk\emulator" /E /NFL /NDL /NJH /NJS /NP | Out-Null
Get-ChildItem "$out\sdk\emulator" -Recurse -File | Where-Object { $_.Name -match $drop } | Remove-Item -Force
if (-not (Test-Path "$out\sdk\emulator\qemu\windows-x86_64\qemu-system-x86_64.exe")) { throw 'engine missing' }

Step 'platform-tools (adb)'
$pt = Split-Path $tools.adb
Copy-Item "$pt\adb.exe", "$pt\AdbWinApi.dll", "$pt\AdbWinUsbApi.dll" "$out\sdk\platform-tools\"
Copy-Item "$pt\NOTICE.txt" "$out\licenses\platform-tools-NOTICE.txt" -ErrorAction SilentlyContinue

Step 'Android 11 x86_64 system image'
$img = "$src\system-images\android-30\default"
if (-not (Test-Path "$img\x86_64\system.img")) { & $z x -y -bso0 -bsp0 "-o$img" (Get-ChildItem "$dl\sysimg-api30-x86_64\x86_64-30_*.zip").FullName }
New-Item -ItemType Directory -Force "$out\sdk\system-images\android-30\default" | Out-Null
robocopy "$img\x86_64" "$out\sdk\system-images\android-30\default\x86_64" /E /NFL /NDL /NJH /NJS /NP | Out-Null
$sys = "$out\sdk\system-images\android-30\default\x86_64\system.img"
if (-not (Test-Path $sys)) { throw 'system image missing' }
# NSIS stores files up to 2 GB: split system.img into 1 GB parts; the installer joins them (copy /b)
$in = [IO.File]::OpenRead($sys); $buf = New-Object byte[] (4MB); $part = 0
try {
    while ($in.Position -lt $in.Length) {
        $o = [IO.File]::Create("$sys.part$part"); $left = 1GB
        try { while ($left -gt 0 -and ($n = $in.Read($buf, 0, [Math]::Min($buf.Length, $left))) -gt 0) { $o.Write($buf, 0, $n); $left -= $n } } finally { $o.Dispose() }
        $part++
    }
} finally { $in.Dispose() }
Set-Content -Encoding ASCII "$sys.parts" "$part`r`n$((Get-Item $sys).Length)"
Remove-Item $sys
"system.img split into $part parts"

Step 'WebView 108 (Bromite, renamed to com.android.webview, AOSP test key)'
$wv = "$root\build\webview-renamed\webview-108.apk"
if (-not (Test-Path $wv)) {
    $bt = $tools.buildTools; $k = "$dl\aosp-testkey"; $py = @($tools.python)
    New-Item -ItemType Directory -Force (Split-Path $wv) | Out-Null
    & $py[0] @($py | Select-Object -Skip 1) -I "$PSScriptRoot\rename-webview.py" "$dl\bromite-webview\x64_SystemWebView.apk" "$root\build\webview-renamed\unsigned.apk"
    & "$bt\zipalign.exe" -f -p 4 "$root\build\webview-renamed\unsigned.apk" "$root\build\webview-renamed\aligned.apk"
    $env:JAVA_HOME = $tools.javaHome
    & "$bt\apksigner.bat" sign --key "$k\testkey.pk8" --cert "$k\testkey.x509.pem" --out $wv "$root\build\webview-renamed\aligned.apk"
    if (-not (Test-Path $wv)) { throw 'WebView build failed' }
}
New-Item -ItemType Directory -Force "$out\apps" | Out-Null
Copy-Item $wv "$out\apps\webview.apk"
Set-Content -Encoding UTF8 "$out\licenses\WebView-Bromite.txt" @"
apps\webview.apk is Bromite SystemWebView 108.0.5359.156 (https://github.com/bromite/bromite, release
108.0.5359.156), x86_64 build. Bromite: GPL-3.0 (its patches); Chromium: BSD-3-Clause and the third-party
licences listed in the app (chrome://credits). SlightDroid changed only the package name (org.bromite.webview ->
com.android.webview, in AndroidManifest.xml and resources.arsc) and re-signed it with the public AOSP test
key so Android 11 accepts it as an update of its built-in WebView. Source: the Bromite repository above;
the rename tool is tools/build/rename-webview.py in SlightDroid's source.
"@

Step 'launcher'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\build-launcher.ps1"
if ($LASTEXITCODE) { throw 'launcher build failed' }
Copy-Item "$root\build\stage\SlightDroid.exe" "$out\SlightDroid.exe"

Step 'tools'
Copy-Item "$root\tools\envcheck\envcheck.ps1", "$root\tools\envcheck\VideoProbe.cs", "$root\tools\envcheck\envcheck.cmd", "$root\tools\diag\diagnostics.ps1" "$out\tools\"
Set-Content -Encoding ASCII "$out\tools\diagnostics.cmd" "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0diagnostics.ps1`"`r`n"

Step 'licenses'
Copy-Item "$root\installer\NOTICE.txt" "$out\licenses\NOTICE.txt"
foreach ($n in 'LICENSE', 'NOTICE.txt', 'NOTICE.csv') { Copy-Item "$src\emulator\$n" "$out\licenses\android-emulator-$n" }
Copy-Item "$img\x86_64\source.properties" "$out\licenses\android-11-system-image-source.properties"

$files = Get-ChildItem $out -Recurse -File
"payload: {0} files, {1:N0} MB in {2}" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $out
