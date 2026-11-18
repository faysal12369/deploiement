# Builds the guide videos (English and French): captioned 1920x1080 frames, then an MP4 with Windows' own encoder.
# 1. flutter test test/generic_test.dart --update-goldens   (the screens, in test\video\en and test\video\fr)
# 2. in Windows PowerShell 5.1: & .\tool\video\make_videos.ps1      (docs\guide-en.mp4, docs\guide-fr.mp4)
param([string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path, [string]$OutDir = '', [int]$Bitrate = 1200000)
if (-not $OutDir) { $OutDir = Join-Path $Repo 'docs' }
$script:Bitrate = $Bitrate
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'mp4lib.ps1')
Add-Type -AssemblyName System.Drawing
$chapters = Get-Content (Join-Path $here 'chapters.json') -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force $OutDir | Out-Null

$navy = [System.Drawing.Color]::FromArgb(255, 0x0F, 0x23, 0x42)
$blue = [System.Drawing.Color]::FromArgb(255, 0x1D, 0x63, 0xED)
$track = [System.Drawing.Color]::FromArgb(255, 0x1E, 0x3A, 0x66)
$soft = [System.Drawing.Color]::FromArgb(255, 0xCB, 0xD5, 0xE1)
$dim = [System.Drawing.Color]::FromArgb(255, 0x94, 0xA3, 0xB8)

function New-Canvas() {
  $bmp = New-Object System.Drawing.Bitmap 1920, 1080
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear($navy)
  return @($bmp, $g)
}

function Draw-Logo($g, $x, $y, $size) {
  $icon = [System.Drawing.Image]::FromFile((Join-Path $Repo 'docs\icon.png'))
  $g.DrawImage($icon, [int]$x, [int]$y, [int]$size, [int]$size)
  $icon.Dispose()
}

function Save-Png($bmp, $path) { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }

foreach ($lang in @('en', 'fr')) {
  $src = Join-Path $Repo "test\video\$lang"
  $tmp = Join-Path $here "vframes\$lang"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $clips = New-Object System.Collections.ArrayList

  # opening card
  $c = New-Canvas; $bmp = $c[0]; $g = $c[1]
  Draw-Logo $g 690 340 128
  $g.DrawString('Déploiement', (New-Object System.Drawing.Font 'Segoe UI Semibold', 60), [System.Drawing.Brushes]::White, 845, 318)
  $sub = if ($lang -eq 'fr') { 'Guide pas à pas' } else { 'Step-by-step guide' }
  $g.DrawString($sub, (New-Object System.Drawing.Font 'Segoe UI', 28), (New-Object System.Drawing.SolidBrush $dim), 853, 420)
  $line = if ($lang -eq 'fr') { "Du projet au déploiement, avec la vraie application (un magasin de démonstration)." } else { 'From a project to a deployment, with the real app (on a demo shop).' }
  $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'
  $g.DrawString($line, (New-Object System.Drawing.Font 'Segoe UI', 24), (New-Object System.Drawing.SolidBrush $soft), (New-Object System.Drawing.RectangleF 0, 600, 1920, 60), $fmt)
  $p = Join-Path $tmp '00_title.png'; Save-Png $bmp $p; $g.Dispose(); $bmp.Dispose()
  [void]$clips.Add(@{ path = $p; seconds = 3.5 })

  $titleFont = New-Object System.Drawing.Font 'Segoe UI Semibold', 30
  $textFont = New-Object System.Drawing.Font 'Segoe UI', 20
  $numFont = New-Object System.Drawing.Font 'Bahnschrift SemiBold', 22
  $total = $chapters.Count
  for ($i = 0; $i -lt $total; $i++) {
    $ch = $chapters[$i]
    $texts = $ch.$lang
    $names = if ($ch.seq) { 1..$ch.n | ForEach-Object { '{0}_{1:00}' -f $ch.seq, $_ } } else { $ch.f }
    $loops = if ($ch.loops) { $ch.loops } else { 1 }
    $made = @()
    foreach ($n in $names) {
      $c = New-Canvas; $bmp = $c[0]; $g = $c[1]
      $img = [System.Drawing.Image]::FromFile("$src\$n.png")
      $g.DrawImage($img, 240, 22, 1440, 900)
      $img.Dispose()
      $g.DrawRectangle((New-Object System.Drawing.Pen $track, 1), 239, 21, 1441, 901)
      # step number, title, text
      $g.FillEllipse((New-Object System.Drawing.SolidBrush $blue), 240, 948, 46, 46)
      $nf = New-Object System.Drawing.StringFormat; $nf.Alignment = 'Center'; $nf.LineAlignment = 'Center'
      $g.DrawString([string]($i + 1), $numFont, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 240, 948, 46, 46), $nf)
      $g.DrawString($texts[0], $titleFont, [System.Drawing.Brushes]::White, 302, 942)
      $g.DrawString($texts[1], $textFont, (New-Object System.Drawing.SolidBrush $soft), (New-Object System.Drawing.RectangleF 304, 994, 1380, 70))
      # progress along the bottom
      $g.FillRectangle((New-Object System.Drawing.SolidBrush $track), 0, 1074, 1920, 6)
      $g.FillRectangle((New-Object System.Drawing.SolidBrush $blue), 0, 1074, [int](1920 * ($i + 1) / $total), 6)
      $p = Join-Path $tmp "$n.png"; Save-Png $bmp $p; $g.Dispose(); $bmp.Dispose()
      $made += $p
    }
    for ($l = 0; $l -lt $loops; $l++) { foreach ($p in $made) { [void]$clips.Add(@{ path = $p; seconds = [double]$ch.d }) } }
  }
  $name = "guide-$lang.mp4"
  $out = Join-Path $OutDir $name
  $seconds = ($clips | ForEach-Object { $_.seconds } | Measure-Object -Sum).Sum
  # an original chill track, made to the exact length of the video (music.py, nothing downloaded)
  $len = $seconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
  $music = Join-Path $env:TEMP "deploiement-music_$len.wav"
  if (-not (Test-Path $music)) { & python -I (Join-Path $here 'music.py') $len $music | Out-Host }
  $r = New-Mp4 $clips $out $music
  "{0}: {1} clips, {2:N1} s, {3:N1} MB, result {4}" -f $name, $clips.Count, $seconds, ((Get-Item $out).Length / 1MB), $r
}
