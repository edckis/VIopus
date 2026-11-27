@echo off
rem Play VIopus with the best measured settings (tools\settings.cmd).
rem Your game folder: set VICTORY_GAME_DIR, or put "set VICTORY_GAME_DIR=..." in local.cmd next to this file.
rem Saves are snapshotted before and after (tools\backup-saves.ps1). The log goes to logs\play.log.
setlocal EnableExtensions DisableDelayedExpansion
set "root=%~dp0"
if exist "%root%local.cmd" call "%root%local.cmd"
if not defined VICTORY_GAME_DIR (
  echo Set VICTORY_GAME_DIR to the folder of your own copy of the game, or create local.cmd ^(see README^).
  pause
  exit /b 1
)
set "runner=%root%target\diag\victory.exe"
if not exist "%runner%" (
  echo No %runner%. Build it first: cargo build --locked --profile diag -p victory --features diagnostics
  pause
  exit /b 2
)
call "%root%tools\settings.cmd"
if not exist "%root%logs" mkdir "%root%logs"
powershell -NoProfile -ExecutionPolicy Bypass -File "%root%tools\backup-saves.ps1"
cd /d "%root%"
"%runner%" run "%VICTORY_GAME_DIR%\game_scarlett_master.exe" --console %VICTORY_CONSOLE% --execute 2> "%root%logs\play.log"
powershell -NoProfile -ExecutionPolicy Bypass -File "%root%tools\backup-saves.ps1"
