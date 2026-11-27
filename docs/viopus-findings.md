# VIopus findings log

All of this was measured on the PC in the [README](../README.md): Ryzen 7 9800X3D, RX 9070 XT, 32 GB, Series S profile. It is ordered by topic, newest first within each.

## The game's time against ours (core-rebuild step 1, 2026-11-27 evening)

**How it was measured:**
- **Traces:** `VICTORY_TIMELINE=150+190+260+290,10,<file>` on `tools\bench7.ps1`, four traces of 10 frames, two standing and two on foot. The same was run once with in-place memory off (`VICTORY_PORT_ALL=0;VICTORY_INPLACE=0`).
- **CPU split:** `tools\threadtimes.py` (new) gives the kernel and user time of every thread over 20 s standing.
- **The card:** one run with `VICTORY_GPU_TIMING=1`, which runs each list on its own; frame rate in that mode is meaningless.

**The critical chain**, the chain of work and waits each present came out of, per frame:

| | Standing (47–49 ms frames) | On foot (33–38 ms frames) |
|---|---|---|
| The game's own code (its threads, outside our calls) | 13–17 ms, 8–12 of it the main thread | 14–18 ms, ~12 the main thread |
| The card | 6–7 ms | 1–2 ms |
| Woken threads waiting for a core | 3.4–4.9 ms | 3.8–4.2 ms |
| The game polling with `Sleep` | 1.9–3.3 ms | 2.7–3.2 ms |
| Our layer: refreshes of copies, `VirtualProtect`, `GetWriteWatch`, jobs, submit steps, landing | ~15–20 ms | ~8–12 ms |

**The game's main thread:**
- It runs 20–24 ms a frame.
- About 82% of that is user time and 18% kernel time (95 of 518 ms per second). The kernel part is page faults and system calls, which is our layer's.
- Only about 60% of its running time lies on the critical chain. The game overlaps the rest with our work.

**CPU load, standing:**
- The game's 49 threads use 4.3 cores together (10% kernel).
- **Our 8 list-translation threads use 4.1 cores**, each about half a core.
- The whole process uses about 11 of the 16 logical processors, which is 8 physical cores. The game's threads therefore share physical cores with ours through SMT.

**The card:**
- It is busy (submission start to end, timestamps) 27–28 ms a frame standing and 18–22 ms on foot.
- It is the same with the copies (28.4 ms), so reading memory in place over PCIe doesn't slow it.
- Its time is mostly in parallel, so it lies only 1–8 ms on the chain. That is why skipping a third of the draws (the shadow maps) changed nothing.
- In the timing run (lists one at a time), about 85% of the card's time is the title's translated lists. Our own lists are the other ~15%: preludes refreshing copies (8 ms) and compares (2.6 ms) of 72 ms.
- The "card ~9.5 ms" figure used earlier is outdated. A Series S renders this scene within 33 ms on a GPU several times slower, so ~24 ms of title work here suggests the translated GPU work is 2–3× slower than it should be. That is not proven yet; per-command times need `VICTORY_GPU_TIMING=1` with `VICTORY_D3D12_DRED=1`.

**The card, follow-up (same evening):**
- **Per command** (`VICTORY_GPU_TIMING=1` with `VICTORY_D3D12_DRED=1`, lists one at a time): 1,580 kinds of commands with no hot one. By kind, per frame: ExecuteIndirect 17.9 ms in 10,126 commands, dispatches 11.5 ms in 1,583, mesh draws 3.5 ms, plain draws 1.6 ms.
- **Barriers:** the title's barrier groups are 1,006 full waits for earlier shader writes a frame. Dropping all of them (`VICTORY_BARRIER_TEST=groups` or `both`, timing only) left the card at 26–28 ms busy a frame against 27–28. So barriers are not what the card spends its time on.

**The pool committed** (`VICTORY_POOL_COMMIT=1`, new):
- The game runs as before, and port 1 still places 544 MB.
- The census sees the four sections (220, 297, 185 and 3,977 MB) as committed, so they can be opened as one heap each.
- The probe opens a committed section in 72 ms per GB. The card copies 1 GB out of it in 40 ms, the same speed as today's shared buffers (37.5 ms).
**What it means:**
- **30 fps:** our ~15–20 ms on the chain and the wake-up delays come out with the core rebuild, which leaves the game's 13–18 ms plus the card. 30 looks reachable without changing the game. The card at 28 ms standing is close to the 33 ms limit, though.
- **60 fps (16.7 ms), three walls:**
  - **The game's main thread:** ~17–20 ms of its own code at today's load. Freeing the four cores our list translation takes may shorten it; how much is unknown.
  - **The card:** 28 ms standing, so it needs to be about 2× faster.
  - **Our layer:** it must be completely off the chain.

## Where a frame goes (2026-11-27)

**Before VIopus (cool_fox, city street, about 12,000 draws, 18 fps):**

- **The game's main thread** is busy only 42% of the time, about 23 ms of a 54 ms frame. Of that, 89% is the game's own code. The layer's code inside it, write traps included, is under 3%.
- **The rest of the frame the game waits**, 13–16 ms of it at presents, for the queue of about 16 submissions behind the layer's submit thread.
- **The submit thread works 47.5 ms a frame:**

  | Part | ms per frame |
  |---|---|
  | Bringing copies up to date (81% of the checks find nothing new) | 17.5 |
  | Waiting for the descriptor-heap records | 11.3 |
  | Copies in the card's memory | 4.1 |
  | Asking the write watch | 3.6 |
  | Planning steps on the card | 3.5 |

  The thread is only about 40–56% busy; the rest is spent handing work to helper threads and waiting for them.
- **What the memory columns mean:** in the copy statistics, `memory 0x40000` is `MEM_MAPPED`, the title's page pool, and `0x20000` is `MEM_PRIVATE`. The biggest per-frame streams are pool memory. The largest is the 174 MB graphics heap, which was copied on the card 10–11 times a frame, once per submission.
- **The audio thread** spends about 25% of its time in the layer's APU Opus decoding. It is not on the frame's critical path.

**After VIopus in-place memory:**

- The submit thread drops to 24–33 ms a frame, and the game waits 0 ms at presents.
- The card is about 69% busy. It sits idle about 15 ms a frame, 12 ms of that because the game had not submitted yet.
- **A 4-frame timeline** (`VICTORY_TIMELINE`) shows the critical path spread out: the card running submissions about 9.5 ms, list translation about 14 ms, the game's own code, and frames that vary from 28 to 60 ms.

## The padding leak (2026-11-26)

- **The symptom:** a 53-minute session ran at 21–22 fps for half an hour, then 8–10 fps. The game had 40 GB private, 0 MB of RAM free, 12,000–21,000 pages a second read back from disk, and system commit at 66.6 of 67.6 GB.
- **The diagnosis:** the diagnostics build's memory map showed the process heap growing from 0.9 to 9.5 GB. The memory line showed "distinct views kept" at 28.8 million, and "shapes of placed views kept" at exactly 4,194,304, the 22-bit cap.
- **Which words vary:** a per-word count of distinct values across the shapes showed the varying words were padding:
  - `D3D12_RESOURCE_DESC` words 1 and 13;
  - the SRV description's word 3;
  - union words past the member its dimension uses, such as word 9 of buffer views.

  Values like `0x3e66e1bc`, `0x7ffd` and `0x0e3f8d00` are stack bytes.
- **The fix** is in `descriptor.rs` (`tidy_resource`, `tidy_view`), with unit tests in `tidy_tests`.
- **After the fix:** about 20 new shapes a second, from genuine variety in buffer sizes. A 45-minute run on foot kept the heap flat.

## In-place memory (2026-11-27)

- **What the probe found** (`inplace.rs`, `VICTORY_INPLACE_PROBE`): the card can read and write the title's private memory, and committed sections, in place.
- **What the driver allows:**
  - `OpenExistingHeapFromFileMapping` refuses a `SEC_RESERVE` section. That is how `xmem` makes the page pool, except under Wine.
  - Tile mappings into a heap opened from existing memory remove the device. So a card-side page table over scattered 64 KiB pages is impossible.
- **How port 1 works** (VIctory-7900XTX): it maps its own view of a section stretch and opens it with `OpenExistingHeapFromAddress1`. The title stays free to remap its own views.
- **`VICTORY_PORT_ALL=1`** (VIopus) lifts port 1's 4 GiB limit. About 87 regions (about 0.7 GB) go in place. With `VICTORY_INPLACE=2`, 3,400 private title buffers (0.38 GB) and about 80 windows join them.
- **What is still refused:** about 6,000 buffers, mostly 4 MiB windows over pool memory with unmapped pages ("Holes"), or over private memory that is not committed in full.
  - Smaller windows, `VICTORY_WINDOW_KB` 256 or 64, put up to 3.5 GB in place, but gave no fps gain and heavy churn: 28,000 regions released as the game remapped memory.

## Ruled out (2026-11-26)

- **Threads and priorities:**
  - `VICTORY_THIN_THREADS` of 4, 6 or 12; with SMT on, 8 (the default) was best.
  - `VICTORY_WIDE_THREADS=8`; `VICTORY_HELPER_PRIORITY` (an experimental patch); spinning pools (worse: they take the SMT sibling's time).
  - Per-thread affinity layouts; the power plan (High vs Balanced, within noise); process priority.
- **Build and memory switches:** thin LTO with `codegen-units=1`; `VICTORY_INPLACE=1` alone; `VICTORY_HEAP_SYNC_EARLY=1`; `VICTORY_JOIN_PARTS=32`.
- **Game data:** the title's own settings have no performance options. Level of detail and density live in compressed RPF9 archives and are not editable.
- **VIctory-7900XTX as shipped** was slower on this PC (83 ms vs 48 ms a frame) and its ports crashed the AMD compiler. Belobug's compiler-crash guard is what made them usable.
- **Vice-Tay** (AMD profile) was slower than cool_fox here.

## The AMD compiler crash

- **Where:** `amdxc64.dll+0x861b9f` (driver 32.0.32029.2010, RDNA4), on certain compute pipelines.
- **The first fix:** `victory warm` finds them and lists them in `warm-bad.txt`, and a skip of those keys at pipeline creation held up for 98 minutes.
- **Belobug's guard** catches the crash at run time: it parks the worker, adds the pipeline to the list, and starts a new worker.
- **The root cause** of 29 of them (the `CS_RaytracingResolve` family) is fixed upstream in Belobug's `a-publier` branch (PR #324: `getDimensions` is no longer merged by the REUSE pass). Those are ray-tracing shaders, which are off for speed here.
