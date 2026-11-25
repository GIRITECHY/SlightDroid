<#
  Dev helper: runs a shell command in the guest over the serial root console started by
  run-lite.ps1 -Console, and prints its output.
#>
param([Parameter(Mandatory)][string]$Cmd, [int]$Port = 45561, [int]$TimeoutSec = 60)
$c = New-Object Net.Sockets.TcpClient('127.0.0.1', $Port)
$s = $c.GetStream(); $buf = New-Object byte[] 65536
$mark = "__END_$([guid]::NewGuid().ToString('N').Substring(0, 8))__"
$b = [Text.Encoding]::ASCII.GetBytes("`n$Cmd; echo $mark`n"); $s.Write($b, 0, $b.Length)
$sb = New-Object Text.StringBuilder; $deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    while ($s.DataAvailable) { $n = $s.Read($buf, 0, $buf.Length); [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n)) }
    $t = $sb.ToString()
    # the echo of our own command line also contains the marker; wait for it on its own line
    if ($t -match "(?m)^$mark\r?$") { break }
    Start-Sleep -Milliseconds 100
}
$c.Close()
$out = $sb.ToString() -replace "\x1b\[[0-9;]*[A-Za-z]", ''
$lines = $out -split "\r?\n" | Where-Object { $_ -notmatch [regex]::Escape($mark) }
$lines -join "`n"
