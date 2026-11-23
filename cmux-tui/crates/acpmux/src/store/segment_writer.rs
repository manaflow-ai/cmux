//! A chat's open log segment and the write of one record to it (`LocalStore::append_line`).
//!
//! The writers' lock (`Writers`) is held only to find, open, rotate or evict a chat's segment;
//! the write itself runs under that segment's own lock. So appends of different chats go on side
//! by side, and no chat's write waits on another's disk (#47421: with 20 coordinators streaming,
//! every append and every page read queued behind one store-wide lock, 11 s at p95).
//!
//! A close (eviction, rotation, compaction, a cold archive, `close_log`) runs under the writers'
//! lock and takes the segment's lock, so it waits for a write in flight and every write after
//! finds the segment closed and asks the writers' map again, which by then names the next one.
//! A holder of the writers' lock that reads or replaces a chat's files closes its writer first
//! ([`LocalStore::close_writer_locked`]): no line lands meanwhile. Lock order: writers, then a
//! segment; a write never takes the writers' lock while it holds its segment's.
//!
//! A segment that fills is closed for good, and its kind copy (`store/kind_index.rs`) is made
//! then, once, after the write and outside both locks, while its bytes are still in the page
//! cache. Without it a chat that was written but never scanned (a new or seeded chat, one moved
//! in or written before copies existed) had no copy of any segment, so its first log load read
//! the whole history raw: a seeded 1 GB chat read 1.18 GB in 3.7 s at its first start.

use super::{LocalStore, Writers, cut_back, log_sync, open_private_append};
use crate::no_panic::LockExt;
use anyhow::Result;
use std::fs::File;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// A chat's open segment in the writers' map.
pub(super) struct SegmentWriter {
    seg: Arc<OpenSegment>,
    /// The writers' clock at its last append: the least recently written one is evicted.
    pub(super) used: u64,
}

pub(super) struct OpenSegment {
    index: u32,
    file: File,
    /// Its length: every whole record written to it. Changed only under `closed`'s lock.
    written: AtomicU64,
    /// Held across each write; true once closed, and a write that finds it so goes back to the
    /// writers' map for the segment open now.
    closed: Mutex<bool>,
}

impl SegmentWriter {
    pub(super) fn new(index: u32, file: File, written: u64, used: u64) -> Self {
        let seg = OpenSegment {
            index,
            file,
            written: AtomicU64::new(written),
            closed: Mutex::new(false),
        };
        Self { seg: Arc::new(seg), used }
    }

    pub(super) fn file(&self) -> &File {
        &self.seg.file
    }

    /// Closes the log, durable first as `flush` would have made it. Called under the
    /// writers' lock, so the cache never holds more than `open_logs` and a session's
    /// records stay in order; it waits for a write in flight to this segment. A failed sync is
    /// logged and noted in `failed`: its records were written (an append is never synced on its
    /// own), so only a machine crash before the kernel writes them back loses them, as it would
    /// any append since the last `flush`.
    pub(super) fn close(self, id: &str, failed: &AtomicBool) {
        let mut closed = self.seg.closed.lock_or_recover();
        *closed = true;
        if let Err(e) = log_sync::sync_segment(&self.seg.file, false) {
            #[cfg(test)]
            log_sync::hold(&log_sync::HOLD_BEFORE_CLOSE_NOTE);
            failed.store(true, Ordering::SeqCst);
            tracing::warn!(session = %id, "sync event log on close: {e}");
        }
    }

    /// Closes it unsynced, for a chat whose files are deleted: a write in flight finishes first,
    /// and the next one opens the log again, as an append after a delete always did.
    pub(super) fn retire(self) {
        *self.seg.closed.lock_or_recover() = true;
    }
}

impl LocalStore {
    /// Closes chat `id`'s open segment, if any, under the writers' lock: a write in flight to it
    /// finishes first and none lands after until the lock is let go.
    pub(super) fn close_writer_locked(&self, id: &str, writers: &mut Writers) {
        if let Some(w) = writers.open.remove(id) {
            w.close(id, &self.sync_failed);
        }
    }

    /// One whole serialized record (`line` ends with its newline) at the end of `id`'s log: the
    /// body of [`super::Store::append`], and the journal store's write of a journaled line
    /// (`store/journal_store.rs`). Refused once the store is sealed.
    pub(super) fn append_line(&self, id: &str, line: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let mut filled = None;
        let wrote = self.append_to_open(id, line, &mut filled);
        if let Some(index) = filled {
            self.copy_filled_segment(id, index);
            // Segment `index` is sealed: a worker may move it cold (`store/cold_segments.rs`).
            self.note_sealed(id);
        }
        wrote
    }

    /// [`Self::append_line`]'s write. `filled` names the segment a rotation closed on the way.
    fn append_to_open(&self, id: &str, line: &[u8], filled: &mut Option<u32>) -> Result<()> {
        loop {
            let (seg, rotated) = self.segment_for(id)?;
            if rotated.is_some() {
                *filled = rotated;
            }
            let mut closed = seg.closed.lock_or_recover();
            if *closed {
                // Closed after the map gave it out: the map names the next one now (or will
                // once the close that set it lets the writers' lock go).
                drop(closed);
                std::thread::yield_now();
                continue;
            }
            let wrote = write(&seg.file, line);
            if let Err(e) = wrote {
                // A full disk (or a signal) can write part of the line before the error. Cut it
                // back to the last whole record, or the next append is glued onto the torn bytes:
                // the merged line reads as no record, so that record is lost and a strict read
                // fails. If the cut fails too, the writer is closed, not dropped: its earlier
                // appends are synced as at any close (a checkpoint's `sync_log` takes a log with
                // no open writer as synced), and the next open cuts the tail.
                let path = self.dir(id).join("events").join(format!("{:06}.ndjson", seg.index));
                if cut_back(&path, seg.written.load(Ordering::Acquire)).is_err() {
                    *closed = true;
                    drop(closed);
                    let mut writers = self.writers.lock_or_recover();
                    if writers.open.get(id).is_some_and(|w| Arc::ptr_eq(&w.seg, &seg))
                        && let Some(w) = writers.open.remove(id)
                    {
                        w.close(id, &self.sync_failed);
                    }
                }
                return Err(e);
            }
            seg.written.fetch_add(line.len() as u64, Ordering::AcqRel);
            return Ok(());
        }
    }

    /// Chat `id`'s open segment, under one hold of the writers' lock from the eviction to the
    /// open: the least recently written log is closed before this one opens, so no more than
    /// `open_logs` are ever open. Its sync runs under the lock, once per eviction: only while
    /// more than `open_logs` sessions are written.
    /// Also the index of the full segment a rotation closed, if one did.
    fn segment_for(&self, id: &str) -> Result<(Arc<OpenSegment>, Option<u32>)> {
        let mut writers = self.writers.lock_or_recover();
        if !writers.open.contains_key(id)
            && writers.open.len() >= self.open_logs
            && let Some(oldest) =
                writers.open.iter().min_by_key(|(_, w)| w.used).map(|(k, _)| k.clone())
        {
            self.close_writer_locked(&oldest, &mut writers);
        }
        if !writers.open.contains_key(id) {
            // A cut left halfway is finished before anything is appended past it.
            self.finish_cut_locked(id, &mut writers)?;
            let writer = self.open_writer(id)?;
            writers.open.insert(id.to_owned(), writer);
        }
        writers.clock += 1;
        let clock = writers.clock;
        let full = writers
            .open
            .get(id)
            .is_some_and(|w| w.seg.written.load(Ordering::Acquire) >= self.segment_bytes);
        let mut rotated = None;
        if full && let Some(old) = writers.open.remove(id) {
            // The full segment closes before the next one opens (rare: once per segment).
            rotated = Some(old.seg.index);
            let index = old.seg.index + 1;
            old.close(id, &self.sync_failed);
            let path = self.dir(id).join("events").join(format!("{index:06}.ndjson"));
            let file = open_private_append(&path)?;
            writers.open.insert(id.to_owned(), SegmentWriter::new(index, file, 0, clock));
        }
        let Some(w) = writers.open.get_mut(id) else {
            anyhow::bail!("no segment writer for session {id}");
        };
        w.used = clock;
        Ok((Arc::clone(&w.seg), rotated))
    }

    /// Makes the kind copy of segment `index`, which filled and closed and is never appended to
    /// again, so a first log load reads its copy, not the segment. Each line is parsed, so the
    /// copy says whether all of them read and a strict scan (the transfer authority's) takes it.
    /// One read of each [`LocalStore::segment_bytes`] of log, from the page cache. A failure only
    /// leaves the copy to the first scan, as before.
    fn copy_filled_segment(&self, id: &str, index: u32) {
        let path = self.dir(id).join("events").join(format!("{index:06}.ndjson"));
        let scan =
            super::kind_index::Scan { kinds: &[], copied: true, strict: false, heads: false };
        if let Err(e) = self.scan_segment(id, index, &path, &scan, &mut |_| true) {
            tracing::debug!(session = %id, segment = index, "copying a filled segment failed: {e}");
        }
    }
}

/// Writes `line` whole to `file`, through the tests' fault seams.
fn write(file: &File, line: &[u8]) -> Result<()> {
    #[cfg(debug_assertions)]
    super::disk_fault::write()?;
    let mut file = file;
    #[cfg(test)]
    if let Some(kept) = super::test_write_fault::take() {
        file.write_all(line.get(..kept.min(line.len())).unwrap_or(line))?;
        return Err(
            std::io::Error::new(std::io::ErrorKind::StorageFull, "no space left (a test)").into()
        );
    }
    file.write_all(line)?;
    Ok(())
}
