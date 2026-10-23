//! A terminal's output ring with absolute byte offsets.

use std::collections::VecDeque;

/// The last `capacity` bytes a terminal printed. Offsets count from the
/// terminal's first byte (or from the base an adoption continues from), so a
/// reader names a position that stays valid while older bytes drop out.
pub struct Ring {
    bytes: VecDeque<u8>,
    /// Offset of `bytes[0]`.
    start: u64,
    capacity: usize,
}

impl Ring {
    /// An empty ring whose next byte has offset `base`.
    pub fn new(base: u64, capacity: usize) -> Self {
        Self { bytes: VecDeque::new(), start: base, capacity }
    }

    /// Append output; the oldest bytes drop out past the capacity. The
    /// writer is never blocked.
    pub fn push(&mut self, data: &[u8]) {
        self.bytes.extend(data);
        let over = self.bytes.len().saturating_sub(self.capacity);
        if over > 0 {
            self.bytes.drain(..over);
            self.start += over as u64;
        }
    }

    /// Offset of the oldest byte kept.
    pub fn oldest(&self) -> u64 {
        self.start
    }

    /// Offset after the newest byte.
    pub fn end(&self) -> u64 {
        self.start + self.bytes.len() as u64
    }

    /// Up to `max` bytes from `from` (clamped to the oldest kept byte), with
    /// the offset they start at.
    pub fn read(&self, from: u64, max: usize) -> (u64, Vec<u8>) {
        let from = from.clamp(self.start, self.end());
        let skip = (from - self.start) as usize;
        let take = max.min(self.bytes.len() - skip);
        let mut out = Vec::with_capacity(take);
        let (head, tail) = self.bytes.as_slices();
        if skip < head.len() {
            let end = (skip + take).min(head.len());
            out.extend_from_slice(&head[skip..end]);
            out.extend_from_slice(&tail[..take - (end - skip)]);
        } else {
            let start = skip - head.len();
            out.extend_from_slice(&tail[start..start + take]);
        }
        (from, out)
    }
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
}
