//! Title memory by address, for translated shaders that read and write
//! through raw 40-bit addresses (`victory_shader::emit::SLOT_MEMORY`: the
//! console's ray-tracing structure builder and the programs that walk its
//! structures; the structures themselves lie in plain title memory, in no
//! buffer object).
//!
//! The copies are the ones every other access uses ([`crate::shadow`]: a
//! title buffer's copy, or the 4 MiB window of memory outside buffers), so
//! a root view and a raw address reach the same host bytes. This module
//! keeps what a shader needs to find them:
//!
//! - the **directory**: per 64 KiB page of title address space the number
//!   of the copy that holds the page (0: none) and the page's byte offset
//!   in it; one buffer for all lists, entries only ever go from empty to
//!   filled;
//! - per view heap a run of slots with a raw unordered access view of each
//!   numbered copy (slot 0 of the run: a null view, for pages without a
//!   copy);
//! - the **faults**: the page numbers shaders found empty, read back here
//!   once a frame, so the copies exist from the next frame on. A pointer a
//!   shader takes out of memory cannot be known before it runs; the
//!   addresses a dispatch is given as root views are made ready before it.
//!
//! **A page that is not there when a shader touches it is a lost access**:
//! the read gives 0, the store is dropped, and the fault note only helps
//! the next frame. For the structure builder that is the same as a dropped
//! stage, so before a dispatch the host makes ready everything it can see
//! the dispatch name: the whole copy around each root view, around each
//! pair of root constants that is a title address and around each root
//! constant that is one in 256-byte units (the builder passes structures
//! all three ways), and the 4 MiB after each (a structure may cross a
//! window's end).
//! shortcut: what a stage reaches only through pointers it reads out of
//! memory (InitHeaders' table of structure addresses, LoadInstances'
//! instance records) is not made ready unless something else named it;
//! the fault count in the log says whether that happens. The whole answer
//! is the extent of the title's allocation around an address, which the
//! memory module of the layer knows and this one does not ask yet.
//!
//! shortcut: a copy that is numbered is kept for the rest of the run, and
//! there are at most [`copies_limit`] of them (4 MiB windows mostly: 4 GiB at
//! most). Every dispatch of such a shader brings all numbered copies up to
//! date and, if it can store, declares all of them written (the bytes are
//! compared on the CPU afterwards, as for any unordered access view): a
//! dirty-page mask written by the shader would bound both.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use victory_shader::emit::{MEMORY_FAULTS, MEMORY_PAGES};
use windows::Win32::Graphics::Direct3D12::*;

use crate::descriptor::host::HostHeap;
use crate::host::{HostList, host};
use crate::shadow::Shadow;

/// Copies that can be numbered (the run of heap slots is one longer). A
/// listed frame of the opening cutscene names about 50 windows; with the
/// ray-tracing structure builder running, 1023 were used up in 20 seconds
/// (26 November: the title's graphics memory is thousands of separate
/// 64 KiB allocations, a copy each), so `VICTORY_MEMORY_COPIES` sets it
/// (default 8191).
static COPIES_N: std::sync::OnceLock<u32> = std::sync::OnceLock::new();
fn copies_limit() -> u32 {
    *COPIES_N.get_or_init(|| {
        std::env::var("VICTORY_MEMORY_COPIES").ok().and_then(|v| v.parse().ok()).unwrap_or(8191).clamp(1023, 65535)
    })
}
/// A window of memory outside buffers (`shadow.rs`).
const CELL: u64 = 4 << 20;
/// A buffer placed over the page pool covers this much of it (a shader's
/// byte in a raw view is 32 bits).
const CHUNK: u64 = 1 << 30;

/// What a copy number stands for.
enum Held {
    /// A host copy of title memory, refreshed and compared as any.
    Shadow(Arc<Shadow>),
    /// A buffer placed over 1 GiB of the title's page pool, opened in place.
    Pool { buffer: ID3D12Resource, len: u64 },
}

/// `VICTORY_POOL_IN_PLACE=1` (with the runtime making the page pool's
/// sections committed, `xmem`): shaders that reach title memory by address
/// reach the pages of the page pool in the pool itself, every view's pages
/// entered as soon as it is mapped. No copy, so no access is lost to a page
/// that had none (the ray-tracing structure builder lost hundreds a frame),
/// no refresh, no copy back, and the pool's pages seen at every address
/// that shows them.
pub(crate) fn pool_in_place() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("VICTORY_POOL_IN_PLACE").is_some_and(|v| v == "1"))
}

/// The runtime mapped a view of the page pool at `[at, at + len)`.
pub(crate) fn pool_view(at: usize, len: usize) {
    if !pool_in_place() {
        return;
    }
    let mut guard = MEMORY.lock().unwrap_or_else(|e| e.into_inner());
    let Some(m) = guard.as_mut() else { return };
    m.forget(at as u64, len as u64);
    let mut page = (at as u64).next_multiple_of(PAGE);
    while page + PAGE <= (at + len) as u64 {
        m.pool_entry(page);
        page += PAGE;
    }
}

/// What `[at, at + len)` showed is gone: their entries emptied.
pub(crate) fn pool_gone(at: usize, len: usize) {
    if !pool_in_place() {
        return;
    }
    let mut guard = MEMORY.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(m) = guard.as_mut() {
        m.forget(at as u64, len as u64);
    }
}
/// A directory page.
const PAGE: u64 = 1 << 16;

struct Memory {
    /// Buffer, its mapping, its GPU address.
    directory: (ID3D12Resource, *mut u32, u64),
    faults: (ID3D12Resource, *mut u32, u64),
    /// Copy `n` is `copies[n - 1]`.
    copies: Vec<Held>,
    /// Pool chunks by section and chunk number: their copy number.
    chunks: HashMap<(usize, u64), usize>,
    /// Per host view heap (by address): the first slot of its run, and how
    /// many copies have their view there.
    heaps: HashMap<usize, (u32, u32)>,
    /// The frame the faults were last read in.
    frame: u64,
    /// Pages asked for this frame that are not the title's memory.
    refused: std::collections::HashSet<u64>,
}

// SAFETY: the mappings are of buffers the struct owns; all access is under
// the mutex.
unsafe impl Send for Memory {}

static MEMORY: Mutex<Option<Memory>> = Mutex::new(None);

/// What a draw binds.
pub(crate) struct Ready {
    pub(crate) directory: u64,
    pub(crate) faults: u64,
    /// The view heap slot of the null view; copy `n`'s view is `n` further.
    pub(crate) base: u32,
}

impl Memory {
    fn new() -> Option<Memory> {
        let host = host()?;
        let make = |dwords: u64, what: &str| {
            let (buffer, data) = host.shared_buffer(dwords * 4)?;
            crate::host::name(&buffer, || format!("title memory by address: {what}"));
            // SAFETY: a fresh mapping of at least that many bytes.
            unsafe { std::ptr::write_bytes(data, 0, (dwords * 4) as usize) };
            // SAFETY: a live buffer.
            let gpu = unsafe { buffer.GetGPUVirtualAddress() };
            Some((buffer, data.cast::<u32>(), gpu))
        };
        tracing::info!("title memory by address: a shader reads or writes through raw addresses");
        Some(Memory {
            directory: make(u64::from(MEMORY_PAGES) * 2, "directory")?,
            faults: make(u64::from(MEMORY_FAULTS), "faults")?,
            copies: Vec::new(),
            chunks: HashMap::new(),
            heaps: HashMap::new(),
            frame: u64::MAX,
            refused: Default::default(),
        })
    }

    /// Gives the page of `address` its copy, if it has none and the memory
    /// is the title's.
    fn map(&mut self, address: u64) {
        let page = address / PAGE;
        // The last entry stays empty: addresses past the directory read it.
        if page >= u64::from(MEMORY_PAGES) - 1 {
            return;
        }
        // SAFETY: inside the directory's mapping.
        let entry = unsafe { self.directory.1.add(page as usize * 2) };
        // SAFETY: as above.
        if unsafe { entry.read() } != 0 {
            return;
        }
        let start = page * PAGE;
        if self.pool_entry(start) {
            return;
        }
        // A shader's pointer, or a constant taken for an address, may be
        // anything: only memory the title has.
        if self.refused.contains(&page) {
            return;
        }
        if !crate::texture::committed(start as *const u8, PAGE as usize) {
            self.refused.insert(page);
            return;
        }
        // The copy a root view at that address would get; a buffer that
        // ends inside the page is passed over for what holds all of it.
        let whole = |s: &Arc<Shadow>| s.offset_in(start).is_some_and(|_| s.left(start) >= PAGE);
        let Some(shadow) = crate::shadow::find(start, 1)
            .filter(whole)
            .or_else(|| crate::shadow::find(start, PAGE).filter(whole))
        else {
            return;
        };
        // SAFETY: a live buffer.
        let flags = unsafe { shadow.buffer.GetDesc() }.Flags;
        if flags.0 & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS.0 == 0 {
            return;
        }
        let n = match self.copies.iter().position(|c| matches!(c, Held::Shadow(s) if Arc::ptr_eq(s, &shadow))) {
            Some(n) => n,
            None if self.copies.len() < copies_limit() as usize => {
                self.copies.push(Held::Shadow(shadow.clone()));
                let n = self.copies.len() - 1;
                // Every page the copy holds whole, not only the one asked
                // for: a structure is more than 64 KiB.
                // shortcut: a page of a title buffer inside this one that
                // has a copy of its own is given this copy too.
                let (first, len) = shadow.span();
                let mut at = first.next_multiple_of(PAGE);
                while at + PAGE <= first + len && at / PAGE < u64::from(MEMORY_PAGES) - 1 {
                    // SAFETY: inside the directory's mapping.
                    let other = unsafe { self.directory.1.add((at / PAGE) as usize * 2) };
                    // SAFETY: as above; the offset first, as below.
                    unsafe {
                        if other.read() == 0 {
                            other.add(1).write_volatile((at - first) as u32);
                            other.write_volatile(n as u32 + 1);
                        }
                    }
                    at += PAGE;
                }
                n
            }
            None => {
                static ONCE: std::sync::Once = std::sync::Once::new();
                ONCE.call_once(|| {
                    tracing::warn!(copies = copies_limit(), "title memory by address: no number left for another copy; its pages read zeros")
                });
                return;
            }
        };
        let offset = shadow.offset_in(start).unwrap_or(0);
        // The offset first: a shader that sees the number sees it too.
        // SAFETY: inside the directory's mapping.
        unsafe {
            entry.add(1).write_volatile(offset as u32);
            entry.write_volatile(n as u32 + 1);
        }
    }

    /// The page at `start` (a multiple of [`PAGE`]) as a view of the title's
    /// page pool, opened in place: its entry names the pool chunk and the
    /// byte in it. False if pool memory is not in place or the page is not
    /// such a view.
    fn pool_entry(&mut self, start: u64) -> bool {
        if !pool_in_place() {
            return false;
        }
        let Some((section, offset, bytes)) = crate::inplace::committed_view_of(start as usize) else {
            return false;
        };
        let chunk = offset / CHUNK;
        let n = match self.chunks.get(&(section, chunk)) {
            Some(&n) => n,
            None => {
                if self.copies.len() >= copies_limit() as usize {
                    return false;
                }
                let Some(heap) = crate::inplace::section_heap(section) else { return false };
                let Some(host) = crate::host::host() else { return false };
                let len = CHUNK.min(bytes - chunk * CHUNK);
                let buffer = match crate::inplace::place(&host.device, &heap, chunk * CHUNK, len) {
                    Ok(b) => b,
                    Err(e) => {
                        static ONCE: std::sync::Once = std::sync::Once::new();
                        ONCE.call_once(|| tracing::warn!(error = %e, "a buffer over the title's page pool was refused: copies as before"));
                        return false;
                    }
                };
                crate::host::name(&buffer, || format!("title memory by address: page pool chunk {chunk}"));
                self.copies.push(Held::Pool { buffer, len });
                let n = self.copies.len() - 1;
                self.chunks.insert((section, chunk), n);
                n
            }
        };
        let page = start / PAGE;
        if page >= u64::from(MEMORY_PAGES) - 1 {
            return false;
        }
        // SAFETY: inside the directory's mapping; the offset first.
        unsafe {
            let entry = self.directory.1.add(page as usize * 2);
            entry.add(1).write_volatile((offset - chunk * CHUNK) as u32);
            entry.write_volatile(n as u32 + 1);
        }
        true
    }

    /// Pages that show something else now: their entries emptied.
    fn forget(&mut self, at: u64, len: u64) {
        let (first, end) = (at / PAGE, (at + len).div_ceil(PAGE).min(u64::from(MEMORY_PAGES) - 1));
        for page in first..end {
            // SAFETY: inside the directory's mapping.
            unsafe { self.directory.1.add(page as usize * 2).write_volatile(0) };
        }
    }

    /// The pages shaders found empty since the last frame.
    fn take_faults(&mut self) {
        let mut pages = Vec::new();
        for i in 1..MEMORY_FAULTS as usize {
            // SAFETY: inside the faults' mapping; the GPU may be writing,
            // a number missed now is written again next frame.
            let at = unsafe { self.faults.1.add(i) };
            // SAFETY: as above.
            let page = unsafe { at.read_volatile() };
            if page != 0 {
                pages.push(page);
                // SAFETY: as above.
                unsafe { at.write_volatile(0) };
            }
        }
        if !pages.is_empty() {
            // Each is an access that read 0 or was dropped.
            static SAID: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            if SAID.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 50 {
                tracing::warn!(
                    pages = pages.len(),
                    first = format_args!("{:#x}", u64::from(pages[0]) * PAGE),
                    "title memory by address: shaders touched pages that had no copy (those accesses read 0 or were dropped); the copies are made now"
                );
            }
        }
        for page in pages {
            self.map(u64::from(page) * PAGE);
        }
    }

    /// For a stage of the structure builder: the title's allocation around
    /// `address`, from `address` on (at most `VICTORY_BVH_WHOLE_MB`; off by
    /// default: the title's graphics memory turned out to be thousands of
    /// 64 KiB allocations, so the allocation around an address is mostly
    /// that one page), each 4 MiB of it given its copy. A stage reaches memory
    /// through pointers it reads out of memory (stage 0 writes each box
    /// where its record says), and a page with no copy when it runs is a
    /// lost access: the stores dropped, the reads zeros, so the next stages
    /// follow zero pointers and stage 19 writes its parent links over the
    /// title's objects (runs of 26 November: 388 pages lost in the first
    /// builder frame, the copies used up three minutes later). The pointers
    /// lie in the allocations the stages are given.
    /// shortcut: once per allocation and 256 MiB step; `VirtualQuery` walks
    /// the page tables, slow on the title's 1 GB blocks.
    fn name_whole(&mut self, address: u64, named: &mut Vec<usize>) {
        use windows_sys::Win32::System::Memory::{MEM_COMMIT, MEMORY_BASIC_INFORMATION, VirtualQuery};
        static CAP: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
        static DONE: Mutex<Option<std::collections::HashSet<(usize, u64)>>> = Mutex::new(None);
        let cap = *CAP.get_or_init(|| {
            std::env::var("VICTORY_BVH_WHOLE_MB").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(0) << 20
        });
        if cap == 0 {
            return;
        }
        let query = |at: usize| {
            // SAFETY: plain data filled in by the query.
            let mut m: MEMORY_BASIC_INFORMATION = unsafe { std::mem::zeroed() };
            // SAFETY: a valid out pointer of the right size.
            (unsafe { VirtualQuery(at as *const _, &mut m, size_of_val(&m)) } != 0).then_some(m)
        };
        let Some(first) = query(address as usize) else { return };
        if first.State != MEM_COMMIT {
            return;
        }
        let allocation = first.AllocationBase as usize;
        {
            let mut done = DONE.lock().unwrap_or_else(|e| e.into_inner());
            if !done.get_or_insert_with(Default::default).insert((allocation, address / cap)) {
                return;
            }
        }
        let end = address + cap;
        let mut at = first.BaseAddress as usize;
        let mut cells = 0u32;
        while (at as u64) < end {
            // (room left for what the stages fault on and the rest of the frame)
            if self.copies.len() >= copies_limit() as usize * 3 / 4 {
                break;
            }
            let Some(m) = query(at) else { break };
            if m.AllocationBase as usize != allocation {
                break;
            }
            let (from, to) = (m.BaseAddress as u64, m.BaseAddress as u64 + m.RegionSize as u64);
            if m.State == MEM_COMMIT {
                let mut cell = from.max(address) & !(CELL - 1);
                while cell < to.min(end) {
                    self.map(cell.max(from));
                    if let Some(n) = self.copy_of(cell.max(from))
                        && !named.contains(&n)
                    {
                        named.push(n);
                    }
                    cells += 1;
                    cell += CELL;
                }
            }
            at = to as usize;
        }
        tracing::info!(
            address = format_args!("{address:#x}"),
            allocation = format_args!("{allocation:#x}"),
            cells,
            copies = self.copies.len(),
            "title memory by address: a builder stage's allocation made ready whole"
        );
    }

    /// What a dispatch names: the copy around `address` and the 4 MiB
    /// after it. Their copy numbers (0-based) go into `named`.
    fn name(&mut self, address: u64, named: &mut Vec<usize>) {
        for at in [address, (address & !(CELL - 1)) + CELL] {
            self.map(at);
            if let Some(n) = self.copy_of(at)
                && !named.contains(&n)
            {
                named.push(n);
            }
        }
    }

    /// The (0-based) number of the copy holding `address`'s page, if any.
    fn copy_of(&self, address: u64) -> Option<usize> {
        let page = address / PAGE;
        if page >= u64::from(MEMORY_PAGES) - 1 {
            return None;
        }
        // SAFETY: inside the directory's mapping.
        let n = unsafe { self.directory.1.add(page as usize * 2).read() };
        (n != 0).then(|| n as usize - 1)
    }
}

/// `VICTORY_MEMORY_WRITES=named` (experimental): a dispatch declares written
/// only the copies its root views and root constants name, not every
/// numbered copy. Each declared copy is snapshotted before the submission
/// and compared after it, which for every numbered copy cost about 1.9 s a
/// frame once the structure builder ran. What a shader stores through a
/// pointer it read out of memory, into a copy nothing named, is then not
/// copied back into title memory.
fn writes_named_only() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| {
        let on = std::env::var("VICTORY_MEMORY_WRITES").is_ok_and(|v| v == "named");
        if on {
            tracing::info!("title memory by address: only the copies a dispatch names are declared written (VICTORY_MEMORY_WRITES=named)");
        }
        on
    })
}

/// `first_use` keys for [`writes_named_only`]: one per copy, below the
/// list's other keys here.
const NAMED_WRITE: usize = usize::MAX - 0x1000;

/// Before a draw whose shader reads title memory by address: what its
/// root arguments name gets its copies (`addresses`: its root views;
/// `constants`: its root constants, see the module), every numbered copy
/// has its view in `heap`'s run and is brought up to date when `list` is
/// submitted (and, with `writes`, copied back after). None if the host
/// cannot hold it; the draw is then dropped.
pub(crate) fn ready(
    list: &HostList,
    heap: &HostHeap,
    addresses: &[u64],
    constants: &[u32],
    writes: bool,
    whole: bool,
) -> Option<Ready> {
    let mut guard = MEMORY.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Memory::new();
        // The pool's views mapped before the first shader that reaches memory by address.
        if pool_in_place()
            && let Some(m) = guard.as_mut()
        {
            let mut pages = 0u64;
            for (at, len) in crate::inplace::committed_views() {
                let mut page = (at as u64).next_multiple_of(PAGE);
                while page + PAGE <= (at + len) as u64 {
                    pages += u64::from(m.pool_entry(page));
                    page += PAGE;
                }
            }
            tracing::info!(pages, chunks = m.chunks.len(), "title memory by address: the page pool's views entered in place");
        }
    }
    let m = guard.as_mut()?;
    let frame = crate::frame::current();
    if m.frame != frame {
        m.frame = frame;
        m.refused.clear();
        m.take_faults();
    }
    let numbered = m.copies.len();
    let mut named = Vec::new();
    let mut seen = Vec::new();
    for &address in addresses {
        m.name(address, &mut named);
        seen.push(address);
    }
    // A title address in two constants (low dword, then bits 32 to 39), or
    // in one in 256-byte units. A constant that only looks like one names
    // memory nothing reads; one that is not the title's memory is refused.
    for (i, &c) in constants.iter().enumerate() {
        if let Some(&high) = constants.get(i + 1)
            && (1..=0xFF).contains(&high)
            && c >= 0x1_0000
        {
            m.name(u64::from(c) | u64::from(high) << 32, &mut named);
            seen.push(u64::from(c) | u64::from(high) << 32);
        }
        if c >= 0x0100_0000 {
            m.name(u64::from(c) << 8, &mut named);
            seen.push(u64::from(c) << 8);
        }
    }
    if whole {
        for address in seen {
            m.name_whole(address, &mut named);
        }
    }
    let key = std::ptr::from_ref(heap) as usize;
    let (base, made) = match m.heaps.get(&key) {
        Some(&run) => run,
        None => {
            // Held for the heap's life: not given back with a list's slots.
            let base = heap.dynamic(copies_limit() + 1)?;
            heap.null_raw_uav_at(base);
            (base, 0)
        }
    };
    for (n, copy) in m.copies.iter().enumerate().skip(made as usize) {
        match copy {
            Held::Shadow(shadow) => {
                let (_, len) = shadow.span();
                heap.raw_uav_at(base + 1 + n as u32, &shadow.buffer, 0, len);
            }
            Held::Pool { buffer, len } => heap.raw_uav_at(base + 1 + n as u32, buffer, 0, *len),
        }
    }
    m.heaps.insert(key, (base, m.copies.len() as u32));
    // Once per list, and for copies numbered since: the builder alone
    // dispatches hundreds of times a frame.
    // shortcut: a copy another list numbers meanwhile is brought up to date
    // by that list's submission, which may run after this one's.
    const READ: usize = usize::MAX - 0x6d;
    const WRITE: usize = usize::MAX - 0x6e;
    let first_read = list.first_use(READ);
    let first_write = writes && list.first_use(WRITE);
    let named_only = writes_named_only();
    for (n, copy) in m.copies.iter().enumerate() {
        // The page pool in place: no refresh, no copy back.
        let Held::Shadow(shadow) = copy else {
            continue;
        };
        let (start, len) = shadow.span();
        if first_read || n >= numbered {
            shadow.refresh(list, start, len);
        }
        let declare = if named_only {
            // Once per list for each copy a dispatch of it names.
            named.contains(&n) && list.first_use(NAMED_WRITE - n)
        } else {
            first_write || n >= numbered
        };
        if writes && declare {
            shadow.gpu_writes(list, start, len);
        }
    }
    if first_read {
        list.keep(&m.directory.0);
        list.keep(&m.faults.0);
    }
    Some(Ready {
        directory: m.directory.2,
        faults: m.faults.2,
        base,
    })
}
