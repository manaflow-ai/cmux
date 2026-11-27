//! Relay-side delta catch-up (RFD 0142 R9): a bounded, per-session log of sealed deltas the relay holds so a
//! viewer that resumes after sleep gets what it missed from the relay edge, without waking the Mac.
//!
//! Each delta is a `cmux-relay-snapshot-v1` envelope (the R2 seal) on the delta stream of its session
//! ([`delta_stream`]), so a delta never opens as a snapshot and a snapshot never opens as a delta. The source
//! numbers deltas `(epoch, seq)` with `seq` counting up by one within an epoch; the position is in the
//! envelope's signed header, so the relay can order the log but cannot relabel, reorder or forge an entry.
//!
//! What the relay sees: the envelopes' sizes and positions (as for R2) and, per catch-up, which position a
//! viewer asks to resume after. It holds no key that opens or forges a delta.
//!
//! Bounds: at most [`MAX_ENTRIES`] deltas and [`MAX_LOG_BYTES`] per session, oldest evicted first; each delta
//! expires [`TTL_MS`] after it was appended (the P8 mailbox's 10 minutes); [`DeltaLog::drain_through`]
//! drops what every viewer has acknowledged. Nothing here writes per keystroke: the Durable Object persists
//! the log in batches, as it does the R2 snapshot.
//!
//! A catch-up either serves every delta after the viewer's position, contiguously, or answers
//! [`CatchUp::Gap`]: the viewer then takes the R2 snapshot or the live link, as it does today. A partial
//! catch-up is never served, so a viewer never applies deltas over a hole.

use std::collections::VecDeque;

use p256::PublicKey;

use crate::{Error, Floor, Opened, Position, peek};

/// The most deltas a session's log holds.
pub const MAX_ENTRIES: usize = 512;
/// The most envelope bytes a session's log holds.
pub const MAX_LOG_BYTES: usize = 1024 * 1024;
/// How long a delta stays in the log after it was appended: the P8 mailbox's expiry.
pub const TTL_MS: u64 = 10 * 60 * 1000;

/// The seal stream a session's deltas use: distinct from its snapshot stream, so one never opens as the other.
pub fn delta_stream(stream: &str) -> String {
    format!("{stream}/delta")
}

/// The position right after `position` in its epoch, or `None` at the end of the epoch's range.
fn next(position: Position) -> Option<Position> {
    position.seq.checked_add(1).map(|seq| Position { epoch: position.epoch, seq })
}

#[derive(Debug, Clone)]
struct Entry {
    position: Position,
    appended_ms: u64,
    envelope: Vec<u8>,
}

/// What [`DeltaLog::append`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Appended {
    /// Added after the last delta; `evicted` older deltas were dropped to stay within the bounds.
    Added { evicted: usize },
    /// Not contiguous with the log (a new epoch, or a hole): the log restarted at this delta.
    Restarted { dropped: usize },
    /// Already held (a retry of the same position): nothing changed.
    Duplicate,
}

/// The relay's answer to "everything after `after`".
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatchUp {
    /// Every delta after the asked position, in order (empty when the viewer is already current).
    Deltas(Vec<Vec<u8>>),
    /// The log does not cover the asked position (expired, evicted, another epoch, or empty): use the
    /// snapshot or the live link.
    Gap,
}

/// One session's delta log on the relay.
#[derive(Debug, Clone)]
pub struct DeltaLog {
    source_key_id: Option<[u8; 32]>,
    entries: VecDeque<Entry>,
    bytes: usize,
    /// The position of the delta most recently appended, kept after it drains so a viewer at it is current.
    head: Option<Position>,
}

impl Default for DeltaLog {
    fn default() -> Self {
        Self::new()
    }
}

impl DeltaLog {
    pub fn new() -> Self {
        Self { source_key_id: None, entries: VecDeque::new(), bytes: 0, head: None }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn bytes(&self) -> usize {
        self.bytes
    }

    /// The newest position appended (it may already have drained).
    pub fn head(&self) -> Option<Position> {
        self.head
    }

    /// Appends a sealed delta the source published at `now_ms`. Reads only the header; refuses a malformed
    /// envelope, one over the byte bound, and one from another source key than the log's (a key change
    /// restarts nothing silently: the DO drops the log with [`DeltaLog::clear`] when the pair re-keys).
    pub fn append(&mut self, envelope: Vec<u8>, now_ms: u64) -> Result<Appended, Error> {
        let header = peek(&envelope)?;
        if envelope.len() > MAX_LOG_BYTES {
            return Err(Error::BadInput);
        }
        match self.source_key_id {
            Some(id) if id != header.source_key_id => return Err(Error::WrongSource),
            _ => self.source_key_id = Some(header.source_key_id),
        }
        self.expire(now_ms);
        let position = header.position;
        // At or before the head: a retry of something already held, or a late one already drained or
        // superseded. Either way the newer state wins and nothing changes.
        if self.head.is_some_and(|head| position <= head) {
            return Ok(Appended::Duplicate);
        }
        let contiguous = self.head.and_then(next) == Some(position);
        let outcome = if contiguous || self.head.is_none() {
            None
        } else {
            let dropped = self.entries.len();
            self.entries.clear();
            self.bytes = 0;
            Some(Appended::Restarted { dropped })
        };
        self.bytes += envelope.len();
        self.entries.push_back(Entry { position, appended_ms: now_ms, envelope });
        self.head = Some(position);
        let mut evicted = 0;
        while self.entries.len() > MAX_ENTRIES || self.bytes > MAX_LOG_BYTES {
            if let Some(old) = self.entries.pop_front() {
                self.bytes -= old.envelope.len();
                evicted += 1;
            }
        }
        Ok(outcome.unwrap_or(Appended::Added { evicted }))
    }

    /// Drops deltas appended more than [`TTL_MS`] before `now_ms`.
    pub fn expire(&mut self, now_ms: u64) {
        while let Some(front) = self.entries.front() {
            if now_ms.saturating_sub(front.appended_ms) < TTL_MS {
                break;
            }
            if let Some(old) = self.entries.pop_front() {
                self.bytes -= old.envelope.len();
            }
        }
    }

    /// Drops every delta at or before `through` (what every viewer acknowledged).
    pub fn drain_through(&mut self, through: Position) {
        while let Some(front) = self.entries.front() {
            if front.position > through {
                break;
            }
            if let Some(old) = self.entries.pop_front() {
                self.bytes -= old.envelope.len();
            }
        }
    }

    /// Forgets the log (the pair re-keyed or was removed).
    pub fn clear(&mut self) {
        *self = Self::new();
    }

    /// Every delta after `after`, contiguously, or [`CatchUp::Gap`].
    pub fn catch_up(&mut self, after: Position, now_ms: u64) -> CatchUp {
        self.expire(now_ms);
        let Some(head) = self.head else { return CatchUp::Gap };
        if after == head {
            return CatchUp::Deltas(Vec::new());
        }
        if after > head || after.epoch != head.epoch {
            return CatchUp::Gap;
        }
        let Some(first) = next(after) else { return CatchUp::Gap };
        let Some(start) = self.entries.iter().position(|e| e.position == first) else {
            return CatchUp::Gap;
        };
        CatchUp::Deltas(self.entries.iter().skip(start).map(|e| e.envelope.clone()).collect())
    }
}

/// Why a viewer stopped applying a catch-up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyError {
    /// The delta is not the next position after the viewer's floor (a hole, a reorder or a replay).
    NotNext { want: Option<Position>, got: Position },
    /// The seal refused it.
    Seal(Error),
}

/// The viewer's side: opens catch-up deltas in order under its floor. Each must be exactly the next position
/// after the floor; the first one that is not (or does not open) stops the apply, and the deltas applied so
/// far stay applied. With no floor, the viewer has no base state and must take the snapshot first.
pub fn apply<V: crate::Viewer + ?Sized>(
    floor: &mut Floor,
    viewer: &V,
    source: &PublicKey,
    stream: &str,
    envelopes: &[Vec<u8>],
) -> (Vec<Opened>, Option<ApplyError>) {
    let stream = delta_stream(stream);
    let mut applied = Vec::with_capacity(envelopes.len());
    for envelope in envelopes {
        let got = match peek(envelope) {
            Ok(header) => header.position,
            Err(error) => return (applied, Some(ApplyError::Seal(error))),
        };
        let want = floor.position().and_then(next);
        if want != Some(got) {
            return (applied, Some(ApplyError::NotNext { want, got }));
        }
        match floor.open(viewer, source, &stream, envelope) {
            Ok(opened) => applied.push(opened),
            Err(error) => return (applied, Some(ApplyError::Seal(error))),
        }
    }
    (applied, None)
}

#[cfg(test)]
mod tests;
