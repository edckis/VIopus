# Passive recorder while the user plays: every 5 s the game's fps line, private bytes and free RAM go to
# <scr>\rec\<tag>\stats.csv; every 15 s a half-size JPEG of the game window, ONLY if the game is already
# the foreground window (never brings it to front, never sends keys). Stops when the game exits.
# Usage: recorder.ps1 -Tag name
param([string]$Tag = 'rec')
$scr = $PSScriptRoot
$dir = "$scr\rec\$Tag"; New-Item -ItemType Directory -Force $dir | Out-Null
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class R {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
[void][R]::SetProcessDPIAware()
$enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
$ep = New-Object System.Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 80L
'time,fps,ms,prep,draws,private_gb,free_ram_gb,shot' | Set-Content "$dir\stats.csv"
$n = 0
while ($true) {
  $g = Get-Process victory -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $g) { if ($n -gt 0) { break }; Start-Sleep 5; continue }
  $m = Get-Content "$scr\gk.err" -Tail 200 -ErrorAction SilentlyContinue | Where-Object { $_ -match ' fps, ' } | Select-Object -Last 1
  $f = if ($m -match ' ([\d.]+) fps, ([\d.]+) ms/frame \(([\d.]+) preparing.*?(\d+) draws/frame') { $matches[1..4] } else { @('', '', '', '') }
  $shot = ''
  if ($n % 3 -eq 0 -and [R]::GetForegroundWindow() -eq $g.MainWindowHandle) {
    $r = New-Object R+RECT; [void][R]::GetWindowRect($g.MainWindowHandle, [ref]$r)
    $w = $r.R - $r.L; $h = $r.B - $r.T
    if ($w -gt 100 -and $h -gt 100) {
      $bmp = New-Object System.Drawing.Bitmap $w, $h
      $gr = [System.Drawing.Graphics]::FromImage($bmp); $gr.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size); $gr.Dispose()
      $sm = New-Object System.Drawing.Bitmap ([int]($w / 2)), ([int]($h / 2))
      $g2 = [System.Drawing.Graphics]::FromImage($sm); $g2.DrawImage($bmp, 0, 0, $sm.Width, $sm.Height); $g2.Dispose(); $bmp.Dispose()
      $shot = "{0:HHmmss}.jpg" -f (Get-Date); $sm.Save("$dir\$shot", $enc, $ep); $sm.Dispose()
    }
  }
  "{0:HH:mm:ss},{1},{2},{3},{4},{5:N2},{6:N2},{7}" -f (Get-Date), $f[0], $f[1], $f[2], $f[3], ($g.PrivateMemorySize64 / 1GB), ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB), $shot | Add-Content "$dir\stats.csv"
  $n++
  Start-Sleep 5
}
Copy-Item "$scr\gk.err" "$dir\game.log" -Force
"recorder done: $n samples in $dir"
