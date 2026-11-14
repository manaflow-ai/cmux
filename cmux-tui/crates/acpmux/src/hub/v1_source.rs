//! A chat v1 drives, as the raw source of its book (agent service v2, row 3b; the design doc's
//! "Files, per chat" and "The chat actor"). v1's event log is the source: read through v1's store
//! by seq ([`Store::read_log`], `store/log_bytes.rs`), never as files, and never written. A line's
//! place is its seq and its end is seq + 1; seqs grow, with gaps. The book's `raw.map` line names
//! the chat's log (`v1:<id>`).
//!
//! - **A chunk** is whole lines as v1 wrote them, never parsed, from a place: at most
//!   [`CHUNK_BYTES`], or one line when a line is larger; with the place after its last line, the
//!   count it was read under and `at_end`. No source gives its end.
//! - **The count's hold.** No lock is held while a chunk is read. The source reads the chat's
//!   count, reads the chunk, and reads the count again, each a lookup under the store's writers'
//!   lock, where every change to the log's lines bumps it before its first rename and after its
//!   last. Two equal counts mean no line of the chunk changed. When they differ it reads the
//!   chunk again, three times at most, then gives it with the newer count: the actor does not
//!   translate it and opens its book again, which takes the next edition.
//! - **`holds`**: a place is held while it is at most one past v1's last seq. The first open of a
//!   chat's book in a daemon's life asks against the last seq v1 found on disk when the daemon
//!   started, since v1 gives the seqs after it to new lines; a later open asks against what the
//!   store holds then (nothing v1 took is lost while the process lives). The start's seq is for
//!   the open's question only: `sync_through` asks against v1's last seq now.
//! - **The hint** is v1's last seq. It is read before a chunk, so a line that lands after the read
//!   moves it, and the actor reads again.
//! - **Never ahead of its raw**: `sync_through` makes v1's log durable through a seq before a
//!   checkpoint or a patch made from it is synced.

use crate::store::{LogFilter, LogMarks, Store};
use acpmux_core::chat::SourceFactory;
use acpmux_core::chat::source::{CHUNK_BYTES, Chunk, RawSource};
use std::io;
use std::ops::Range;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// Reads of one chunk again when the count moved while it was read, before it is given with the
/// newer count.
pub(crate) const TRIES: usize = 3;

/// v1's last seq of the chat now: raised only once the line is in the log.
pub(crate) type LastSeq = Arc<dyn Fn() -> u64 + Send + Sync>;

/// What a source of one chat counts, shared by every source its factory made.
#[derive(Default, Debug)]
pub(crate) struct Counters {
    /// Bytes the store took from the log's files.
    pub read: AtomicU64,
    /// Chunks given.
    pub chunks: AtomicU64,
    /// The largest buffer a read built: the source holds no other, and none after it is given.
    pub held_max: AtomicU64,
    /// Chunks read again because the count moved while they were read.
    pub reread: AtomicU64,
}

/// One chat's v1 log, for the book's actor: [`V1Log::factory`] makes its sources.
#[derive(Clone)]
pub(crate) struct V1Log<S> {
    pub store: S,
    pub id: String,
    /// The last seq v1 found on disk when this daemon started.
    pub found_at_start: u64,
    pub last_seq: LastSeq,
    /// Whether a source of this chat was made before in this daemon's life.
    pub opened: Arc<AtomicBool>,
    pub counters: Arc<Counters>,
}

impl<S> V1Log<S>
where
    S: AsRef<dyn Store> + Clone + Send + Sync + 'static,
{
    pub fn new(store: S, id: &str, found_at_start: u64, last_seq: LastSeq) -> Self {
        Self {
            store,
            id: id.to_owned(),
            found_at_start,
            last_seq,
            opened: Arc::default(),
            counters: Arc::default(),
        }
    }

    pub fn open(&self) -> io::Result<V1Source<S>> {
        let first = !self.opened.swap(true, Ordering::SeqCst);
        V1Source::open(self, first)
    }

    pub fn factory(&self) -> SourceFactory {
        let log = self.clone();
        Arc::new(move || log.open().map(|source| Box::new(source) as Box<dyn RawSource>))
    }
}

pub(crate) struct V1Source<S> {
    store: S,
    id: String,
    identity: Vec<u8>,
    /// The first open in this life holds what v1 found on disk at the start; a later one asks.
    found_at_start: Option<u64>,
    last_seq: LastSeq,
    marks: LogMarks,
    /// The count the last chunk was read under (at open, the count then).
    stamp: u64,
    counters: Arc<Counters>,
}

/// A v1 line's places: its seq and seq + 1.
pub(crate) fn seq_places(line: &[u8], _: u64) -> io::Result<Range<u64>> {
    let seq = crate::store::log_line_seq(line)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "a v1 line with no seq"))?;
    let end = seq
        .checked_add(1)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "a v1 seq past the end"))?;
    Ok(seq..end)
}

fn other(error: anyhow::Error) -> io::Error {
    io::Error::other(format!("{error:#}"))
}

impl<S> V1Source<S>
where
    S: AsRef<dyn Store> + Clone + Send + Sync + 'static,
{
    fn open(log: &V1Log<S>, first: bool) -> io::Result<Self> {
        let stamp = log.store.as_ref().log_stamp(&log.id).map_err(other)?;
        Ok(Self {
            store: log.store.clone(),
            id: log.id.clone(),
            identity: format!("v1:{}", log.id).into_bytes(),
            found_at_start: first.then_some(log.found_at_start),
            last_seq: log.last_seq.clone(),
            marks: LogMarks::default(),
            stamp,
            counters: log.counters.clone(),
        })
    }

    fn store(&self) -> &dyn Store {
        self.store.as_ref()
    }
}

impl<S> RawSource for V1Source<S>
where
    S: AsRef<dyn Store> + Clone + Send + Sync + 'static,
{
    fn read_chunk(&mut self, place: u64) -> io::Result<Chunk> {
        let hint = (self.last_seq)();
        // A read away from where the last chunk ended (a body read back) leaves that mark for the
        // next read from the cursor.
        let cursor = (self.marks.end.is_some() && self.marks.end_seq() != Some(place))
            .then(|| self.marks.take_end());
        let mut bytes = Vec::with_capacity(CHUNK_BYTES);
        let mut tries = 0;
        let store = self.store.clone();
        let store = store.as_ref();
        let (chunk, stamp) = loop {
            let before = store.log_stamp(&self.id).map_err(other)?;
            let chunk = store
                .read_log(&self.id, place, LogFilter::ALL, before, &mut self.marks, &mut bytes)
                .map_err(other)?;
            self.counters.read.fetch_add(chunk.read, Ordering::Relaxed);
            let held = bytes.capacity() + self.marks.waiting();
            self.counters.held_max.fetch_max(held as u64, Ordering::Relaxed);
            let after = store.log_stamp(&self.id).map_err(other)?;
            if before == after || tries == TRIES {
                break (chunk, after);
            }
            tries += 1;
            self.counters.reread.fetch_add(1, Ordering::Relaxed);
        };
        if let Some(cursor) = cursor {
            self.marks.put_end(cursor);
        }
        self.stamp = stamp;
        self.counters.chunks.fetch_add(1, Ordering::Relaxed);
        Ok(Chunk::with_stamp(bytes, 0, seq_places, chunk.at_end, hint, stamp))
    }

    fn holds(&mut self, place: u64) -> io::Result<bool> {
        let last = self.found_at_start.unwrap_or_else(|| (self.last_seq)());
        Ok(place <= last.saturating_add(1))
    }

    fn hint(&self) -> io::Result<u64> {
        Ok((self.last_seq)())
    }

    fn sync_through(&mut self, place: u64) -> io::Result<()> {
        // Asked against the log as it is now: the start's last seq answers the open's question
        // alone, and a line v1 appended since is the source's to sync.
        if place > (self.last_seq)().saturating_add(1) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "v1's log has not reached this place",
            ));
        }
        self.store().sync_log_through(&self.id, place.saturating_sub(1)).map_err(other)
    }

    fn identity(&self) -> &[u8] {
        &self.identity
    }

    fn stamp(&self) -> u64 {
        self.stamp
    }
}

#[cfg(all(test, target_os = "linux"))]
mod gates;
#[cfg(test)]
mod tests;
