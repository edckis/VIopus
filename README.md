# VIopus

A personal fork of [VIctory](https://github.com/Marvisak/VIctory), the compatibility layer that runs an Xbox Series title on Windows from files you supply. VIopus is tuned for an **AMD Ryzen + Radeon RX 9070 XT** PC. The goal is a stable 30 fps or more in the open world, from real rendered frames only (no frame generation).

> [!NOTE]
> **Priorities, in this order:**
>
> 1. **Frame rate and performance.** The target is a stable 30 fps or more while driving. Today that is still under 20 in places, which is not playable.
> 2. **Stability.** No crashes or leaks in long sessions. A faster setting that crashes is kept off by default until it is safe.
> 3. **Graphics, later.** For now VIopus does not care how the game looks. Settings and changes are chosen for frame rate even when the picture suffers. Examples: the Series S profile at its 1280×720 render size, ray tracing off, and the cheap ambient-light stand-in.

> [!IMPORTANT]
> **Measured on one PC only.** Every number here comes from this machine:
>
> | Part | |
> |---|---|
> | CPU | AMD Ryzen 7 9800X3D (8 cores, 16 threads) |
> | GPU | AMD Radeon RX 9070 XT, 16 GB (RDNA4) |
> | RAM | 32 GB DDR5-6000 |
> | Board | Gigabyte B850M EAGLE WIFI6E ICE, BIOS F5 |
> | OS | Windows 11 Home |
>
> **BIOS: turn off X3D Turbo Mode.** On Gigabyte boards, *X3D Turbo Mode* disables SMT. Windows then shows 8 logical processors instead of 16, even when the BIOS item *SMT Control* is set to *Auto*. The layer needs those threads: with 16 logical processors it was about 15% faster here, and before that the CPU was saturated. Check in Task Manager → Performance → CPU that it says **16 logical processors**. You can turn X3D Turbo Mode back on for other games.

**This repository contains no game files, code or assets.** You need your own copy of the title. VIopus is not affiliated with or endorsed by the title's developer or publisher.

## Where it stands (2026-11-27)

These runs use the Series S profile and the same test save: a city street at noon, about 12,000 draws a frame standing. Each run is 90 s standing, then 90 s running on foot (about 7,000 draws a frame), using `tools\bench7.ps1`. The test save is reset before every run, so the place and hour are always the same. Runs of the same build on different days differ by 1.5–4 fps, so treat small differences as noise.

| Build (all with the VIopus leak fix) | Standing | On foot | Submit thread (ms/frame) | Lowest free RAM |
|---|---|---|---|---|
| [Vice-Tay](https://github.com/TaynanGT/Vice-Tay), AMD profile | 16.6 fps | 17.7 fps | 50.7 | 0.8 GB |
| [Belobug rx9070xt](https://github.com/Belobug/VIctory-Belobug-AMD/tree/rx9070xt), as shipped | 17.0 fps | 16.0 fps | 44.6 | 1.8 GB |
| [cool_fox](https://github.com/codec-d/cool_fox) (`pareto-residency`) | 18.2 fps | 19.5 fps | 47.5 | 3.1 GB |
| Belobug rx9070xt + renderer ports 1, 2, 5, 6, 7 | 19.7–21.2 fps | 18.2–22.5 fps | 38.0–48.6 | 0.5–1.3 GB |
| **VIopus** (ports + in-place memory) | **22.6–23.4 fps** | **24.4–29.2 fps** | **24–33** | **3.0 GB** |

**Clean re-test, 2026-11-27 afternoon.** Earlier the same day, `tools\gk.ps1` let each run's settings leak into the next runs of a batch, which made some A/B results wrong (corrected below). These runs start from clean settings and alternate a default VIopus run with each variant. A check of each run's log confirmed that only the intended switch was active.

| Run | Standing | On foot | Prep (ms/frame) | Draws standing |
|---|---|---|---|---|
| VIopus default, 7 runs | 19.5–21.1 fps (median 20.3) | 21.5–27.2 fps (median 22.3) | 33–36 | 11,500–12,300 |
| [Vice-Tay](https://github.com/TaynanGT/Vice-Tay) 231b6a9 (2026-11-27, with its new speedups), 2 runs | 17.4–18.0 fps | 18.1–18.2 fps | 46–48 | ~12,000 |
| VIopus + `VICTORY_SKIP_NAMES=CascadeShadows`, 2 runs | 20.5–21.1 fps | 22.4–23.9 fps | 34–35 | 7,900–8,100 |
| VIopus + `VICTORY_INPLACE_BIG=1`, 2 runs | 20.3–20.5 fps | 21.9–23.7 fps | 27–30 | ~11,700 |

- **VIopus is about 14% faster standing and 28% faster on foot than the updated Vice-Tay** (against the default runs next to them).
- The VIopus numbers are lower than in the table above. That table was measured on another day; the same build drifts 2–4 fps between days.

Other measurements on this PC:

- **VIopus while driving fast, as it ships now** (graphics heap kept as a copy, 60 fps cap): 15.5 minutes at top speed in the fastest car, played by hand. **No crash.** It averaged 19.9 fps, with a median of 19.5, the slowest 10% of samples below 15.9, and a peak of 34.4. About 7,200 draws a frame.
- **The same drive with the graphics heap in place** (8 minutes): 21.7 fps on average, a median of 22.3, the slowest 10% below 16.7. It crashed after 10.5 minutes (see fix 2).
- **VIopus on foot for 30 minutes**, automated: no crash, with memory flat at 27–28 GB private. It ran at 28–30.6 fps through town (5,500–8,000 draws), and a steady 30.0 fps in light scenes.
- **[VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX) as shipped:** 12.2 fps (83 ms a frame) on an earlier city save where cool_fox did 20.7 fps. Its renderer ports crashed AMD's shader compiler at boot until Belobug added the compiler-crash guard.
- **Belobug-AMD `main`** (2026-11-26): 5–7 fps in the open world.

The numbers mean the following:

- *Submit thread* is the layer's thread that prepares each submission for the card. It was the wall before VIopus; the title waits for it at every present.
- In the busiest street the title's own main thread is busy only about 23 ms of a frame, so 30 fps is possible. The remaining time is spread over the card (about 9.5 ms), translating the title's command lists (about 14 ms), and occasional spikes of up to 60 ms.

## What VIopus changed, and the proof

1. **Memory leak in the descriptor views fixed**, [`crates/victory-gpu/src/descriptor.rs`](crates/victory-gpu/src/descriptor.rs) (`tidy_resource`, `tidy_view`).
   - **The bug:** the title leaves padding in its resource and view descriptions uninitialized. That is stack garbage, different on every call. The layer interned views by every word, so the same view written twice became two entries.
   - **The effect:** the placed-view "shapes" table hit its 4,194,304 cap after about 18 minutes, and from then on every placed view became a table entry that is never freed. One 53-minute session reached 28.8 million entries (11 GB). RAM ran out and fps fell from 21 to 8.
   - **The fix:** the padding words are zeroed before interning. Shapes now grow about 20 a second instead of 5,000–9,000. Over a 45-minute run the heap went from 1.61 to 1.88 GB and levelled off, and fps stayed at 18–28 without collapsing.
   - [Vice-Tay](https://github.com/TaynanGT/Vice-Tay) found and fixed the same leak independently.
   - `VICTORY_VIEW_TIDY=0` turns the fix off.
2. **The card reads the title's memory in place**, [`crates/victory-gpu/src/port.rs`](crates/victory-gpu/src/port.rs), `VICTORY_PORT_ALL=1`, used together with `VICTORY_INPLACE=2`.
   - **Before:** renderer port 1 (VIctory-7900XTX) already let the card read the title's 32-bit graphics heap in place, but only memory below 4 GiB qualified.
   - **The change:** VIopus lifts that limit. Every title buffer or window that is one committed stretch of a section is used where the title has it, with no host copy, no write tracking and no copy-back.
   - **The reason:** the bytes themselves are small, about 115 MB up and 30 MB back a frame, which is about 6 ms of raw bus time. The ~30 ms was the bookkeeping that keeps two copies in step.
   - **The result:** the submit thread dropped from 48.6 to 24–33 ms a frame, and fps rose 10–30% over the same build without it.
   - **The limit:** the card cannot follow scattered 64 KiB pages. Tile mappings into a heap opened from the title's memory remove the device. So pages must form one stretch to qualify. How much memory qualifies changes from run to run with how the title lays out its pages: between 485 and 688 MB of the pool, and between 208 and 381 MB of private buffers. That is the biggest source of run-to-run difference.
   - **The exception, the 32-bit graphics heap** (`VICTORY_PORT_LOW=0`, the default):
     - **The crash:** with this heap in place, a fast drive crashed after 10.5 minutes. The title was walking a linked list of its own allocator whose node, 3 KB into this heap, held garbage. The title keeps its CPU bookkeeping inside the memory the card writes.
     - **The fix:** the heap is kept as a copy, as before port 1.
     - **The cost:** one hand-played drive each came out at 19.9 fps with the copy and 21.7 fps in place, about 8%. An earlier 2×2 benchmark that showed about 3% was not valid (the settings leaked between runs), and its clean re-run is still to do.
     - **The result:** a 15-minute drive at top speed did not crash.
     - `VICTORY_PORT_LOW=1` puts the heap back in place.
3. **No 300–800 ms freezes while new pipelines compile**: `VICTORY_PIPELINE_WAIT_MS=10`, set in `tools\settings.cmd`.
   - **Before:** a frame waited up to 500 ms for a pipeline still compiling, and the worst frames measured exactly 500.8 ms.
   - **Now:** a new effect shows a frame or two late instead. Play feels much smoother with less input lag.
4. **SMT on** (BIOS X3D Turbo Mode off; see the note at the top): about +15%.
5. **AMD shader-compiler crashes survived.**
   - **The problem:** AMD's RDNA4 compiler crashes at `amdxc64.dll+0x861b9f` on some pipelines. Before any fix, this killed every run within 7–15 minutes.
   - **cool_fox / Vice-Tay:** a skip list, `warm-bad.txt`, held in `pipeline/library.rs` (`known_bad`), held up for 98 minutes with no crash.
   - **VIopus:** Belobug's compiler-crash guard catches these crashes at run time, so the skip list isn't needed here.
6. **The 30 fps cap lifted to 60.** This is upstream's `VICTORY_FRAME_INTERVAL_MS` switch, now on by default in `tools\settings.cmd`. The loader patches the three places where the title reads its own frame-rate setting (`rate=60` in the log), so its clock and simulation step stay right, and the frame clock ticks at 16.667 ms. The heavy city scenes are below 30 fps anyway, so they are unchanged; light scenes are no longer stopped at exactly 30.0. Set `VICTORY_FRAME_INTERVAL_MS=33.333` to bring back the console's 30.
7. **Faster locks in the descriptor heap host.** In cool_fox this was worth about 5–7%. The part that stops 8 threads from fighting over the same reference counts is now ported: `HostHeap::keep` checks the slot without a lock. In VIopus it brought no measurable change, because list translation is not what limits the frame here (see below). The rest is kept for reference in [`docs/patches/cool_fox-local-changes.patch`](docs/patches/cool_fox-local-changes.patch).

### Tried and measured, no gain on this PC

- **System settings:** Windows power plan, process and helper-thread priorities, CPU affinity layouts, spinning thread pools.
- **Thread counts and build:** `VICTORY_THIN_THREADS` of 4, 6 or 12; `VICTORY_WIDE_THREADS=8`; thin LTO with `codegen-units=1`.
- **Other switches:** `VICTORY_HEAP_SYNC_EARLY`, `VICTORY_JOIN_PARTS=32`. (`VICTORY_SUBMIT_FRAMES=2` was also reported here as no gain, but that test was not valid because settings leaked between runs. It is still to be re-tested.)
- **More memory in place:** `VICTORY_INPLACE_BIG=1` puts the big private buffers in place.
  - **Clean re-test:** the submit thread's prep fell from about 35 to 28 ms a frame (−19%), and the title waited less at presents (12.5 vs 16.5 ms). But fps rose only 1–5%, which is at the edge of the noise.
  - **What that means:** once the prep is cheaper, something else holds the frame.
  - It stays off until it has had a long stability run.
- **Arranging the pool's pages:** `VICTORY_ARRANGE_ALL=1` tries to make the title's scattered pool buffers one stretch, the way upstream's `arrange` does for the 32-bit heap. The title maps those buffers one page per call into pages that DirectStorage has already filled, so no page could be moved without copying its data. The switch is kept, off.
- **Making the "nothing changed" checks cheaper:** a profile of the submit thread shows the checks are a small part of its time. Its CPU goes to copying bytes (about 27%), asking Windows about written pages (`GetWriteWatch`, about 15%) and refreshing textures (about 16%), and it waits more than half the time.
- **Skipping the sun's shadow maps:** `VICTORY_SKIP_NAMES=CascadeShadows`. That removes about a third of the draw calls standing (12,000 → 8,000). Fps didn't change in a clean, alternating re-test: 20.8 fps standing against 20.7 for the default runs beside it. So translating the title's draw calls is not what limits the frame. The limit is the submit thread's bookkeeping for memory that is still copied: about 10 ms a frame of checks, 96% of which find nothing new.
- **Smaller memory windows:** `VICTORY_WINDOW_KB` 256 or 64 put up to 3.5 GB in place, but fps didn't change and the layer kept rebuilding regions.
- **Moving the game data from D: to C:**, both NVMe drives.
- **The title's own graphics settings:** they have no performance options.
- **Frame generation was left out on purpose:** generated frames are not rendered frames.

## Known problems

- **What corrupted the graphics heap is not found yet.** It may be a card write the translation gets wrong. Keeping the heap as a copy (fix 2) avoids the crash; one 15-minute drive is the evidence so far.
- **Ragged dark speckle** along the left and right window edges.
- **32 GB of RAM is tight:** the game uses 23–28 GB of private memory. Close browsers before playing.
- **The 60 fps cap is new here.** Whether anything in the game misbehaves above 30 fps (physics, animation, scripts) has not been checked in long play yet.

## How to run

1. Install Rust: the toolchain is pinned in `rust-toolchain.toml`, and `rustup` fetches it. You also need the MSVC build tools with a Windows SDK.
2. Build the diagnostics build, which all the numbers above are of:
   ```powershell
   cargo build --locked --profile diag -p victory --features diagnostics
   ```
3. Tell VIopus where your copy of the game is. Create `local.cmd` next to this README; git ignores it:
   ```bat
   @echo off
   set "VICTORY_GAME_DIR=D:\path\to\your\game"
   ```
4. Translate the shaders once. This takes about 80 s:
   ```powershell
   $env:VICTORY_CACHE_DIR = "$env:LOCALAPPDATA\VIctory\cache-viopus"
   .\target\diag\victory.exe shaders "D:\path\to\your\game\shaders.rpf"
   ```
5. Run `Play-VIopus.cmd` and press Enter at the title screen.
   - It snapshots your saves before and after the game, with `tools\backup-saves.ps1`.
   - It writes the log to `logs\play.log`.
   - To change a setting, set it before you start; see `tools\settings.cmd`.

All forks of VIctory share one save folder, `%LOCALAPPDATA%\victory\data`. Back it up before switching forks: `tools\backup-saves.ps1` makes verified, read-only, timestamped snapshots and never deletes anything.

## Tools (`tools/`)

| File | What it does |
|---|---|
| `settings.cmd` | The default settings, shared by both launchers |
| `play-test.cmd` | Launcher for automated runs |
| `gk.ps1` | Game helper. `launch [NAME=VALUE;...]` presses Enter by itself. `GK_TESTDATA=1` uses a fresh copy of `%LOCALAPPDATA%\VIctory\viopus-test\template` instead of your saves; make the template by copying a snapshot of a save of your own there. It has to be outside the repository, because the runtime refuses to put game data in the source tree. Also `shot`, `key`, `keys`, `status` and `stop`. Keys and screenshots only go to the game window while it is in front. |
| `bench7.ps1` | A/B benchmark on the test save: standing, then running; fps, frame time, draws, private memory, free RAM |
| `longrun.ps1` | A long run on foot with memory and fps every minute, to catch leaks |
| `recorder.ps1` | Records fps, memory and screenshots while you play. It never takes focus and never sends keys. |
| `sampler.py` | A sampling CPU profiler per thread, using `dbghelp` and the build's `.pdb` |
| `backup-saves.ps1` | Save snapshots to `D:\` and `E:\` by default; use `-Roots` to change |

## Credits

VIopus is other people's work with a few changes on top. The full history is kept, so every commit still names its author.

- **[VIctory](https://github.com/Marvisak/VIctory)** by Marvisak and its contributors: the loader, the runtime services, the Direct3D 12 back end and the shader recompiler.
- **[Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD)**: the `rx9070xt` branch VIopus is built on. It brought the RX 9070 XT fixes, the AMD compiler-crash guard, texture uploads in the submission prelude, the FSR 4 bridge, the ambient light idea, pipeline workers, and work by romainhedouin.
- **[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX)**: the "porting, not emulating" renderer ports 1, 2, 5, 6 and 7. Port 1, the title's graphics heap read in place, is what `VICTORY_PORT_ALL` extends.
- **[codec-d/cool_fox](https://github.com/codec-d/cool_fox)**: the `pareto-residency` fork. It was the best build on this PC until VIopus, and many measurements here were made on it.
- **[TaynanGT/Vice-Tay](https://github.com/TaynanGT/Vice-Tay)**: independently found the same padding leak, and the frame generation bridge.
- **[DexNom/VIctory](https://github.com/DexNom/VIctory)**: ray tracing fixes, cube gradients, sparse textures, and the PC FidelityFX bridge.
- **[fxceless/victory-fork](https://github.com/fxceless/victory-fork)**: the fork upstream started from, and submissions prepared on a thread of their own (`VICTORY_ASYNC_SUBMIT`).
- **[FQY55kai/ZJOU-VICTORY](https://github.com/FQY55kai/ZJOU-VICTORY)**.
- **[myokex/victory-amd](https://github.com/myokex/victory-amd)**: the guard over every view of a page (with Spexivus, joroyt and tightfall), and Joshua Odom's reads into title memory.
- **Geckomacabre** and **cxy0072019-sketch**: the texture read-back.
- **[XCL](https://github.com/ivall/xcl)** (GPL-2.0-only) was read for how the same title behaves under another layer. No code from it is here.
- The VIopus measurements and changes were made by edckis with [Claude Code](https://claude.com/claude-code). The upstream README is kept in [`docs/UPSTREAM-README.md`](docs/UPSTREAM-README.md), and a longer log of findings is in [`docs/viopus-findings.md`](docs/viopus-findings.md).

## License

GPL-3.0-or-later, the same as VIctory. See [LICENSE](LICENSE). The one file it does not cover is named in [docs/asset-policy.md](docs/asset-policy.md).
