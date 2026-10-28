//! A terminal's output ring, mapped read-only.
//!
//! The segment is the holder's (`cmux_holder::ring`, layout 2): a 64-byte
//! header `magic "CMHR" | layout u32 | capacity u64 | base u64 | end u64 |
//! oldest u64 | reading u64`, then `capacity` data bytes; the byte at
//! offset `o` is at data position `o % capacity`, and the ring keeps
//! `oldest .. end`. The holder keeps writing while the worker reads, so the
//! worker never parses the mapping in place: it copies a window, then
//! re-reads `oldest` and drops the copy when the writer reached it (the
//! writer publishes `oldest` past every byte it will overwrite before it
//! stores; cmux-holder `ring_protocol.rs`). A torn read cannot be undone
//! after the parser saw it (p01-process.md, correction to task 131).
//!
//! The tests pin these constants to the holder's own segments.

use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::sync::atomic::{Ordering, fence};

use crate::shm::Mapping;

/// Header bytes before the data.
pub const RING_HEADER: usize = 64;
/// The largest ring a segment may describe (cmux-holder's `MAX_CAPACITY`).
pub const MAX_RING_CAPACITY: u64 = 64 << 20;
const MAGIC: [u8; 4] = *b"CMHR";
/// The header layout with a published `oldest` (the only one the worker reads).
const LAYOUT: u32 = 2;
const OFF_CAPACITY: usize = 8;
const OFF_END: usize = 24;
const OFF_OLDEST: usize = 32;

/// A segment the worker refuses to parse.
#[derive(Debug)]
pub enum RingError {
    /// The capacity is 0 or above [`MAX_RING_CAPACITY`].
    BadCapacity(u64),
    /// The segment could not be mapped.
    Map(io::Error),
    /// The header's magic is not a ring's.
    NotARing,
    /// A header layout other than 2.
    Layout(u32),
    /// The header's capacity is not the one the daemon announced.
    CapacityMismatch { header: u64, announced: u64 },
}

impl std::fmt::Display for RingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadCapacity(capacity) => write!(f, "ring capacity {capacity} out of range"),
            Self::Map(error) => write!(f, "map ring: {error}"),
            Self::NotARing => f.write_str("not a terminal ring segment"),
            Self::Layout(layout) => write!(f, "ring layout {layout} unsupported"),
            Self::CapacityMismatch { header, announced } => {
                write!(f, "ring capacity {header} differs from announced {announced}")
            }
        }
    }
}

impl std::error::Error for RingError {}

/// What one [`RingView::copy`] got.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RingCopy {
    /// Nothing new before the limit.
    Empty,
    /// `len` bytes from `from` are in the buffer, whole and in order.
    Bytes { from: u64, len: usize },
    /// The writer dropped bytes from `from` on: the oldest kept byte is
    /// `oldest`. The buffer is empty.
    Lapped { from: u64, oldest: u64 },
}

/// A ring segment mapped read-only.
#[derive(Debug)]
pub struct RingView {
    map: Mapping,
    capacity: u64,
}

impl RingView {
    /// Map `segment`, whose data area the daemon announced as `capacity`
    /// bytes, read-only and check its header. The descriptor is closed: the
    /// mapping keeps the object.
    pub fn open(segment: OwnedFd, capacity: u64) -> Result<Self, RingError> {
        if capacity == 0 || capacity > MAX_RING_CAPACITY {
            return Err(RingError::BadCapacity(capacity));
        }
        // In range by the check above.
        let len = RING_HEADER + capacity as usize;
        let map = Mapping::map(segment.as_fd(), len, false).map_err(RingError::Map)?;
        let mut head = [0u8; 16];
        if !map.copy_out(0, &mut head) {
            return Err(RingError::NotARing);
        }
        if head[..4] != MAGIC {
            return Err(RingError::NotARing);
        }
        let layout = u32::from_le_bytes([head[4], head[5], head[6], head[7]]);
        if layout != LAYOUT {
            return Err(RingError::Layout(layout));
        }
        let mut word = [0u8; 8];
        word.copy_from_slice(&head[OFF_CAPACITY..OFF_CAPACITY + 8]);
        let header = u64::from_le_bytes(word);
        if header != capacity {
            return Err(RingError::CapacityMismatch { header, announced: capacity });
        }
        Ok(Self { map, capacity })
    }

    pub fn capacity(&self) -> u64 {
        self.capacity
    }

    /// The offset after the newest byte the writer published.
    pub fn end(&self) -> u64 {
        self.map.word(OFF_END).map_or(0, |word| word.load(Ordering::Acquire))
    }

    /// The offset of the oldest byte the ring keeps.
    pub fn oldest(&self) -> u64 {
        self.map.word(OFF_OLDEST).map_or(0, |word| word.load(Ordering::Acquire))
    }

    /// Copy up to `max` bytes from `from`, stopping at `until` and at the
    /// published end, into `out` (replacing its contents); then check that
    /// the writer did not reach them meanwhile.
    pub fn copy(&self, from: u64, until: u64, max: usize, out: &mut Vec<u8>) -> RingCopy {
        out.clear();
        let oldest = self.oldest();
        if from < oldest {
            return RingCopy::Lapped { from, oldest };
        }
        let end = self.end().min(until);
        if from >= end {
            return RingCopy::Empty;
        }
        // `end - from` may exceed the capacity only in a corrupt header:
        // the window is then cut to what one turn of the ring holds.
        let len = (end - from).min(self.capacity).min(max as u64) as usize;
        out.resize(len, 0);
        let start = (from % self.capacity) as usize;
        let first = len.min(self.capacity as usize - start);
        let (head, tail) = out.split_at_mut(first);
        // Both ranges are inside the data area: `start < capacity`, the head
        // ends at the capacity at most and the tail is shorter than a turn.
        let copied =
            self.map.copy_out(RING_HEADER + start, head) && self.map.copy_out(RING_HEADER, tail);
        debug_assert!(copied, "ring window outside the mapping");
        // The data loads above happen before the second read of `oldest`.
        fence(Ordering::Acquire);
        let oldest = self.oldest();
        if oldest > from {
            out.clear();
            return RingCopy::Lapped { from, oldest };
        }
        RingCopy::Bytes { from, len }
    }
}
