//! Per-stream sequence, ack and replay: the transport-neutral core of a link
//! that survives a carrier change.
//!
//! [`ReliableSession`](../../cmux_remote/session/struct.ReliableSession.html)
//! does this for the Mac-to-remote link's fixed lanes over an async runtime;
//! this is the same bookkeeping without a runtime, keyed by any stream id (the
//! phone link keys it by channel), so a crate that must stay small (the iOS
//! build) reuses it without the rest of `cmux-remote`.
//!
//! - [`ReplayLog`]: what this side sent and the peer has not acked, per
//!   stream, with the sequence each frame got. Bounded in bytes per stream.
//! - [`Cursors`]: per stream, the last sequence received in order. A replayed
//!   frame at or below the cursor is a duplicate and is dropped, so every frame
//!   reaches its owner exactly once.
//!
//! Sequences start at 1 per stream; a cursor of 0 means nothing received.

use std::collections::{BTreeMap, VecDeque};

/// A payload the log can hold: it knows its size in bytes.
pub trait ByteLen {
    fn byte_len(&self) -> usize;
}

impl<T: AsRef<[u8]>> ByteLen for T {
    fn byte_len(&self) -> usize {
        self.as_ref().len()
    }
}

#[derive(Debug)]
struct OutStream<P> {
    next: u64,
    unacked: VecDeque<(u64, P)>,
    bytes: usize,
    /// The sequence of this stream's last frame (its close), once sent.
    last: Option<u64>,
}

impl<P> Default for OutStream<P> {
    fn default() -> Self {
        Self { next: 1, unacked: VecDeque::new(), bytes: 0, last: None }
    }
}

/// Frames sent and not yet acked, per stream `K`.
#[derive(Debug)]
pub struct ReplayLog<K, P> {
    streams: BTreeMap<K, OutStream<P>>,
    bytes: usize,
}

impl<K, P> Default for ReplayLog<K, P> {
    fn default() -> Self {
        Self { streams: BTreeMap::new(), bytes: 0 }
    }
}

impl<K: Ord + Copy, P: Clone> ReplayLog<K, P> {
    /// Gives `payload` the next sequence of `stream` and keeps it until acked.
    /// `last`: no frame of `stream` follows (its close); once acked through
    /// it, the stream is forgotten.
    pub fn record(&mut self, stream: K, payload: P, last: bool) -> u64
    where
        P: ByteLen,
    {
        let entry = self.streams.entry(stream).or_default();
        let sequence = entry.next;
        entry.next += 1;
        let size = payload.byte_len();
        entry.bytes += size;
        self.bytes += size;
        entry.unacked.push_back((sequence, payload));
        if last {
            entry.last = Some(sequence);
        }
        sequence
    }

    /// The peer has everything of `stream` through `sequence`. Returns the
    /// bytes released.
    pub fn ack(&mut self, stream: K, sequence: u64) -> usize
    where
        P: ByteLen,
    {
        let Some(entry) = self.streams.get_mut(&stream) else { return 0 };
        let mut freed = 0;
        while let Some((front, _)) = entry.unacked.front()
            && *front <= sequence
        {
            if let Some((_, payload)) = entry.unacked.pop_front() {
                freed += payload.byte_len();
            }
        }
        entry.bytes -= freed;
        self.bytes -= freed;
        if entry.last.is_some_and(|last| last <= sequence) {
            self.streams.remove(&stream);
        }
        freed
    }

    /// Forget `stream` whole (the peer dropped it; nothing of it matters).
    pub fn forget(&mut self, stream: K) -> usize {
        let Some(entry) = self.streams.remove(&stream) else { return 0 };
        self.bytes -= entry.bytes;
        entry.bytes
    }

    /// Unacked bytes of `stream`.
    pub fn stream_bytes(&self, stream: K) -> usize {
        self.streams.get(&stream).map_or(0, |entry| entry.bytes)
    }

    /// Unacked bytes across every stream.
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// Streams with a log entry (sent frames, acked or not, not yet closed).
    pub fn streams(&self) -> impl Iterator<Item = K> + '_ {
        self.streams.keys().copied()
    }

    /// The frames of `stream` after `cursor`, oldest first, with their
    /// sequences: what a peer whose cursor is `cursor` is missing. Everything
    /// at or below `cursor` is acked by the same call.
    pub fn resume_from(&mut self, stream: K, cursor: u64) -> Vec<(u64, P)>
    where
        P: ByteLen,
    {
        self.ack(stream, cursor);
        self.streams
            .get(&stream)
            .map(|entry| entry.unacked.iter().cloned().collect())
            .unwrap_or_default()
    }
}

/// What [`Cursors::accept`] makes of an inbound frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Inbound {
    /// The next frame of its stream: deliver it.
    Deliver,
    /// At or below the cursor: already delivered, drop it.
    Duplicate,
    /// Past the cursor by more than one: a frame is missing (a protocol
    /// error on an ordered carrier).
    Gap { expected: u64 },
    /// No cursor for the stream and it is not new (the stream was closed
    /// here): drop it.
    Unknown,
}

/// Per stream, the last sequence received in order.
#[derive(Debug, Default, Clone)]
pub struct Cursors<K> {
    cursors: BTreeMap<K, u64>,
}

impl<K: Ord + Copy> Cursors<K> {
    /// Starts tracking `stream` at 0 (this side opened it).
    pub fn open(&mut self, stream: K) {
        self.cursors.entry(stream).or_insert(0);
    }

    /// Stops tracking `stream` (closed here); later frames of it are
    /// [`Inbound::Unknown`].
    pub fn close(&mut self, stream: K) {
        self.cursors.remove(&stream);
    }

    /// Judge frame `sequence` of `stream`; `new_stream`: the stream may start
    /// here (a peer-opened stream never seen before). Advances the cursor on
    /// [`Inbound::Deliver`].
    pub fn accept(&mut self, stream: K, sequence: u64, new_stream: bool) -> Inbound {
        let cursor = match self.cursors.get_mut(&stream) {
            Some(cursor) => cursor,
            None if new_stream && sequence == 1 => {
                self.cursors.insert(stream, 1);
                return Inbound::Deliver;
            }
            None => return Inbound::Unknown,
        };
        if sequence <= *cursor {
            Inbound::Duplicate
        } else if sequence == *cursor + 1 {
            *cursor = sequence;
            Inbound::Deliver
        } else {
            Inbound::Gap { expected: *cursor + 1 }
        }
    }

    pub fn get(&self, stream: K) -> Option<u64> {
        self.cursors.get(&stream).copied()
    }

    /// Every tracked stream and its cursor: what a resume sends.
    pub fn snapshot(&self) -> Vec<(K, u64)> {
        self.cursors.iter().map(|(stream, cursor)| (*stream, *cursor)).collect()
    }

    pub fn len(&self) -> usize {
        self.cursors.len()
    }

    pub fn is_empty(&self) -> bool {
        self.cursors.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_is_only_what_the_peer_lacks_and_duplicates_drop() {
        let mut log = ReplayLog::<u32, Vec<u8>>::default();
        let mut peer = Cursors::<u32>::default();
        for i in 0..5u8 {
            log.record(7, vec![i; 10], false);
        }
        // The peer got 1..=3; 4 and 5 were lost with the carrier.
        for sequence in 1..=3 {
            assert_eq!(peer.accept(7, sequence, true), Inbound::Deliver);
        }
        let missing = log.resume_from(7, peer.get(7).unwrap());
        assert_eq!(missing.iter().map(|(s, _)| *s).collect::<Vec<_>>(), vec![4, 5]);
        assert_eq!(log.bytes(), 20, "acked bytes are released by the resume");
        // A late copy of 3 is a duplicate; 5 before 4 is a gap.
        assert_eq!(peer.accept(7, 3, true), Inbound::Duplicate);
        assert_eq!(peer.accept(7, 5, true), Inbound::Gap { expected: 4 });
        assert_eq!(peer.accept(7, 4, true), Inbound::Deliver);
        assert_eq!(peer.accept(7, 5, true), Inbound::Deliver);
    }

    #[test]
    fn a_closed_stream_is_forgotten_once_its_last_frame_is_acked() {
        let mut log = ReplayLog::<u32, Vec<u8>>::default();
        log.record(1, vec![0; 4], false);
        let last = log.record(1, vec![0; 2], true);
        assert_eq!(log.ack(1, last - 1), 4);
        assert_eq!(log.streams().count(), 1);
        assert_eq!(log.ack(1, last), 2);
        assert_eq!(log.streams().count(), 0);
        assert_eq!(log.bytes(), 0);
        let mut cursors = Cursors::<u32>::default();
        cursors.open(2);
        cursors.close(2);
        assert_eq!(cursors.accept(2, 1, false), Inbound::Unknown);
    }
}
