<#
  Builds dist\SlightDroid-Setup-<version>.exe from build\payload with the portable NSIS
  (build\tools\nsis-3.13). Run stage.ps1 first. Prints size and SHA-256 of the result.
#>
param([string]$Version = '0.1.0-alpha')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$makensis = "$root\build\tools\nsis-3.13\makensis.exe"
if (-not (Test-Path "$root\build\payload\SlightDroid.exe")) { throw 'run stage.ps1 first' }
New-Item -ItemType Directory -Force "$root\dist" | Out-Null
$out = "$root\dist\SlightDroid-Setup-$Version.exe"
$sw = [Diagnostics.Stopwatch]::StartNew()
# progress window with percent and ETA (follows the growing installer file)
Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSScriptRoot\build-progress.ps1",'-Out',$out -WindowStyle Normal
& $makensis /V2 "/DVERSION=$Version" "/DPAYLOAD=$root\build\payload" "/DOUTFILE=$out" "$root\installer\SlightDroid.nsi"
if ($LASTEXITCODE) { throw "makensis failed ($LASTEXITCODE)" }
$h = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLower()
"{0}`n{1:N0} MB, built in {2:N0} s`nSHA-256 {3}" -f $out, ((Get-Item $out).Length / 1MB), $sw.Elapsed.TotalSeconds, $h
"$h  $(Split-Path -Leaf $out)" | Set-Content -Encoding ASCII "$out.sha256"
