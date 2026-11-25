<#
.SYNOPSIS
  Downloads and verifies SlightDroid's pinned third-party inputs (tools/fetch/deps.json).

.DESCRIPTION
  Segmented download, like a download manager: each file is split into byte ranges that
  are fetched in parallel by separate curl.exe processes. A package may list several
  mirror URLs ("mirrors"), and the segments are spread across them. A segment that
  stalls or fails is retried from where it stopped. When all segments are complete they
  are joined and the file is verified (size + sha512/sha256/sha1).

  Layout: downloads/<id>/<file>, with segments in downloads/<id>/<file>.seg<N> while running.
  Already-verified files are skipped. A file that fails verification is renamed *.bad.
  Nothing is installed or executed besides curl.exe, which ships with Windows 10/11.

.PARAMETER Only
  Comma-separated package ids (default: everything the current build needs).
.PARAMETER All
  Also fetch packages marked legacy (earlier QEMU engine, test inputs).
.PARAMETER Segments
  Parallel connections per file (default 8).
#>
param([string]$Only = '', [int]$Segments = 8, [switch]$All)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$manifest = Get-Content -Raw (Join-Path $PSScriptRoot 'deps.json') | ConvertFrom-Json
$want = if ($Only) { $Only.Split(',') | ForEach-Object { $_.Trim() } } else { @() }
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$MinSegment = 4MB          # don't split small files into tiny pieces
$StallSeconds = 30         # restart a segment that hasn't grown for this long

function Get-Hash($path, $algo) { (Get-FileHash -Algorithm $algo -Path $path).Hash.ToLowerInvariant() }

function Test-Package($pkg, $path) {
    foreach ($algo in 'sha512', 'sha256', 'sha1') {
        if ($pkg.PSObject.Properties[$algo] -and $pkg.$algo) {
            $h = Get-Hash $path $algo
            return [pscustomobject]@{ Ok = ($h -eq $pkg.$algo.ToLowerInvariant()); Algo = $algo; Hash = $h }
        }
    }
    return [pscustomobject]@{ Ok = $true; Algo = 'sha256 (unpinned, first seen)'; Hash = (Get-Hash $path 'sha256') }
}

# Size and range support, asked from the server with a 1-byte range request.
function Get-RemoteInfo([string]$url) {
    $hdr = & $curl -s -L --max-time 30 -r 0-0 -D - -o NUL $url
    $range = $hdr | Select-String -Pattern '^content-range:\s*bytes 0-0/(\d+)' | Select-Object -Last 1
    if ($range) { return @{ Size = [int64]$range.Matches[0].Groups[1].Value; Ranges = $true } }
    $len = $hdr | Select-String -Pattern '^content-length:\s*(\d+)' | Select-Object -Last 1
    return @{ Size = $(if ($len) { [int64]$len.Matches[0].Groups[1].Value } else { 0 }); Ranges = $false }
}

# Real length, also for files another process is still writing. (Get-Item reads the directory
# entry, which NTFS doesn't update while a writer keeps the file open, so it shows 0.)
function Get-Len([string]$p) {
    if (-not (Test-Path $p)) { return 0 }
    try { $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite,Delete'); try { $fs.Length } finally { $fs.Dispose() } }
    catch { (Get-Item $p).Length }
}

function Merge-Tmp($s) {
    if (Test-Path $s.Tmp) {
        $fs = [IO.File]::Open($s.File, 'Append', 'Write')
        try { $in = [IO.File]::OpenRead($s.Tmp); try { $in.CopyTo($fs) } finally { $in.Dispose() } } finally { $fs.Dispose() }
        Remove-Item $s.Tmp
    }
}

function Join-Segments([string[]]$parts, [string]$dest) {
    $out = [IO.File]::Open($dest, 'Create', 'Write')
    try {
        foreach ($p in $parts) {
            $in = [IO.File]::OpenRead($p)
            try { $in.CopyTo($out, 4MB) } finally { $in.Dispose() }
        }
    } finally { $out.Dispose() }
}

function Invoke-SegmentedDownload($pkg, [string]$out) {
    $urls = @($pkg.url)
    if ($pkg.PSObject.Properties['mirrors'] -and $pkg.mirrors) { $urls = @($pkg.mirrors) + $urls }

    $info = Get-RemoteInfo $urls[0]
    $size = if ($pkg.PSObject.Properties['size'] -and $pkg.size) { [int64]$pkg.size } else { $info.Size }
    if (-not $info.Ranges -or $size -le 0) {
        Write-Host "       no range support or unknown size: single connection"
        & $curl -L --fail --retry 5 -s -S -o $out $urls[0]
        return ($LASTEXITCODE -eq 0)
    }

    $segN = if ($pkg.PSObject.Properties['segments'] -and $pkg.segments) { [int]$pkg.segments } else { $Segments }
    $n = [int][math]::Max(1, [math]::Min($segN, [math]::Floor($size / $MinSegment)))
    $chunk = [int64][math]::Ceiling($size / $n)
    $segs = @()
    for ($i = 0; $i -lt $n; $i++) {
        $a = $i * $chunk; $b = [math]::Min($size, $a + $chunk) - 1
        $segs += [pscustomobject]@{
            Index = $i; Start = $a; End = $b; File = "$out.seg$i"; Url = $urls[$i % $urls.Count]
            Proc = $null; Tmp = "$out.seg$i.tmp"; LastLen = -1; LastGrow = Get-Date; Tries = 0
        }
    }
    # resume: keep bytes from an interrupted earlier run
    foreach ($s in $segs) {
        Merge-Tmp $s
        $need = $s.End - $s.Start + 1
        if ((Get-Len $s.File) -gt $need) { Remove-Item $s.File }   # layout changed since last run
    }
    $resumed = ($segs | ForEach-Object { Get-Len $_.File } | Measure-Object -Sum).Sum
    Write-Host ("       {0:N1} MB in {1} segments over {2} source(s){3}" -f ($size / 1MB), $n, $urls.Count, $(if ($resumed) { (", resuming with {0:N1} MB" -f ($resumed / 1MB)) }))

    while ($true) {
        $allDone = $true
        foreach ($s in $segs) {
            $need = $s.End - $s.Start + 1
            # fold a finished attempt's .tmp into the segment file
            if ($s.Proc -and $s.Proc.HasExited) { Merge-Tmp $s; $s.Proc = $null }
            $have = Get-Len $s.File
            if ($have -gt $need) { throw "segment $($s.Index) of $($pkg.id) is larger than its range" }
            if ($have -eq $need) { continue }
            $allDone = $false

            if (-not $s.Proc) {
                if ($s.Tries -ge 20) { throw "segment $($s.Index) of $($pkg.id) failed 20 times" }
                $s.Tries++
                # after a failure, try the next source for this segment
                if ($s.Tries -gt 1 -and $urls.Count -gt 1) { $s.Url = $urls[($s.Index + $s.Tries) % $urls.Count] }
                $from = $s.Start + $have
                $cargs = @('-L', '--fail', '-s', '-r', "$from-$($s.End)", '-o', "`"$($s.Tmp)`"", "`"$($s.Url)`"")
                $s.Proc = Start-Process -FilePath $curl -ArgumentList $cargs -NoNewWindow -PassThru
                $s.LastLen = -1; $s.LastGrow = Get-Date
            } else {
                # stall watchdog
                $cur = (Get-Len $s.Tmp)
                if ($cur -ne $s.LastLen) { $s.LastLen = $cur; $s.LastGrow = Get-Date }
                elseif (((Get-Date) - $s.LastGrow).TotalSeconds -gt $StallSeconds) {
                    try { $s.Proc.Kill() } catch {}
                }
            }
        }
        if ($allDone) { break }
        Start-Sleep -Milliseconds 500
    }
    Join-Segments ($segs | ForEach-Object { $_.File }) $out
    $segs | ForEach-Object { Remove-Item $_.File }
    return $true
}

$failed = 0
foreach ($pkg in $manifest.packages) {
    if ($want.Count -and $want -notcontains $pkg.id) { continue }
    if (-not $want.Count -and -not $All -and $pkg.PSObject.Properties['legacy'] -and $pkg.legacy) { continue }
    $dir = Join-Path $root "downloads\$($pkg.id)"
    $out = Join-Path $dir $pkg.file
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (Test-Path $out) {
        $v = Test-Package $pkg $out
        if ($v.Ok) { Write-Host ("[skip] {0,-22} already verified ({1})" -f $pkg.id, $v.Algo); continue }
        Write-Host "[redo] $($pkg.id): existing file does not verify"
        Remove-Item $out
    }
    Remove-Item "$out.part" -ErrorAction SilentlyContinue   # leftover from the old single-connection fetcher

    Write-Host ("[get ] {0,-22} {1}" -f $pkg.id, $pkg.file)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $ok = Invoke-SegmentedDownload $pkg $out } catch { Write-Host "[FAIL] $($pkg.id): $_"; $failed++; continue }
    if (-not $ok) { Write-Host "[FAIL] $($pkg.id): download failed"; $failed++; continue }

    $len = (Get-Item $out).Length
    if ($pkg.PSObject.Properties['size'] -and $pkg.size -and $len -ne [int64]$pkg.size) {
        Write-Host "[FAIL] $($pkg.id): size $len, expected $($pkg.size)"; Move-Item -Force $out "$out.bad"; $failed++; continue
    }
    $v = Test-Package $pkg $out
    if (-not $v.Ok) { Write-Host "[FAIL] $($pkg.id): $($v.Algo) mismatch ($($v.Hash))"; Move-Item -Force $out "$out.bad"; $failed++; continue }
    Write-Host ("[ ok ] {0,-22} {1:N1} MB in {2:N0} s ({3:N1} MB/s), {4} verified" -f $pkg.id, ($len / 1MB), $sw.Elapsed.TotalSeconds, ($len / 1MB / [math]::Max(1, $sw.Elapsed.TotalSeconds)), $v.Algo)
}

if ($failed) { Write-Host "$failed package(s) failed"; exit 1 }
Write-Host 'All requested packages downloaded and verified.'
