<#
.SYNOPSIS
  Builds SlightDroid's Lite system image: Android-x86's system.img minus the packages in
  guest/lite/debloat.txt (analytics, Google apps, taskbar shell).

.DESCRIPTION
  Windows cannot write ext4, so Android-x86's own initrd does it: the copy is attached as a
  writable virtio disk, booted headless into the initrd debug shell (SlightDroid initrd, DEBUG=1),
  remounted read-write, the listed folders are deleted, the filesystem is synced and checked,
  and the VM powers off. Runs QEMU portably; installs nothing.
#>
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\..\build\guest-src\android-x86-9\system.img'),
    [string]$Out = (Join-Path $PSScriptRoot '..\..\build\payload\guest\lite\system.img'),
    [string]$Engine = (Join-Path $PSScriptRoot '..\..\build\payload\engine'),
    [string]$Guest = (Join-Path $PSScriptRoot '..\..\build\payload\guest\lite'),
    [int]$Port = 45571
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Engine = (Resolve-Path $Engine).Path; $Guest = (Resolve-Path $Guest).Path
if (-not (Test-Path $Source)) {
    & "$root\build\tools\7zip-msi\Files\7-Zip\7z.exe" e -y -bso0 -bsp0 "-o$(Split-Path $Source)" "$(Split-Path $Source)\system.sfs" system.img
}
$list = Get-Content "$root\guest\lite\debloat.txt" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
if ($list | Where-Object { $_ -match '\.\.|^/|\s' }) { throw 'debloat.txt: paths must be relative, without spaces or ..' }

$tmp = "$Out.building"
Copy-Item $Source $tmp -Force

$qargs = @('-accel', 'whpx', '-machine', 'q35', '-smp', '2', '-m', '1024', '-L', "`"$Engine\share`"",
    '-kernel', "`"$Guest\kernel`"", '-initrd', "`"$Guest\initrd.img`"",
    '-append', '"root=/dev/ram0 console=ttyS0 SLIGHTDROID=1 SLIGHTDROID_SYSTEM=vda DEBUG=1"',
    '-drive', "file=`"$tmp`",if=virtio,format=raw",
    '-display', 'none', '-vga', 'none', '-nodefaults', '-serial', "tcp:127.0.0.1:${Port},server=on,wait=on")
$q = Start-Process "$Engine\qemu-system-x86_64.exe" -ArgumentList $qargs -PassThru -NoNewWindow -RedirectStandardError "$tmp.err"
$c = $null
for ($i = 0; $i -lt 50 -and -not $c; $i++) { try { $c = New-Object Net.Sockets.TcpClient('127.0.0.1', $Port) } catch { Start-Sleep -Milliseconds 200 } }
if (-not $c) { $q.Kill(); throw 'no serial connection' }
$s = $c.GetStream(); $buf = New-Object byte[] 65536; $sb = New-Object Text.StringBuilder
function Wait-For([string]$pattern, [int]$sec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $sec) {
        if ($q.HasExited) { throw "QEMU exited: $(Get-Content -Raw "$tmp.err")" }
        while ($s.DataAvailable) { $n = $s.Read($buf, 0, $buf.Length); [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
        if ($sb.ToString() -match $pattern) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "timeout waiting for $pattern"
}
function Send([string]$t) { $b = [Text.Encoding]::ASCII.GetBytes("$t`n"); $s.Write($b, 0, $b.Length) }

try {
    Wait-For "Type 'exit' to continue booting" 120
    $before = $sb.Length
    Send 'mount -o remount,rw /android/system && echo RW_OK || echo RW_FAIL'
    Wait-For 'RW_(OK|FAIL)\r?\n' 30
    if ($sb.ToString().Substring($before) -notmatch 'RW_OK') { throw 'could not remount system read-write' }
    $rm = ($list | ForEach-Object { "/android/system/$_" }) -join ' '
    # zero the freed blocks too, so the removed apps do not still take space in the compressed installer
    Send "df -k /android/system | tail -1; rm -rf $rm; for d in $rm; do [ -e `$d ] && echo STILL `$d; done; dd if=/dev/zero of=/android/system/.zero bs=1048576 2>/dev/null; rm -f /android/system/.zero; sync; df -k /android/system | tail -1; echo RM_DONE"
    Wait-For 'RM_DONE\r?\n' 900
    $serial = $sb.ToString().Substring($before)
    if ($serial -match 'STILL /android') { throw "not removed: $(([regex]::Matches($serial, 'STILL /android\S+') | ForEach-Object Value) -join ', ')" }
    $df = [regex]::Matches($serial, '(\d+)\s+(\d+)\s+(\d+)\s+\d+%') | ForEach-Object { [long]$_.Groups[2].Value }
    Send 'umount /android/system 2>/dev/null; sync; echo o > /proc/sysrq-trigger'
    if (-not $q.WaitForExit(30000)) { $q.Kill() }
} finally { $c.Close(); if (-not $q.HasExited) { $q.Kill() } }

Move-Item -Force $tmp $Out
Remove-Item "$tmp.err" -ErrorAction SilentlyContinue
"removed {0} folders; system used {1:N0} MB -> {2:N0} MB; image: {3}" -f $list.Count, ($df[0] / 1024), ($df[-1] / 1024), $Out
