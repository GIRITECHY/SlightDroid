<#
  Dev benchmark: how evenly a WebView-played video reaches the screen (the NetMirror case), for one engine
  variant. Starts the portable test copy (build\run-g11, data build\test-g11, which has WebView 108
  installed) with extra engine options, plays build\vtest\h264-1080p30.mp4 (steady 30 fps) in the WebView
  test app via a local web server, and reads SurfaceFlinger's present-to-present histogram for that app.
    webview-video-bench.ps1 -Label host -EngineArgs ''
#>
param([string]$Label = 'default', [string]$EngineArgs = '', [string]$GpuMode = '')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$adb = "$root\build\tools\platform-tools\adb.exe"
$dir = "$root\build\test-g11"
$log = "$dir\logs\launcher.log"
$srv = Start-Process py -ArgumentList '-3.12', '-I', '-m', 'http.server', '8765', '--bind', '127.0.0.1', '--directory', "$root\build\vtest" -WindowStyle Hidden -PassThru
$before = @(Select-String -Path $log -Pattern 'ready after').Count
$env:SLIGHTDROID_DATA = $dir; $env:SLIGHTDROID_ENGINE_ARGS = ("-no-snapshot-load " + $EngineArgs).Trim(); $env:SLIGHTDROID_NOFALLBACK = '1'
if ($GpuMode) { $env:SLIGHTDROID_GPUMODE = $GpuMode }
$l = Start-Process "$root\build\run-g11\SlightDroid.exe" -PassThru
Remove-Item Env:SLIGHTDROID_DATA, Env:SLIGHTDROID_ENGINE_ARGS, Env:SLIGHTDROID_NOFALLBACK; if ($GpuMode) { Remove-Item Env:SLIGHTDROID_GPUMODE }
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 200 -and @(Select-String -Path $log -Pattern 'ready after').Count -le $before) { Start-Sleep 2 }
$st = @{}; Get-Content "$dir\vm.state" | ForEach-Object { $k, $v = $_ -split '=', 2; $st[$k] = $v }
$s = "127.0.0.1:$($st.adb)"; & $adb connect $s | Out-Null
Start-Sleep 10
& $adb -s $s shell 'am force-stop org.chromium.webview_shell; am start -n org.chromium.webview_shell/.WebViewBrowserActivity -d http://10.0.2.2:8765/v.html' | Out-Null
Start-Sleep 6
& $adb -s $s shell 'input tap 640 450' | Out-Null   # WebView needs a tap before it plays video
Start-Sleep 4
& $adb -s $s shell 'dumpsys SurfaceFlinger --timestats -enable -clear' | Out-Null
Start-Sleep 15
$t = (& $adb -s $s shell 'dumpsys SurfaceFlinger --timestats -dump -maxlayers 4') -join "`n"
& $adb -s $s shell 'dumpsys SurfaceFlinger --timestats -disable' | Out-Null
$rr = (& $adb -s $s shell 'dumpsys SurfaceFlinger | grep refresh-rate') -join ''
$m = [regex]::Match($t, 'layerName = (org\.chromium\.webview_shell[^\n]*)\n(.*?)present2present histogram is as below:\n([^\n]*)', 'Singleline')
if (-not $m.Success) { "[$Label] WebView layer not found; layers: " + (([regex]::Matches($t, 'layerName = ([^\n]*)') | ForEach-Object { $_.Groups[1].Value }) -join ' | '); (& $adb -s $s shell 'dumpsys window | grep -m1 mCurrentFocus') } else {
    $h = [regex]::Matches($m.Groups[3].Value, '(\d+)ms=(\d+)') | ForEach-Object { [pscustomobject]@{ ms = [int]$_.Groups[1].Value; n = [int]$_.Groups[2].Value } } | Where-Object n -gt 0
    $tot = ($h | Measure-Object n -Sum).Sum
    $even = ($h | Where-Object { $_.ms -ge 30 -and $_.ms -le 37 } | Measure-Object n -Sum).Sum
    $hitch = ($h | Where-Object { $_.ms -ge 50 } | Measure-Object n -Sum).Sum
    $fps = [regex]::Match($m.Groups[2].Value, 'averageFPS = ([\d.]+)').Groups[1].Value
    "[{0}] {1}  frames {2}, avg {3} fps, on-time (30-37 ms) {4:N0}%, hitches (>=50 ms) {5:N1}%" -f $Label, $rr.Trim(), $tot, $fps, (100 * $even / [math]::Max(1, $tot)), (100 * $hitch / [math]::Max(1, $tot))
    "   " + (($h | ForEach-Object { "$($_.ms)=$($_.n)" }) -join ' ')
}
foreach ($p in [int]$st.pid, $l.Id) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
Get-Process emulator -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$root\build\*" } | Stop-Process -Force
Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object CommandLine -like '*http.server*8765*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep 3
