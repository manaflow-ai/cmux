//! A terminal's output ring with absolute byte offsets, in memory the
//! holder can hand to another process.
//!
//! Wire version 4: the ring lives in a shared memory segment (`memfd` on
//! Linux, an unlinked POSIX `shm_open` object elsewhere). The holder passes
//! its descriptor to the daemon with the PTY master, and the daemon keeps a
//! custody dup of both. When the holder dies, the bytes it read from the PTY
//! but never sent are still in the segment: the daemon hands the segment to
//! a new holder, which continues the same ring, and the daemon re-attaches
//! from the last offset it parsed. Only the bytes of a `read` whose end the
//! holder had not published yet are lost (a holder killed inside the `read`
//! or between its return and the store of the new end): the kernel took
//! them from the PTY, and nobody knows how many there were. Such a loss is
//! never silent: before each `read` the holder publishes `reading` (the
//! offset the read starts at, plus one) and clears it after it published
//! the new end. A segment whose `reading` names its own `end` belonged to a
//! holder that died inside a read ([`interrupted_read`]): the daemon then
//! marks a discontinuity at that offset (its parser gets CAN there, and
//! the loss is logged) instead of splicing the bytes before and after.
//!
//! Layout 2 (little endian, [`HEADER`] bytes, then `capacity` data bytes):
//! `magic "CMHR" | layout u32 | capacity u64 | base u64 | end u64 |
//! oldest u64 | reading u64`. `reading` is 0 when no read is in flight (a
//! segment of a holder that never wrote it reads 0 too: its header bytes
//! past `oldest` are the zeros `ftruncate` made). `base` is the offset of
//! the first byte the ring ever held;
//! the byte at offset `o` is at data position `o % capacity`; the ring keeps
//! `oldest .. end`, where `oldest` is at least `max(base, end - capacity)`.
//! A write that reuses the room of kept bytes first publishes the new
//! `oldest` past every byte it will overwrite, then stores the data, then
//! publishes the new `end`. So a reader of a dead writer's segment, which
//! trusts only `oldest .. end`, sees only whole writes and no byte a later
//! write overwrote, wherever the writer died. (Layout 1 had no `oldest`: a
//! writer killed inside a write over the oldest kept bytes left newer bytes
//! at old offsets. A layout 1 segment is still adopted, as it was.) Layout
//! 2 is wire version 5 (`crate::wire::RING_VERSION`): a holder passes
//! segments only on a link of that version and a daemon hands them only to
//! such a holder, so a holder that knows only layout 1 never gets one. A
//! layout 1 segment a holder continues for an older daemon keeps its layout
//! 1 header (its writer still publishes `oldest`), so that daemon can hand
//! it to a holder of its own build. One process at a time writes a ring:
//! the holder that owns the terminal (the daemon gives a segment to a new
//! holder only after the old one's link ended).
//!
//! A cold terminal's ring gives its pages back ([`Ring::release_before`]):
//! the holder moves `oldest` past the bytes no reader needs any more, then
//! tells the kernel their pages may go, as Chrome's
//! `base/memory/discardable_shared_memory.cc` does for a purged segment
//! (`MADV_FREE_REUSABLE` on macOS, `MADV_REMOVE` on Linux). The header keeps
//! its layout: a reader trusts only `oldest .. end`, so it never reads a
//! released page.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::AtomicU64;

// The offset protocol (publication order, adopted window, loss marker):
// no `unsafe`, so cmux-tui/verify/loom-ring runs it under loom.
#[path = "ring_protocol.rs"]
mod protocol;

use protocol::{Cursor, Snapshot, Words};

/// Header bytes before the data.
pub const HEADER: usize = 64;
/// Segment magic.
const MAGIC: [u8; 4] = *b"CMHR";
/// Layout version of the header this build writes.
const LAYOUT: u32 = 2;
/// The layout before the published `oldest`: adopted, and kept for an older
/// daemon ([`Ring::upgrade_layout`]), never made.
const LAYOUT_NO_OLDEST: u32 = 1;
/// The largest ring a segment may describe (a corrupt header must not make
/// the holder map gigabytes).
const MAX_CAPACITY: u64 = 64 << 20;
const OFF_CAPACITY: usize = 8;
const OFF_BASE: usize = 16;
const OFF_END: usize = 24;
const OFF_OLDEST: usize = 32;
/// `reading`: 1 + the offset a `read` in flight started at, 0 for none.
const OFF_READING: usize = 40;

/// The last `capacity` bytes a terminal printed. Offsets count from the
/// terminal's first byte (or from the base an adoption continues from), so a
/// reader names a position that stays valid while older bytes drop out.
pub struct Ring {
    /// The mapping: header, then data.
    map: *mut u8,
    map_len: usize,
    base: u64,
    /// The header's layout: [`LAYOUT`], or [`LAYOUT_NO_OLDEST`] for an
    /// adopted layout 1 segment not upgraded ([`Self::upgrade_layout`]).
    layout: u32,
    /// The capacity and the kept window `oldest .. end`; mirrors the
    /// header's words.
    cursor: Cursor,
    /// The shared segment, `None` for a private ring (no shared memory).
    /// Shared with each frame that passes it ([`Self::segment`]).
    segment: Option<Arc<OwnedFd>>,
    /// A write before this offset may store into a page marked reusable
    /// ([`Self::release_before`], or a dead holder's before this one adopted
    /// the segment): it takes its pages back first ([`reuse_pages`]). After
    /// one whole turn of the ring past the release, every page was taken.
    reusable_until: Option<u64>,
}

// SAFETY: the mapping is owned by this value and only reached through
// `&self`/`&mut self`; another process writes it only after this one's link
// ended (module docs), so moving the value between threads is sound.
unsafe impl Send for Ring {}

impl Ring {
    /// An empty ring whose next byte has offset `base`, in a shared segment
    /// when one can be made, else in private memory.
    pub fn new(base: u64, capacity: usize) -> Self {
        if let Ok(segment) = create_segment(base, capacity)
            && let Ok(ring) = Self::adopt(segment)
        {
            return ring;
        }
        Self::private(base, capacity)
    }

    /// A ring in private memory (no descriptor to pass).
    pub fn private(base: u64, capacity: usize) -> Self {
        let map_len = HEADER + capacity;
        // SAFETY: an anonymous private mapping of `map_len` bytes.
        let map = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                map_len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            )
        };
        assert!(map != libc::MAP_FAILED, "map a terminal ring: {}", io::Error::last_os_error());
        let mut ring = Self {
            map: map.cast(),
            map_len,
            base,
            layout: LAYOUT,
            cursor: Cursor::new(capacity, base, base),
            segment: None,
            reusable_until: None,
        };
        ring.write_header();
        ring
    }

    /// Continue the ring in `segment` (a dead holder's, passed back by the
    /// daemon): its offsets and kept bytes are this ring's. The header keeps
    /// its layout until [`Self::upgrade_layout`].
    pub fn adopt(segment: OwnedFd) -> io::Result<Self> {
        // SAFETY: zeroed stat is a valid out-buffer for fstat.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: fstat of a live descriptor into a live local.
        if unsafe { libc::fstat(segment.as_raw_fd(), &mut stat) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let size = u64::try_from(stat.st_size).unwrap_or(0);
        if size < HEADER as u64 {
            return Err(invalid("ring segment smaller than its header"));
        }
        // Map the header first: the capacity says how much to map.
        let header = map_shared(segment.as_raw_fd(), HEADER)?;
        // SAFETY: the header mapping is HEADER bytes; reads are in bounds.
        let (magic, layout, capacity, base, snapshot) = unsafe {
            let bytes = std::slice::from_raw_parts(header, HEADER);
            let magic: [u8; 4] = bytes[..4].try_into().unwrap_or_default();
            let layout = u32::from_le_bytes(bytes[4..8].try_into().unwrap_or_default());
            let capacity = u64::from_le_bytes(bytes[8..16].try_into().unwrap_or_default());
            let base = u64::from_le_bytes(bytes[16..24].try_into().unwrap_or_default());
            let snapshot = Snapshot::load(&header_words(header));
            libc::munmap(header.cast(), HEADER);
            (magic, layout, capacity, base, snapshot)
        };
        if magic != MAGIC || (layout != LAYOUT && layout != LAYOUT_NO_OLDEST) {
            return Err(invalid("not a terminal ring segment"));
        }
        if capacity == 0 || capacity > MAX_CAPACITY || HEADER as u64 + capacity > size {
            return Err(invalid("bad terminal ring capacity"));
        }
        // Layout 1 published no `oldest`.
        let cursor = snapshot.adopt(capacity as usize, base, layout == LAYOUT).map_err(invalid)?;
        let map_len = HEADER + cursor.capacity();
        let map = map_shared(segment.as_raw_fd(), map_len)?;
        let kept_by_size = base.max(cursor.end().saturating_sub(cursor.capacity() as u64));
        let mut ring = Self {
            map,
            map_len,
            base,
            layout,
            cursor,
            segment: Some(Arc::new(segment)),
            // Only a released segment keeps less than its size allows
            // ([`Self::release_before`]; writes give `oldest` back to the
            // size once they took every released page). A fresh one
            // (`Self::new`) released nothing: no write pays for a reuse.
            reusable_until: (layout == LAYOUT && cursor.oldest() > kept_by_size)
                .then_some(cursor.end() + cursor.capacity() as u64),
        };
        // This build publishes `oldest` from here on, whatever the layout
        // says (a layout 1 segment's `oldest` word read 0 until then).
        ring.write_header();
        Ok(ring)
    }

    /// Mark the segment layout 2 from now on: its readers may trust the
    /// published `oldest`. Only for a segment no holder older than wire
    /// version 5 will continue (the daemon on the link speaks
    /// `crate::wire::RING_VERSION`).
    pub fn upgrade_layout(&mut self) {
        if self.layout != LAYOUT {
            self.layout = LAYOUT;
            self.write_header();
        }
    }

    /// The header's layout version (1 or 2).
    pub fn layout(&self) -> u32 {
        self.layout
    }

    /// The shared segment, to pass to the daemon; `None` for a private ring.
    /// A frame that passes it holds a clone of this handle, not a dup of the
    /// descriptor, so passing it costs the holder no descriptor, and the
    /// segment stays open until the frame is written even if the ring is
    /// gone by then.
    pub fn segment(&self) -> Option<&Arc<OwnedFd>> {
        self.segment.as_ref()
    }

    /// Append output; the oldest bytes drop out past the capacity. The
    /// writer is never blocked.
    pub fn push(&mut self, data: &[u8]) {
        let map = self.map;
        // SAFETY: the mapping lives as long as `self`.
        let words = unsafe { header_words(map) };
        let reuse = self.reusable_until.is_some();
        self.cursor.push(&words, data, |range, bytes| {
            if reuse {
                reuse_pages(map, HEADER + range.start, range.len());
            }
            // SAFETY: `range` is inside the data area (`Cursor::room`), and
            // no other slice of the data is live during a push.
            unsafe { data_mut(map, range) }.copy_from_slice(bytes);
        });
        self.end_reuse();
    }

    /// Read at most `max` bytes straight into the ring with `read` (given
    /// the room up to the end of the data area, never empty) and publish
    /// what it returned. Returns `read`'s result: the bytes are in the ring
    /// as soon as it returns, so a crash right after loses at most one
    /// unpublished read, and the segment says so: `reading` names the
    /// offset the read started at from before `read` runs until after its
    /// end is published ([`interrupted_read`]).
    pub fn read_with(&mut self, max: usize, read: impl FnOnce(&mut [u8]) -> isize) -> isize {
        let map = self.map;
        // SAFETY: the mapping lives as long as `self`.
        let words = unsafe { header_words(map) };
        let reuse = self.reusable_until.is_some();
        let n = self.cursor.read_with(&words, max, |range| {
            if reuse {
                reuse_pages(map, HEADER + range.start, range.len());
            }
            // SAFETY: `range` is inside the data area (`Cursor::room`), and
            // no other slice of the data is live during the read.
            read(unsafe { data_mut(map, range) })
        });
        self.end_reuse();
        n
    }

    /// After a write: once the writes went one whole turn of the ring past
    /// the release, they took every released page back
    /// ([`Self::reusable_until`]), and the next write needs no syscall.
    fn end_reuse(&mut self) {
        if self.reusable_until.is_some_and(|until| self.cursor.end() >= until) {
            self.reusable_until = None;
        }
    }

    /// Drop every byte before `offset` (at most the end) from the ring and
    /// give the kernel the data pages that hold no kept byte; returns how
    /// many bytes of pages went. For a cold terminal whose bytes before
    /// `offset` no reader needs: the daemon parsed them and the holder's
    /// prologue is past them. `oldest` is published first, so a reader of
    /// this segment (a holder adopting it after this one died) never trusts
    /// a released byte. A layout 1 segment releases nothing: a holder that
    /// knows only layout 1 computes its window from the end and would read
    /// the released pages as output.
    pub fn release_before(&mut self, offset: u64) -> usize {
        if self.layout != LAYOUT {
            return 0;
        }
        // SAFETY: the mapping lives as long as `self`.
        let words = unsafe { header_words(self.map) };
        // The new `oldest` is in the segment before a page goes.
        if !self.cursor.drop_before(&words, offset) {
            return 0;
        }
        let page = page_size();
        let mut released = 0;
        for (start, end) in self.unkept_spans() {
            // Whole pages only: the header page and a page that holds a kept
            // byte stay.
            let first = start.next_multiple_of(page);
            let last = end / page * page;
            if last > first && discard_pages(self.map, first, last - first, self.segment.is_some())
            {
                released += last - first;
            }
        }
        if released > 0 {
            self.reusable_until = Some(self.cursor.end() + self.cursor.capacity() as u64);
        }
        released
    }

    /// Whether [`Self::release_before`] would drop a byte before `offset`.
    pub fn can_release_before(&self, offset: u64) -> bool {
        self.layout == LAYOUT && offset.min(self.cursor.end()) > self.cursor.oldest()
    }

    /// The spans of the mapping (byte positions from its start) whose data
    /// bytes are outside `oldest .. end`, in order.
    fn unkept_spans(&self) -> Vec<(usize, usize)> {
        let (capacity, oldest) = (self.cursor.capacity(), self.cursor.oldest());
        let (data, data_end) = (HEADER, HEADER + capacity);
        let kept = (self.cursor.end() - oldest) as usize;
        if kept == 0 {
            return vec![(data, data_end)];
        }
        let start = data + (oldest % capacity as u64) as usize;
        let end = start + kept;
        if end <= data_end {
            vec![(data, start), (end, data_end)]
        } else {
            // The kept bytes wrap: the free room is between their end and start.
            vec![(data + (end - data_end), start)]
        }
    }

    /// Offset of the oldest byte kept.
    pub fn oldest(&self) -> u64 {
        self.cursor.oldest()
    }

    /// Offset after the newest byte.
    pub fn end(&self) -> u64 {
        self.cursor.end()
    }

    /// Up to `max` bytes from `from` (clamped to the oldest kept byte), with
    /// the offset they start at.
    pub fn read(&self, from: u64, max: usize) -> (u64, Vec<u8>) {
        let (from, head, tail) = self.slices(from, max);
        let mut out = Vec::with_capacity(head.len() + tail.len());
        out.extend_from_slice(head);
        out.extend_from_slice(tail);
        (from, out)
    }

    /// [`Self::read`] without a copy: the offset and the bytes as at most
    /// two slices of the ring's buffer, in order.
    pub fn slices(&self, from: u64, max: usize) -> (u64, &[u8], &[u8]) {
        let (from, head, tail) = self.cursor.window(from, max);
        let data = self.data();
        (from, &data[head], &data[tail])
    }

    /// The data area.
    fn data(&self) -> &[u8] {
        // SAFETY: the mapping holds HEADER + capacity bytes for this
        // value's life, and only this process writes it (module docs).
        unsafe { std::slice::from_raw_parts(self.map.add(HEADER), self.cursor.capacity()) }
    }

    fn write_header(&mut self) {
        // SAFETY: the header is HEADER bytes at the start of the mapping.
        unsafe {
            let header = std::slice::from_raw_parts_mut(self.map, HEADER);
            header[..4].copy_from_slice(&MAGIC);
            header[4..8].copy_from_slice(&self.layout.to_le_bytes());
            header[OFF_CAPACITY..OFF_CAPACITY + 8]
                .copy_from_slice(&(self.cursor.capacity() as u64).to_le_bytes());
            header[OFF_BASE..OFF_BASE + 8].copy_from_slice(&self.base.to_le_bytes());
        }
        // SAFETY: the mapping lives as long as `self`.
        let words = unsafe { header_words(self.map) };
        self.cursor.republish(&words);
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        // SAFETY: unmaps the mapping this value made.
        unsafe { libc::munmap(self.map.cast(), self.map_len) };
    }
}

/// The protocol words of the header mapped at `map`.
///
/// # Safety
/// `map` is a live mapping of at least [`HEADER`] bytes for `'a`, page
/// aligned, so the words at `OFF_END`, `OFF_OLDEST` and `OFF_READING` are
/// 8-byte aligned.
unsafe fn header_words<'a>(map: *mut u8) -> Words<'a> {
    // SAFETY: the caller's contract; each word is an aligned u64 inside the
    // header that both processes reach only atomically.
    unsafe {
        Words {
            end: &*map.add(OFF_END).cast::<AtomicU64>(),
            oldest: &*map.add(OFF_OLDEST).cast::<AtomicU64>(),
            reading: &*map.add(OFF_READING).cast::<AtomicU64>(),
        }
    }
}

/// The data bytes `range` of the ring mapped at `map`, to write.
///
/// # Safety
/// `map` is a live ring mapping of [`HEADER`] + capacity bytes for `'a`,
/// `range` is inside `0..capacity`, and no other slice of those bytes is
/// live meanwhile.
unsafe fn data_mut<'a>(map: *mut u8, range: std::ops::Range<usize>) -> &'a mut [u8] {
    // SAFETY: the caller's contract.
    unsafe { std::slice::from_raw_parts_mut(map.add(HEADER + range.start), range.len()) }
}

/// A new shared ring segment whose next byte has offset `base`: the
/// descriptor to pass, with the header written (layout 2). The daemon makes
/// one when it hands a terminal that had none (an older holder's) to a
/// holder of wire version 5 (`crate::wire::RING_VERSION`), so the next
/// holder crash loses no byte either.
pub fn create_segment(base: u64, capacity: usize) -> io::Result<OwnedFd> {
    let segment = new_segment()?;
    // Already close-on-exec where the platform opens it so; else this
    // closes the rest of the window (see `new_segment`).
    crate::pty::set_cloexec(segment.as_raw_fd());
    let size = (HEADER + capacity) as libc::off_t;
    // SAFETY: sizes a descriptor this function owns.
    if unsafe { libc::ftruncate(segment.as_raw_fd(), size) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let map = map_shared(segment.as_raw_fd(), HEADER)?;
    // SAFETY: the header mapping is HEADER bytes.
    unsafe {
        let header = std::slice::from_raw_parts_mut(map, HEADER);
        header[..4].copy_from_slice(&MAGIC);
        header[4..8].copy_from_slice(&LAYOUT.to_le_bytes());
        header[OFF_CAPACITY..OFF_CAPACITY + 8].copy_from_slice(&(capacity as u64).to_le_bytes());
        header[OFF_BASE..OFF_BASE + 8].copy_from_slice(&base.to_le_bytes());
        Cursor::new(capacity, base, base).republish(&header_words(map));
        libc::munmap(map.cast(), HEADER);
    }
    Ok(segment)
}

/// The end offset recorded in a ring segment (what its writer published).
pub fn segment_end(segment: &OwnedFd) -> io::Result<u64> {
    let map = map_shared(segment.as_raw_fd(), HEADER)?;
    // SAFETY: the header mapping is HEADER bytes.
    let end = unsafe {
        let end = protocol::published_end(&header_words(map));
        libc::munmap(map.cast(), HEADER);
        end
    };
    Ok(end)
}

/// Where the writer of `segment` died inside a PTY read: `Some(end)` when
/// its `reading` names the segment's own `end` (the read started there and
/// its end was never published, so the bytes it took from the PTY are
/// lost, however many there were: none, when it died before the kernel took
/// any, but nobody can tell), else `None` (no read in flight, or one
/// whose end was published before the writer died). A live writer's
/// segment can read `Some` too, while a read is in flight: ask only about a
/// segment whose writer is gone (its link ended).
pub fn interrupted_read(segment: &OwnedFd) -> io::Result<Option<u64>> {
    // SAFETY: zeroed stat is a valid out-buffer for fstat.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fstat of a live descriptor into a live local.
    if unsafe { libc::fstat(segment.as_raw_fd(), &mut stat) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // A mapping past the end of the object would fault on the first read.
    if u64::try_from(stat.st_size).unwrap_or(0) < HEADER as u64 {
        return Err(invalid("ring segment smaller than its header"));
    }
    let map = map_shared(segment.as_raw_fd(), HEADER)?;
    // SAFETY: the header mapping is HEADER bytes.
    let (magic, interrupted) = unsafe {
        let magic: [u8; 4] = std::slice::from_raw_parts(map, 4).try_into().unwrap_or_default();
        let interrupted = protocol::interrupted_read(&header_words(map));
        libc::munmap(map.cast(), HEADER);
        (magic, interrupted)
    };
    if magic != MAGIC {
        return Err(invalid("not a terminal ring segment"));
    }
    Ok(interrupted)
}

fn page_size() -> usize {
    // SAFETY: sysconf only reads system configuration.
    usize::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap_or(4096).max(1)
}

/// Let the kernel take `len` bytes of pages at `at` from the mapping `map`
/// (page aligned): their contents may read as zeros afterwards. True when
/// the kernel took the advice.
#[cfg(target_vendor = "apple")]
fn discard_pages(map: *mut u8, at: usize, len: usize, _shared: bool) -> bool {
    // MADV_FREE_REUSABLE, not MADV_FREE: the pages leave the task's
    // footprint at once (Activity Monitor and `phys_footprint` count them
    // no longer), as in Chrome's DiscardableSharedMemory::Purge.
    // SAFETY: a page-aligned range inside this ring's live mapping.
    unsafe { libc::madvise(map.add(at).cast(), len, libc::MADV_FREE_REUSABLE) == 0 }
}

/// [`discard_pages`] on Linux: `MADV_REMOVE` frees a shared (memfd)
/// segment's pages, as Chrome's DiscardableSharedMemory::Purge does;
/// `MADV_DONTNEED` frees a private ring's.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn discard_pages(map: *mut u8, at: usize, len: usize, shared: bool) -> bool {
    let advice = if shared { libc::MADV_REMOVE } else { libc::MADV_DONTNEED };
    // SAFETY: a page-aligned range inside this ring's live mapping.
    unsafe { libc::madvise(map.add(at).cast(), len, advice) == 0 }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
fn discard_pages(_map: *mut u8, _at: usize, _len: usize, _shared: bool) -> bool {
    false
}

/// Take back the pages of the `len` bytes at `at` in the mapping `map`
/// before a write stores into them: `MADV_FREE_REUSE` on macOS (Chrome's
/// DiscardableSharedMemory::Lock), so the kernel neither drops a byte
/// written after it nor leaves the page out of the footprint. Linux needs
/// nothing: a removed page comes back as a zero page on the write.
#[cfg(target_vendor = "apple")]
fn reuse_pages(map: *mut u8, at: usize, len: usize) {
    let page = page_size();
    let (first, last) = (at / page * page, (at + len).next_multiple_of(page));
    // SAFETY: page-aligned; the write's range is inside the mapping, which
    // is page-rounded by the kernel.
    unsafe { libc::madvise(map.add(first).cast(), last - first, libc::MADV_FREE_REUSE) };
}

#[cfg(not(target_vendor = "apple"))]
fn reuse_pages(_map: *mut u8, _at: usize, _len: usize) {}

fn map_shared(fd: RawFd, len: usize) -> io::Result<*mut u8> {
    // SAFETY: maps `len` bytes of a live descriptor read-write and shared.
    let map = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            len,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        )
    };
    if map == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    Ok(map.cast())
}

#[cfg(target_os = "linux")]
fn new_segment() -> io::Result<OwnedFd> {
    // SAFETY: memfd_create returns a new descriptor or -1.
    let fd = unsafe { libc::memfd_create(c"cmux-holder-ring".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a fresh descriptor this function owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// An unlinked POSIX shared memory object: only descriptors reach it.
///
/// It is opened close-on-exec (`O_CLOEXEC`), so a process another thread
/// of a multithreaded daemon spawns meanwhile does not inherit a writable
/// descriptor to a terminal's output. A system whose `shm_open` refuses the
/// flag (`EINVAL`) gets the object without it and [`create_segment`] sets
/// `FD_CLOEXEC` right after: there, a process spawned on another thread
/// between the two calls can inherit the descriptor, and with it keep the
/// segment alive and write to it.
#[cfg(not(target_os = "linux"))]
fn new_segment() -> io::Result<OwnedFd> {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(0);
    for _ in 0..16 {
        // At most 31 bytes on macOS (PSHMNAMLEN).
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        let name = format!(
            "/cmhr{:x}.{:x}.{:x}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
            nanos
        );
        let name = std::ffi::CString::new(name).map_err(|_| invalid("ring name"))?;
        let open = |flags: libc::c_int| {
            // SAFETY: shm_open with a NUL-terminated name; the mode is variadic.
            unsafe {
                libc::shm_open(
                    name.as_ptr(),
                    flags | libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                    0o600 as libc::c_uint,
                )
            }
        };
        let mut fd = open(libc::O_CLOEXEC);
        if fd < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::EINVAL) {
            // SAFETY: removes the name in case the refused open made it.
            unsafe { libc::shm_unlink(name.as_ptr()) };
            fd = open(0);
        }
        if fd < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::AlreadyExists {
                continue;
            }
            return Err(error);
        }
        // SAFETY: removes the name just made; the descriptor keeps the object.
        unsafe { libc::shm_unlink(name.as_ptr()) };
        // SAFETY: a fresh descriptor this function owns.
        return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free ring segment name"))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_newest_bytes_with_stable_offsets() {
        let mut ring = Ring::new(100, 4);
        ring.push(b"abcdef");
        assert_eq!((ring.oldest(), ring.end()), (102, 106));
        assert_eq!(ring.read(0, 10), (102, b"cdef".to_vec()));
        assert_eq!(ring.read(104, 1), (104, b"e".to_vec()));
        assert_eq!(ring.read(106, 10), (106, Vec::new()));
    }

    #[test]
    fn reads_across_the_wrap_of_its_buffer() {
        let mut ring = Ring::new(0, 8);
        ring.push(b"012345");
        ring.push(b"6789ab");
        assert_eq!((ring.oldest(), ring.end()), (4, 12));
        assert_eq!(ring.read(4, 8), (4, b"456789ab".to_vec()));
        assert_eq!(ring.read(6, 3), (6, b"678".to_vec()));
        assert_eq!(ring.read(10, 8), (10, b"ab".to_vec()));
    }

    #[test]
    fn a_private_ring_behaves_the_same() {
        let mut ring = Ring::private(0, 8);
        ring.push(b"0123456789");
        assert!(ring.segment().is_none());
        assert_eq!(ring.read(0, 16), (2, b"23456789".to_vec()));
    }

    /// The segment outlives its writer: a ring adopted from the descriptor
    /// has every byte the first one published, at the same offsets, and
    /// continues them.
    #[test]
    fn an_adopted_segment_continues_the_dead_writers_ring() {
        let mut first = Ring::new(1000, 16);
        let segment = first.segment().expect("a shared ring").try_clone().unwrap();
        first.push(b"hello ");
        // `read_with` offers the room up to the end of the data area: 1006
        // is at position 14 of 16, so 2 bytes, then the rest after the wrap.
        let mut word: &[u8] = b"world";
        while !word.is_empty() {
            let n = first.read_with(64, |room| {
                let n = room.len().min(word.len());
                room[..n].copy_from_slice(&word[..n]);
                n as isize
            });
            word = &word[n as usize..];
        }
        drop(first);
        assert_eq!(segment_end(&segment).unwrap(), 1011);
        let mut second = Ring::adopt(segment).unwrap();
        assert_eq!((second.oldest(), second.end()), (1000, 1011));
        assert_eq!(second.read(1000, 64), (1000, b"hello world".to_vec()));
        second.push(b"!!!!!!");
        assert_eq!(second.read(0, 64), (1001, b"ello world!!!!!!".to_vec()));
    }

    /// A writer that dies inside a write over the oldest kept bytes (the
    /// data stored, its end not published) leaves a segment whose kept
    /// window holds no overwritten byte: every byte an adopter trusts is the
    /// byte first written at that offset.
    #[test]
    fn a_writer_dead_inside_a_write_over_kept_bytes_leaves_only_whole_bytes() {
        let mut first = Ring::new(0, 16);
        let segment = first.segment().expect("a shared ring").try_clone().unwrap();
        let stream: Vec<u8> = (0..64u8).map(|byte| b'A' + byte % 26).collect();
        first.push(&stream[..20]);
        assert_eq!((first.oldest(), first.end()), (4, 20));
        // The next read gets the room from 20 (position 4) to the end of
        // the data area, 12 bytes over offsets 4..16, and "dies" right after
        // it stored them.
        let mut adopted = None;
        first.read_with(64, |room| {
            for (index, byte) in room.iter_mut().enumerate() {
                *byte = b'#' + index as u8;
            }
            adopted = Some(Ring::adopt(segment.try_clone().unwrap()).unwrap());
            room.len() as isize
        });
        let dead = adopted.unwrap();
        let (from, kept) = dead.read(0, 64);
        assert_eq!(dead.end(), 20, "the unpublished read is not part of the ring");
        assert_eq!(kept, stream[from as usize..20].to_vec(), "an overwritten byte is kept");
    }

    /// A writer killed inside a PTY read (the kernel already stored bytes
    /// in the room it offered, the new end not published) leaves a segment
    /// that says so: [`interrupted_read`] names the offset the read started
    /// at, the end an adopter continues from. A read whose end was
    /// published, and a segment no read is in flight on, name no loss.
    #[test]
    fn a_writer_dead_inside_a_read_leaves_the_offset_of_its_loss() {
        let mut first = Ring::new(0, 64);
        let segment = first.segment().expect("a shared ring").try_clone().unwrap();
        first.push(b"before");
        assert_eq!(interrupted_read(&segment).unwrap(), None, "no read in flight");
        let mut dead = None;
        let n = first.read_with(16, |room| {
            room[..5].copy_from_slice(b"taken");
            // The holder "dies" here: the kernel took the bytes from the
            // PTY, the new end is not published.
            dead = Some(interrupted_read(&segment).unwrap());
            5
        });
        assert_eq!(dead, Some(Some(6)), "the dead writer's segment names the loss at its end");
        assert_eq!(n, 5);
        assert_eq!(interrupted_read(&segment).unwrap(), None, "a published read names no loss");
        // An adopter of the dead writer's segment continues at that end.
        let mut second = Ring::new(0, 64);
        let segment = second.segment().unwrap().try_clone().unwrap();
        second.push(b"before");
        second.read_with(16, |_| {
            let adopted = Ring::adopt(segment.try_clone().unwrap()).unwrap();
            assert_eq!(adopted.end(), 6);
            0
        });
        assert_eq!(interrupted_read(&segment).unwrap(), None, "an empty read clears its mark");
    }

    /// An oversized push publishes no offset it skipped as a byte, and an
    /// adopter of a segment from before it starts where the push jumped to.
    #[test]
    fn an_oversized_push_keeps_its_tail_at_the_right_offsets() {
        let mut ring = Ring::new(0, 8);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        ring.push(b"0123");
        ring.push(b"abcdefghijkl");
        assert_eq!((ring.oldest(), ring.end()), (8, 16));
        assert_eq!(ring.read(0, 64), (8, b"efghijkl".to_vec()));
        drop(ring);
        let adopted = Ring::adopt(segment).unwrap();
        assert_eq!(adopted.read(0, 64), (8, b"efghijkl".to_vec()));
    }

    /// A new segment is close-on-exec from the moment `shm_open` (or
    /// `memfd_create`) returns it, before [`create_segment`] sets the flag
    /// again: a process another daemon thread spawns meanwhile does not
    /// inherit a writable copy of a terminal's output. Red on a macOS major
    /// whose `shm_open` ignores `O_CLOEXEC` (or refuses it: the `EINVAL`
    /// fallback opens without it).
    #[test]
    fn a_new_segment_is_close_on_exec_when_it_is_opened() {
        let segment = new_segment().unwrap();
        // SAFETY: F_GETFD of a descriptor this test owns.
        let flags = unsafe { libc::fcntl(segment.as_raw_fd(), libc::F_GETFD) };
        assert!(flags >= 0, "F_GETFD: {}", io::Error::last_os_error());
        assert_ne!(flags & libc::FD_CLOEXEC, 0, "the segment opened without close-on-exec");
    }

    /// A layout 1 segment continued for an older daemon keeps its layout 1
    /// header (so a holder that knows only layout 1 can continue it again)
    /// until the holder upgrades it for a daemon of wire version 5.
    #[test]
    fn an_adopted_layout_1_segment_stays_layout_1_until_upgraded() {
        let ring = Ring::new(0, 8);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        drop(ring);
        let header = map_shared(segment.as_raw_fd(), HEADER).unwrap();
        // SAFETY: the header mapping is HEADER bytes; rewrite it as layout 1.
        unsafe {
            std::slice::from_raw_parts_mut(header.add(4), 4)
                .copy_from_slice(&LAYOUT_NO_OLDEST.to_le_bytes());
            libc::munmap(header.cast(), HEADER);
        }
        let read_layout = |segment: &OwnedFd| {
            let header = map_shared(segment.as_raw_fd(), HEADER).unwrap();
            // SAFETY: the header mapping is HEADER bytes.
            unsafe {
                let layout = u32::from_le_bytes(
                    std::slice::from_raw_parts(header.add(4), 4).try_into().unwrap(),
                );
                libc::munmap(header.cast(), HEADER);
                layout
            }
        };
        let mut adopted = Ring::adopt(segment.try_clone().unwrap()).unwrap();
        adopted.push(b"abc");
        assert_eq!((adopted.layout(), read_layout(&segment)), (1, 1));
        adopted.upgrade_layout();
        assert_eq!((adopted.layout(), read_layout(&segment)), (2, 2));
    }

    /// A layout 1 segment (no published `oldest`) is still adopted, its
    /// window computed from its end and capacity as before.
    #[test]
    fn a_layout_1_segment_is_adopted() {
        let mut ring = Ring::new(10, 8);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        ring.push(b"0123456789");
        drop(ring);
        let header = map_shared(segment.as_raw_fd(), HEADER).unwrap();
        // SAFETY: the header mapping is HEADER bytes; rewrite it as layout 1.
        unsafe {
            std::slice::from_raw_parts_mut(header.add(4), 4)
                .copy_from_slice(&LAYOUT_NO_OLDEST.to_le_bytes());
            std::slice::from_raw_parts_mut(header.add(OFF_OLDEST), 8).fill(0);
            libc::munmap(header.cast(), HEADER);
        }
        let adopted = Ring::adopt(segment).unwrap();
        assert_eq!(adopted.read(0, 64), (12, b"23456789".to_vec()));
    }

    fn pattern(from: u64, len: usize) -> Vec<u8> {
        (from..from + len as u64).map(|offset| b'a' + (offset % 23) as u8).collect()
    }

    /// A cold ring released before the offset the daemon
    /// confirmed keeps every byte from there on, at the same offsets, for
    /// itself and for a holder that adopts its segment after it died; the
    /// pages it gave back take new output again.
    #[test]
    fn a_released_ring_keeps_its_window_and_an_adopter_loses_no_byte() {
        const CAPACITY: usize = 256 * 1024;
        let mut ring = Ring::new(0, CAPACITY);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        ring.push(&pattern(0, 200 * 1024));
        let confirmed = 150 * 1024;
        let released = ring.release_before(confirmed);
        assert!(released >= 100 * 1024, "released {released} bytes of pages");
        assert_eq!((ring.oldest(), ring.end()), (confirmed, 200 * 1024));
        assert_eq!(ring.read(0, CAPACITY), (confirmed, pattern(confirmed, 50 * 1024)));
        // Nothing more to release before the same offset.
        assert!(!ring.can_release_before(confirmed));
        assert_eq!(ring.release_before(confirmed), 0);
        drop(ring);
        // The holder died: its successor continues the segment, no byte lost.
        let mut adopted = Ring::adopt(segment).unwrap();
        assert_eq!(adopted.read(0, CAPACITY), (confirmed, pattern(confirmed, 50 * 1024)));
        // New output wraps over the released pages and reads back whole.
        adopted.push(&pattern(200 * 1024, CAPACITY));
        assert_eq!(adopted.read(0, 2 * CAPACITY), (200 * 1024, pattern(200 * 1024, CAPACITY)));
    }

    /// A write takes pages back ([`reuse_pages`], a syscall per write) only
    /// where a release gave some away: never in a fresh ring, nor in an
    /// adopted segment that released nothing, and in a released one until
    /// the writes took every released page.
    #[test]
    fn only_a_released_ring_takes_pages_back_on_a_write() {
        const CAPACITY: usize = 64 * 1024;
        let mut fresh = Ring::new(0, CAPACITY);
        assert_eq!(fresh.reusable_until, None, "a fresh segment released nothing");
        let segment = fresh.segment().expect("a shared ring").try_clone().unwrap();
        fresh.push(&pattern(0, CAPACITY + 1000));
        assert_eq!(fresh.reusable_until, None);
        drop(fresh);
        let mut adopted = Ring::adopt(segment).unwrap();
        assert_eq!(adopted.reusable_until, None, "a dead writer's full ring released nothing");
        let segment = adopted.segment().expect("a shared ring").try_clone().unwrap();
        adopted.push(&pattern(CAPACITY as u64 + 1000, 2000));
        let end = adopted.end();
        assert!(adopted.release_before(end - 100) > 0);
        assert_eq!(adopted.reusable_until, Some(end + CAPACITY as u64));
        drop(adopted);
        // The dead writer released pages: its successor takes them back.
        let mut released = Ring::adopt(segment).unwrap();
        assert_eq!(released.reusable_until, Some(end + CAPACITY as u64));
        released.push(&pattern(end, CAPACITY));
        assert_eq!(released.reusable_until, None, "one turn of the ring took every page back");
        assert_eq!(released.read(0, CAPACITY), (end, pattern(end, CAPACITY)));
    }

    /// Everything confirmed: every data page but the header's goes, and the
    /// ring keeps nothing; the next write is whole.
    #[test]
    fn a_fully_confirmed_ring_gives_back_every_data_page() {
        const CAPACITY: usize = 1 << 20;
        for mut ring in [Ring::new(0, CAPACITY), Ring::private(0, CAPACITY)] {
            ring.push(&pattern(0, CAPACITY));
            let released = ring.release_before(u64::MAX);
            assert!(released >= CAPACITY - 2 * page_size(), "released {released} bytes of pages");
            assert_eq!((ring.oldest(), ring.end()), (CAPACITY as u64, CAPACITY as u64));
            ring.push(b"after");
            assert_eq!(ring.read(0, 64), (CAPACITY as u64, b"after".to_vec()));
        }
    }

    /// The pages leave memory: the memfd segment's blocks drop by what the
    /// ring released.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_released_segment_frees_its_pages() {
        const CAPACITY: usize = 1 << 20;
        let mut ring = Ring::new(0, CAPACITY);
        let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
        let blocks = || {
            // SAFETY: zeroed stat is a valid out-buffer for fstat.
            let mut stat: libc::stat = unsafe { std::mem::zeroed() };
            // SAFETY: fstat of a live descriptor into a live local.
            assert_eq!(unsafe { libc::fstat(segment.as_raw_fd(), &mut stat) }, 0);
            stat.st_blocks as usize * 512
        };
        ring.push(&pattern(0, CAPACITY));
        let before = blocks();
        ring.release_before(CAPACITY as u64);
        let freed = before - blocks();
        assert!(freed >= 900 * 1024, "the segment freed {freed} bytes");
    }

    /// A layout 1 segment continued for an older daemon releases nothing:
    /// a holder that knows only layout 1 would read released pages.
    #[test]
    fn a_layout_1_ring_is_never_released() {
        let mut ring = Ring::new(0, 64 * 1024);
        ring.layout = LAYOUT_NO_OLDEST;
        ring.push(&pattern(0, 64 * 1024));
        assert!(!ring.can_release_before(64 * 1024));
        assert_eq!(ring.release_before(64 * 1024), 0);
        assert_eq!(ring.oldest(), 0);
    }

    #[test]
    fn a_made_segment_starts_empty_at_its_base() {
        let segment = create_segment(77, 32).unwrap();
        let ring = Ring::adopt(segment).unwrap();
        assert_eq!((ring.oldest(), ring.end()), (77, 77));
    }

    #[test]
    fn a_foreign_descriptor_is_not_a_ring() {
        let segment = new_segment().unwrap();
        // SAFETY: sizes a descriptor this test owns.
        assert_eq!(unsafe { libc::ftruncate(segment.as_raw_fd(), 4096) }, 0);
        assert!(Ring::adopt(segment).is_err());
    }
}
