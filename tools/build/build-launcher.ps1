<#
  Compiles launcher\*.cs into build\stage\SlightDroid.exe with the C# compiler that ships with
  Windows (.NET Framework 4.x csc.exe). Nothing to install.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$out = "$root\build\stage\SlightDroid.exe"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
$src = Get-ChildItem "$root\launcher\*.cs" | ForEach-Object { $_.FullName }
$icon = "$root\launcher\SlightDroid.ico"
$opts = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001', "/out:$out",
          '/r:System.Windows.Forms.dll', '/r:System.Drawing.dll', '/r:System.Core.dll', '/r:Microsoft.VisualBasic.dll')
if (-not (Test-Path $icon)) { throw "missing $icon (run make-logo.ps1)" }
$opts += "/win32icon:$icon", "/resource:$icon,SlightDroid.ico"
& $csc @opts @src
if ($LASTEXITCODE) { throw "csc failed ($LASTEXITCODE)" }
"{0} ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1KB)
