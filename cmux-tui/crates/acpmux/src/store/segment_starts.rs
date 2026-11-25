//! The first seq of each log segment, kept once read, so a read past `after` finds the segment
//! that holds `after + 1` without opening the segments before it.
//!
//! A forward read (`LocalStore::scan_lines`: an attach's page, a settled view's delta, a fork's
//! tail) learned where to start by opening each segment's successor for its first line: on Leo's
//! daemon (2026-11-18, 556 chats, one of 711 segments and 5.8 GB) every open of that chat opened,
//! permission-checked and read the head of 711 files, three tokio workers sat in it for a whole
//! 4 s sample, and `acpmux daemon status` answered in 4.9 to 11.8 s. Now the start is a binary
//! search over the segments' first seqs, each read once and kept while its file is the same file
//! (inode, length and change time), so a page opens only the segments it returns records from.

use super::*;

/// The most segments whose first seq is kept: 24 bytes and a key each, a few MB at most. A store
/// asked about more starts over.
const KEPT: usize = 131_072;

/// The file a kept first seq was read from: a segment rewritten (a compaction's rename, a cut)
/// is another file, and its first seq is read again.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct FileStamp {
    ino: u64,
    len: u64,
    changed: i128,
}

#[derive(Default)]
pub(crate) struct SegmentStarts {
    map: Mutex<HashMap<(String, u32), (FileStamp, u64)>>,
    /// Tests: the segments whose head was read (a miss).
    #[cfg(test)]
    pub(crate) reads: std::sync::atomic::AtomicU64,
}

#[cfg(unix)]
fn stamp(path: &Path) -> Option<FileStamp> {
    use std::os::unix::fs::MetadataExt;
    // Read in the held home: a replacement home at the same path never stamps a segment
    // (`held_home_reads_tests.rs`).
    let meta = crate::home_fs::symlink_metadata(path).ok()?;
    meta.is_file().then(|| FileStamp {
        ino: meta.ino() ^ meta.dev().rotate_left(32),
        len: meta.len(),
        changed: i128::from(meta.ctime()) * 1_000_000_000 + i128::from(meta.ctime_nsec()),
    })
}

#[cfg(not(unix))]
fn stamp(_path: &Path) -> Option<FileStamp> {
    None
}

impl SegmentStarts {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<(String, u32), (FileStamp, u64)>> {
        self.map.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Segment `index` of chat `id`'s first seq: kept, or read from `path` and kept. None for a
    /// segment with no readable line yet (never kept: its first line may still come).
    pub(crate) fn first_seq(&self, id: &str, index: u32, path: &Path) -> Result<Option<u64>> {
        let stamp = stamp(path);
        let key = (id.to_owned(), index);
        if let Some(stamp) = stamp
            && let Some((kept, first)) = self.lock().get(&key)
            && *kept == stamp
        {
            return Ok(Some(*first));
        }
        #[cfg(test)]
        self.reads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let first = log_line::first_seq(path)?;
        if let (Some(stamp), Some(first)) = (stamp, first) {
            let mut map = self.lock();
            if map.len() >= KEPT && !map.contains_key(&key) {
                map.clear();
            }
            map.insert(key, (stamp, first));
        }
        Ok(first)
    }

    /// Drops chat `id`'s kept seqs (its folder is gone).
    pub(crate) fn forget(&self, id: &str) {
        self.lock().retain(|(chat, _), _| chat != id);
    }

    /// The index into `segments` of the first segment that may hold a record past `after`: the
    /// last whose first seq is at or before `after + 1` (seqs only grow from segment to
    /// segment, so every earlier one holds only records at or before `after`), else the first.
    /// A segment with no readable line counts as starting past `after`: the search then starts
    /// at or before the right segment, never past it, and the read skips by seq.
    pub(crate) fn start(&self, id: &str, segments: &[(u32, PathBuf)], after: u64) -> Result<usize> {
        if after == 0 || segments.len() < 2 {
            return Ok(0);
        }
        let bound = after.saturating_add(1);
        // The first index in 1..len whose segment does not start at or before `bound`.
        let (mut lo, mut hi) = (1usize, segments.len());
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let (index, path) = &segments[mid];
            if self.first_seq(id, *index, path)?.is_some_and(|first| first <= bound) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        Ok(lo - 1)
    }

    /// Exclusive end of the segments that can hold records before `before`. A reverse page
    /// starts here instead of checking every newer segment. An unreadable head keeps the old
    /// conservative scan: it cannot prove that a segment holds no requested record.
    pub(crate) fn end(&self, id: &str, segments: &[(u32, PathBuf)], before: u64) -> Result<usize> {
        if before == u64::MAX {
            return Ok(segments.len());
        }
        let (mut lo, mut hi) = (0, segments.len());
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let (index, path) = &segments[mid];
            let Some(first) = self.first_seq(id, *index, path)? else {
                return Ok(segments.len());
            };
            if first < before {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        Ok(lo)
    }
}

#[cfg(test)]
#[path = "segment_starts_tests.rs"]
mod tests;
