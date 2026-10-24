//! A terminal's output ring in shared memory, written by the daemon's output
//! path and read in place by local attach streams (`terminal-output-ring-v1`,
//! plans/cmux-next/app-daemon-connection-DESIGN.md section 4).
//!
//! Layout (little endian, [`HEADER`] bytes, then `capacity` data bytes):
//! `magic "CMAR" | layout u32 | capacity u64 | base u64 | end u64 | reserve u64`.
//! The byte at offset `o` is at data position `o % capacity`; the ring holds
//! `max(base, end - capacity) .. end`.
//!
//! One writer (the terminal's output path) and any number of readers in other
//! processes, none of which waits for another. The writer stores `reserve`
//! (the end of the bytes it is about to write), fences, copies the bytes,
//! then publishes `end`. A reader reads `[s, t)` with `t <= end`, fences, and
//! loads `reserve`: when `reserve > s + capacity` the writer may have
//! overwritten part of what it read (a lap) and the reader resyncs from a
//! snapshot. This is the seqlock rule; it detects every overwrite and never
//! makes the writer wait.
//!
//! Readers get a read-only descriptor: they cannot change the ring, and the
//! writer never reads the data area back, so nothing a reader does reaches
//! the parser.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicU64, Ordering, fence};

/// Header bytes before the data.
pub(crate) const HEADER: usize = 64;
/// Segment magic.
pub(crate) const MAGIC: [u8; 4] = *b"CMAR";
/// Layout version of the header.
pub(crate) const LAYOUT: u32 = 1;
/// The largest ring a reader accepts (a corrupt header must not make a
/// reader map gigabytes).
pub(crate) const MAX_CAPACITY: u64 = 64 << 20;
/// Bytes a terminal's ring keeps: the holder's per-terminal ring size, so a
/// terminal holds at most this much resident output per hop. A reader that
/// falls this far behind resyncs by snapshot.
pub(crate) const DEFAULT_CAPACITY: usize = 1 << 20;

const OFF_CAPACITY: usize = 8;
const OFF_BASE: usize = 16;
const OFF_END: usize = 24;
const OFF_RESERVE: usize = 32;

/// The writer's side of a terminal's output ring.
pub(crate) struct OutputRing {
    map: *mut u8,
    map_len: usize,
    capacity: usize,
    base: u64,
    end: u64,
    /// The read-only descriptor handed to readers.
    reader: OwnedFd,
}

// SAFETY: the mapping is owned by this value and written only through
// `&mut self`; other processes map it read-only.
unsafe impl Send for OutputRing {}
// SAFETY: `&self` methods only read immutable fields.
unsafe impl Sync for OutputRing {}

impl OutputRing {
    /// A new ring whose next byte has offset `base`.
    pub(crate) fn create(base: u64, capacity: usize) -> io::Result<Self> {
        if capacity == 0 || capacity as u64 > MAX_CAPACITY {
            return Err(invalid("output ring capacity out of range"));
        }
        let (writer, reader) = new_segment()?;
        let map_len = HEADER + capacity;
        let size = libc::off_t::try_from(map_len).map_err(|_| invalid("output ring too large"))?;
        // SAFETY: sizes a descriptor this function owns.
        if unsafe { libc::ftruncate(writer.as_raw_fd(), size) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let map = map(writer.as_raw_fd(), map_len, libc::PROT_READ | libc::PROT_WRITE)?;
        drop(writer);
        let ring = Self { map, map_len, capacity, base, end: base, reader };
        // SAFETY: the header is HEADER bytes at the start of the fresh mapping.
        unsafe {
            let header = std::slice::from_raw_parts_mut(map, HEADER);
            header[..4].copy_from_slice(&MAGIC);
            header[4..8].copy_from_slice(&LAYOUT.to_le_bytes());
            header[OFF_CAPACITY..OFF_CAPACITY + 8]
                .copy_from_slice(&(capacity as u64).to_le_bytes());
            header[OFF_BASE..OFF_BASE + 8].copy_from_slice(&base.to_le_bytes());
        }
        ring.atomic(OFF_RESERVE).store(base, Ordering::Relaxed);
        ring.atomic(OFF_END).store(base, Ordering::Release);
        Ok(ring)
    }

    /// The read-only descriptor a reader maps.
    pub(crate) fn reader_descriptor(&self) -> &OwnedFd {
        &self.reader
    }

    pub(crate) fn capacity(&self) -> usize {
        self.capacity
    }

    pub(crate) fn base(&self) -> u64 {
        self.base
    }

    /// Offset after the newest byte.
    pub(crate) fn end(&self) -> u64 {
        self.end
    }

    /// Append output. Never waits; past the capacity the oldest bytes drop out
    /// (a reader still on them sees a lap).
    pub(crate) fn push(&mut self, mut data: &[u8]) {
        if data.is_empty() {
            return;
        }
        let total = data.len() as u64;
        let target = self.end + total;
        // Reserve before any byte lands, so a reader that read an overwritten
        // byte sees the reservation after its acquire fence.
        self.atomic(OFF_RESERVE).store(target, Ordering::Relaxed);
        fence(Ordering::Release);
        let mut at = self.end;
        if data.len() > self.capacity {
            let skip = data.len() - self.capacity;
            at += skip as u64;
            data = &data[skip..];
        }
        while !data.is_empty() {
            let start = (at % self.capacity as u64) as usize;
            let n = (self.capacity - start).min(data.len());
            // SAFETY: start + n <= capacity, inside the data area.
            unsafe {
                std::ptr::copy_nonoverlapping(data.as_ptr(), self.map.add(HEADER + start), n);
            }
            at += n as u64;
            data = &data[n..];
        }
        self.end = target;
        self.atomic(OFF_END).store(target, Ordering::Release);
    }

    fn atomic(&self, offset: usize) -> &AtomicU64 {
        // SAFETY: offset is an 8-byte aligned u64 slot in the page-aligned
        // header, which lives as long as `self`.
        unsafe { &*self.map.add(offset).cast::<AtomicU64>() }
    }
}

impl Drop for OutputRing {
    fn drop(&mut self) {
        // SAFETY: unmaps the mapping this value made. Readers keep their own
        // mappings, so the pages stay valid for them.
        unsafe { libc::munmap(self.map.cast(), self.map_len) };
    }
}

/// A reader's view of a ring, mapped read-only. The daemon itself never reads
/// a ring; this is the reference implementation of the reader protocol the
/// app follows (CmuxNextDaemon `TerminalOutputRingMapping`), and the tests' reader.
#[cfg(test)]
pub(crate) struct OutputRingReader {
    map: *const u8,
    map_len: usize,
    capacity: usize,
    base: u64,
}

// SAFETY: the mapping is read-only and owned by this value.
#[cfg(test)]
unsafe impl Send for OutputRingReader {}

#[cfg(test)]
impl OutputRingReader {
    /// Map `descriptor` (a ring's read-only descriptor) and check its header.
    pub(crate) fn map(descriptor: &OwnedFd) -> io::Result<Self> {
        let fd = descriptor.as_raw_fd();
        // SAFETY: zeroed stat is a valid out-buffer for fstat.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: fstat of a live descriptor into a live local.
        if unsafe { libc::fstat(fd, &mut stat) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let size = u64::try_from(stat.st_size).unwrap_or(0);
        if size < HEADER as u64 {
            return Err(invalid("output ring smaller than its header"));
        }
        let header = map(fd, HEADER, libc::PROT_READ)?;
        // SAFETY: the header mapping is HEADER bytes.
        let (magic, layout, capacity, base) = unsafe {
            let bytes = std::slice::from_raw_parts(header, HEADER);
            let magic: [u8; 4] = bytes[..4].try_into().unwrap_or_default();
            let layout = u32::from_le_bytes(bytes[4..8].try_into().unwrap_or_default());
            let capacity = u64::from_le_bytes(bytes[8..16].try_into().unwrap_or_default());
            let base = u64::from_le_bytes(bytes[16..24].try_into().unwrap_or_default());
            libc::munmap(header.cast(), HEADER);
            (magic, layout, capacity, base)
        };
        if magic != MAGIC || layout != LAYOUT {
            return Err(invalid("not an output ring"));
        }
        if capacity == 0 || capacity > MAX_CAPACITY || HEADER as u64 + capacity > size {
            return Err(invalid("bad output ring capacity"));
        }
        let capacity = capacity as usize;
        let map_len = HEADER + capacity;
        let map = map(fd, map_len, libc::PROT_READ)?;
        Ok(Self { map, map_len, capacity, base })
    }

    pub(crate) fn capacity(&self) -> usize {
        self.capacity
    }

    pub(crate) fn base(&self) -> u64 {
        self.base
    }

    /// The writer's published end.
    pub(crate) fn end(&self) -> u64 {
        self.atomic(OFF_END).load(Ordering::Acquire)
    }

    /// `[from, to)` as at most two slices of the mapping, or `None` when the
    /// bytes already dropped out (`to - from` larger than the capacity, or
    /// `from` before the base). The slices may be overwritten while read:
    /// check [`Self::unlapped`] after using them.
    pub(crate) fn slices(&self, from: u64, to: u64) -> Option<(&[u8], &[u8])> {
        if from < self.base || to < from || to - from > self.capacity as u64 {
            return None;
        }
        let len = (to - from) as usize;
        let start = (from % self.capacity as u64) as usize;
        let first = len.min(self.capacity - start);
        // SAFETY: both ranges lie inside the data area of the mapping.
        unsafe {
            let data = self.map.add(HEADER);
            Some((
                std::slice::from_raw_parts(data.add(start), first),
                std::slice::from_raw_parts(data, len - first),
            ))
        }
    }

    /// Whether bytes read from offset `from` on are still the ones the
    /// writer published: false when the writer has started to overwrite them.
    pub(crate) fn unlapped(&self, from: u64) -> bool {
        fence(Ordering::Acquire);
        self.atomic(OFF_RESERVE).load(Ordering::Relaxed) <= from + self.capacity as u64
    }

    fn atomic(&self, offset: usize) -> &AtomicU64 {
        // SAFETY: an aligned u64 slot of the read-only header mapping.
        unsafe { &*self.map.add(offset).cast::<AtomicU64>() }
    }
}

#[cfg(test)]
impl Drop for OutputRingReader {
    fn drop(&mut self) {
        // SAFETY: unmaps the mapping this value made.
        unsafe { libc::munmap(self.map.cast_mut().cast(), self.map_len) };
    }
}

fn map(fd: RawFd, len: usize, prot: libc::c_int) -> io::Result<*mut u8> {
    // SAFETY: maps `len` bytes of a live descriptor, shared.
    let map = unsafe { libc::mmap(std::ptr::null_mut(), len, prot, libc::MAP_SHARED, fd, 0) };
    if map == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    Ok(map.cast())
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// A new segment: a read-write descriptor for the writer and a read-only one
/// for readers, close-on-exec, reachable only through descriptors.
#[cfg(target_os = "linux")]
fn new_segment() -> io::Result<(OwnedFd, OwnedFd)> {
    // SAFETY: memfd_create returns a new descriptor or -1.
    let fd = unsafe { libc::memfd_create(c"cmux-output-ring".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a fresh descriptor this function owns.
    let writer = unsafe { OwnedFd::from_raw_fd(fd) };
    let path =
        std::ffi::CString::new(format!("/proc/self/fd/{fd}")).map_err(|_| invalid("memfd path"))?;
    // SAFETY: opens the memfd again, read-only.
    let reader = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
    if reader < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a fresh descriptor this function owns.
    Ok((writer, unsafe { OwnedFd::from_raw_fd(reader) }))
}

/// An unlinked POSIX shared memory object, opened read-write and read-only
/// before the unlink, so no name outlives this call.
#[cfg(not(target_os = "linux"))]
fn new_segment() -> io::Result<(OwnedFd, OwnedFd)> {
    for _ in 0..16 {
        let mut random = [0_u8; 12];
        getrandom::fill(&mut random).map_err(|_| invalid("no randomness for a ring name"))?;
        // "/cmar" + 24 hex digits = 29 bytes, under macOS PSHMNAMLEN (31).
        let hex: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let name =
            std::ffi::CString::new(format!("/cmar{hex}")).map_err(|_| invalid("ring name"))?;
        // SAFETY: shm_open with a NUL-terminated name.
        let fd = unsafe {
            libc::shm_open(name.as_ptr(), libc::O_RDWR | libc::O_CREAT | libc::O_EXCL, 0o600)
        };
        if fd < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EEXIST) {
                continue;
            }
            return Err(error);
        }
        // SAFETY: a fresh descriptor this function owns.
        let writer = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: shm_open of the name just made, read-only.
        let reader = unsafe { libc::shm_open(name.as_ptr(), libc::O_RDONLY, 0) };
        let reader_error = io::Error::last_os_error();
        // SAFETY: removes the name; open descriptors keep the object.
        unsafe { libc::shm_unlink(name.as_ptr()) };
        if reader < 0 {
            return Err(reader_error);
        }
        // SAFETY: a fresh descriptor this function owns.
        let reader = unsafe { OwnedFd::from_raw_fd(reader) };
        for descriptor in [&writer, &reader] {
            // SAFETY: sets close-on-exec on a live descriptor.
            unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
        }
        return Ok((writer, reader));
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free output ring name"))
}

#[cfg(test)]
#[path = "tests/output_ring.rs"]
mod tests;
