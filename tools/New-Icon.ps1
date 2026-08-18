#Requires -Version 5.1
<#
.SYNOPSIS
    Generate the launcher icon.

.DESCRIPTION
    Draws a download-tray glyph at several sizes and assembles them into a multi-resolution .ico.
    Kept as a script rather than a checked-in binary blob alone, so the design is editable and the
    icon is reproducible.

    Windows has accepted PNG-compressed icon entries since Vista, which avoids hand-rolling DIBs
    with AND masks.

.EXAMPLE
    .\tools\New-Icon.ps1
#>
[CmdletBinding()]
param(
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'App\Launcher\PortableSideloader.ico'),
    [int[]]  $Sizes      = @(16, 24, 32, 48, 64, 128, 256)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-IconBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    $u = $Size / 32.0   # design on a 32x32 grid, then scale

    $slate  = [System.Drawing.Color]::FromArgb(255, 42, 52, 66)
    $accent = [System.Drawing.Color]::FromArgb(255, 74, 176, 122)

    # Tray: an open-topped container, drawn as three strokes so it reads at 16px.
    $penWidth = [Math]::Max(2.75 * $u, 2.0)
    $pen = New-Object System.Drawing.Pen($slate, $penWidth)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $left   = 4 * $u
    $right  = 28 * $u
    $top    = 20 * $u
    $bottom = 28 * $u

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddLine($left, $top, $left, $bottom)
    $path.AddLine($left, $bottom, $right, $bottom)
    $path.AddLine($right, $bottom, $right, $top)
    $g.DrawPath($pen, $path)
    $path.Dispose()

    # Arrow descending into the tray.
    $brush = New-Object System.Drawing.SolidBrush($accent)
    $shaftW = 5 * $u
    $cx = 16 * $u
    $g.FillRectangle($brush, ($cx - $shaftW / 2), (3 * $u), $shaftW, (10 * $u))

    # AddPolygon needs a typed array; a plain PowerShell Object[] fails to bind.
    $head = New-Object System.Drawing.Drawing2D.GraphicsPath
    $points = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF([single]($cx - 8 * $u), [single](12 * $u))),
        (New-Object System.Drawing.PointF([single]($cx + 8 * $u), [single](12 * $u))),
        (New-Object System.Drawing.PointF([single]$cx, [single](22 * $u)))
    )
    $head.AddPolygon($points)
    $g.FillPath($brush, $head)
    $head.Dispose()

    $brush.Dispose(); $pen.Dispose(); $g.Dispose()
    return $bmp
}

$pngs = @()
foreach ($size in $Sizes) {
    $bmp = New-IconBitmap -Size $size
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , @{ Size = $size; Bytes = $ms.ToArray() }
    $ms.Dispose(); $bmp.Dispose()
}

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$fs = [System.IO.File]::Create($OutputPath)
try {
    $bw = New-Object System.IO.BinaryWriter($fs)

    # ICONDIR
    $bw.Write([uint16]0)             # reserved
    $bw.Write([uint16]1)             # type: icon
    $bw.Write([uint16]$pngs.Count)

    # ICONDIRENTRY per image; 0 in the size byte means 256.
    $offset = 6 + (16 * $pngs.Count)
    foreach ($p in $pngs) {
        $dim = if ($p.Size -ge 256) { 0 } else { $p.Size }
        $bw.Write([byte]$dim)        # width
        $bw.Write([byte]$dim)        # height
        $bw.Write([byte]0)           # palette size
        $bw.Write([byte]0)           # reserved
        $bw.Write([uint16]1)         # colour planes
        $bw.Write([uint16]32)        # bits per pixel
        $bw.Write([uint32]$p.Bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $p.Bytes.Length
    }
    foreach ($p in $pngs) { $bw.Write($p.Bytes) }
    $bw.Flush()
} finally {
    $fs.Dispose()
}

$info = Get-Item -LiteralPath $OutputPath
Write-Host ''
Write-Host ("  wrote {0} ({1:N0} bytes, {2} sizes: {3})" -f $info.Name, $info.Length, $pngs.Count, ($Sizes -join ', ')) -ForegroundColor Green
Write-Host ''

