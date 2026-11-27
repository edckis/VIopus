# Build comparison on the test saves (GK_TESTDATA=1 always): launch, wait for the world, settle 45 s,
# then 90 s standing: game fps/ms/prep/draws from the log, the game's private bytes and free RAM.
# Optional -Move: a further 90 s running around (W+A/D+F). Closes the game at the end.
# Usage: bench7.ps1 -Tag name -Env "VICTORY_PORT_ALL=0;VICTORY_INPLACE=0" [-Move]
param([string]$Tag = 'x', [string]$Env = '', [int]$Threshold = 3500, [switch]$Move)
$scr = $PSScriptRoot
$log = "$scr\gk.err"; $out = "$scr\bench7-$Tag.txt"
Remove-Item $out -ErrorAction SilentlyContinue
function Say($m) { $l = ("{0:HH:mm:ss} {1}" -f (Get-Date), $m); $l | Add-Content $out; $l }
& "$scr\gk.ps1" launch ("GK_TESTDATA=1;VICTORY_PIPELINE_WAIT_MS=10;" + $Env) | Out-Null
$game = $null; for ($i = 0; $i -lt 60 -and -not $game; $i++) { Start-Sleep 1; $game = Get-Process victory -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not $game) { Say "$Tag no game"; exit 1 }
$hits = 0; $deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline -and -not $game.HasExited) {
  Start-Sleep 5
  $m = Get-Content $log -Tail 300 -ErrorAction SilentlyContinue | Where-Object { $_ -match ' fps, ' -and $_ -match 'draws/frame' } | Select-Object -Last 1
  if ($m -match '(\d+) draws/frame' -and [int]$matches[1] -ge $Threshold) { $hits++ } else { $hits = 0 }
  if ($hits -ge 2) { break }
}
if ($game.HasExited) { Say "$Tag game exited before the world (crash?)"; exit 1 }
if ($hits -lt 2) { Say "$Tag never reached the world"; & "$scr\gk.ps1" stop | Out-Null; exit 1 }
Start-Sleep 45
function Phase($name, [scriptblock]$during) {
  $start = [datetime]::UtcNow; $mem = @()
  $end = (Get-Date).AddSeconds(90); $k = 0
  while ((Get-Date) -lt $end -and -not $game.HasExited) {
    if ($during) { & $during $k } else { Start-Sleep 5 }
    $k++
    $game.Refresh(); $mem += [pscustomobject]@{ priv = $game.PrivateMemorySize64 / 1GB; free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
  }
  $fps = Get-Content $log -Tail 4000 | ForEach-Object { if ($_ -match '^(\S+)Z\s+INFO victory_gpu::host: ([\d.]+) fps, ([\d.]+) ms/frame \(([\d.]+) preparing.*?\), (\d+) draws/frame') { [pscustomobject]@{ t = [datetime]::Parse($matches[1] + 'Z', [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal'); fps = [double]$matches[2]; ms = [double]$matches[3]; prep = [double]$matches[4]; draws = [int]$matches[5] } } } | Where-Object { $_.t -ge $start }
  Say ("{0} {1}: game fps {2:N2} (min {3:N1}) ms {4:N1} prep {5:N1} draws {6:N0} | private {7:N1} GB max {8:N1} | free RAM min {9:N1} GB{10}" -f $Tag, $name, ($fps | Measure-Object fps -Average).Average, ($fps | Measure-Object fps -Minimum).Minimum, ($fps | Measure-Object ms -Average).Average, ($fps | Measure-Object prep -Average).Average, ($fps | Measure-Object draws -Average).Average, ($mem | Measure-Object priv -Average).Average, ($mem | Measure-Object priv -Maximum).Maximum, ($mem | Measure-Object free -Minimum).Minimum, $(if ($game.HasExited) { ' | GAME EXITED' } else { '' }))
}
Phase 'standing' $null
if ($Move -and -not $game.HasExited) { $dirs = 'W,A,F', 'W,D,F', 'W,F'; Phase 'moving' { param($k) & "$scr\gk.ps1" keys $dirs[$k % 3] 4 | Out-Null } }
$sub = Get-Content $log -Tail 3000 | Where-Object { $_ -match 'that thread worked ([\d.]+) ms; threads of the title waited .*? ([\d.]+) ms at presents' } | Select-Object -Last 1
if ($sub -match 'that thread worked ([\d.]+) ms; threads of the title waited .*? ([\d.]+) ms at presents') { Say "  submit thread worked $($matches[1]) ms/frame; title waited $($matches[2]) ms at presents" }
$crash = @(Select-String -Path $log -Pattern 'compiler crashed|crashed under|left out for the compiler' -ErrorAction SilentlyContinue).Count
if ($crash) { Say "  compiler-crash guard lines in the log: $crash" }
Copy-Item $log "$scr\bench7-$Tag.err" -Force
if (-not $game.HasExited) { & "$scr\gk.ps1" stop | Out-Null } else { Say "  exit code $($game.ExitCode)" }

