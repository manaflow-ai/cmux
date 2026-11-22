//! A bounded ring of the bytes a terminal's attach stream carried, keyed by
//! the stream's monotonic byte offset (`terminal-resume-v1`).
//!
//! A viewer that lost its link and reattaches with the last `offset` it read
//! gets exactly the bytes after it, with no replay and no reset, while they
//! are still in the ring and nothing replaced the stream's state meanwhile.
//! The ring is written under the terminal lock, in the same places the
//! snapshot stream position advances, so the offsets agree.
//!
//! The `generation` a viewer holds is `"<nonce>.<epoch>"`. The nonce names this
//! terminal instance (a recreated terminal has a new one, so an offset of the
//! old one never matches). The epoch counts the events that change what a
//! mirror shows besides the bytes (a resize or host replay, a color change):
//! a viewer that held another epoch gets today's replay.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

/// Bytes kept per terminal.
pub(crate) const RESUME_RING_BYTES: usize = 4 * 1024 * 1024;

/// Where a stream stands: terminal nonce, epoch and the offset after its last byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct StreamStamp {
    pub nonce: u64,
    pub epoch: u64,
    pub offset: u64,
}

impl StreamStamp {
    /// The opaque `generation` string of the wire.
    pub(crate) fn generation(&self) -> String {
        format!("{:x}.{}", self.nonce, self.epoch)
    }

    /// The nonce and epoch of a `generation` string.
    pub(crate) fn parse_generation(text: &str) -> Option<(u64, u64)> {
        let (nonce, epoch) = text.split_once('.')?;
        Some((u64::from_str_radix(nonce, 16).ok()?, epoch.parse().ok()?))
    }
}

struct RingInner {
    bytes: VecDeque<u8>,
    /// Offset after the last byte.
    end: u64,
    epoch: u64,
}

pub(crate) struct ResumeRing {
    nonce: u64,
    budget: usize,
    inner: Mutex<RingInner>,
}

fn fresh_nonce() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos() as u64);
    let mixed =
        nanos ^ (u64::from(std::process::id()) << 40) ^ NEXT.fetch_add(1, Ordering::Relaxed);
    // splitmix64 finalizer
    let mut z = mixed.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

impl Default for ResumeRing {
    fn default() -> Self {
        Self::with_budget(RESUME_RING_BYTES)
    }
}

impl ResumeRing {
    pub(crate) fn with_budget(budget: usize) -> Self {
        Self {
            nonce: fresh_nonce(),
            budget,
            inner: Mutex::new(RingInner { bytes: VecDeque::new(), end: 0, epoch: 0 }),
        }
    }

    pub(crate) fn append(&self, output: &[u8]) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.end += output.len() as u64;
        let tail = output.get(output.len().saturating_sub(self.budget)..).unwrap_or_default();
        inner.bytes.extend(tail.iter().copied());
        let over = inner.bytes.len().saturating_sub(self.budget);
        if over > 0 {
            inner.bytes.drain(..over);
        }
    }

    /// A change a viewer holding the old epoch cannot resume across.
    pub(crate) fn bump_epoch(&self) {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).epoch += 1;
    }

    pub(crate) fn stamp(&self) -> StreamStamp {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        StreamStamp { nonce: self.nonce, epoch: inner.epoch, offset: inner.end }
    }

    /// The bytes after `offset` when the viewer's `(nonce, epoch)` is current
    /// and `offset` is still in the ring; with the stamp they bring it to.
    pub(crate) fn missing_after(
        &self,
        (nonce, epoch): (u64, u64),
        offset: u64,
    ) -> Option<(Vec<u8>, StreamStamp)> {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if nonce != self.nonce || epoch != inner.epoch || offset > inner.end {
            return None;
        }
        let start = inner.end - inner.bytes.len() as u64;
        if offset < start {
            return None;
        }
        let skip = (offset - start) as usize;
        let missing: Vec<u8> = inner.bytes.range(skip..).copied().collect();
        Some((missing, StreamStamp { nonce, epoch, offset: inner.end }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_bytes_are_exact_and_the_ring_is_bounded() {
        let ring = ResumeRing::with_budget(8);
        ring.append(b"abcd");
        let stamp = ring.stamp();
        let held = (stamp.nonce, stamp.epoch);
        assert_eq!(ring.missing_after(held, 2).unwrap().0, b"cd");
        assert_eq!(ring.missing_after(held, 4).unwrap().0, b"");
        assert!(ring.missing_after(held, 5).is_none());
        ring.append(b"efghij");
        // Ten bytes written, the last eight kept: offsets 2.. resume.
        assert_eq!(ring.missing_after(held, 2).unwrap().0, b"cdefghij");
        assert!(ring.missing_after(held, 1).is_none());
        ring.append(&[b'z'; 100]);
        assert_eq!(ring.stamp().offset, 110);
        assert_eq!(ring.missing_after(held, 102).unwrap().0.len(), 8);
        ring.bump_epoch();
        assert!(ring.missing_after(held, 110).is_none());
        assert!(ring.missing_after((held.0 ^ 1, ring.stamp().epoch), 110).is_none());
    }

    #[test]
    fn generation_strings_round_trip() {
        let stamp = StreamStamp { nonce: 0xdead_beef_0123, epoch: 7, offset: 9 };
        assert_eq!(
            StreamStamp::parse_generation(&stamp.generation()),
            Some((stamp.nonce, stamp.epoch))
        );
        assert_eq!(StreamStamp::parse_generation("nope"), None);
    }
}
