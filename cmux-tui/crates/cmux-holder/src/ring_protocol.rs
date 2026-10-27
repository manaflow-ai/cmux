//! The offset protocol of a terminal ring segment (`crate::ring`): the
//! order in which its writer publishes `oldest`, `end` and `reading` around
//! the data it stores, and how a reader of a dead writer's segment turns
//! those words into the window it trusts and the loss it reports.
//!
//! This file holds no mapping, descriptor or `unsafe`: the words are plain
//! atomics and the data is reached through the caller's closures, so
//! `cmux-tui/verify/loom-ring` includes it through `#[path]` and runs it
//! under loom. With `--cfg loom` the atomics and the fence are loom's;
//! the holder build uses std's.
//!
//! Writer order for one write of up to `len` bytes at `end` (one process
//! writes a segment at a time):
//!
//! 1. publish `oldest` past every kept byte whose room the write reuses,
//!    then a SeqCst fence, so no data store lands before it;
//! 2. for a PTY read only: publish `reading` = `end + 1`, then a fence;
//! 3. store the data;
//! 4. publish the new `end` (Release: after the data);
//! 5. for a PTY read only: give back the room a short read did not use
//!    (`oldest`), then clear `reading`.
//!
//! A reader that trusts only `oldest .. end` of a segment whose writer
//! stopped anywhere in that sequence sees only whole writes and no byte a
//! later write overwrote; a `reading` that names the segment's own `end`
//! says a read's bytes were taken from the PTY and never published.

use std::ops::Range;

#[cfg(loom)]
use loom::sync::atomic::{AtomicU64, Ordering, fence};
#[cfg(not(loom))]
use std::sync::atomic::{AtomicU64, Ordering, fence};

/// The header words both the writer and a later reader of a segment use.
pub(crate) struct Words<'a> {
    pub(crate) end: &'a AtomicU64,
    pub(crate) oldest: &'a AtomicU64,
    /// 1 + the offset a `read` in flight started at, 0 for none.
    pub(crate) reading: &'a AtomicU64,
    /// The model's kill point after each word the writer stores.
    #[cfg(loom)]
    pub(crate) kill_point: &'a dyn KillPoint,
}

/// Under loom: where the model may SIGKILL the writer, once each header
/// word store is in the segment (the data stores are the caller's).
#[cfg(loom)]
pub(crate) trait KillPoint {
    fn reached(&self);
}

impl Words<'_> {
    /// A header word store is done.
    #[inline]
    fn stored(&self) {
        #[cfg(loom)]
        self.kill_point.reached();
    }
}

/// The writer's view of a ring: its capacity and the window it keeps,
/// mirrored in the segment's words as it publishes them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Cursor {
    capacity: usize,
    /// The offset of the oldest byte kept.
    oldest: u64,
    /// The offset after the newest byte.
    end: u64,
}

impl Cursor {
    /// A ring of `capacity` data bytes keeping `oldest .. end`.
    pub(crate) fn new(capacity: usize, oldest: u64, end: u64) -> Self {
        Self { capacity, oldest, end }
    }

    pub(crate) fn capacity(&self) -> usize {
        self.capacity
    }

    pub(crate) fn oldest(&self) -> u64 {
        self.oldest
    }

    pub(crate) fn end(&self) -> u64 {
        self.end
    }

    /// Up to `max` bytes from `from` (clamped into the kept window): the
    /// offset they start at and their data positions, at most two ranges
    /// in order (the second after the wrap).
    pub(crate) fn window(&self, from: u64, max: usize) -> (u64, Range<usize>, Range<usize>) {
        let from = from.clamp(self.oldest, self.end);
        let take = max.min((self.end - from) as usize);
        let start = (from % self.capacity as u64) as usize;
        let first = take.min(self.capacity - start);
        (from, start..start + first, 0..take - first)
    }

    /// The free room from `end` to the end of the data area (where the next
    /// byte goes), never empty.
    pub(crate) fn room(&self) -> Range<usize> {
        let start = (self.end % self.capacity as u64) as usize;
        start..self.capacity
    }

    /// Publish both window words as this cursor has them (a new or adopted
    /// header).
    pub(crate) fn republish(&mut self, words: &Words<'_>) {
        self.publish_oldest(words, self.oldest);
        self.publish(words, self.end);
    }

    /// Append `data`; `store` copies a piece of it to a data range. The
    /// oldest bytes drop out past the capacity.
    pub(crate) fn push(
        &mut self,
        words: &Words<'_>,
        mut data: &[u8],
        mut store: impl FnMut(Range<usize>, &[u8]),
    ) {
        // Only the last `capacity` bytes of an oversized push can stay: the
        // stream jumps past the rest. The jump is in `oldest` only (nothing
        // is kept until the first chunk's `end` is published), so a reader of
        // a dead writer's segment never sees the skipped offsets as bytes.
        if data.len() > self.capacity {
            let skip = data.len() - self.capacity;
            let start = self.end + skip as u64;
            self.publish_oldest(words, start);
            self.end = start;
            data = &data[skip..];
        }
        while !data.is_empty() {
            let room = self.room();
            let n = room.len().min(data.len());
            self.forfeit(words, n);
            store(room.start..room.start + n, &data[..n]);
            self.publish(words, self.end + n as u64);
            data = &data[n..];
        }
    }

    /// One PTY read into the room up to the end of the data area (at most
    /// `max` bytes, never empty): `read` gets the data range and returns
    /// `read(2)`'s result, whose bytes are published. `reading` names the
    /// offset the read started at from before `read` runs until after its
    /// end is published.
    pub(crate) fn read_with(
        &mut self,
        words: &Words<'_>,
        max: usize,
        read: impl FnOnce(Range<usize>) -> isize,
    ) -> isize {
        let room = self.room();
        let len = room.len().min(max.max(1));
        let before = self.oldest;
        self.forfeit(words, len);
        self.publish_reading(words, Some(self.end));
        let n = read(room.start..room.start + len);
        if n > 0 {
            self.publish(words, self.end + n as u64);
        }
        // A short read overwrote less than the room it was offered: the
        // bytes past it are still whole and kept again.
        self.publish_oldest(words, before.max(self.end.saturating_sub(self.capacity as u64)));
        // After the new end: a writer killed between the two stores left a
        // `reading` behind its `end`, which names no loss.
        self.publish_reading(words, None);
        n
    }

    /// Make every byte before `end` part of the ring: after the data, so a
    /// reader of a dead writer's segment never sees an unwritten byte.
    fn publish(&mut self, words: &Words<'_>, end: u64) {
        self.end = end;
        words.end.store(end, Ordering::Release);
        words.stored();
    }

    /// Before a write of up to `len` bytes at `end`: drop out of the ring
    /// every kept byte whose room the write reuses, so a reader of a dead
    /// writer's segment never trusts a byte the write overwrote.
    fn forfeit(&mut self, words: &Words<'_>, len: usize) {
        let reused = (self.end + len as u64).saturating_sub(self.capacity as u64);
        if reused > self.oldest {
            self.publish_oldest(words, reused);
        }
        // The new `oldest` must be in the segment before the first data
        // byte is stored over the bytes it dropped.
        fence(Ordering::SeqCst);
    }

    /// Store `reading` (the offset a PTY read in flight starts at), and make
    /// it part of the segment before the kernel takes the first byte from
    /// the PTY: a writer SIGKILLed inside the read leaves it behind.
    fn publish_reading(&mut self, words: &Words<'_>, at: Option<u64>) {
        let word = at.map_or(0, |at| at + 1);
        words.reading.store(word, Ordering::Release);
        words.stored();
        fence(Ordering::SeqCst);
    }

    /// Store `oldest`: before a write that drops bytes, after one that
    /// kept more than it was offered.
    fn publish_oldest(&mut self, words: &Words<'_>, oldest: u64) {
        self.oldest = oldest;
        words.oldest.store(oldest, Ordering::Release);
        words.stored();
    }
}

/// The window words of a segment as a reader found them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Snapshot {
    pub(crate) end: u64,
    /// The published `oldest` (0 in a layout that has none).
    pub(crate) oldest: u64,
}

impl Snapshot {
    pub(crate) fn load(words: &Words<'_>) -> Self {
        let end = words.end.load(Ordering::Acquire);
        let oldest = words.oldest.load(Ordering::Acquire);
        Self { end, oldest }
    }

    /// The window a new writer continues: `trust_oldest` when the layout
    /// publishes `oldest`. A writer that died inside a write published an
    /// `oldest` past the bytes it was overwriting, possibly past the `end`
    /// it never got to publish: nothing is kept then.
    pub(crate) fn adopt(
        self,
        capacity: usize,
        base: u64,
        trust_oldest: bool,
    ) -> Result<Cursor, &'static str> {
        if self.end < base {
            return Err("terminal ring ends before its base");
        }
        let kept_by_size = base.max(self.end.saturating_sub(capacity as u64));
        let oldest =
            if trust_oldest { self.oldest.clamp(kept_by_size, self.end) } else { kept_by_size };
        Ok(Cursor { capacity, oldest, end: self.end })
    }
}

/// The end offset the writer published.
pub(crate) fn published_end(words: &Words<'_>) -> u64 {
    words.end.load(Ordering::Acquire)
}

/// `Some(end)` when the segment's `reading` names a read that started at
/// (or, in a damaged header, past) its `end` and whose end was never
/// published, else `None`. Ask only about a segment whose writer is gone.
pub(crate) fn interrupted_read(words: &Words<'_>) -> Option<u64> {
    let end = words.end.load(Ordering::Acquire);
    let reading = words.reading.load(Ordering::Acquire);
    // `reading` holds the read's start + 1 (0 = none), so `reading > end`
    // is a read that started at or past `end`. A start past `end` cannot be
    // written by a writer: a damaged header still names a loss at `end`,
    // never a silent splice.
    (reading > end).then_some(end)
}
