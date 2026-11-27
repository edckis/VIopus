@echo off
rem Launcher for automated runs (tools\gk.ps1 launch): the same settings as Play-VIopus.cmd, no backup,
rem output left to the caller (gk.ps1 writes it to tools\gk.err).
setlocal EnableExtensions DisableDelayedExpansion
set "root=%~dp0.."
if exist "%root%\local.cmd" call "%root%\local.cmd"
set "runner=%root%\target\diag\victory.exe"
if not exist "%runner%" (
  echo No %runner%. 1>&2
  exit /b 2
)
call "%~dp0settings.cmd"
cd /d "%root%"
"%runner%" run "%VICTORY_GAME_DIR%\game_scarlett_master.exe" --console %VICTORY_CONSOLE% --execute
exit /b %errorlevel%
