<#
  Dev-PC freeze test (portable, no install): runs build\payload\SlightDroid.exe with its own data folder
  (build\test-<Name>), a given graphics mode and a serial kernel log, then probes Android every 10 s
  for -Minutes. Reports when ADB/launcher stop answering. Kills only the PIDs it started.
    freeze-test.ps1 -Name ft-virgl -Gpu virgl -Minutes 4
#>
param([string]$Name = 'ft', [ValidateSet('virgl','std')][string]$Gpu = 'virgl', [int]$Minutes = 4,
      [string]$Extra = '', [switch]$Keep, [hashtable]$Env = @{},
      [string]$ProbeCmd = 'cat /proc/uptime; getprop slightdroid.ready; dumpsys window | grep -m1 mCurrentFocus; ls /data/anr 2>/dev/null | wc -l')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$adb = "$root\build\tools\platform-tools\adb.exe"
$dir = "$root\build\test-$Name"
if (-not $Keep -and (Test-Path $dir)) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null
@"
ram_mb=auto
cpus=auto
gpu=$Gpu
accel=whpx
storage_gb=50
resolution=auto
dpi=0
window=fit
drag_drop=off
$Extra
"@ | Set-Content -Encoding ASCII "$dir\settings.ini"

# serial console -> file (SLIGHTDROID_CONSOLE makes the launcher add console=ttyS0 and a tcp serial port)
$con = Get-Random -Minimum 40000 -Maximum 49000
$serialLog = "$dir\serial.log"
$env:SLIGHTDROID_DATA = $dir; $env:SLIGHTDROID_CONSOLE = "$con"; $env:SLIGHTDROID_NOFALLBACK = "1"; foreach ($k in $Env.Keys) { Set-Item "Env:$k" $Env[$k] }
$launcher = Start-Process "$root\build\payload\SlightDroid.exe" -PassThru
Remove-Item Env:SLIGHTDROID_DATA, Env:SLIGHTDROID_CONSOLE, Env:SLIGHTDROID_NOFALLBACK; foreach ($k in $Env.Keys) { Remove-Item "Env:$k" }
$serialJob = Start-Job -ArgumentList $con, $serialLog {
    param($port, $file)
    for ($i = 0; $i -lt 60; $i++) { try { $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $port); break } catch { Start-Sleep -Milliseconds 500 } }
    $s = $c.GetStream(); $buf = New-Object byte[] 65536
    $fs = [IO.File]::Open($file, 'Append', 'Write', 'ReadWrite')
    while (($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $n); $fs.Flush() }
}
for ($i = 0; $i -lt 60 -and -not (Test-Path "$dir\vm.state"); $i++) { Start-Sleep 1 }
$st = @{}; Get-Content "$dir\vm.state" | ForEach-Object { $k, $v = $_ -split '=', 2; $st[$k] = $v }
$enginePid = [int]$st.pid; $port = $st.adb
"[$Name] gpu=$Gpu launcher=$($launcher.Id) engine=$enginePid adb=$port serial=$con"

function Probe([string]$cmd, [int]$t = 15) {
    $j = Start-Job -ArgumentList $adb, $port, $cmd { param($a, $p, $c) & $a connect "127.0.0.1:$p" | Out-Null; & $a -s "127.0.0.1:$p" shell $c 2>&1 }
    if (Wait-Job $j -Timeout $t) { $o = (Receive-Job $j) -join ' | '; Remove-Job $j; return $o }
    Stop-Job $j; Remove-Job $j -Force; return 'TIMEOUT'
}
$t0 = Get-Date; $readyAt = $null; $frozen = 0; $result = 'OK'
while (((Get-Date) - $t0).TotalMinutes -lt ($Minutes + 2)) {
    Start-Sleep 10
    if (-not (Get-Process -Id $enginePid -ErrorAction SilentlyContinue)) { $result = 'ENGINE EXITED'; break }
    $o = Probe $ProbeCmd
    $el = [int]((Get-Date) - $t0).TotalSeconds
    "{0,4}s  {1}" -f $el, $o
    if (-not $readyAt -and $o -match '\| 1 \|') { $readyAt = Get-Date }
    if ($o -eq 'TIMEOUT' -or $o -match 'Not Responding') { $frozen++ } else { $frozen = 0 }
    if ($frozen -ge 3) { $result = 'FROZEN'; break }
    if ($readyAt -and ((Get-Date) - $readyAt).TotalMinutes -ge $Minutes) { break }
}
"[$Name] RESULT: $result  (ready: $(if ($readyAt) { [int]($readyAt - $t0).TotalSeconds } else { 'never' }) s)"
Get-Content "$dir\logs\launcher.log" -ErrorAction SilentlyContinue | Select-Object -Last 4
# kill only what this test started
foreach ($p in $enginePid, $launcher.Id) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
Start-Sleep 2; Stop-Job $serialJob -ErrorAction SilentlyContinue; Remove-Job $serialJob -Force -ErrorAction SilentlyContinue
"--- serial.log: warnings/errors (last 40) ---"
if (Test-Path $serialLog) { Select-String -Path $serialLog -Pattern 'hung|blocked for|rcu|stall|BUG|WARN|Oops|lockup|virtio_gpu|drm|fence|lowmemory|oom' | Select-Object -Last 40 | ForEach-Object { $_.Line } }
