# Long run for memory growth: the character runs around (W + A/D + F sprint, as drivetest.ps1),
# and every minute the game's private bytes, the process heap from the memory map and the view
# table size are printed. Usage: longrun.ps1 -Minutes 15   (game must already be in the world)
param([int]$Minutes = 15)
$t = $PSScriptRoot
$end = (Get-Date).AddMinutes($Minutes); $next = Get-Date
$dirs = 'W,A,F', 'W,D,F', 'W,F'
$i = 0
while ((Get-Date) -lt $end) {
  if ((Get-Date) -ge $next) {
    $g = Get-Process victory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $g) { 'game gone'; break }
    $heap = Select-String -Path "$t\gk.err" -Pattern 'memory map \(' | Select-Object -Last 1 | ForEach-Object { if ($_.Line -match 'process heap segments \(private, 15.8 MB each\) (\d+) MB') { $matches[1] } }
    $views = Select-String -Path "$t\gk.err" -SimpleMatch 'memory, what holds it' | Select-Object -Last 1 | ForEach-Object { if ($_.Line -match 'distinct\s+views\s+kept: (\d+) \(\d+ free\) (\d+) MB') { "$($matches[1]) / $($matches[2]) MB" } }
    $fps = Select-String -Path "$t\gk.err" -Pattern ' fps, ' | Select-Object -Last 1 | ForEach-Object { if ($_.Line -match ' ([\d.]+) fps, ([\d.]+) ms/frame.*?(\d+) draws/frame') { "$($matches[1]) fps $($matches[2]) ms $($matches[3]) draws" } }
    "{0:HH:mm:ss} private {1:N1} GB  heap {2} MB  views {3}  free RAM {4:N1} GB  | {5}" -f (Get-Date), ($g.PrivateMemorySize64/1GB), $heap, $views, ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB), $fps
    $next = (Get-Date).AddMinutes(1)
  }
  & "$t\gk.ps1" keys $dirs[$i % 3] 4 | Out-Null
  $i++
}
