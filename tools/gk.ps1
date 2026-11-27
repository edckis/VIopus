# Game helper: drive and look at the VIctory game window. Safe by construction:
#  - key presses are sent ONLY while the game window is the foreground window (checked before every
#    press and every 50 ms while a key is held; a held key is released at once if focus is lost)
#  - screenshots cover ONLY the game window's rectangle, and only while that window is in front
#  - stop closes the window first and kills only as a last resort
# Usage:
#   gk.ps1 launch [NAME=VALUE ...]   start the diag build (VICTORY_KEYS presses Enter itself)
#   gk.ps1 shot <name>               JPEG of the game window -> <scratchpad>\cur\<name>.jpg
#   gk.ps1 key <KEY> <seconds>       hold W/A/S/D/Enter/... for that long (game must be in front)
#   gk.ps1 status                    process, foreground, fps line
#   gk.ps1 stop                      close the game
param([Parameter(Position=0)][string]$Action, [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Rest)
$scr = $PSScriptRoot
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class U {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
[void][U]::SetProcessDPIAware()
function Game { Get-Process victory -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
function Front($g) {
  if ([U]::GetForegroundWindow() -eq $g.MainWindowHandle) { return $true }
  [void][U]::ShowWindow($g.MainWindowHandle, 9); [void][U]::SetForegroundWindow($g.MainWindowHandle)
  Start-Sleep -Milliseconds 300
  return ([U]::GetForegroundWindow() -eq $g.MainWindowHandle)
}
switch ($Action) {
  'launch' {
    if (Get-Process victory -ErrorAction SilentlyContinue) { 'already running'; exit 1 }
    # the game folder: the environment, else local.cmd next to the README (set "VICTORY_GAME_DIR=...")
    if (-not $env:VICTORY_GAME_DIR -and (Test-Path "$scr\..\local.cmd")) {
      $line = Get-Content "$scr\..\local.cmd" | Where-Object { $_ -match 'VICTORY_GAME_DIR=([^"]+)' } | Select-Object -First 1
      if ($line -match 'VICTORY_GAME_DIR=([^"]+)') { $env:VICTORY_GAME_DIR = $matches[1].Trim() }
    }
    if (-not $env:VICTORY_GAME_DIR) { 'set VICTORY_GAME_DIR (or create local.cmd, see README) to the folder of your own copy of the game first'; exit 1 }
    # Every launch starts from clean settings: what an earlier launch in the same PowerShell session
    # set (VICTORY_*, GK_*) would otherwise carry over to this one (it did: A/B runs in one batch all
    # ran with the first variant's switches). Only the game folder is kept.
    Get-ChildItem Env: | Where-Object { ($_.Name -like 'VICTORY_*' -or $_.Name -like 'GK_*') -and $_.Name -ne 'VICTORY_GAME_DIR' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    $env:VICTORY_LOG = 'info'
    $env:VICTORY_KEYS = '9:Enter'
    # several settings: separate with ';' (a comma stays inside a value, as in VICTORY_SKIP_NAMES)
    foreach ($kv in ((@($Rest) -join ';') -split ';' | Where-Object { $_ -match '=' })) { $n, $v = $kv.Trim() -split '=', 2; Set-Item "env:$n" $v; "env $n=$v" }
    $log = "$scr\gk.err"; Remove-Item $log -ErrorAction SilentlyContinue
    # GK_TESTDATA=1: the game reads and writes a test copy of the saves (reset from
    # testdata-template, a copy of a save of your own, see README) instead of the user's own:
    # every test starts at the same place and hour, and the user's saves stay as they are.
    if ($env:GK_TESTDATA -eq '1') {
      $tpl = "$env:LOCALAPPDATA\VIctory\viopus-test\template"; $work = "$env:LOCALAPPDATA\VIctory\viopus-test\work"
      if (Test-Path $work) { Remove-Item $work -Recurse -Force }
      Copy-Item $tpl $work -Recurse
      Get-ChildItem $work -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
      $env:VICTORY_DATA_DIR = $work
      "test saves reset from the template: $work"
    }
    # GK_LAUNCHER: another launcher (.cmd) than tools\play-test.cmd
    $launcher = if ($env:GK_LAUNCHER) { $env:GK_LAUNCHER } else { "$scr\play-test.cmd" }
    "launcher file: $launcher"
    $p = Start-Process -FilePath $launcher -RedirectStandardOutput "$scr\gk.out" -RedirectStandardError $log -WindowStyle Hidden -PassThru
    "launcher pid $($p.Id)"
    # Every automated run gets the memory guard (tools\memguard.ps1, log in tools\memguard.log).
    Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$scr\memguard.ps1" -WindowStyle Hidden | Out-Null
  }
  'shot' {
    $g = Game; if (-not $g) { 'no game window'; exit 1 }
    if (-not (Front $g)) { 'game window not in front, no screenshot taken'; exit 2 }
    $r = New-Object U+RECT; [void][U]::GetWindowRect($g.MainWindowHandle, [ref]$r)
    $w = $r.R - $r.L; $h = $r.B - $r.T
    New-Item -ItemType Directory -Force "$scr\cur" | Out-Null
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $gr = [System.Drawing.Graphics]::FromImage($bmp); $gr.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size); $gr.Dispose()
    $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 85L
    if ($Rest.Count -gt 1 -and $Rest[1] -eq 'small') {
      $sm = New-Object System.Drawing.Bitmap ([int]($w / 2)), ([int]($h / 2))
      $g2 = [System.Drawing.Graphics]::FromImage($sm); $g2.InterpolationMode = 'HighQualityBicubic'
      $g2.DrawImage($bmp, 0, 0, $sm.Width, $sm.Height); $g2.Dispose(); $bmp.Dispose(); $bmp = $sm
    }
    $path = "$scr\cur\$($Rest[0]).jpg"; $bmp.Save($path, $enc, $ep); $bmp.Dispose()
    "$path  ($w x $h) title: $($g.MainWindowTitle)"
  }
  'key' {
    $g = Game; if (-not $g) { 'no game window'; exit 1 }
    $name = $Rest[0]; $secs = [double]$Rest[1]
    $vk = switch ($name) { 'Enter' {0x0D} 'Esc' {0x1B} 'Tab' {0x09} 'Back' {0x08} 'Backspace' {0x08} 'Space' {0x20} 'Up' {0x26} 'Down' {0x28} 'Left' {0x25} 'Right' {0x27} default { if ($name.Length -eq 1) { [byte][char]$name.ToUpper() } else { 0 } } }
    if (-not $vk) { "unknown key $name"; exit 1 }
    if (-not (Front $g)) { 'game window not in front, no key sent'; exit 2 }
    $scan = [byte][U]::MapVirtualKey([uint32]$vk, 0)
    [U]::keybd_event([byte]$vk, $scan, 0, [UIntPtr]::Zero)
    $end = (Get-Date).AddSeconds($secs); $lost = $false
    while ((Get-Date) -lt $end) {
      Start-Sleep -Milliseconds 50
      if ([U]::GetForegroundWindow() -ne $g.MainWindowHandle) { $lost = $true; break }
    }
    [U]::keybd_event([byte]$vk, $scan, 2, [UIntPtr]::Zero)
    if ($lost) { "focus lost, key released early" } else { "held $name for $secs s" }
  }
  'keys' {
    # keys <K1,K2,..> <seconds>: hold several keys together (game window must stay in front)
    $g = Game; if (-not $g) { 'no game window'; exit 1 }
    $names = $Rest[0] -split ','; $secs = [double]$Rest[1]
    $map = @{ 'Enter' = 0x0D; 'Esc' = 0x1B; 'Tab' = 0x09; 'Back' = 0x08; 'Space' = 0x20; 'Up' = 0x26; 'Down' = 0x28; 'Left' = 0x25; 'Right' = 0x27 }
    $vks = @(); foreach ($n in $names) { if ($map.ContainsKey($n)) { $vks += [byte]$map[$n] } elseif ($n.Length -eq 1) { $vks += [byte][char]$n.ToUpper() } else { "unknown key $n"; exit 1 } }
    if (-not (Front $g)) { 'game window not in front, no key sent'; exit 2 }
    foreach ($vk in $vks) { [U]::keybd_event($vk, [byte][U]::MapVirtualKey([uint32]$vk, 0), 0, [UIntPtr]::Zero) }
    $end = (Get-Date).AddSeconds($secs); $lost = $false
    while ((Get-Date) -lt $end) { Start-Sleep -Milliseconds 50; if ([U]::GetForegroundWindow() -ne $g.MainWindowHandle) { $lost = $true; break } }
    foreach ($vk in $vks) { [U]::keybd_event($vk, [byte][U]::MapVirtualKey([uint32]$vk, 0), 2, [UIntPtr]::Zero) }
    if ($lost) { 'focus lost, keys released early' } else { "held $($Rest[0]) for $secs s" }
  }
  'status' {
    $g = Get-Process victory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $g) { 'not running'; exit 0 }
    $fg = if ($g.MainWindowHandle -ne 0 -and [U]::GetForegroundWindow() -eq $g.MainWindowHandle) { 'game in front' } else { 'game NOT in front' }
    "pid $($g.Id), ws $([math]::Round($g.WorkingSet64/1GB,1)) GB, $fg, title: $($g.MainWindowTitle)"
    $m = Get-Content "$scr\gk.err" -Tail 300 -ErrorAction SilentlyContinue | Where-Object { $_ -match ' fps, ' } | Select-Object -Last 1
    if ($m) { ($m -replace '^(\S+)Z\s+INFO victory_gpu::host: ', '$1 ') -replace '\(\d.*?preparing.*?\), ', '' | ForEach-Object { $_.Substring(0, [Math]::Min(170, $_.Length)) } }
  }
  'stop' {
    $g = Get-Process victory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $g) { 'not running'; exit 0 }
    [void]$g.CloseMainWindow()
    if (-not $g.WaitForExit(8000)) {
      # the window ignores a close request: wait until no save file has changed for 15 s (max 90 s), then kill
      $saves = Join-Path $env:LOCALAPPDATA 'victory\data'
      $quiet = 0
      for ($i = 0; $i -lt 45 -and $quiet -lt 15; $i++) {
        $recent = Get-ChildItem $saves -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-15) } | Select-Object -First 1
        if ($recent) { $quiet = 0 } else { $quiet += 2 }
        Start-Sleep 2
      }
      'window did not close; no save written lately, killing'
      $g.Kill(); [void]$g.WaitForExit(10000)
    }
    "game exited: $($g.HasExited)"
  }
  default { 'usage: gk.ps1 launch|shot|key|status|stop' }
}




