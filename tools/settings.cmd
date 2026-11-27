@echo off
rem VIopus default settings, called by Play-VIopus.cmd and tools\play-test.cmd.
rem Each one is only set if it is not set already: set it yourself first to change it (0 turns a switch off).

rem Belobug's scripts\play.ps1 settings (not -Safe)
if not defined VICTORY_TEXTURE_NO_WAIT set "VICTORY_TEXTURE_NO_WAIT=1"
if not defined VICTORY_RELAY set "VICTORY_RELAY=2"
if not defined VICTORY_WIDE_BACK set "VICTORY_WIDE_BACK=1"
if not defined VICTORY_CARD_REHASH_RUNS set "VICTORY_CARD_REHASH_RUNS=1"
if not defined VICTORY_JOIN_COPIES set "VICTORY_JOIN_COPIES=1"
if not defined VICTORY_INDIRECT_WINDOW set "VICTORY_INDIRECT_WINDOW=1"
if not defined VICTORY_RELAY_COPY set "VICTORY_RELAY_COPY=1"
if not defined VICTORY_CARD_STEPS set "VICTORY_CARD_STEPS=2"
if not defined VICTORY_INDIRECT_BATCH set "VICTORY_INDIRECT_BATCH=2"
if not defined VICTORY_MAP_THREADS set "VICTORY_MAP_THREADS=1"
if not defined VICTORY_TITLE_PRIORITIES set "VICTORY_TITLE_PRIORITIES=0"
if not defined VICTORY_CARD_AWAKE set "VICTORY_CARD_AWAKE=1"
if not defined VICTORY_SHOW_AFTER set "VICTORY_SHOW_AFTER=1"
if not defined VICTORY_AMBIENT set "VICTORY_AMBIENT=0.8"
if not defined VICTORY_D3D12_DRED set "VICTORY_D3D12_DRED=light"
if not defined VICTORY_THIN set "VICTORY_THIN=1"
if not defined VICTORY_JOIN_PARTS set "VICTORY_JOIN_PARTS=8"
if not defined VICTORY_UPLOAD_AHEAD set "VICTORY_UPLOAD_AHEAD=1"

rem Renderer ports 1, 2, 5, 6, 7 (VIctory-7900XTX by avatarmanz, carried by Belobug)
if not defined VICTORY_PORT_CONSTANTS set "VICTORY_PORT_CONSTANTS=1"
if not defined VICTORY_PORT_DESCRIPTORS set "VICTORY_PORT_DESCRIPTORS=1"
if not defined VICTORY_PORT_CBV set "VICTORY_PORT_CBV=1"
if not defined VICTORY_PORT_GUARD set "VICTORY_PORT_GUARD=1"
if not defined VICTORY_PORT_JOURNAL set "VICTORY_PORT_JOURNAL=1"

rem VIopus: the card reads and writes the title's memory in place (no copy, no tracking, no copy-back)
if not defined VICTORY_PORT_ALL set "VICTORY_PORT_ALL=1"
if not defined VICTORY_INPLACE set "VICTORY_INPLACE=2"
rem ...except the title's 32-bit graphics heap, kept as a copy: the title keeps its allocator's bookkeeping
rem in it, and with it in place a 10-minute fast drive crashed there; as a copy a 15-minute drive at top
rem speed did not (about 1-2 fps less while driving). VICTORY_PORT_LOW=1 puts it in place again.
if not defined VICTORY_PORT_LOW set "VICTORY_PORT_LOW=0"

rem A frame waits at most 10 ms for a pipeline still compiling (the default 500 made 300-800 ms spikes)
if not defined VICTORY_PIPELINE_WAIT_MS set "VICTORY_PIPELINE_WAIT_MS=10"

rem The title's 30 fps cap lifted to 60 (upstream switch: the title's own frame-rate setting is patched
rem at load, so its clock and simulation step stay right). 33.333 puts the console's 30 back.
if not defined VICTORY_FRAME_INTERVAL_MS set "VICTORY_FRAME_INTERVAL_MS=16.667"

if not defined VICTORY_CACHE_DIR set "VICTORY_CACHE_DIR=%LOCALAPPDATA%\VIctory\cache-viopus"
if not defined VICTORY_CONSOLE set "VICTORY_CONSOLE=series-s"
if not defined VICTORY_LOG set "VICTORY_LOG=info"
