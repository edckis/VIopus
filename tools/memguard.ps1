# Memory guard for test runs: while the game runs, every 2 s, look at the
# system's commit charge and free RAM; when either goes past its limit, close
# the game (gk.ps1 stop, then a hard kill if it hangs) before Windows runs out
# and takes other programs down with it (2026-11-27: a run hit the commit limit
# and the Claude Code session died with the game).
# The pagefile is managed by Windows and grows on demand, so the commit limit
# it reports moves; the guard uses a fixed ceiling instead.
# Started by gk.ps1 launch for every automated run; exits when the game does.
# Log: tools\memguard.log (peak commit and lowest free RAM of each run).
param([double]$MinFreeGB = 0.5, [double]$MaxCommitGB = 70, [int]$WaitForGameS = 120)
$scr = $PSScriptRoot
$log = "$scr\memguard.log"
function Say($m) { ("{0:HH:mm:ss} {1}" -f (Get-Date), $m) | Add-Content $log }
$avail = New-Object System.Diagnostics.PerformanceCounter 'Memory', 'Available MBytes'
$committed = New-Object System.Diagnostics.PerformanceCounter 'Memory', 'Committed Bytes'
$deadline = (Get-Date).AddSeconds($WaitForGameS)
while (-not (Get-Process victory -ErrorAction SilentlyContinue)) {
  if ((Get-Date) -gt $deadline) { Say 'no game came up'; exit 0 }
  Start-Sleep 1
}
Say ("watching: stop below {0} GB free RAM or above {1} GB committed" -f $MinFreeGB, $MaxCommitGB)
$peak = 0.0; $low = [double]::MaxValue
while (Get-Process victory -ErrorAction SilentlyContinue) {
  $freeGB = $avail.NextValue() / 1024
  $commitGB = $committed.NextValue() / 1GB
  $peak = [Math]::Max($peak, $commitGB); $low = [Math]::Min($low, $freeGB)
  if ($freeGB -lt $MinFreeGB -or $commitGB -gt $MaxCommitGB) {
    Say ("STOPPING the game: free RAM {0:N1} GB, committed {1:N1} GB" -f $freeGB, $commitGB)
    & "$scr\gk.ps1" stop | Out-Null
    Start-Sleep 5
    Get-Process victory -ErrorAction SilentlyContinue | Stop-Process -Force
    exit 1
  }
  Start-Sleep 2
}
Say ("game gone; peak committed {0:N1} GB, lowest free RAM {1:N1} GB" -f $peak, $low)
