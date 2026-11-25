<#
  Shows a live progress window for fetch-deps.ps1: one bar for the whole set and one for
  the file being downloaded. Read-only: it only looks at file sizes in downloads/.
  Closes itself when every package is present.
#>
$ErrorActionPreference = 'SilentlyContinue'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$deps = (Get-Content -Raw (Join-Path $PSScriptRoot 'deps.json') | ConvertFrom-Json).packages
$Host.UI.RawUI.WindowTitle = 'SlightDroid - downloading packages'

# Expected sizes: pinned in deps.json, otherwise asked from the server once (HEAD request).
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
foreach ($p in $deps) {
    if (-not ($p.PSObject.Properties['size'] -and $p.size)) {
        $len = (& $curl -sIL --max-time 20 $p.url | Select-String -Pattern '^content-length:\s*(\d+)' | Select-Object -Last 1)
        $size = if ($len) { [int64]$len.Matches[0].Groups[1].Value } else { 0 }
        $p | Add-Member -Force NoteProperty size $size
    }
}
$total = ($deps | Measure-Object -Property size -Sum).Sum
$start = Get-Date; $firstBytes = $null

while ($true) {
    $done = [int64]0; $current = $null; $finished = 0
    foreach ($p in $deps) {
        $f = Join-Path $root "downloads\$($p.id)\$($p.file)"
        if (Test-Path $f) { $done += (Get-Item $f).Length; $finished++; continue }
        # segmented download: <file>.seg<N> plus in-flight <file>.seg<N>.tmp
        $segFiles = @(Get-ChildItem -Path (Split-Path $f) -Filter "$($p.file).seg*" -File)
        if ($segFiles.Count) {
            # open each file to get its real size (NTFS shows 0 for files still being written)
            $b = [int64]0
            foreach ($sf in $segFiles) {
                try { $fs = [IO.File]::Open($sf.FullName, 'Open', 'Read', 'ReadWrite,Delete'); $b += $fs.Length; $fs.Dispose() } catch { $b += $sf.Length }
            }
            $done += $b
            $conns = @($segFiles | Where-Object Name -like '*.tmp').Count
            $current = @{ p = $p; b = $b; c = $conns }
        }
    }
    if ($null -eq $firstBytes) { $firstBytes = $done }
    $secs = [math]::Max(1, ((Get-Date) - $start).TotalSeconds)
    $rate = ($done - $firstBytes) / $secs
    $eta = if ($rate -gt 0) { [int](($total - $done) / $rate) } else { -1 }
    $pct = if ($total) { [math]::Min(100, [int](100 * $done / $total)) } else { 0 }

    Write-Progress -Id 1 -Activity "SlightDroid packages: $finished of $($deps.Count) done" `
        -Status ("{0:N0} / {1:N0} MB  ({2}%)  {3:N1} MB/s" -f ($done / 1MB), ($total / 1MB), $pct, ($rate / 1MB)) `
        -PercentComplete $pct -SecondsRemaining $eta
    if ($current) {
        $cp = if ($current.p.size) { [math]::Min(100, [int](100 * $current.b / $current.p.size)) } else { 0 }
        Write-Progress -Id 2 -ParentId 1 -Activity "Downloading $($current.p.file)" `
            -Status ("{0:N0} / {1:N0} MB   {2} parallel segments" -f ($current.b / 1MB), ($current.p.size / 1MB), $current.c) -PercentComplete $cp
    } else {
        Write-Progress -Id 2 -ParentId 1 -Activity 'Verifying checksum...' -Status ' ' -PercentComplete 100
    }
    if ($finished -eq $deps.Count) { break }
    Start-Sleep -Seconds 1
}
Write-Progress -Id 2 -Activity ' ' -Completed
Write-Progress -Id 1 -Activity ' ' -Completed
Write-Host ''
Write-Host "  All $($deps.Count) packages downloaded ($([int]($total / 1MB)) MB). This window closes in 15 s." -ForegroundColor Green
Start-Sleep -Seconds 15
