<#
  Generates the SlightDroid icon and installer/doc assets from logo.png (System.Drawing only):
    launcher\SlightDroid.ico     16/20/24/32/40/48/64/128 (32-bit DIB) + 256 (PNG)  -> exe, tray, windows
    installer\SlightDroid.ico    same file                                          -> Setup / Uninstall
    installer\wizard.bmp         164x314 welcome/finish side image for Setup
    docs\logo.png, docs\logo-wordmark.png                                           -> README
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$srcLogo = Join-Path $root 'logo.png'
if (-not (Test-Path $srcLogo)) { throw "missing $srcLogo" }
$srcImg = [Drawing.Image]::FromFile($srcLogo)

function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}

function New-LogoBitmap([int]$s) {
    $b = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($b)
    $g.Clear([Drawing.Color]::Transparent)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    $clip = RoundRect 0 0 $s $s ($s * 0.16)
    $g.SetClip($clip)
    $g.DrawImage($srcImg, 0, 0, $s, $s)
    $g.ResetClip()
    $clip.Dispose()
    $g.Dispose()
    return $b
}

# ICO entry as a 32-bit DIB (BITMAPINFOHEADER + bottom-up BGRA + AND mask): readable by every
# Windows tool, csc /win32icon and System.Drawing.Icon.
function DibBytes([Drawing.Bitmap]$b) {
    $s = $b.Width; $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2)); $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    for ($y = $s - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $s; $x++) { $c = $b.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) } }
    $stride = [int]([Math]::Ceiling($s / 32.0) * 4)
    $w.Write((New-Object byte[] ($stride * $s)))                     # AND mask: all 0 (alpha decides)
    $w.Flush(); return $ms.ToArray()
}

function Write-Ico([string]$path, [int[]]$sizes) {
    $imgs = foreach ($s in $sizes) {
        $b = New-LogoBitmap $s
        if ($s -ge 256) { $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() } else { , (DibBytes $b) }
        $b.Dispose()
    }
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
    $off = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $d = $imgs[$i]
        $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s }))); $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
        $w.Write([byte]0); $w.Write([byte]0); $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$d.Length); $w.Write([int]$off)
        $off += $d.Length
    }
    foreach ($d in $imgs) { $w.Write([byte[]]$d, 0, $d.Length) }
    $w.Flush(); [IO.File]::WriteAllBytes($path, $ms.ToArray())
}

New-Item -ItemType Directory -Force "$root\docs", "$root\installer", "$root\launcher" | Out-Null
Write-Ico "$root\launcher\SlightDroid.ico" @(16, 20, 24, 32, 40, 48, 64, 128, 256)
Copy-Item "$root\launcher\SlightDroid.ico" "$root\installer\SlightDroid.ico" -Force

Copy-Item $srcLogo "$root\docs\logo.png" -Force
Copy-Item $srcLogo "$root\docs\logo-wordmark.png" -Force

# NSIS welcome/finish image: 164x314, 24-bit BMP
$wz = New-Object Drawing.Bitmap(164, 314, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [Drawing.Graphics]::FromImage($wz)
$g.SmoothingMode = 'AntiAlias'
$g.InterpolationMode = 'HighQualityBicubic'
$g.PixelOffsetMode = 'HighQuality'
$c1 = [Drawing.Color]::FromArgb(10, 18, 28)
$c2 = [Drawing.Color]::FromArgb(12, 48, 44)
$bg = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.Point(0, 0)), (New-Object Drawing.Point(164, 314)), $c1, $c2)
$g.FillRectangle($bg, 0, 0, 164, 314)
$clip = RoundRect 22 48 120 120 (120 * 0.16)
$g.SetClip($clip)
$g.DrawImage($srcImg, 22, 48, 120, 120)
$g.ResetClip()
$clip.Dispose()
$g.TextRenderingHint = 'AntiAliasGridFit'
$f2 = New-Object Drawing.Font('Segoe UI Semibold', 23, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'
$g.DrawString('SlightDroid', $f2, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 186, 164, 36)), $sf)
$f3 = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$g.DrawString("Android apps on`nlow-end PCs", $f3, (New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(220, 240, 245))), (New-Object Drawing.RectangleF(0, 224, 164, 40)), $sf)
$g.Dispose(); $wz.Save("$root\installer\wizard.bmp", [Drawing.Imaging.ImageFormat]::Bmp); $wz.Dispose()
$srcImg.Dispose()

Get-Item "$root\launcher\SlightDroid.ico", "$root\installer\SlightDroid.ico", "$root\installer\wizard.bmp", "$root\docs\logo.png", "$root\docs\logo-wordmark.png" | Select-Object Name, Length
