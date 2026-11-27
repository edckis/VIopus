//! VIopus core rebuild, milestone 1 (`VICTORY_DIRECT=1`, with
//! `VICTORY_POOL_COMMIT=1`): the title's page pool where the title has it,
//! found by address.
//!
//! Every section of the pool is committed whole, so each is opened once as
//! a host heap (`OpenExistingHeapFromFileMapping`) with one buffer placed
//! over all of it. A **directory** gives, per 64 KiB page of title address
//! space below 128 GiB, the number of the section that page shows (0: none)
//! and the page's byte offset in that section's buffer. The title maps
//! physical pages one at a time and often shows a page at several addresses:
//! each address simply has its own entry, and every one of them reaches the
//! same bytes, the title's own. Nothing is copied, tracked or sent back.
//!
//! The directory has the layout of `victory_shader::emit::SLOT_MEMORY`'s
//! (two dwords per page: number + 1, offset), so the translator's lookup can
//! serve both. It lives in memory the card reads over the bus; the title
//! changes its mappings a few dozen times a frame, and each change is two
//! dword stores here.
//!
//! What uses it: nothing yet. Milestone 2 has the translated shaders' buffer
//! accesses go through it (see `docs/core-rebuild-plan.md`).
//!
//! shortcut: a heap opened on a section holds all of its pages in the PC's
//! memory while it stands (the pool is the title's own and lives as long as
//! it does; it is never let go here).

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use victory_shader::emit::MEMORY_PAGES;
use windows::Win32::Graphics::Direct3D12::*;

use crate::descriptor::host::HostHeap;
use crate::host::host;

/// A directory page.
const PAGE: u64 = 1 << 16;

/// Sections that can be numbered (the run of view heap slots is one longer:
/// slot 0 of it reads zeros).
pub(crate) const COPIES: u32 = 63;

/// `VICTORY_DIRECT=1`: on. Without a committed pool (`VICTORY_POOL_COMMIT=1`)
/// it finds nothing to open and the directory stays empty.
pub(crate) fn on() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| crate::switch::on("VICTORY_DIRECT"))
}

/// A section of the pool and, once the host is there, its heap and buffer.
struct Section {
    handle: usize,
    bytes: u64,
    opened: Option<(ID3D12Heap, ID3D12Resource)>,
    /// Refused by the host: never asked again.
    refused: bool,
}

struct Direct {
    /// The CPU's mapping of the directory and the buffer the card reads.
    entries: *mut u32,
    directory: ID3D12Resource,
    gpu: u64,
    /// Section `n` (its number is `n + 1` in the directory).
    sections: Vec<Section>,
    by_handle: HashMap<usize, usize>,
    /// Per host view heap (by address): the first slot of its run, and how
    /// many sections have their view there.
    heaps: HashMap<usize, (u32, u32)>,
}

// SAFETY: the mapping is of memory the struct owns; all access is under the
// mutex (the card reads it on its own, which is the point).
unsafe impl Send for Direct {}

static DIRECT: Mutex<Option<Direct>> = Mutex::new(None);

/// Since the start: pages filled, pages cleared, pages above the directory,
/// views of sections not known; sections opened, refused.
static STATS: [AtomicU64; 6] = [const { AtomicU64::new(0) }; 6];

/// The directory, made when first needed: the runtime makes the pool's
/// sections before the title has a device, and the directory waits for the
/// host. Sections and views told before then are kept and put in then.
static EARLY: Mutex<Early> = Mutex::new((Vec::new(), Vec::new()));

/// The directory's CPU mapping once made, for lock-free looks
/// ([`covers`]), and which sections are open.
static ENTRIES: std::sync::atomic::AtomicPtr<u32> = std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());
static OPEN: [std::sync::atomic::AtomicBool; COPIES as usize] = [const { std::sync::atomic::AtomicBool::new(false) }; COPIES as usize];

/// `f` on the directory, made first if the host is there; without it,
/// `early` on what is kept for then (under the same lock: nothing told in
/// between is lost).
fn with<R>(f: impl FnOnce(&mut Direct) -> R, early: impl FnOnce(&mut Early)) -> Option<R> {
    let mut guard = DIRECT.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Direct::new();
        if let Some(d) = guard.as_mut() {
            let (sections, views) = std::mem::take(&mut *EARLY.lock().unwrap_or_else(|e| e.into_inner()));
            for (handle, bytes) in sections {
                d.section(handle, bytes);
            }
            for (at, len, handle, offset) in views {
                d.mapped(at, len, handle, offset);
            }
            ENTRIES.store(d.entries, Ordering::Release);
        }
    }
    match guard.as_mut() {
        Some(d) => Some(f(d)),
        None => {
            early(&mut EARLY.lock().unwrap_or_else(|e| e.into_inner()));
            None
        }
    }
}

type Early = (Vec<(usize, u64)>, Vec<(usize, usize, usize, u64)>);

impl Direct {
    fn new() -> Option<Direct> {
        let host = host()?;
        let bytes = u64::from(MEMORY_PAGES) * 8;
        let (directory, data) = host.shared_buffer(bytes)?;
        crate::host::name(&directory, || "VIopus direct: directory of title memory by address".into());
        // SAFETY: a fresh mapping of that many bytes.
        unsafe { std::ptr::write_bytes(data, 0, bytes as usize) };
        // SAFETY: a live buffer.
        let gpu = unsafe { directory.GetGPUVirtualAddress() };
        tracing::info!(mb = bytes >> 20, "VIopus direct: the directory of the title's page pool by address is made");
        Some(Direct { entries: data.cast(), directory, gpu, sections: Vec::new(), by_handle: HashMap::new(), heaps: HashMap::new() })
    }

    fn section(&mut self, handle: usize, bytes: u64) {
        if self.by_handle.contains_key(&handle) {
            return;
        }
        if self.sections.len() >= COPIES as usize {
            static ONCE: std::sync::Once = std::sync::Once::new();
            ONCE.call_once(|| tracing::warn!(COPIES, "VIopus direct: no number left for another section of the pool"));
            return;
        }
        self.by_handle.insert(handle, self.sections.len());
        self.sections.push(Section { handle, bytes, opened: None, refused: false });
    }

    fn entry(&self, page: u64) -> *mut u32 {
        // SAFETY: inside the directory (callers check the page).
        unsafe { self.entries.add(page as usize * 2) }
    }

    /// `[at, at + len)` shows `handle`'s bytes from `offset` on.
    fn mapped(&mut self, at: usize, len: usize, handle: usize, offset: u64) {
        let Some(&n) = self.by_handle.get(&handle) else {
            STATS[3].fetch_add(1, Ordering::Relaxed);
            return;
        };
        let (at, len) = (at as u64, len as u64);
        let mut page = at / PAGE;
        while page * PAGE < at + len {
            if page >= u64::from(MEMORY_PAGES) - 1 {
                STATS[2].fetch_add(1, Ordering::Relaxed);
            } else {
                let byte = offset + (page * PAGE - at);
                let entry = self.entry(page);
                // The offset first: a shader that sees the number sees it too.
                // SAFETY: an entry of the directory, under the mutex.
                unsafe {
                    entry.add(1).write_volatile(byte as u32);
                    entry.write_volatile(n as u32 + 1);
                }
                STATS[0].fetch_add(1, Ordering::Relaxed);
            }
            page += 1;
        }
    }

    /// `[at, at + len)` shows nothing of the pool any more.
    fn unmapped(&mut self, at: usize, len: usize) {
        let (at, len) = (at as u64, len as u64);
        let mut page = at / PAGE;
        while page * PAGE < at + len && page < u64::from(MEMORY_PAGES) - 1 {
            // Only whole pages: a partial unmap leaves the rest shown.
            if page * PAGE >= at && (page + 1) * PAGE <= at + len {
                let entry = self.entry(page);
                // SAFETY: an entry of the directory, under the mutex.
                unsafe {
                    if entry.read_volatile() != 0 {
                        entry.write_volatile(0);
                        STATS[1].fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
            page += 1;
        }
    }

    /// Opens what is not open yet.
    fn open(&mut self) {
        let Some(host) = host() else { return };
        for s in self.sections.iter_mut().filter(|s| s.opened.is_none() && !s.refused) {
            let heap = crate::inplace::open(&host.device, crate::inplace::From::Section(s.handle));
            let placed = heap.as_ref().ok().map(|heap| crate::inplace::place(&host.device, heap, 0, s.bytes));
            match (heap, placed) {
                (Ok(heap), Some(Ok(buffer))) => {
                    crate::host::name(&buffer, || format!("VIopus direct: a section of the title's page pool ({} MB)", s.bytes >> 20));
                    tracing::info!(section = format_args!("{:#x}", s.handle), mb = s.bytes >> 20, "VIopus direct: a section of the pool opened as a host heap");
                    s.opened = Some((heap, buffer));
                    STATS[4].fetch_add(1, Ordering::Relaxed);
                    if let Some(&n) = self.by_handle.get(&s.handle) {
                        OPEN[n].store(true, Ordering::Release);
                    }
                }
                (heap, placed) => {
                    let why = match (heap, placed) {
                        (Err(e), _) => format!("not opened: {e}"),
                        (_, Some(Err(e))) => format!("no buffer placed: {e}"),
                        _ => "?".to_owned(),
                    };
                    tracing::warn!(section = format_args!("{:#x}", s.handle), mb = s.bytes >> 20, why, "VIopus direct: a section of the pool refused");
                    s.refused = true;
                    STATS[5].fetch_add(1, Ordering::Relaxed);
                }
            }
        }
    }
}

/// The runtime made a section of the pool (`committed`: with `SEC_COMMIT`).
pub(crate) fn section(handle: usize, bytes: u64, committed: bool) {
    if !on() || !committed {
        return;
    }
    with(|d| d.section(handle, bytes), |e| e.0.push((handle, bytes)));
}

/// The runtime shows `section`'s bytes from `offset` on at `[at, at + len)`.
pub(crate) fn mapped(at: usize, len: usize, section: usize, offset: u64) {
    if !on() {
        return;
    }
    with(|d| d.mapped(at, len, section, offset), |e| e.1.push((at, len, section, offset)));
}

/// What `[at, at + len)` showed is gone.
pub(crate) fn unmapped(at: usize, len: usize) {
    if !on() {
        return;
    }
    let end = at.saturating_add(len);
    with(|d| d.unmapped(at, len), |e| e.1.retain(|&(a, l, _, _)| a + l <= at || a >= end));
}

/// What a draw binds for a shader that finds title memory through the
/// directory.
pub(crate) struct Ready {
    pub(crate) directory: u64,
    /// The view heap slot that reads zeros; section `n`'s view is `n + 1`
    /// further.
    pub(crate) base: u32,
}

/// For a draw in `heap`: the directory and the run of section views there.
pub(crate) fn ready(heap: &HostHeap) -> Option<Ready> {
    with(
        |d| {
        d.open();
        let key = std::ptr::from_ref(heap) as usize;
        let (base, made) = match d.heaps.get(&key) {
            Some(&run) => run,
            None => {
                // Held for the heap's life.
                let base = heap.dynamic(COPIES + 1)?;
                for n in 0..=COPIES {
                    heap.null_raw_uav_at(base + n);
                }
                (base, 0)
            }
        };
        for (n, s) in d.sections.iter().enumerate().skip(made as usize) {
            if let Some((_, buffer)) = &s.opened {
                heap.raw_uav_at(base + 1 + n as u32, buffer, 0, s.bytes);
            }
        }
        let opened = d.sections.iter().take_while(|s| s.opened.is_some() || s.refused).count() as u32;
        d.heaps.insert(key, (base, opened));
        Some(Ready { directory: d.gpu, base })
        },
        |_| {},
    )
    .flatten()
}

/// Whether every page of `[at, at + len)` is in the directory and its section
/// open: an access there reaches the title's own bytes. Without a lock (a
/// draw asks it per buffer); a mapping that changes meanwhile is the title's
/// race, as on the console.
pub(crate) fn covers(at: u64, len: u64) -> bool {
    let entries = ENTRIES.load(Ordering::Acquire);
    if entries.is_null() || len == 0 {
        return false;
    }
    let mut page = at / PAGE;
    while page * PAGE < at + len {
        if page >= u64::from(MEMORY_PAGES) - 1 {
            return false;
        }
        // SAFETY: an entry of the directory, which lives for good.
        let n = unsafe { entries.add(page as usize * 2).read_volatile() } as usize;
        if n == 0 || !OPEN.get(n - 1).is_some_and(|o| o.load(Ordering::Acquire)) {
            return false;
        }
        page += 1;
    }
    true
}

/// The line every ten seconds or so.
pub(crate) fn say() {
    if !on() {
        return;
    }
    static LAST: AtomicU64 = AtomicU64::new(0);
    let now = crate::host::now_ms();
    let last = LAST.load(Ordering::Relaxed);
    if now < last + 10_000 || LAST.compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed).is_err() {
        return;
    }
    let s: Vec<u64> = STATS.iter().map(|s| s.load(Ordering::Relaxed)).collect();
    let shown = with(
        |d| {
            d.open();
            let mut n = 0u64;
            for page in 0..u64::from(MEMORY_PAGES) {
                // SAFETY: an entry of the directory, under the mutex.
                n += u64::from(unsafe { d.entry(page).read_volatile() } != 0);
            }
            (n, d.sections.iter().filter(|s| s.opened.is_some()).map(|s| s.bytes).sum::<u64>())
        },
        |_| {},
    );
    let (pages, open_bytes) = shown.unwrap_or((0, 0));
    tracing::info!(
        "VIopus direct: {} pages of title addresses ({} MB) show the pool in place; sections open {} ({} MB), refused {}; since the start pages filled {}, cleared {}, above the directory {}, views of sections not known {}",
        pages,
        (pages * PAGE) >> 20,
        s[4],
        open_bytes >> 20,
        s[5],
        s[0],
        s[1],
        s[2],
        s[3]
    );
}
