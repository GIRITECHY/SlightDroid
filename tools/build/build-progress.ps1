<#
  Progress window for an installer build. makensis reports no percentage and writes the installer file only
  at the very end, so progress is the elapsed time measured against the previous build's duration
  (<installer>.lastsecs, default 21 minutes), shown with elapsed time and ETA. Closes itself when makensis
  finishes and remembers this build's duration for next time. Read-only otherwise.
#>
param([string]$Out = (Join-Path $PSScriptRoot '..\..\dist\SlightDroid-Setup-0.1.0-alpha.exe'), [double]$ExpectedSeconds = 0)
$Host.UI.RawUI.WindowTitle = 'SlightDroid - installer build progress'
$secsFile = "$Out.lastsecs"
if ($ExpectedSeconds -le 0) { $ExpectedSeconds = if (Test-Path $secsFile) { [double](Get-Content $secsFile) } else { 1260 } }
for ($i = 0; $i -lt 30 -and -not (Get-Process makensis -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
$start = (Get-Process makensis -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1).StartTime
if (-not $start) { $start = Get-Date }
while (Get-Process makensis -ErrorAction SilentlyContinue) {
    $el = ((Get-Date) - $start).TotalSeconds
    $pct = [math]::Min(99, [int](100 * $el / $ExpectedSeconds))
    $eta = [int][math]::Max(30, $ExpectedSeconds - $el)
    Write-Progress -Activity 'Building SlightDroid-Setup.exe (compressing Android 11 + engine)' `
        -Status ("{0}%  -  elapsed {1}:{2:D2}  -  previous build took {3}:{4:D2}" -f $pct, [int]($el / 60), ([int]$el % 60), [int]($ExpectedSeconds / 60), ([int]$ExpectedSeconds % 60)) `
        -PercentComplete $pct -SecondsRemaining $eta
    Start-Sleep -Seconds 2
}
Write-Progress -Activity 'done' -Completed
$took = ((Get-Date) - $start).TotalSeconds
if ((Test-Path $Out) -and (Get-Item $Out).LastWriteTime -gt $start) {
    Set-Content $secsFile ([int]$took)
    Write-Host ("`n  Installer build finished in {0}:{1:D2}: {2:N0} MB. This window closes in 15 s." -f [int]($took / 60), ([int]$took % 60), ((Get-Item $Out).Length / 1MB)) -ForegroundColor Green
} else {
    Write-Host "`n  makensis stopped without writing a new installer (see the build window)." -ForegroundColor Yellow
}
Start-Sleep -Seconds 15
