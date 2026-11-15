//! Each segment's copy of its indexed records (`store/kind_index.rs`), kept in memory once read.
//!
//! A resend's prompt state (`hub/prompt_ledger.rs` `logged_prompt`) and an inbox answer
//! (`hub/inbox.rs` `logged_inbox_answer`) each scan a chat's indexed kinds, and a restart's resume
//! pass asks them per session, per retry and per queued prompt. Read from disk, every one of those
//! scans opened each segment's copy, read it whole, hashed every byte of it and parsed every
//! record of its kinds again: about 1.3 cores of a NIGHTLY daemon for minutes after a restart
//! (2026-11-15 sample: 2947 of 4269 samples per thread under `scan_kinds`). So a scan that read a
//! segment's copy to its end keeps its lines here, each parsed at most once, and a later scan of
//! the same file reads only the segment's bytes past them.
//!
//! A memo is of one segment file (device, inode, birth) and the bytes of it its lines cover, as a
//! copy on disk is: a segment is only appended to, or replaced whole by a rename, so a memo whose
//! file is no longer the segment's, or is shorter than it covers, is dropped and the copy read
//! again. Lines appended since are read from the segment past the memo and added to it. The memos
//! hold at most [`BUDGET`] bytes (an estimate of their lines and parsed records); past it the
//! least recently read go, and a scan reads their copies from disk as before.

use super::*;
use std::sync::{Arc, OnceLock};

/// The most bytes the memos hold, estimated as three times their lines' bytes (the line and its
/// parsed record).
pub(super) const BUDGET: usize = 96 << 20;

/// One indexed line of a segment, parsed when a scan first wants it.
pub(super) struct Entry {
    /// Its kind's place in [`kind_index::INDEXED_KINDS`]; None when its head does not say (it is
    /// parsed to learn), `Some(u16::MAX)` for a kind that list does not hold.
    kind: Option<u16>,
    raw: Box<[u8]>,
    rec: OnceLock<Option<EventRecord>>,
}

impl Entry {
    fn new(raw: &[u8]) -> Self {
        let kind = record_kind(raw).map(|kind| {
            kind_index::INDEXED_KINDS
                .iter()
                .position(|k| k.as_bytes() == kind)
                .and_then(|i| u16::try_from(i).ok())
                .unwrap_or(u16::MAX)
        });
        Self { kind, raw: raw.into(), rec: OnceLock::new() }
    }

    /// Whether a scan for `kinds` may want this line: its kind is one of them, or unknown.
    pub(super) fn may_match(&self, kinds: &[&str]) -> bool {
        match self.kind {
            None => true,
            Some(i) => kind_index::INDEXED_KINDS
                .get(usize::from(i))
                .is_some_and(|kind| kinds.contains(kind)),
        }
    }

    /// The line's record, parsed once; None for a line that does not read.
    pub(super) fn record(&self) -> Option<&EventRecord> {
        self.rec.get_or_init(|| parse_record(&self.raw).ok()).as_ref()
    }

    pub(super) fn raw(&self) -> &[u8] {
        &self.raw
    }
}

/// The entries of `lines`, indexed lines as a copy holds them.
pub(super) fn entries(lines: &[u8]) -> Vec<Arc<Entry>> {
    lines
        .split_inclusive(|b| *b == b'\n')
        .filter(|l| !l.iter().all(u8::is_ascii_whitespace))
        .map(|l| Arc::new(Entry::new(l)))
        .collect()
}

/// What the copy on disk covers: the segment's first `len` bytes, its first `entries` entries,
/// whose lines are `lines_len` bytes with FNV-1a hash `lines_hash`.
#[derive(Clone, Copy)]
pub(super) struct Disk {
    pub(super) len: u64,
    pub(super) entries: usize,
    pub(super) lines_len: u64,
    pub(super) lines_hash: u64,
}

/// One segment's indexed lines, oldest first.
#[derive(Clone)]
pub(super) struct SegmentMemo {
    pub(super) file: (u64, u64, u64),
    /// The segment bytes the lines cover, whole lines.
    pub(super) len: u64,
    /// Every line of those bytes read as a record (a strict scan takes no other memo).
    pub(super) parsed: bool,
    /// None when no copy on disk is known to match.
    pub(super) disk: Option<Disk>,
    /// Runs of entries, merged as a binary counter merges: a few runs, each entry's pointer
    /// copied O(log n) times over the memo's life, never its bytes.
    runs: Vec<Arc<[Arc<Entry>]>>,
    bytes: usize,
}

impl SegmentMemo {
    pub(super) fn new(
        file: (u64, u64, u64),
        len: u64,
        parsed: bool,
        disk: Option<Disk>,
        entries: Vec<Arc<Entry>>,
    ) -> Self {
        let mut memo = Self { file, len, parsed, disk, runs: Vec::new(), bytes: 0 };
        memo.push(entries);
        memo
    }

    /// Adds `entries`, read past the memo's lines.
    pub(super) fn push(&mut self, entries: Vec<Arc<Entry>>) {
        if entries.is_empty() {
            return;
        }
        self.bytes = self.bytes.saturating_add(
            entries.iter().map(|e| e.raw.len().saturating_mul(3).saturating_add(64)).sum(),
        );
        self.runs.push(entries.into());
        while let [.., a, b] = self.runs.as_slice()
            && a.len() <= b.len()
        {
            let merged: Arc<[Arc<Entry>]> = a.iter().chain(b.iter()).cloned().collect();
            self.runs.truncate(self.runs.len().saturating_sub(2));
            self.runs.push(merged);
        }
    }

    pub(super) fn entries(&self) -> impl Iterator<Item = &Arc<Entry>> {
        self.runs.iter().flat_map(|run| run.iter())
    }

    pub(super) fn count(&self) -> usize {
        self.runs.iter().map(|run| run.len()).sum()
    }
}

#[derive(Default)]
struct Memos {
    map: HashMap<(String, u32), (Arc<SegmentMemo>, u64)>,
    tick: u64,
    bytes: usize,
}

/// The memos of a store's segments.
#[derive(Default)]
pub(crate) struct KindMemo {
    memos: Mutex<Memos>,
}

impl KindMemo {
    fn lock(&self) -> std::sync::MutexGuard<'_, Memos> {
        self.memos.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Segment `index` of chat `id`'s memo, when it is of the file `stamp` is and no longer.
    pub(super) fn get(
        &self,
        id: &str,
        index: u32,
        stamp: &kind_index::Stamp,
    ) -> Option<Arc<SegmentMemo>> {
        let mut memos = self.lock();
        memos.tick = memos.tick.wrapping_add(1);
        let tick = memos.tick;
        let key = (id.to_owned(), index);
        let (memo, used) = memos.map.get_mut(&key)?;
        if memo.file == stamp.id && stamp.id.2 != 0 && stamp.len >= memo.len {
            *used = tick;
            return Some(Arc::clone(memo));
        }
        if let Some((gone, _)) = memos.map.remove(&key) {
            memos.bytes = memos.bytes.saturating_sub(gone.bytes);
        }
        None
    }

    /// Keeps `memo` as segment `index` of chat `id`'s, the least recently read going past
    /// [`BUDGET`]. One larger than the budget alone is not kept.
    pub(super) fn put(&self, id: &str, index: u32, memo: SegmentMemo) {
        if memo.file.2 == 0 || memo.bytes > BUDGET {
            self.forget_segment(id, index);
            return;
        }
        let mut memos = self.lock();
        memos.tick = memos.tick.wrapping_add(1);
        let tick = memos.tick;
        let bytes = memo.bytes;
        if let Some((old, _)) = memos.map.insert((id.to_owned(), index), (Arc::new(memo), tick)) {
            memos.bytes = memos.bytes.saturating_sub(old.bytes);
        }
        memos.bytes = memos.bytes.saturating_add(bytes);
        while memos.bytes > BUDGET {
            let Some(oldest) =
                memos.map.iter().min_by_key(|(_, (_, used))| *used).map(|(k, _)| k.clone())
            else {
                break;
            };
            if let Some((gone, _)) = memos.map.remove(&oldest) {
                memos.bytes = memos.bytes.saturating_sub(gone.bytes);
            }
        }
    }

    fn forget_segment(&self, id: &str, index: u32) {
        let mut memos = self.lock();
        if let Some((gone, _)) = memos.map.remove(&(id.to_owned(), index)) {
            memos.bytes = memos.bytes.saturating_sub(gone.bytes);
        }
    }

    /// Drops chat `id`'s memos (its folder is gone).
    pub(super) fn forget(&self, id: &str) {
        let mut memos = self.lock();
        let gone: usize = memos
            .map
            .iter()
            .filter(|((chat, _), _)| chat == id)
            .map(|(_, (memo, _))| memo.bytes)
            .sum();
        memos.map.retain(|(chat, _), _| chat != id);
        memos.bytes = memos.bytes.saturating_sub(gone);
    }

    #[cfg(test)]
    pub(super) fn bytes(&self) -> usize {
        self.lock().bytes
    }
}
