<#
  Dev benchmark of the engine's graphics path: starts the portable test copy (build\run-g11, data
  build\test-bench) with a resolution and GPU backend, scrolls the Settings app the same way each time and
  reports Android's frame statistics (jank %, frame-time and GPU-time percentiles). Kills only its own PIDs.
    gpu-bench.ps1 -Res 1280x800 -Gpu host
#>
param([string]$Res = 'auto', [string]$Gpu = 'host', [int]$Swipes = 30)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$adb = "$root\build\tools\platform-tools\adb.exe"
$dir = "$root\build\test-bench"
New-Item -ItemType Directory -Force $dir | Out-Null
"gpu=virgl`r`nresolution=$Res`r`ndrag_drop=off" | Set-Content -Encoding ASCII "$dir\settings.ini"
$log = "$dir\logs\launcher.log"
$before = if (Test-Path $log) { @(Select-String -Path $log -Pattern 'ready after').Count } else { 0 }
$env:SLIGHTDROID_DATA = $dir; $env:SLIGHTDROID_GPUMODE = $Gpu; $env:SLIGHTDROID_NOFALLBACK = '1'
$l = Start-Process "$root\build\run-g11\SlightDroid.exe" -PassThru
Remove-Item Env:SLIGHTDROID_DATA, Env:SLIGHTDROID_GPUMODE, Env:SLIGHTDROID_NOFALLBACK
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180 -and -not ((Test-Path $log) -and @(Select-String -Path $log -Pattern 'ready after').Count -gt $before)) { Start-Sleep 1 }
$st = @{}; Get-Content "$dir\vm.state" | ForEach-Object { $k, $v = $_ -split '=', 2; $st[$k] = $v }
$s = "127.0.0.1:$($st.adb)"; & $adb connect $s | Out-Null
$line = (Get-Content $log | Select-String ' start: ' | Select-Object -Last 1).Line
"[$Res / $Gpu] " + ($line -replace '^.*\(ram', '(ram')
Start-Sleep 15
& $adb -s $s shell 'am start -W -a android.settings.SETTINGS' | Out-Null
Start-Sleep 4
& $adb -s $s shell 'dumpsys gfxinfo com.android.settings reset' | Out-Null
$size = (& $adb -s $s shell 'wm size') -replace '.*: ', ''
$w, $h = ($size.Trim() -split 'x') | ForEach-Object { [int]$_ }
$x = [int]($w / 2); $y1 = [int]($h * 0.8); $y2 = [int]($h * 0.25)
for ($i = 0; $i -lt $Swipes; $i++) {
    if ($i % 2 -eq 0) { & $adb -s $s shell "input swipe $x $y1 $x $y2 250" } else { & $adb -s $s shell "input swipe $x $y2 $x $y1 250" }
}
Start-Sleep 2
& $adb -s $s shell 'dumpsys gfxinfo com.android.settings' | Select-String -Pattern 'Total frames|Janky|90th percentile|99th percentile|90th gpu|Frame deadline|Slow issue' | ForEach-Object { '   ' + $_.Line.Trim() }
$eng = Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue
if ($eng) { '   engine working set: {0:N0} MB' -f ($eng.WorkingSet64 / 1MB) }
foreach ($p in [int]$st.pid, $l.Id) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
Get-Process emulator -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\build\*" } | Stop-Process -Force
Start-Sleep 3
