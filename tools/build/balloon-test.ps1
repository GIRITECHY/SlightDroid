<#
  Dev test: does shrinking the Android guest with the virtio balloon give memory back to Windows?
  Starts a portable compatibility-mode VM (build\test-balloon), waits until ready, then sets the
  balloon to several sizes and records the engine's working set / private bytes and guest MemAvailable.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$adb = "$root\build\tools\platform-tools\adb.exe"
$dir = "$root\build\test-balloon"
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory $dir | Out-Null
"gpu=std`r`ndrag_drop=off" | Set-Content -Encoding ASCII "$dir\settings.ini"
$env:SLIGHTDROID_DATA = $dir; $env:SLIGHTDROID_NOFALLBACK = '1'
$l = Start-Process "$root\build\payload\SlightDroid.exe" -PassThru
Remove-Item Env:SLIGHTDROID_DATA, Env:SLIGHTDROID_NOFALLBACK
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 150 -and -not ((Test-Path "$dir\logs\launcher.log") -and (Select-String -Path "$dir\logs\launcher.log" -Pattern 'ready after' -Quiet))) { Start-Sleep 2 }
$st = @{}; Get-Content "$dir\vm.state" | ForEach-Object { $k, $v = $_ -split '=', 2; $st[$k] = $v }
$eng = Get-Process -Id ([int]$st.pid)
function Qmp($cmd) {
    $c = New-Object Net.Sockets.TcpClient('127.0.0.1', [int]$st.qmp); $s = $c.GetStream(); $s.ReadTimeout = 20000
    $r = New-Object IO.StreamReader($s); $w = New-Object IO.StreamWriter($s); $w.AutoFlush = $true
    [void]$r.ReadLine(); $w.WriteLine('{"execute":"qmp_capabilities"}'); [void]$r.ReadLine(); $w.WriteLine($cmd)
    do { $o = $r.ReadLine() } while ($o -match '"event"'); $c.Close(); $o
}
& $adb connect "127.0.0.1:$($st.adb)" | Out-Null
function Snap($label) {
    $eng.Refresh()
    $ma = (& $adb -s "127.0.0.1:$($st.adb)" shell 'grep -E "MemTotal|MemAvailable" /proc/meminfo' | ForEach-Object { ($_ -split '\s+')[1] }) -join '/'
    $os = Get-CimInstance Win32_OperatingSystem
    "{0,-22} engine WS {1,5} MB  private {2,5} MB  | guest total/avail kB {3}  | Windows free {4,5} MB" -f $label, [int]($eng.WorkingSet64 / 1MB), [int]($eng.PrivateMemorySize64 / 1MB), $ma, [int]($os.FreePhysicalMemory / 1KB)
}
Start-Sleep 20; Snap 'ready (2048 MB)'
$a=$adb; $s="127.0.0.1:$($st.adb)"; & $a -s $s shell 'am start -a android.intent.action.VIEW -d https://www.google.com com.android.chrome' | Out-Null; Start-Sleep 12
cmd /c "`"$a`" -s $s exec-out screencap -p > `"$env:TEMP\col-guest.png`""; Qmp ('{"execute":"screendump","arguments":{"filename":"' + ($env:TEMP -replace '\\','/') + '/col-host.png","format":"png"}}')
foreach ($mb in 1536, 1024, 768) {
    Qmp ('{"execute":"balloon","arguments":{"value":' + ([long]$mb * 1MB) + '}}') | Out-Null
    Start-Sleep 25; Snap "balloon -> $mb MB"
}
Qmp ('{"execute":"balloon","arguments":{"value":' + (2048L * 1MB) + '}}') | Out-Null
Start-Sleep 20; Snap 'balloon -> 2048 MB'
foreach ($p in $eng.Id, $l.Id) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
