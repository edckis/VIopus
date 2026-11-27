# Snapshots the VIctory game saves (every fork, every title id).
#
# SAFE BY DESIGN: this script only ADDS a new timestamped folder under
# <backup root>\snapshots\. It never deletes, moves or overwrites anything,
# in the backups or in the live save folders. Snapshots are marked read-only.
# A snapshot identical to the newest one is skipped, so running it often is fine.
#
# Run:   powershell -ExecutionPolicy Bypass -File tools\backup-saves.ps1 [-Roots D:\my-backups,E:\my-backups]
# Restore: copy a snapshot's <title>\saves folder back into %LOCALAPPDATA%\victory\data\<title>\ with the game closed.

param([string[]]$Roots = @('D:\VIctory-saves-backup', 'E:\VIctory-saves-backup'))
$ErrorActionPreference = 'Stop'

# Where the live saves are. Forks share %LOCALAPPDATA%\victory\data (Windows paths
# are case-insensitive, so "VIctory" is the same folder). The DexNom runtime keeps
# its own older copy in "DexNom Runtime\state".
$sources = [ordered]@{
    'victory-data' = Join-Path $env:LOCALAPPDATA 'victory\data'
    'dexnom-state' = Join-Path $env:LOCALAPPDATA 'DexNom Runtime\state'
}

# Backup roots: D: always, E: (portable drive) only when it is plugged in.
$roots = $Roots | Where-Object {
    (Test-Path (Split-Path $_ -Qualifier))
}

function Get-TreeHash([string]$path) {
    # One hash over relative names + file contents, so identical trees compare equal.
    $lines = Get-ChildItem $path -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($path.Length)
        "$rel|" + (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))) -replace '-', ''
}

# Stage a copy of just the saves + settings (not crash dumps or temp files).
$stage = Join-Path $env:TEMP ("victory-saves-stage-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$count = 0
foreach ($name in $sources.Keys) {
    $src = $sources[$name]
    if (-not (Test-Path $src)) { continue }
    foreach ($title in Get-ChildItem $src -Directory) {
        foreach ($part in 'saves', 'storage') {
            $from = Join-Path $title.FullName $part
            if (Test-Path $from) {
                $to = Join-Path $stage "$name\$($title.Name)\$part"
                New-Item -ItemType Directory -Path (Split-Path $to) -Force | Out-Null
                Copy-Item $from $to -Recurse
                $count += (Get-ChildItem $to -Recurse -File).Count
            }
        }
    }
}
if ($count -eq 0) { Write-Host 'No save files found; nothing to back up.'; Remove-Item $stage -Recurse -Force; exit 1 }

$hash = Get-TreeHash $stage
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($root in $roots) {
    $snaps = Join-Path $root 'snapshots'
    New-Item -ItemType Directory -Path $snaps -Force | Out-Null
    $newest = Get-ChildItem $snaps -Directory | Sort-Object Name | Select-Object -Last 1
    if ($newest -and (Test-Path (Join-Path $newest.FullName 'tree.sha256')) -and
        ((Get-Content (Join-Path $newest.FullName 'tree.sha256') -Raw).Trim() -eq $hash)) {
        Write-Host "$root : unchanged since $($newest.Name), skipped."
        continue
    }
    $dest = Join-Path $snaps $stamp
    Copy-Item $stage $dest -Recurse
    # Verify the copy matches what was staged before calling it done.
    if ((Get-TreeHash $dest) -ne $hash) {
        throw "Snapshot at $dest does not match the saves it was copied from. It was left in place for inspection."
    }
    Set-Content (Join-Path $dest 'tree.sha256') $hash
    Get-ChildItem $dest -Recurse -File | ForEach-Object { $_.IsReadOnly = $true }
    Write-Host "$root : saved $count files, verified -> $dest"
}
Remove-Item $stage -Recurse -Force

