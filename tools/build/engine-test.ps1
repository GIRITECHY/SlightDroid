<#
  Portable end-to-end test of build\payload (Google engine): start -> ready, then stop (quick-boot save) and
  start again (resume). Uses its own data folder (build\test-<Name>) and kills only what it started.
#>
param([string]$Name = 'g11', [switch]$Fresh, [int]$Cycles = 2)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dir = "$root\build\test-$Name"
if ($Fresh -and (Test-Path $dir)) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null
$log = "$dir\logs\launcher.log"
function ReadyCount { if (Test-Path $log) { @(Select-String -Path $log -Pattern 'ready after').Count } else { 0 } }
for ($i = 1; $i -le $Cycles; $i++) {
    $before = ReadyCount
    $env:SLIGHTDROID_DATA = $dir
    $l = Start-Process "$root\build\payload\SlightDroid.exe" -PassThru
    Remove-Item Env:SLIGHTDROID_DATA
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 240 -and (ReadyCount) -le $before -and -not $l.HasExited) { Start-Sleep 1 }
    "cycle $i : $(if ((ReadyCount) -gt $before) { 'READY' } else { 'NOT READY' }) after $([int]$sw.Elapsed.TotalSeconds) s (launcher exited: $($l.HasExited))"
    Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { '   ' + $_.Substring(0, [Math]::Min(200, $_.Length)) }
    if ($i -lt $Cycles) {
        Start-Sleep 20
        $env:SLIGHTDROID_DATA = $dir
        $s = Start-Process "$root\build\payload\SlightDroid.exe" -ArgumentList '--stop' -PassThru
        Remove-Item Env:SLIGHTDROID_DATA
        $s.WaitForExit(60000) | Out-Null
        $l.WaitForExit(30000) | Out-Null
        "   stopped; snapshot: " + ((Get-ChildItem "$dir\avd\SlightDroid.avd\snapshots" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB).ToString('N0') + ' MB'
    }
}
