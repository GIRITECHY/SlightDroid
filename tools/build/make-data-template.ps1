<#
.SYNOPSIS
  Creates the blank ext4 data-disk template (data-template.qcow2) for the Lite guest.

.DESCRIPTION
  Windows can't create ext4, so we let Android format it: boot the Android-x86 ISO headless
  in QEMU with DEBUG=1 and the console on a serial port (TCP), then run Android's own
  mke2fs on the blank virtio disk from the debug shell, check it with blkid, and power off.
  The result is compressed with qemu-img. It ships in the installer; on first launch SlightDroid
  copies it to the user's data folder.

  Runs QEMU portably from build\stage\engine (WHPX). Installs nothing.
#>
param(
    [string]$Iso = (Join-Path $PSScriptRoot '..\..\downloads\android-x86-9\android-x86-9.0-r2.iso'),
    [string]$GuestDir = (Join-Path $PSScriptRoot '..\..\build\guest-src\android-x86-9'),
    [string]$Engine = (Join-Path $PSScriptRoot '..\..\build\stage\engine'),
    [string]$Out = (Join-Path $PSScriptRoot '..\..\build\stage\guest\lite\data-template.qcow2'),
    [string]$SizeGB = '8',
    [int]$Port = 45551
)
$ErrorActionPreference = 'Stop'
$Iso = (Resolve-Path $Iso).Path; $GuestDir = (Resolve-Path $GuestDir).Path; $Engine = (Resolve-Path $Engine).Path
$work = Join-Path (Split-Path $Out) 'work'
New-Item -ItemType Directory -Force -Path $work, (Split-Path $Out) | Out-Null
$raw = Join-Path $work 'data.qcow2'
$log = Join-Path $work 'serial.log'
Remove-Item $raw, $log -ErrorAction SilentlyContinue

& "$Engine\qemu-img.exe" create -q -f qcow2 $raw "${SizeGB}G"
if ($LASTEXITCODE) { throw 'qemu-img create failed' }

$qargs = @(
    '-name', 'SlightDroid-datatemplate', '-accel', 'whpx', '-machine', 'q35', '-smp', '2', '-m', '1024',
    '-L', "`"$Engine\share`"",
    '-kernel', "`"$GuestDir\kernel`"", '-initrd', "`"$GuestDir\initrd.img`"",
    '-append', '"root=/dev/ram0 console=ttyS0 DEBUG=1 SRC= DATA="',
    '-drive', "file=`"$Iso`",if=virtio,format=raw,readonly=on",
    '-drive', "file=`"$raw`",if=virtio,format=qcow2",
    '-display', 'none', '-vga', 'none', '-nodefaults',
    '-serial', "tcp:127.0.0.1:${Port},server=on,wait=on"
)
$sw = [Diagnostics.Stopwatch]::StartNew()
$qemu = Start-Process -FilePath "$Engine\qemu-system-x86_64.exe" -ArgumentList $qargs -PassThru -NoNewWindow `
    -RedirectStandardError (Join-Path $work 'qemu.err')

# connect to the serial port (QEMU waits for us before starting the guest)
$client = $null
for ($i = 0; $i -lt 50 -and -not $client; $i++) {
    try { $client = New-Object Net.Sockets.TcpClient('127.0.0.1', $Port) } catch { Start-Sleep -Milliseconds 200 }
}
if (-not $client) { $qemu.Kill(); throw 'could not connect to QEMU serial port' }
$stream = $client.GetStream()
$buf = New-Object byte[] 65536
$text = New-Object Text.StringBuilder

function Read-Until([string]$pattern, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($qemu.HasExited) { throw "QEMU exited (code $($qemu.ExitCode)); see $work\qemu.err" }
        while ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            $s = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
            [void]$text.Append($s); Add-Content -Path $log -Value $s -NoNewline
        }
        if ($text.ToString() -match $pattern) { return $true }
        Start-Sleep -Milliseconds 200
    }
    throw "timeout waiting for '$pattern' (see $log)"
}
function Send([string]$cmd) { $b = [Text.Encoding]::ASCII.GetBytes("$cmd`n"); $stream.Write($b, 0, $b.Length) }

try {
    Read-Until "Type 'exit' to continue booting" 180 | Out-Null
    $bootSec = $sw.Elapsed.TotalSeconds
    Start-Sleep -Milliseconds 500
    [void]$text.Clear()
    Send 'ls -l /dev/block/ /dev/vd* 2>&1; echo MARK1'
    Read-Until 'MARK1\s*\r?\n.*' 20 | Out-Null
    Send '/android/system/bin/mke2fs -t ext4 -L data -m 0 /dev/vdb && echo MKFS_OK || echo MKFS_FAIL'
    Read-Until 'MKFS_(OK|FAIL)\r?\n' 120 | Out-Null
    if ($text.ToString() -notmatch 'MKFS_OK\r?\n') { throw "mke2fs failed (see $log)" }
    [void]$text.Clear()
    Send 'blkid /dev/vdb; echo MARK2'
    Read-Until 'MARK2\r?\n' 20 | Out-Null
    $blk = $text.ToString()
    if ($blk -notmatch 'TYPE="ext4"') { throw "blkid does not report ext4: $blk" }
    Send 'sync; echo o > /proc/sysrq-trigger'
    if (-not $qemu.WaitForExit(30000)) { $qemu.Kill() }
} finally {
    $client.Close()
    if (-not $qemu.HasExited) { $qemu.Kill() }
}

& "$Engine\qemu-img.exe" convert -c -O qcow2 $raw $Out
if ($LASTEXITCODE) { throw 'qemu-img convert failed' }
Remove-Item $raw
"debug shell after {0:N1} s; ext4 confirmed ({1}); template {2:N1} MB -> {3}" -f $bootSec, (($blk -split "`n" | Select-String 'vdb') -join '').Trim(), ((Get-Item $Out).Length / 1MB), $Out
