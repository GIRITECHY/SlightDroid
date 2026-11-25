<#
.SYNOPSIS
  Dev runner: boots the Lite guest portably from the project folder and measures it.

.DESCRIPTION
  Uses the same QEMU arguments the shipped launcher will use (keep them in sync with
  launcher/Vm.cs). Creates a fresh qcow2 overlay on the ext4 data template, starts QEMU with
  WHPX, waits for ADB on 127.0.0.1:<AdbPort> and for sys.boot_completed, then reports boot
  time, guest memory and QEMU host memory, idle CPU. Leaves the VM running unless -Stop.

  Dev-PC numbers are PROXY numbers (docs/PLAN.md section 6).
#>
param(
    [int]$RamMB = 1024,
    [int]$Cpus = 2,
    [string]$Gpu = 'virgl',        # virgl = virtio-vga-gl + SDL/ANGLE ; std = virtio-vga (no 3D)
    [string]$Res = '1280x720',
    [int]$AdbPort = 55555,
    [switch]$Stop,
    [switch]$Fresh,
    [switch]$Console          # root shell on serial (tcp 127.0.0.1:45561) for debugging
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$engine = "$root\build\stage\engine"
$guest = "$root\build\stage\guest\lite"      # kernel, SlightDroid initrd, raw system.img
$tpl = "$root\build\stage\guest\lite\data-template.qcow2"
$work = "$root\build\run-lite"; New-Item -ItemType Directory -Force $work | Out-Null
$data = "$work\data.qcow2"
$adb = "$root\build\tools\platform-tools\adb.exe"

if ($Fresh -or -not (Test-Path $data)) {
    Remove-Item $data -ErrorAction SilentlyContinue
    & "$engine\qemu-img.exe" create -q -f qcow2 -b $tpl -F qcow2 $data
}
$w, $h = $Res.Split('x')
$append = "root=/dev/ram0 quiet SLIGHTDROID=1 SLIGHTDROID_SYSTEM=vda SETUPWIZARD=0 DATA=vdb video=${w}x${h} androidboot.hardware=android_x86 HWACCEL=1"
$gpuArgs = if ($Gpu -eq 'virgl') { @('-device', 'virtio-vga-gl', '-display', 'sdl,gl=on') } else { @('-device', 'virtio-vga', '-display', 'sdl') }

$qargs = @(
    '-name', 'SlightDroid', '-accel', 'whpx', '-machine', 'q35', '-smp', "$Cpus", '-m', "$RamMB",
    '-L', "`"$engine\share`"",
    '-kernel', "`"$guest\kernel`"", '-initrd', "`"$guest\initrd.img`"", '-append', "`"$append`"",
    '-drive', "file=`"$guest\system.img`",if=virtio,format=raw,readonly=on",
    '-drive', "file=`"$data`",if=virtio,format=qcow2,cache=writeback",
    '-netdev', "user,id=n0,hostfwd=tcp:127.0.0.1:${AdbPort}-:5555", '-device', 'virtio-net-pci,netdev=n0',
    '-device', 'qemu-xhci', '-device', 'usb-tablet', '-device', 'usb-kbd',
    '-audiodev', 'dsound,id=snd0', '-device', 'ich9-intel-hda', '-device', 'hda-duplex,audiodev=snd0',
    '-device', 'virtio-balloon-pci,free-page-reporting=on',
    '-qmp', 'tcp:127.0.0.1:45560,server=on,wait=off'
) + $gpuArgs
if ($Console) { $append += ' console=ttyS0 androidboot.console=ttyS0'; $qargs[$qargs.IndexOf('-append') + 1] = "`"$append`""; $qargs += @('-serial', 'tcp:127.0.0.1:45561,server=on,wait=off') }

$sw = [Diagnostics.Stopwatch]::StartNew()
$qemu = Start-Process -FilePath "$engine\qemu-system-x86_64.exe" -ArgumentList $qargs -PassThru -NoNewWindow `
    -RedirectStandardError "$work\qemu.err" -RedirectStandardOutput "$work\qemu.out"
$qemu.Id | Set-Content "$work\qemu.pid"

$ErrorActionPreference = 'Continue'   # adb writes status to stderr
& $adb kill-server 2>$null | Out-Null
$booted = $false
while ($sw.Elapsed.TotalSeconds -lt 300) {
    if ($qemu.HasExited) { throw "QEMU exited with $($qemu.ExitCode): $(Get-Content -Raw "$work\qemu.err")" }
    # QEMU's port forward accepts the TCP connection before the guest is reachable, which
    # leaves adb stuck "offline": drop such a connection and try again.
    & $adb connect "127.0.0.1:$AdbPort" 2>$null | Out-Null
    $v = (& $adb -s "127.0.0.1:$AdbPort" shell getprop slightdroid.ready 2>&1) -join ''
    if ($v.Trim() -eq '1') { $booted = $true; break }
    if ($v -match 'offline|not found|closed') { & $adb disconnect "127.0.0.1:$AdbPort" 2>$null | Out-Null }
    Start-Sleep -Seconds 1
}
if (-not $booted) { throw "no boot_completed after $([int]$sw.Elapsed.TotalSeconds) s (VM left running for inspection)" }
$bootSec = $sw.Elapsed.TotalSeconds
$s = "127.0.0.1:$AdbPort"

# let it settle, then measure idle
Start-Sleep -Seconds 30
$p = Get-Process -Id $qemu.Id
$cpu0 = $p.TotalProcessorTime; $t0 = Get-Date; Start-Sleep -Seconds 20; $p.Refresh()
$idleCpu = 100 * ($p.TotalProcessorTime - $cpu0).TotalSeconds / ((Get-Date) - $t0).TotalSeconds / [Environment]::ProcessorCount
$mem = (& $adb -s $s shell cat /proc/meminfo) -join "`n"
function Get-MemMB($k) { if ($mem -match "$k\s*:\s*(\d+)") { [int]($Matches[1] / 1024) } else { -1 } }
$counters = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess=$($qemu.Id)"

$r = [ordered]@{
    when = (Get-Date).ToString('s'); proxy = $true; host = (Get-CimInstance Win32_Processor).Name.Trim()
    guest = 'Android-x86 9.0-r2 (32-bit)'; accel = 'whpx'; gpu = $Gpu; ramMB = $RamMB; cpus = $Cpus; res = $Res
    bootSec = [math]::Round($bootSec, 1)
    android = ((& $adb -s $s shell getprop ro.build.version.release) -join '').Trim()
    renderer = ((& $adb -s $s shell getprop ro.hardware.egl) -join '').Trim()
    glRenderer = (((& $adb -s $s shell dumpsys SurfaceFlinger) | Select-String 'GLES:' | Select-Object -First 1) -as [string]).Trim()
    guestMemTotalMB = (Get-MemMB 'MemTotal'); guestMemAvailMB = (Get-MemMB 'MemAvailable'); guestSwapTotalMB = (Get-MemMB 'SwapTotal')
    qemuWorkingSetMB = [int]($p.WorkingSet64 / 1MB); qemuPrivateMB = [int]($p.PrivateMemorySize64 / 1MB)
    qemuPrivateWorkingSetMB = $(if ($counters) { [int]($counters.WorkingSetPrivate / 1MB) } else { -1 })
    qemuIdleCpuPctOfHost = [math]::Round($idleCpu, 2)
}
$r | ConvertTo-Json | Tee-Object -FilePath "$work\last-run.json"
if ($Stop) { Stop-Process -Id $qemu.Id -Force }
