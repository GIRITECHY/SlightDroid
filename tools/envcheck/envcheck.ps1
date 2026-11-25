<#
.SYNOPSIS
  SlightDroid environment check.

.DESCRIPTION
  Checks whether this PC can run SlightDroid and what it can do on it. The reference target is a
  low-end PC: 4 GB RAM, Intel Pentium, integrated graphics, HDD or eMMC (see docs/PLAN.md).

  Collects facts (Windows, CPU, accelerators, RAM, pagefile, disk, GPU, hardware video
  decode, screen), then evaluates them into a PASS/WARN/FAIL report with an accelerator
  list, guest profile, display resolution and video tier.

  Functional tests rather than flags:
    - WHPX: creates, sets up and deletes an empty partition (same API path as QEMU -accel whpx).
    - Video decode: for every GPU, creates real D3D11 video decoders per codec at
      1920x1088 and 3840x2160. A driver refuses what its fixed-function decoder can't do.

  Runs without admin rights.

.PARAMETER Json
  Also write the full result as JSON to this path (read later by the frontend).

.PARAMETER Simulate
  Testing only. Replaces detected facts with a reference machine so the low-end paths
  can be exercised on any PC. The report is clearly labelled as a simulation.
    pentium-silver  Tier A: Pentium Silver N5030, 4 GB, UHD 605, eMMC, Win10, no hypervisor
    pentium-old     Tier B: Pentium G3220 (Haswell), 4 GB, HD Graphics, HDD, Win10, no hypervisor
    no-whpx         this PC, but WHPX feature off and no hypervisor running
    bios-off        this PC, but VT-x/AMD-V disabled in firmware
    tiny-ram        this PC, but 2 GB RAM

.OUTPUTS
  Exit code 0 = ready, 1 = ready with warnings, 2 = blocked.
#>
[CmdletBinding()]
param(
    [string]$Json,
    [ValidateSet('', 'pentium-silver', 'pentium-old', 'no-whpx', 'bios-off', 'tiny-ram')]
    [string]$Simulate = '',
    # Installer mode: the exit code is a decision (see the end of the script)
    [switch]$Decision
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ToolVersion = '0.2.0'
$GuestOverheadMB = 150   # host-side budget excluding guest RAM (docs/PLAN.md)

function Try-Get { param([scriptblock]$Block) try { & $Block } catch { $null } }

# ===========================================================================
# Native helpers (compiled in memory; no external dependencies)
# ===========================================================================
$native = @'
using System;
using System.Runtime.InteropServices;

public static class EmuNative {
    [DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettingsW(string device, int mode, ref DEVMODE dm);

    // Physical resolution and refresh of the primary display (not DPI-scaled).
    public static uint[] PrimaryDisplay() {
        var dm = new DEVMODE(); dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettingsW(null, -1 /* ENUM_CURRENT_SETTINGS */, ref dm)) return new uint[] { 0, 0, 0 };
        return new uint[] { dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency };
    }
}

public static class EmuWhp {
    [DllImport("WinHvPlatform.dll")] public static extern int WHvGetCapability(int code, out ulong buf, uint size, out uint written);
    [DllImport("WinHvPlatform.dll")] public static extern int WHvCreatePartition(out IntPtr partition);
    [DllImport("WinHvPlatform.dll")] public static extern int WHvSetPartitionProperty(IntPtr partition, int code, ref uint value, uint size);
    [DllImport("WinHvPlatform.dll")] public static extern int WHvSetupPartition(IntPtr partition);
    [DllImport("WinHvPlatform.dll")] public static extern int WHvDeletePartition(IntPtr partition);

    // "" on success, otherwise the failing step and HRESULT.
    public static string ProbePartition() {
        IntPtr p;
        int hr = WHvCreatePartition(out p);
        if (hr != 0) return string.Format("WHvCreatePartition hr=0x{0:X8}", hr);
        try {
            uint cpus = 1;
            hr = WHvSetPartitionProperty(p, 0x1fff /* ProcessorCount */, ref cpus, 4);
            if (hr != 0) return string.Format("WHvSetPartitionProperty hr=0x{0:X8}", hr);
            hr = WHvSetupPartition(p);
            if (hr != 0) return string.Format("WHvSetupPartition hr=0x{0:X8}", hr);
            return "";
        } finally { WHvDeletePartition(p); }
    }
}
'@
Add-Type -TypeDefinition $native
Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $PSScriptRoot 'VideoProbe.cs'))

$CodecNames = @('H.264', 'HEVC Main', 'HEVC Main10', 'VP9', 'VP9 10-bit', 'AV1')

# ===========================================================================
# 1. COLLECT facts
# ===========================================================================
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cv = Try-Get { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
$cpu = @(Get-CimInstance Win32_Processor)[0]

$F = [ordered]@{}

$F.os = [ordered]@{
    caption = $os.Caption.Trim()
    edition = $(if ($cv -and $cv.PSObject.Properties['EditionID']) { $cv.EditionID } else { '?' })
    displayVersion = $(if ($cv -and $cv.PSObject.Properties['DisplayVersion']) { $cv.DisplayVersion } else { '' })
    build = [int]$os.BuildNumber
    is64 = ($os.OSArchitecture -match '64')
    isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$F.cpu = [ordered]@{
    name = $cpu.Name.Trim()
    vendor = $(switch -Regex ($cpu.Manufacturer) { 'Intel' { 'Intel' } 'AMD' { 'AMD' } default { $cpu.Manufacturer } })
    cores = [int]$cpu.NumberOfCores
    threads = [int]$cpu.NumberOfLogicalProcessors
    vtFirmware = [bool]$cpu.VirtualizationFirmwareEnabled
    slat = [bool]$cpu.SecondLevelAddressTranslationExtensions
    isa = [ordered]@{
        'SSSE3'  = [EmuNative]::IsProcessorFeaturePresent(36)
        'SSE4.1' = [EmuNative]::IsProcessorFeaturePresent(37)
        'SSE4.2' = [EmuNative]::IsProcessorFeaturePresent(38)
        'AVX'    = [EmuNative]::IsProcessorFeaturePresent(39)
        'AVX2'   = [EmuNative]::IsProcessorFeaturePresent(40)
    }
}

$dg = Try-Get { Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard }
$F.hv = [ordered]@{
    present = [bool]$cs.HypervisorPresent
    vbs = [bool]($dg -and $dg.VirtualizationBasedSecurityStatus -eq 2)
    hvci = [bool]($dg -and (@($dg.SecurityServicesRunning) -contains 2))
    hyperVRole = [bool](Try-Get { Get-Service vmms })
    features = @{}
}
if ($F.os.isAdmin) {
    foreach ($f in 'HypervisorPlatform', 'Microsoft-Hyper-V-All', 'VirtualMachinePlatform') {
        $s = Try-Get { (Get-WindowsOptionalFeature -Online -FeatureName $f).State }
        $F.hv.features[$f] = if ($s) { "$s" } else { 'NotAvailable' }
    }
}

$F.whpx = [ordered]@{ dllPresent = $false; hypervisorPresent = $false; features = $null; partitionSetup = $false; error = '' }
$F.whpx.dllPresent = Test-Path (Join-Path $env:SystemRoot 'System32\WinHvPlatform.dll')
if ($F.whpx.dllPresent) {
    try {
        [uint64]$val = 0; [uint32]$written = 0
        $hr = [EmuWhp]::WHvGetCapability(0, [ref]$val, 8, [ref]$written)
        if ($hr -ne 0) { throw ('WHvGetCapability hr=0x{0:X8}' -f $hr) }
        $F.whpx.hypervisorPresent = ($val -band 1) -eq 1
        if ([EmuWhp]::WHvGetCapability(1, [ref]$val, 8, [ref]$written) -eq 0) { $F.whpx.features = ('0x{0:X}' -f $val) }
        if ($F.whpx.hypervisorPresent) {
            $err = [EmuWhp]::ProbePartition()
            if ($err) { $F.whpx.error = $err } else { $F.whpx.partitionSetup = $true }
        } else { $F.whpx.error = 'WHPX API present but no hypervisor running' }
    } catch { $F.whpx.error = $_.Exception.Message }
} else {
    $F.whpx.error = 'WinHvPlatform.dll missing (Windows Hypervisor Platform feature off)'
}

$aehdSvc = $null
foreach ($n in 'aehd', 'gvm') { if (-not $aehdSvc) { $aehdSvc = Try-Get { Get-Service $n } } }
$F.aehd = [ordered]@{
    installed = [bool]$aehdSvc
    running = [bool]($aehdSvc -and $aehdSvc.Status -eq 'Running')
    service = $(if ($aehdSvc) { $aehdSvc.Name } else { '' })
}

$pf = @(Try-Get { Get-CimInstance Win32_PageFileUsage })
$F.mem = [ordered]@{
    totalMB = [int][math]::Round($cs.TotalPhysicalMemory / 1MB)
    freeMB = [int][math]::Round($os.FreePhysicalMemory / 1KB)
    pagefileAuto = [bool]$cs.AutomaticManagedPagefile
    pagefileMB = [int](($pf | Where-Object { $_ } | Measure-Object -Property AllocatedBaseSize -Sum).Sum)
}

$driveRoot = [IO.Path]::GetPathRoot((Resolve-Path $PSScriptRoot).Path)
$drive = Try-Get { [IO.DriveInfo]::new($driveRoot) }
$pd = Try-Get {
    $num = (Get-Partition -DriveLetter $driveRoot.Substring(0, 1)).DiskNumber
    Get-PhysicalDisk | Where-Object { [string]$_.DeviceId -eq [string]$num } | Select-Object -First 1
}
$F.disk = [ordered]@{
    root = $driveRoot
    freeGB = $(if ($drive) { [math]::Round($drive.AvailableFreeSpace / 1GB, 1) } else { -1 })
    mediaType = $(if ($pd) { "$($pd.MediaType)" } else { 'Unknown' })
    busType = $(if ($pd) { "$($pd.BusType)" } else { 'Unknown' })
    model = $(if ($pd) { "$($pd.FriendlyName)" } else { '' })
}

$F.gpus = @()
$driverByName = @{}
foreach ($v in @(Get-CimInstance Win32_VideoController)) { $driverByName[$v.Name] = $v.DriverVersion }
foreach ($g in [EmuVideoProbe]::Probe()) {
    if ($g.Software) { continue }
    $dec = [ordered]@{}
    foreach ($c in $CodecNames) { $dec[$c] = $(if ($g.MaxHeight.ContainsKey($c)) { $g.MaxHeight[$c] } else { 0 }) }
    $F.gpus += [pscustomobject][ordered]@{
        name = $g.Adapter.Trim()
        vendorId = ('0x{0:X4}' -f $g.VendorId)
        vramMB = [int][math]::Round($g.DedicatedVideoMemory / 1MB)
        driver = $(if ($driverByName.ContainsKey($g.Adapter.Trim())) { $driverByName[$g.Adapter.Trim()] } else { '' })
        featureLevel = $g.FeatureLevel
        decode = $dec
        error = $g.Error
    }
}

$disp = [EmuNative]::PrimaryDisplay()
$F.screen = [ordered]@{ width = [int]$disp[0]; height = [int]$disp[1]; hz = [int]$disp[2] }

# ===========================================================================
# 2. SIMULATE (testing only)
# ===========================================================================
function New-SimGpu($name, $vendor, $vram, $fl, $h264, $hevc, $hevc10, $vp9, $vp910, $av1) {
    [pscustomobject][ordered]@{
        name = $name; vendorId = $vendor; vramMB = $vram; driver = '(simulated)'; featureLevel = $fl; error = ''
        decode = [ordered]@{ 'H.264' = $h264; 'HEVC Main' = $hevc; 'HEVC Main10' = $hevc10; 'VP9' = $vp9; 'VP9 10-bit' = $vp910; 'AV1' = $av1 }
    }
}
switch ($Simulate) {
    'pentium-silver' {
        $F.os.caption = 'Microsoft Windows 10 Home'; $F.os.edition = 'Core'; $F.os.displayVersion = '22H2'; $F.os.build = 19045
        $F.cpu.name = 'Intel(R) Pentium(R) Silver N5030 CPU @ 1.10GHz'; $F.cpu.vendor = 'Intel'; $F.cpu.cores = 4; $F.cpu.threads = 4
        $F.cpu.vtFirmware = $true; $F.cpu.slat = $true
        $F.cpu.isa = [ordered]@{ 'SSSE3' = $true; 'SSE4.1' = $true; 'SSE4.2' = $true; 'AVX' = $false; 'AVX2' = $false }
        $F.hv.present = $false; $F.hv.vbs = $false; $F.hv.hvci = $false; $F.hv.hyperVRole = $false
        $F.whpx = [ordered]@{ dllPresent = $false; hypervisorPresent = $false; features = $null; partitionSetup = $false; error = 'WinHvPlatform.dll missing (Windows Hypervisor Platform feature off)' }
        $F.aehd = [ordered]@{ installed = $false; running = $false; service = '' }
        $F.mem = [ordered]@{ totalMB = 3934; freeMB = 1650; pagefileAuto = $true; pagefileMB = 2816 }
        $F.disk = [ordered]@{ root = 'C:\'; freeGB = 21.4; mediaType = 'Unspecified'; busType = 'SD'; model = 'eMMC 64GB' }
        $F.gpus = @(New-SimGpu 'Intel(R) UHD Graphics 605' '0x8086' 128 0xc100 2160 2160 2160 2160 2160 0)
        $F.screen = [ordered]@{ width = 1366; height = 768; hz = 60 }
    }
    'pentium-old' {
        $F.os.caption = 'Microsoft Windows 10 Home'; $F.os.edition = 'Core'; $F.os.displayVersion = '22H2'; $F.os.build = 19045
        $F.cpu.name = 'Intel(R) Pentium(R) CPU G3220 @ 3.00GHz'; $F.cpu.vendor = 'Intel'; $F.cpu.cores = 2; $F.cpu.threads = 2
        $F.cpu.vtFirmware = $true; $F.cpu.slat = $true
        $F.cpu.isa = [ordered]@{ 'SSSE3' = $true; 'SSE4.1' = $true; 'SSE4.2' = $true; 'AVX' = $false; 'AVX2' = $false }
        $F.hv.present = $false; $F.hv.vbs = $false; $F.hv.hvci = $false; $F.hv.hyperVRole = $false
        $F.whpx = [ordered]@{ dllPresent = $false; hypervisorPresent = $false; features = $null; partitionSetup = $false; error = 'WinHvPlatform.dll missing (Windows Hypervisor Platform feature off)' }
        $F.aehd = [ordered]@{ installed = $false; running = $false; service = '' }
        $F.mem = [ordered]@{ totalMB = 4004; freeMB = 1420; pagefileAuto = $true; pagefileMB = 4096 }
        $F.disk = [ordered]@{ root = 'C:\'; freeGB = 88.0; mediaType = 'HDD'; busType = 'SATA'; model = 'WDC WD5000AAKX' }
        $F.gpus = @(New-SimGpu 'Intel(R) HD Graphics' '0x8086' 128 0xb100 1080 0 0 0 0 0)
        $F.screen = [ordered]@{ width = 1366; height = 768; hz = 60 }
    }
    'no-whpx' {
        $F.hv.present = $false; $F.hv.vbs = $false; $F.hv.hvci = $false
        $F.cpu.vtFirmware = $true; $F.cpu.slat = $true
        $F.whpx = [ordered]@{ dllPresent = $false; hypervisorPresent = $false; features = $null; partitionSetup = $false; error = 'WinHvPlatform.dll missing (Windows Hypervisor Platform feature off)' }
    }
    'bios-off' {
        $F.hv.present = $false; $F.hv.vbs = $false; $F.hv.hvci = $false
        $F.cpu.vtFirmware = $false; $F.cpu.slat = $false
        $F.whpx = [ordered]@{ dllPresent = $false; hypervisorPresent = $false; features = $null; partitionSetup = $false; error = 'no hypervisor (virtualization disabled in firmware)' }
    }
    'tiny-ram' { $F.mem.totalMB = 2048; $F.mem.freeMB = 600 }
}

# ===========================================================================
# 3. EVALUATE
# ===========================================================================
$checks = New-Object System.Collections.ArrayList
function Add-Check([string]$Area, [string]$Name, [string]$Status, [string]$Detail) {
    [void]$checks.Add([pscustomobject]@{ Area = $Area; Name = $Name; Status = $Status; Detail = $Detail })
}
function Yn($b) { if ($b) { 'yes' } else { 'no' } }

$isHome = $F.os.edition -match '^Core'
$vtName = if ($F.cpu.vendor -eq 'AMD') { 'AMD-V (SVM)' } else { 'Intel VT-x' }
$lowEndCpu = $F.cpu.name -match 'Pentium|Celeron|Atom|Athlon|A4-|A6-|E1-|E2-'
$totalGB = [math]::Round($F.mem.totalMB / 1024, 1)

# --- Windows ---
$winName = if ($F.os.build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
Add-Check 'Windows' 'Edition' 'INFO' ("{0} ({1}) {2} build {3}" -f $F.os.caption, $F.os.edition, $F.os.displayVersion, $F.os.build)
if (-not $F.os.is64) { Add-Check 'Windows' '64-bit OS' 'FAIL' 'a 64-bit Windows is required' }
else { Add-Check 'Windows' '64-bit OS' 'PASS' 'yes' }
if ($F.os.build -ge 17763) { Add-Check 'Windows' 'Supported version' 'PASS' "$winName build $($F.os.build) (needs 1809 / 17763+)" }
else { Add-Check 'Windows' 'Supported version' 'FAIL' "build $($F.os.build) is older than Windows 10 1809; update Windows" }
Add-Check 'Windows' 'Running as admin' 'INFO' $(if ($F.os.isAdmin) { 'yes' } else { 'no (not needed)' })

# --- CPU ---
$cpuClass = if ($lowEndCpu) { 'low-end class (SlightDroid target)' } else { 'above the target class' }
Add-Check 'CPU' 'Processor' 'INFO' ("{0} - {1}C/{2}T, {3}" -f $F.cpu.name, $F.cpu.cores, $F.cpu.threads, $cpuClass)
if ($F.cpu.threads -ge 2) {
    $note = if ($F.cpu.threads -le 2) { '; guest and Windows share both threads (1 vs 2 vCPU decided by benchmark)' } else { '' }
    Add-Check 'CPU' 'Logical CPUs >= 2' 'PASS' "$($F.cpu.threads)$note"
} else { Add-Check 'CPU' 'Logical CPUs >= 2' 'FAIL' "$($F.cpu.threads); at least 2 required" }

$vtOn = $F.hv.present -or $F.cpu.vtFirmware
if ($F.hv.present) {
    Add-Check 'CPU' "$vtName in firmware" 'PASS' 'on (a Windows hypervisor is running; Windows hides the CPU flags then)'
} elseif ($F.cpu.vtFirmware) {
    Add-Check 'CPU' "$vtName in firmware" 'PASS' 'on'
    if ($F.cpu.slat) { Add-Check 'CPU' 'SLAT (EPT/NPT)' 'PASS' 'present' }
    else { Add-Check 'CPU' 'SLAT (EPT/NPT)' 'FAIL' 'missing: this CPU is too old for WHPX and AEHD (Tier C, unsupported)' }
} else {
    Add-Check 'CPU' "$vtName in firmware" 'FAIL' 'off in BIOS/UEFI, or not supported by this CPU (see guide below)'
}
$isaText = ($F.cpu.isa.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, (Yn $_.Value) }) -join ' '
if ($F.cpu.isa['SSSE3'] -and $F.cpu.isa['SSE4.2']) {
    $noAvx = if (-not $F.cpu.isa['AVX']) { ' (no AVX is normal for Pentium; SlightDroid guest images must not need it)' } else { '' }
    Add-Check 'CPU' 'Guest ISA' 'PASS' "$isaText$noAvx"
} else {
    Add-Check 'CPU' 'Guest ISA' 'FAIL' "$isaText - Android x86 needs SSSE3 and SSE4.2"
}

# --- Accelerators ---
# WHPX works with both engine candidates. AEHD works only with the Android Emulator engine
# (upstream QEMU has no AEHD backend). See docs/PLAN.md, decisions 1 and 3.
$canVm = $vtOn -and ($F.hv.present -or $F.cpu.slat)
$whpxNow = [bool]$F.whpx.partitionSetup
$whpxEnableable = (-not $whpxNow) -and $canVm -and ($F.os.build -ge 17763)
$aehdNow = [bool]$F.aehd.running
$aehdInstallable = (-not $F.aehd.installed) -and $canVm -and (-not $F.hv.present)

Add-Check 'Accelerator' 'Windows hypervisor running' 'INFO' ("{0} (VBS {1}, Memory Integrity {2})" -f (Yn $F.hv.present), $(if ($F.hv.vbs) { 'on' } else { 'off' }), $(if ($F.hv.hvci) { 'on' } else { 'off' }))
if ($whpxNow) {
    Add-Check 'Accelerator' 'WHPX' 'PASS' "usable now: test partition created and set up (features $($F.whpx.features))"
} elseif ($whpxEnableable) {
    Add-Check 'Accelerator' 'WHPX' 'INFO' 'not enabled; can be enabled (Windows feature + reboot, see guide)'
} else {
    Add-Check 'Accelerator' 'WHPX' 'INFO' "not usable: $($F.whpx.error)"
}
if ($aehdNow) {
    Add-Check 'Accelerator' 'AEHD' 'PASS' "usable now: service '$($F.aehd.service)' running (Android Emulator engine only)"
} elseif ($F.aehd.installed) {
    Add-Check 'Accelerator' 'AEHD' 'WARN' "installed but not running$(if ($F.hv.present) { ': it cannot run while the Windows hypervisor is on' })"
} elseif ($aehdInstallable) {
    Add-Check 'Accelerator' 'AEHD' 'INFO' 'not installed; can be installed (no hypervisor running). Android Emulator engine only'
} else {
    $why = if ($F.hv.present) { 'the Windows hypervisor is running (VBS/Hyper-V/WHPX)' } else { 'virtualization not available' }
    Add-Check 'Accelerator' 'AEHD' 'INFO' "not possible: $why"
}
$accelNow = @(); if ($whpxNow) { $accelNow += 'whpx' }; if ($aehdNow) { $accelNow += 'aehd' }
$accelPossible = @(); if ($whpxEnableable) { $accelPossible += 'whpx' }; if ($aehdInstallable) { $accelPossible += 'aehd' }
if ($accelNow.Count) {
    Add-Check 'Accelerator' 'Usable now' 'PASS' (($accelNow | ForEach-Object { $_.ToUpper() }) -join ', ')
} elseif ($accelPossible.Count) {
    Add-Check 'Accelerator' 'Usable now' 'FAIL' ("none yet; can enable: {0} (see guide). No software-mode fallback" -f (($accelPossible | ForEach-Object { $_.ToUpper() }) -join ' or '))
} else {
    Add-Check 'Accelerator' 'Usable now' 'FAIL' 'none, and none can be enabled until virtualization works (see guide)'
}

# --- Memory ---
if ($F.mem.totalMB -ge 5800) {
    Add-Check 'Memory' 'Host RAM' 'PASS' "$totalGB GB: Lite or Standard profile"
} elseif ($F.mem.totalMB -ge 3500) {
    Add-Check 'Memory' 'Host RAM' 'PASS' "$totalGB GB: Lite profile (the target class)"
} else {
    Add-Check 'Memory' 'Host RAM' 'FAIL' "$totalGB GB; at least 4 GB required"
}
$needMB = 1024 + $GuestOverheadMB
if ($F.mem.freeMB -ge $needMB) {
    Add-Check 'Memory' 'Free RAM now' 'PASS' ("{0} MB free (Lite needs ~{1} MB at peak, ~850 MB at idle)" -f $F.mem.freeMB, $needMB)
} else {
    Add-Check 'Memory' 'Free RAM now' 'WARN' ("{0} MB free; Lite needs ~{1} MB at peak. Close other apps or Windows will page to disk" -f $F.mem.freeMB, $needMB)
}
if ($F.mem.pagefileMB -gt 0 -or $F.mem.pagefileAuto) {
    Add-Check 'Memory' 'Pagefile' 'PASS' ("{0}{1}" -f $(if ($F.mem.pagefileAuto) { 'system managed' } else { 'fixed' }), $(if ($F.mem.pagefileMB) { ", $($F.mem.pagefileMB) MB now" } else { '' }))
} else {
    $st = if ($F.mem.totalMB -lt 8000) { 'WARN' } else { 'INFO' }
    Add-Check 'Memory' 'Pagefile' $st 'disabled; on a 4 GB PC the VM may fail to reserve memory. Enable a system-managed pagefile'
}

# --- Disk ---
$media = if ($F.disk.busType -in 'SD', 'MMC') { 'eMMC/SD' } elseif ($F.disk.mediaType -in 'SSD', 'HDD') { $F.disk.mediaType } else { 'unknown' }
$bootBudget = switch ($media) { 'SSD' { 'cold <= 40 s, snapshot <= 10 s' } 'HDD' { 'cold <= 70 s, snapshot <= 15 s (HDD is the slowest case)' } default { 'between SSD and HDD' } }
Add-Check 'Disk' "Type of $($F.disk.root)" 'INFO' ("{0} ({1}{2}) - boot budget: {3}" -f $media, $F.disk.busType, $(if ($F.disk.model) { ", $($F.disk.model)" }), $bootBudget)
$st = if ($F.disk.freeGB -ge 8) { 'PASS' } elseif ($F.disk.freeGB -ge 5) { 'WARN' } else { 'FAIL' }
Add-Check 'Disk' "Free space on $($F.disk.root)" $st "$($F.disk.freeGB) GB (Lite needs ~5 GB incl. overlay and snapshot)"

# --- GPU and video ---
function Get-FlText([int]$fl) { if ($fl -le 0) { 'none' } else { '{0}_{1}' -f (($fl -shr 12) -band 0xF), (($fl -shr 8) -band 0xF) } }
# SlightDroid renders and decodes on the integrated GPU (lowest dedicated VRAM) so hybrid laptops
# don't wake a discrete GPU. On the target class there is only one GPU anyway.
$gpu = $F.gpus | Where-Object { -not $_.error -and $_.featureLevel -gt 0 } | Sort-Object vramMB | Select-Object -First 1
foreach ($g in $F.gpus) {
    $dec = ($g.decode.GetEnumerator() | ForEach-Object { '{0}:{1}' -f $_.Key, $(switch ($_.Value) { 2160 { '4K' } 1080 { '1080p' } default { '-' } }) }) -join ' '
    $mark = if ($gpu -and $g.name -eq $gpu.name) { ' [SlightDroid uses this]' } else { '' }
    Add-Check 'GPU' $g.name 'INFO' ("D3D FL {0}, {1} MB VRAM{2}; HW decode {3}" -f (Get-FlText $g.featureLevel), $g.vramMB, $mark, $dec)
}
if (-not $gpu) {
    Add-Check 'GPU' 'Direct3D 11 GPU' 'WARN' 'no hardware D3D11 GPU: software rendering only, 720p, no hardware video decode'
} elseif ($gpu.featureLevel -ge 0xb000) {
    Add-Check 'GPU' 'Direct3D 11 GPU' 'PASS' "$($gpu.name), feature level $(Get-FlText $gpu.featureLevel) (ANGLE GLES 3.0)"
} else {
    Add-Check 'GPU' 'Direct3D 11 GPU' 'WARN' "$($gpu.name), feature level $(Get-FlText $gpu.featureLevel): limited GLES, 720p low-resource mode"
}

$hw1080 = @(); $hw4k = @()
if ($gpu) {
    foreach ($kv in $gpu.decode.GetEnumerator()) {
        if ($kv.Value -ge 1080) { $hw1080 += $kv.Key }
        if ($kv.Value -ge 2160) { $hw4k += $kv.Key }
    }
}
if ($hw1080 -contains 'H.264') {
    Add-Check 'Video' '1080p playback' 'PASS' ("hardware decode: {0}" -f ($hw1080 -join ', '))
} else {
    Add-Check 'Video' '1080p playback' 'WARN' 'no H.264 hardware decode: software decode on the host, 720p recommended'
}
if ($hw4k.Count) {
    $no4k = @($CodecNames | Where-Object { $hw4k -notcontains $_ })
    $missing = if ($no4k.Count) { "; not in 4K: $($no4k -join ', ') (reported to the user)" } else { '' }
    Add-Check 'Video' '4K playback' 'PASS' ("hardware decode: {0}{1}" -f ($hw4k -join ', '), $missing)
} else {
    Add-Check 'Video' '4K playback' 'INFO' 'not possible on this GPU: no 4K hardware decoder. SlightDroid will say so instead of stuttering'
}
$videoTier = if ($hw4k -contains 'HEVC Main' -or $hw4k -contains 'VP9') { 'A' } elseif ($hw1080 -contains 'H.264') { 'B' } else { 'software' }

Add-Check 'Display' 'Primary screen' 'INFO' ("{0}x{1} @ {2} Hz" -f $F.screen.width, $F.screen.height, $F.screen.hz)

# ===========================================================================
# 4. RECOMMEND
# ===========================================================================
if ($F.mem.totalMB -ge 5800) {
    $profile = 'Standard'; $guestRam = $(if ($F.mem.totalMB -ge 7800) { 2048 } else { 1536 })
    $profileWhy = "Android 13 x86_64, $guestRam MB guest RAM (Lite also available)"
} else {
    $profile = 'Lite'; $guestRam = 1024
    $profileWhy = 'Android 11 Go, 1024 MB guest RAM'
}
$lowRes = ($videoTier -ne 'A') -or (-not $gpu) -or ($gpu.featureLevel -lt 0xb000) -or ($F.screen.height -gt 0 -and $F.screen.height -le 800)
$resolution = if ($lowRes) { '1280x720 (low-resource mode)' } else { '1920x1080' }
$guestCpus = 2

# ===========================================================================
# 5. OUTPUT
# ===========================================================================
$fails = @($checks | Where-Object Status -eq 'FAIL').Count
$warns = @($checks | Where-Object Status -eq 'WARN').Count
$overall = if ($fails) { 'BLOCKED' } elseif ($warns) { 'READY (with warnings)' } else { 'READY' }
$exitCode = if ($fails) { 2 } elseif ($warns) { 1 } else { 0 }

$colors = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }
Write-Host ''
Write-Host "SlightDroid environment check v$ToolVersion   $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
if ($Simulate) { Write-Host "*** SIMULATION: $Simulate - these are NOT this PC's real results ***" -ForegroundColor Magenta }
Write-Host ('=' * 78)
$lastArea = ''
foreach ($c in $checks) {
    if ($c.Area -ne $lastArea) { Write-Host ''; Write-Host "[$($c.Area)]" -ForegroundColor Cyan; $lastArea = $c.Area }
    Write-Host ('  {0,-5} ' -f $c.Status) -ForegroundColor $colors[$c.Status] -NoNewline
    Write-Host ('{0,-28} {1}' -f $c.Name, $c.Detail)
}
Write-Host ''
Write-Host ('=' * 78)
Write-Host ("Overall:      {0}  ({1} fail, {2} warn)" -f $overall, $fails, $warns) -ForegroundColor $(if ($fails) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' })
$accText = if ($accelNow.Count) { ($accelNow | ForEach-Object { $_.ToUpper() }) -join ', ' } else { 'none enabled' }
if ($accelPossible.Count) { $accText += "  (can enable: $(($accelPossible | ForEach-Object { $_.ToUpper() }) -join ', '))" }
Write-Host ("Accelerators: {0}" -f $accText)
Write-Host ("Profile:      {0} - {1}" -f $profile, $profileWhy)
Write-Host ("Guest:        {0} vCPUs, {1}" -f $guestCpus, $resolution)
Write-Host ("Video tier:   {0}" -f $(switch ($videoTier) { 'A' { 'A - 1080p and 4K in hardware' } 'B' { 'B - 1080p H.264 in hardware, no 4K' } default { 'software decode only (720p recommended)' } }))
Write-Host ("Host class:   {0}" -f $(if ($lowEndCpu -or $F.mem.totalMB -lt 5800) { 'low-end (SlightDroid target)' } else { 'above target - benchmarks here are NOT representative' }))

$guide = @()
if (-not $accelNow.Count) {
    if (-not $vtOn) {
        $guide += "Virtualization ($vtName) is OFF in BIOS/UEFI, or this CPU lacks it. To turn it on:"
        $guide += '  1. Restart into firmware setup: press F2, F10, Del or Esc at power-on, or use'
        $guide += '     Settings > System > Recovery > Advanced startup > UEFI Firmware Settings.'
        if ($F.cpu.vendor -eq 'AMD') { $guide += '  2. Set "SVM Mode" / "AMD-V" to Enabled (often under Advanced > CPU Configuration).' }
        else { $guide += '  2. Set "Intel Virtualization Technology" / "VT-x" to Enabled (Advanced > CPU Configuration).' }
        $guide += '  3. Save and exit (usually F10), then run this check again.'
        $guide += '  If the option does not exist, the CPU is too old for SlightDroid.'
    } elseif ($accelPossible.Count) {
        $guide += 'Virtualization is on, but no accelerator is enabled yet. Pick one:'
        if ($accelPossible -contains 'whpx') {
            $guide += '  WHPX: in an admin PowerShell, then reboot:'
            $guide += '    Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All'
        }
        if ($accelPossible -contains 'aehd') {
            $guide += '  AEHD: install Google''s Android Emulator Hypervisor Driver (one-time, needs admin).'
            $guide += '    Works only while no Windows hypervisor (Hyper-V, VBS, WHPX) is running.'
        }
        $guide += '  Which is faster on low-end PCs is being measured (docs/PLAN.md, decision 3).'
    }
}
if ($guide.Count) {
    Write-Host ''
    Write-Host 'What to do:' -ForegroundColor Yellow
    $guide | ForEach-Object { Write-Host $_ }
}
Write-Host ''

if ($Json) {
    $result = [ordered]@{
        tool = 'SlightDroid-envcheck'; version = $ToolVersion; timestamp = (Get-Date).ToString('o'); simulate = $Simulate
        overall = $overall; exitCode = $exitCode
        accelerators = [ordered]@{ usable = $accelNow; enableable = $accelPossible }
        profile = $profile; guestRamMB = $guestRam; guestCpus = $guestCpus; resolution = $resolution
        videoTier = $videoTier; hwDecode1080 = $hw1080; hwDecode4K = $hw4k
        renderGpu = $(if ($gpu) { $gpu.name } else { $null })
        lowEndHost = [bool]($lowEndCpu -or $F.mem.totalMB -lt 5800)
        facts = $F; checks = $checks; guide = $guide
    }
    $full = [IO.Path]::GetFullPath($Json)
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $result | ConvertTo-Json -Depth 8 | Out-File -FilePath $full -Encoding utf8
    Write-Host "JSON written to $full"
}

if ($Decision) {
    # Installer mode: one decision as the exit code (and the word on stdout).
    #   0 READY        an accelerator is usable and nothing else blocks
    #  10 ENABLE_WHPX  only blocker: WHPX not enabled yet, and it can be (Setup offers to enable + restart)
    #  20 BIOS         virtualization is off in firmware (Setup shows the BIOS guide)
    #  30 UNSUPPORTED  something else blocks (RAM, 32-bit Windows, CPU features, old Windows)
    $otherFails = @($checks | Where-Object { $_.Status -eq 'FAIL' -and $_.Name -ne 'Usable now' -and $_.Name -notlike "*in firmware" })
    if ($otherFails.Count) { $d = 30; $word = 'UNSUPPORTED: ' + (($otherFails | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; ') }
    elseif (-not $vtOn) { $d = 20; $word = 'BIOS' }
    elseif ($accelNow.Count) { $d = 0; $word = 'READY' }
    elseif ($accelPossible -contains 'whpx') { $d = 10; $word = 'ENABLE_WHPX' }
    else { $d = 30; $word = 'UNSUPPORTED: no usable accelerator' }
    [Console]::Out.WriteLine($word)
    exit $d
}
exit $exitCode
