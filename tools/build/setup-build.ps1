<#
.SYNOPSIS
  One-time setup for building SlightDroid on a fresh clone. Installs nothing on the PC.

.DESCRIPTION
  1. Downloads the pinned inputs the current build needs (tools/fetch/fetch-deps.ps1; files that
     are already there and verify are skipped).
  2. Unpacks the portable build tools into build\tools: NSIS, 7-Zip (an administrative extract of
     its MSI, which copies files without installing) and Android platform-tools (adb).
  3. Finds the Android SDK build-tools (zipalign, apksigner), a Java runtime and Python 3, and
     writes their locations to build\tools\toolpaths.json for stage-engine.ps1.

  Prerequisites the script cannot provide: Python 3, and Android Studio (or the Android SDK
  build-tools plus any Java 17+ runtime). Override detection with -Sdk / -JavaHome / -Python.
#>
param([string]$Sdk = '', [string]$JavaHome = '', [string]$Python = '', [switch]$NoFetch)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dl = "$root\downloads"
$tools = "$root\build\tools"
New-Item -ItemType Directory -Force $tools | Out-Null
function Step($m) { Write-Host "== $m" -ForegroundColor Cyan }

if (-not $NoFetch) {
    Step 'downloads (tools/fetch/deps.json)'
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\tools\fetch\fetch-deps.ps1"
    if ($LASTEXITCODE) { throw 'some downloads failed; run setup-build.ps1 again to resume' }
}

Step 'portable build tools'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Expand-Once($zip, $marker) {
    if (Test-Path $marker) { Write-Host "   present: $marker"; return }
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tools)
    if (-not (Test-Path $marker)) { throw "unpacking $zip did not produce $marker" }
    Write-Host "   unpacked: $marker"
}
Expand-Once (Get-ChildItem "$dl\nsis\nsis-*.zip" | Select-Object -First 1).FullName "$tools\nsis-3.13\makensis.exe"
Expand-Once (Get-ChildItem "$dl\platform-tools\platform-tools_*.zip" | Select-Object -First 1).FullName "$tools\platform-tools\adb.exe"
$sevenZip = "$tools\7zip-msi\Files\7-Zip\7z.exe"
if (-not (Test-Path $sevenZip)) {
    # msiexec cannot open a package through a folder link (junction), so work from a temp copy
    $src = (Get-ChildItem "$dl\7zip\7z*.msi" | Select-Object -First 1).FullName
    $msi = Join-Path $env:TEMP ("slightdroid-" + [IO.Path]::GetFileName($src)); Copy-Item $src $msi -Force
    # /a = administrative install: only extracts the MSI's files into TARGETDIR (no registry, no system install)
    $p = Start-Process msiexec.exe -ArgumentList "/a `"$msi`" /qn TARGETDIR=`"$tools\7zip-msi`"" -Wait -PassThru
    Remove-Item $msi -ErrorAction SilentlyContinue
    if (-not (Test-Path $sevenZip)) { throw "7-Zip extract failed (msiexec exit $($p.ExitCode))" }
    Write-Host "   unpacked: $sevenZip"
} else { Write-Host "   present: $sevenZip" }

Step 'Android SDK build-tools, Java, Python'
# build-tools: newest version folder that has zipalign + apksigner
$sdkCandidates = @($Sdk, $env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk") | Where-Object { $_ -and (Test-Path "$_\build-tools") }
$bt = $null
foreach ($s in $sdkCandidates) {
    $bt = Get-ChildItem "$s\build-tools" -Directory | Where-Object { (Test-Path "$($_.FullName)\zipalign.exe") -and (Test-Path "$($_.FullName)\apksigner.bat") } |
          Sort-Object { try { [version]($_.Name -replace '-.*$', '') } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    if ($bt) { break }
}
if (-not $bt) { throw 'Android SDK build-tools not found. Install Android Studio (SDK Manager > SDK Tools > Build-Tools) or pass -Sdk <path to the Android SDK>.' }

# Java: -JavaHome, JAVA_HOME, Android Studio's bundled runtime, or java on PATH
$javaCandidates = @($JavaHome, $env:JAVA_HOME, "$env:ProgramFiles\Android\Android Studio\jbr", "$env:LOCALAPPDATA\Programs\Android Studio\jbr", "${env:ProgramFiles(x86)}\Android\Android Studio\jbr")
$java = $javaCandidates | Where-Object { $_ -and (Test-Path "$_\bin\java.exe") } | Select-Object -First 1
if (-not $java) {
    $j = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($j) { $java = Split-Path (Split-Path $j.Source) }
}
if (-not $java) { throw 'No Java runtime found (apksigner needs one). Install Android Studio or pass -JavaHome <folder with bin\java.exe>.' }

# Python 3.8+: -Python, else every interpreter the py launcher knows (newest first), else python on PATH
# (the Microsoft Store stub is skipped). Each candidate must really run: launchers can point at removed installs.
function Test-Python([string]$exe) {
    if (-not $exe -or -not (Test-Path $exe)) { return $false }
    $pinfo = New-Object Diagnostics.ProcessStartInfo $exe, '-I -c "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)"'
    $pinfo.UseShellExecute = $false; $pinfo.CreateNoWindow = $true; $pinfo.RedirectStandardError = $true; $pinfo.RedirectStandardOutput = $true
    try { $pr = [Diagnostics.Process]::Start($pinfo); $pr.WaitForExit(20000) | Out-Null; return $pr.ExitCode -eq 0 } catch { return $false }
}
$cands = @()
if ($Python) { $cands += $Python }
if (Get-Command py.exe -ErrorAction SilentlyContinue) {
    $list = cmd /c "py.exe -0p 2>nul"
    $cands += $list | ForEach-Object { if ($_ -match '([A-Za-z]:\\[^\r\n]*python\.exe)') { $Matches[1].Trim() } }
}
$cands += Get-Command python.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*WindowsApps*' } | ForEach-Object Source
$pyExe = $cands | Where-Object { Test-Python $_ } | Select-Object -First 1
if (-not $pyExe) { throw 'Python 3.8+ not found. Install it from python.org or pass -Python <path to python.exe>.' }
$py = @($pyExe)

$paths = [ordered]@{ buildTools = $bt.FullName; javaHome = $java; python = $py; sevenZip = $sevenZip; nsis = "$tools\nsis-3.13\makensis.exe"; adb = "$tools\platform-tools\adb.exe" }
$paths | ConvertTo-Json | Set-Content -Encoding UTF8 "$tools\toolpaths.json"
$paths.GetEnumerator() | ForEach-Object { "   {0,-10} {1}" -f $_.Key, ($_.Value -join ' ') }
Write-Host "`nReady. Next: tools\build\stage-engine.ps1, then tools\build\build-installer.ps1" -ForegroundColor Green
