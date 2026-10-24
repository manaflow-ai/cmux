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
//! holder had not published yet are lost (the instructions between the
//! `read` returning and the store of the new end).
//!
//! Layout (little endian, [`HEADER`] bytes, then `capacity` data bytes):
//! `magic "CMHR" | layout u32 | capacity u64 | base u64 | end u64`. `base`
//! is the offset of the first byte the ring ever held; the byte at offset
//! `o` is at data position `o % capacity`; the ring keeps
//! `max(base, end - capacity) .. end`. A writer stores the data first and
//! the new `end` after it, so a reader of a dead writer's segment sees only
//! whole writes. One process at a time writes a ring: the holder that owns
//! the terminal (the daemon gives a segment to a new holder only after the
//! old one's link ended).

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicU64, Ordering};

/// Header bytes before the data.
pub const HEADER: usize = 64;
/// Segment magic.
const MAGIC: [u8; 4] = *b"CMHR";
/// Layout version of the header.
const LAYOUT: u32 = 1;
/// The largest ring a segment may describe (a corrupt header must not make
/// the holder map gigabytes).
const MAX_CAPACITY: u64 = 64 << 20;
const OFF_CAPACITY: usize = 8;
const OFF_BASE: usize = 16;
const OFF_END: usize = 24;

/// The last `capacity` bytes a terminal printed. Offsets count from the
/// terminal's first byte (or from the base an adoption continues from), so a
/// reader names a position that stays valid while older bytes drop out.
pub struct Ring {
    /// The mapping: header, then data.
    map: *mut u8,
    map_len: usize,
    capacity: usize,
    base: u64,
    /// The offset after the newest byte; mirrors the header's `end`.
    end: u64,
    /// The shared segment, `None` for a private ring (no shared memory).
    segment: Option<OwnedFd>,
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
        let mut ring = Self { map: map.cast(), map_len, capacity, base, end: base, segment: None };
        ring.write_header();
        ring
    }

    /// Continue the ring in `segment` (a dead holder's, passed back by the
    /// daemon): its offsets and kept bytes are this ring's.
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
        let (magic, layout, capacity, base, end) = unsafe {
            let bytes = std::slice::from_raw_parts(header, HEADER);
            let magic: [u8; 4] = bytes[..4].try_into().unwrap_or_default();
            let layout = u32::from_le_bytes(bytes[4..8].try_into().unwrap_or_default());
            let capacity = u64::from_le_bytes(bytes[8..16].try_into().unwrap_or_default());
            let base = u64::from_le_bytes(bytes[16..24].try_into().unwrap_or_default());
            let end = (*header.add(OFF_END).cast::<AtomicU64>()).load(Ordering::Acquire);
            libc::munmap(header.cast(), HEADER);
            (magic, layout, capacity, base, end)
        };
        if magic != MAGIC || layout != LAYOUT {
            return Err(invalid("not a terminal ring segment"));
        }
        if capacity == 0 || capacity > MAX_CAPACITY || HEADER as u64 + capacity > size {
            return Err(invalid("bad terminal ring capacity"));
        }
        if end < base {
            return Err(invalid("terminal ring ends before its base"));
        }
        let capacity = capacity as usize;
        let map_len = HEADER + capacity;
        let map = map_shared(segment.as_raw_fd(), map_len)?;
        Ok(Self { map, map_len, capacity, base, end, segment: Some(segment) })
    }

    /// The shared segment, to pass to the daemon; `None` for a private ring.
    pub fn segment(&self) -> Option<&OwnedFd> {
        self.segment.as_ref()
    }

    /// Append output; the oldest bytes drop out past the capacity. The
    /// writer is never blocked.
    pub fn push(&mut self, mut data: &[u8]) {
        // Only the last `capacity` bytes of an oversized push can stay.
        if data.len() > self.capacity {
            let skip = data.len() - self.capacity;
            self.publish(self.end + skip as u64);
            data = &data[skip..];
        }
        while !data.is_empty() {
            let room = self.writable();
            let n = room.len().min(data.len());
            room[..n].copy_from_slice(&data[..n]);
            self.publish(self.end + n as u64);
            data = &data[n..];
        }
    }

    /// Read at most `max` bytes straight into the ring with `read` (given
    /// the room up to the end of the data area, never empty) and publish
    /// what it returned. Returns `read`'s result: the bytes are in the ring
    /// as soon as it returns, so a crash right after loses at most one
    /// unpublished read.
    pub fn read_with(&mut self, max: usize, read: impl FnOnce(&mut [u8]) -> isize) -> isize {
        let room = self.writable();
        let len = room.len().min(max.max(1));
        let n = read(&mut room[..len]);
        if n > 0 {
            self.publish(self.end + n as u64);
        }
        n
    }

    /// Offset of the oldest byte kept.
    pub fn oldest(&self) -> u64 {
        self.base.max(self.end.saturating_sub(self.capacity as u64))
    }

    /// Offset after the newest byte.
    pub fn end(&self) -> u64 {
        self.end
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
        let from = from.clamp(self.oldest(), self.end);
        let take = max.min((self.end - from) as usize);
        let start = (from % self.capacity as u64) as usize;
        let first = take.min(self.capacity - start);
        let data = self.data();
        (from, &data[start..start + first], &data[..take - first])
    }

    /// The data area.
    fn data(&self) -> &[u8] {
        // SAFETY: the mapping holds HEADER + capacity bytes for this
        // value's life, and only this process writes it (module docs).
        unsafe { std::slice::from_raw_parts(self.map.add(HEADER), self.capacity) }
    }

    /// The free room from `end` to the end of the data area (where the next
    /// byte goes), never empty.
    fn writable(&mut self) -> &mut [u8] {
        let start = (self.end % self.capacity as u64) as usize;
        // SAFETY: start < capacity, so the slice stays inside the data area.
        unsafe {
            std::slice::from_raw_parts_mut(self.map.add(HEADER + start), self.capacity - start)
        }
    }

    /// Make every byte before `end` part of the ring: after the data, so a
    /// reader of a dead holder's segment never sees an unwritten byte.
    fn publish(&mut self, end: u64) {
        self.end = end;
        // SAFETY: OFF_END is an 8-byte aligned u64 inside the page-aligned header.
        unsafe { (*self.map.add(OFF_END).cast::<AtomicU64>()).store(end, Ordering::Release) };
    }

    fn write_header(&mut self) {
        // SAFETY: the header is HEADER bytes at the start of the mapping.
        unsafe {
            let header = std::slice::from_raw_parts_mut(self.map, HEADER);
            header[..4].copy_from_slice(&MAGIC);
            header[4..8].copy_from_slice(&LAYOUT.to_le_bytes());
            header[OFF_CAPACITY..OFF_CAPACITY + 8]
                .copy_from_slice(&(self.capacity as u64).to_le_bytes());
            header[OFF_BASE..OFF_BASE + 8].copy_from_slice(&self.base.to_le_bytes());
        }
        self.publish(self.end);
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        // SAFETY: unmaps the mapping this value made.
        unsafe { libc::munmap(self.map.cast(), self.map_len) };
    }
}

/// A new shared ring segment whose next byte has offset `base`: the
/// descriptor to pass, with the header written. The daemon makes one when it
/// hands a terminal that had none (an older holder's) to a holder of wire
/// version 4, so the next holder crash loses no byte either.
pub fn create_segment(base: u64, capacity: usize) -> io::Result<OwnedFd> {
    let segment = new_segment()?;
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
        (*map.add(OFF_END).cast::<AtomicU64>()).store(base, Ordering::Release);
        libc::munmap(map.cast(), HEADER);
    }
    Ok(segment)
}

/// The end offset recorded in a ring segment (what its writer published).
pub fn segment_end(segment: &OwnedFd) -> io::Result<u64> {
    let map = map_shared(segment.as_raw_fd(), HEADER)?;
    // SAFETY: the header mapping is HEADER bytes; OFF_END is aligned.
    let end = unsafe {
        let end = (*map.add(OFF_END).cast::<AtomicU64>()).load(Ordering::Acquire);
        libc::munmap(map.cast(), HEADER);
        end
    };
    Ok(end)
}

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
#[cfg(not(target_os = "linux"))]
fn new_segment() -> io::Result<OwnedFd> {
    use std::sync::atomic::AtomicU32;
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
        // SAFETY: shm_open with a NUL-terminated name; the mode is variadic.
        let fd = unsafe {
            libc::shm_open(
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                0o600 as libc::c_uint,
            )
        };
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
