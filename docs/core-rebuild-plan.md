# Core rebuild plan (branch `core-rebuild`)

The goal is more than 60 fps; the first stop is a stable 30. The plan follows from the measurements of 2026-11-27 (details in [viopus-findings.md](viopus-findings.md)).

## What the measurements say

- **The system is flat.** Per 48 ms frame standing:
  - our submit thread works 38–47 ms;
  - the copy-back thread (relay and landing) about 20 ms;
  - the pass over the descriptor heap about 13 ms;
  - list translation 4 cores (87,000 calls a frame at 3.7 µs each);
  - the game's threads lose about 35 ms of CPU a frame to our write traps.
- **Trimming one part moves the limit to the next.** Big buffers in place cut the submit thread's prep by 19%, and fps rose only 1–5%. A big gain needs whole stages removed.
- **Most of those stages exist only because buffers have two copies:**
  - refreshes of host copies;
  - write watch and guards (`GetWriteWatch`, `VirtualProtect`, faults);
  - copy-back of what shaders wrote;
  - compares;
  - most of the descriptor mirroring for buffers.
- **The card is busy 27–28 ms a frame standing.** It overlaps our work, so it sits only 1–8 ms on the critical path.
  - Barriers are not the cause: dropping all of them saved at most 2 ms.
  - The time is spread over about 10,000 small indirect draws and 1,600 dispatches. Deeper than that needs AMD's Radeon GPU Profiler.

## What is already there

- **The pool can be one heap.** With `VICTORY_POOL_COMMIT=1` (commit 1173f28), the page pool's four sections (220, 297, 185 and 3,977 MB) are committed whole.
  - The game runs as before.
  - A committed section opens as one host heap (`OpenExistingHeapFromFileMapping`).
  - The card reads it over PCIe at about 25 GB/s, the same as today's shared buffers.
  - The largest section, 3,977 MB, fits one raw view: byte offsets fit in 32 bits.
- **The translator already has a software page table.** `memory()` in `victory-shader/src/emit/lower.rs` turns a 40-bit title address into a 64 KiB page, then a directory entry (copy number, offset), then a bindless raw view and a byte offset. The host side is `victory-gpu/src/memory.rs`. Today only the ray-tracing structure builder and its walkers use it.

## The rebuild, in milestones

Each milestone is behind a switch and gets a clean alternating A/B (`tools\bench7.ps1`, with the log checked for the switch).

1. **The directory points at the title's memory itself.**
   - Each committed pool section is opened once as a heap with one raw view.
   - Private memory committed whole is opened in parts, as `VICTORY_INPLACE` does now.
   - When the title maps pool pages at an address, the directory entry of each 64 KiB page becomes (section view, page offset in the section). Aliased pages need nothing extra.
   - The ray-tracing shaders are the first users: no arenas, no faults for pool memory.
   - Expected fps change: none. This milestone proves the path.
2. **Buffer accesses through the directory (translator).**
   - `buffer_*` loads, stores and atomics read their buffer descriptor (V#) words from title memory, which is now in place. They take the base address, stride and record count from it, add the offset, bound it as the console does (out of range reads 0), and go through `memory()`.
   - Raw and structured accesses come first. Typed (`format`) loads keep today's views until the format can be decoded in the shader.
   - The host keeps everything else as it is, so both paths can be compared.
   - Expected: no CPU gain yet; it measures the card's cost of the extra lookup.
3. **The host stops keeping copies of buffers only reached through the directory.**
   - That means no refreshes, no write watch or guards, no copy-back, no compares, and no descriptor mirroring for those buffers.
   - This is where the CPU time comes back. Expected: most of the submit thread's refresh work (about 16 ms), the relay's landing (about 20 ms), and the title threads' write traps.
4. **Constant buffers and typed buffers** through the same path. Then textures stay the only copies.
5. **Then the card:** a Radeon GPU Profiler capture, to see whether the 28 ms is clocks, per-draw overhead of ExecuteIndirect, or the translated shaders.

## Risks

- **Out-of-range accesses:** the console returns 0 for buffer reads past the record count, and some shaders rely on it. Milestone 2 must bound every access.
- **Writes by the card into memory the CPU reads:** this already happens with port 1. The title keeps allocator lists in its 32-bit graphics heap, which crashed once when that heap was in place (`VICTORY_PORT_LOW`). That heap stays a copy until the cause is known.
- **PCIe reads:** data the card reads many times a frame (big static meshes) is slower from the PC's memory than from the card's own. Milestone 3 must keep a card copy for buffers the CPU never writes.
- **Scale:** milestones 2 and 3 change the translator and the host's descriptor handling, the two biggest parts of the layer. That is weeks, not days, and the first CPU gain is at milestone 3.

## Result of milestones 1 and 2 (2026-11-27 night): stopped

- **Milestone 1** works. The pool's four sections open as host heaps, and the directory follows the title's mappings (10.7 GB of addresses).
- **Milestone 2** works, but rendering is not fully right (the road is darker in places) and it adds GPU work. Whole-dword buffer loads through shader resource views read the pool in place page by page.
  - The host's view stays the fallback where a page is not in the pool or the card writes it.
  - Hidden write paths had to be found one by one: copy-back landings, copies, render targets.
- **Why it stops here (measured, 10 s standing, `VICTORY_DIRECT=1`):**

  | Refresh requests of host copies | Requests | Share |
  |---|---|---|
  | All | 32 M | 100% |
  | Of copies the card writes | 19.1 M | 60% (98% of the bytes) |
  | Of memory outside the pool (private memory, above the directory, not mapped) | 8.6 M | 27% |
  | Of memory that could be read in place | 2.3 M | **7%** |
  | Crossing out of the pool, or pages flagged written | 2.0 M | 6% |

  Milestone 3 could leave out at most the 7%. The work is in buffers the card writes, which need every reader and writer in place at once. The rest is private memory, which `VICTORY_INPLACE` handles in another way.
- **AMD driver leak:** each run with the pool opened as host heaps (`OpenExistingHeapFromFileMapping` on the committed sections) leaves about 4.3 GB of commit charge behind after the game exits, until a reboot. After seven runs the PC had 42 GB committed with nothing running (11.7 GB after a reboot). An earlier run went past the commit limit, and the title and another program died with it. **Do not run `VICTORY_DIRECT=1` without a reboot plan.** `tools\memguard.ps1` now guards every automated run.
- The code stays on `core-rebuild`, off by default (`VICTORY_POOL_COMMIT`, `VICTORY_DIRECT`).
