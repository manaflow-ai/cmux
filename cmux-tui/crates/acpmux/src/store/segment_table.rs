//! A shared segment table: repeated pages neither enumerate `events/` nor copy its paths.
//! Directory stamps use the same conservative timestamp policy as the indexed-kind reader.
//! Recent or changing directories are listed afresh; a cold first read discovers the table.

use super::*;
use std::sync::Arc;

#[derive(Clone, Debug, Default)]
pub(super) struct SegmentList(Arc<[(u32, PathBuf)]>);

impl std::ops::Deref for SegmentList {
    type Target = [(u32, PathBuf)];

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

/// Ownership of a listing is shared; only paths actually visited by a reader are copied.
pub(super) struct SegmentIter {
    list: SegmentList,
    range: std::ops::Range<usize>,
}

impl SegmentIter {
    fn copy_at(&self, index: usize) -> Option<(u32, PathBuf)> {
        let entry = self.list.get(index)?;
        #[cfg(test)]
        PATH_COPIES.with(|count| count.set(count.get() + 1));
        Some(entry.clone())
    }
}

#[cfg(test)]
thread_local! {
    pub(super) static PATH_COPIES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

impl Iterator for SegmentIter {
    type Item = (u32, PathBuf);

    fn next(&mut self) -> Option<Self::Item> {
        let index = self.range.next()?;
        self.copy_at(index)
    }

    fn nth(&mut self, n: usize) -> Option<Self::Item> {
        let index = self.range.nth(n)?;
        self.copy_at(index)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.range.size_hint()
    }
}

impl DoubleEndedIterator for SegmentIter {
    fn next_back(&mut self) -> Option<Self::Item> {
        let index = self.range.next_back()?;
        self.copy_at(index)
    }

    fn nth_back(&mut self, n: usize) -> Option<Self::Item> {
        let index = self.range.nth_back(n)?;
        self.copy_at(index)
    }
}

impl ExactSizeIterator for SegmentIter {}

impl IntoIterator for SegmentList {
    type Item = (u32, PathBuf);
    type IntoIter = SegmentIter;

    fn into_iter(self) -> Self::IntoIter {
        let range = 0..self.len();
        SegmentIter { list: self, range }
    }
}

impl<'a> IntoIterator for &'a SegmentList {
    type Item = &'a (u32, PathBuf);
    type IntoIter = std::slice::Iter<'a, (u32, PathBuf)>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

struct Entry {
    stamp: kind_heads::DirStamp,
    list: SegmentList,
    cut_pending: bool,
    sealed: bool,
    bytes: usize,
}

#[derive(Default)]
struct Table {
    entries: HashMap<String, Entry>,
    bytes: usize,
}

/// Bound retained path bytes as well as entries: a single large chat is not a small entry.
const MAX_BYTES: usize = 32 << 20;
const MAX_CHATS: usize = 16_384;

#[derive(Default)]
pub(super) struct SegmentTable {
    table: Mutex<Table>,
    #[cfg(test)]
    listings: std::sync::atomic::AtomicU64,
}

impl SegmentTable {
    pub(super) fn forget(&self, id: &str) {
        let mut table = self.table.lock_or_recover();
        if let Some(entry) = table.entries.remove(id) {
            table.bytes = table.bytes.saturating_sub(entry.bytes);
        }
    }

    /// The segments, whether a cut's intent is beside them, and whether a segment zstd'd in
    /// place with no plain one of its name is (`store/sealed_segments.rs`).
    pub(super) fn list(&self, id: &str, dir: &Path) -> Result<(SegmentList, bool, bool)> {
        let stamp = kind_heads::dir_stamp(dir, std::time::SystemTime::now()).ok().flatten();
        if let Some(stamp) = stamp {
            let table = self.table.lock_or_recover();
            if let Some(entry) = table.entries.get(id).filter(|entry| entry.stamp == stamp) {
                return Ok((entry.list.clone(), entry.cut_pending, entry.sealed));
            }
        }
        // No table lock is held during filesystem work, rehydration, or cut recovery.
        #[cfg(test)]
        self.listings.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut out = Vec::new();
        let mut cold = Vec::new();
        let mut cut_pending = false;
        let mut sealed = Vec::new();
        let Ok(rd) = std::fs::read_dir(dir) else {
            self.forget(id);
            return Ok((SegmentList::default(), false, false));
        };
        for entry in rd {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name == compact::CUT {
                cut_pending = true;
            } else if let Some(stem) = name.strip_suffix(".ndjson")
                && let Ok(index) = stem.parse::<u32>()
            {
                out.push((index, entry.path()));
            } else if let Some(index) = super::cold_segments::idx_index(&name) {
                cold.push(index);
            } else if let Some(plain) = sealed_segments::plain_name(&name) {
                sealed.push(plain.to_owned());
            }
        }
        // A sealed segment that went cold (`store/cold_segments.rs`) reads from its archive once
        // only its index is left: while its `.ndjson` is there, that is the segment.
        if !cold.is_empty()
            && let Some(session) = dir.parent()
        {
            for index in cold {
                if !out.iter().any(|(i, _)| *i == index) {
                    out.push((index, super::cold_segments::zst_path(session, index)));
                }
            }
        }
        out.sort();
        let sealed = sealed.iter().any(|plain| {
            !out.iter().any(|(_, path)| path.file_name().is_some_and(|f| f == plain.as_str()))
        });
        let bytes = out.iter().fold(id.len(), |bytes, (_, path)| {
            bytes.saturating_add(std::mem::size_of::<(u32, PathBuf)>() + path.as_os_str().len())
        });
        let list = SegmentList(out.into());
        let after = kind_heads::dir_stamp(dir, std::time::SystemTime::now()).ok().flatten();
        if let Some(stamp) = stamp.filter(|stamp| Some(*stamp) == after)
            && !list.is_empty()
            && bytes <= MAX_BYTES
        {
            let mut table = self.table.lock_or_recover();
            if let Some(old) = table.entries.remove(id) {
                table.bytes = table.bytes.saturating_sub(old.bytes);
            }
            if table.bytes.saturating_add(bytes) > MAX_BYTES || table.entries.len() >= MAX_CHATS {
                table.entries.clear();
                table.bytes = 0;
            }
            table.bytes += bytes;
            table.entries.insert(
                id.to_owned(),
                Entry { stamp, list: list.clone(), cut_pending, sealed, bytes },
            );
        } else {
            self.forget(id);
        }
        Ok((list, cut_pending, sealed))
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    struct Fixture(PathBuf);

    impl Drop for Fixture {
        fn drop(&mut self) {
            kind_heads::SETTLED_FOR.with(|value| value.set(None));
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn fixture() -> (Fixture, LocalStore) {
        let root =
            std::env::temp_dir().join(format!("acpmux-segment-table-{}", uuid::Uuid::now_v7()));
        let store = LocalStore::new(root.clone(), 64 << 10).unwrap();
        (Fixture(root), store)
    }

    fn append(store: &LocalStore, seq: u64) {
        store
            .append(
                "c",
                &EventRecord {
                    seq,
                    at: seq,
                    dir: "in".into(),
                    kind: "agent_message_chunk".into(),
                    msg: serde_json::json!({"text": "x".repeat(65_536)}),
                    host_seq: None,
                },
            )
            .unwrap();
    }

    #[test]
    fn repeated_pages_share_the_segment_table_at_every_log_size() {
        let mut failures = Vec::new();
        for size in [1, 64, 512] {
            let (_fixture, store) = fixture();
            for seq in 1..=size {
                append(&store, seq);
            }
            // Model an already-settled directory without sleeping in a performance test.
            kind_heads::SETTLED_FOR.with(|value| value.set(Some(std::time::Duration::ZERO)));
            let table = store.segments("c").unwrap();
            assert_eq!(table.len() as u64, size);
            let before = store.segment_table.listings.load(Ordering::Relaxed);
            let started = std::time::Instant::now();
            let mut shared = true;
            for _ in 0..32 {
                let next = store.segments("c").unwrap();
                shared &= Arc::ptr_eq(&table.0, &next.0);
                let page = store.events("c", size - 1, 1).unwrap();
                assert_eq!(page.len(), 1);
                assert_eq!(page.first().unwrap().seq, size);
            }
            let lists = store.segment_table.listings.load(Ordering::Relaxed) - before;
            eprintln!(
                "segment table: {size} segments, 32 pages, {lists} directory listings, {} us",
                started.elapsed().as_micros()
            );
            if lists != 0 || !shared {
                failures.push((size, lists, shared));
            }
        }
        assert!(failures.is_empty(), "segment table reuse failed: {failures:?}");
    }

    #[test]
    fn a_recent_directory_rotation_is_visible_without_waiting() {
        let (_fixture, store) = fixture();
        append(&store, 1);
        kind_heads::SETTLED_FOR.with(|value| value.set(Some(std::time::Duration::ZERO)));
        let first = store.segments("c").unwrap();
        // Real policy: a same-clock-tick directory mutation cannot reuse a cached stamp.
        kind_heads::SETTLED_FOR.with(|value| value.set(None));
        append(&store, 2);
        let rotated = store.segments("c").unwrap();
        assert_eq!(rotated.len(), 2);
        assert!(!Arc::ptr_eq(&first.0, &rotated.0));
        assert_eq!(store.events("c", 1, 1).unwrap().first().unwrap().seq, 2);
    }

    #[test]
    fn removing_and_recreating_a_directory_cannot_reuse_its_table() {
        let (_fixture, store) = fixture();
        append(&store, 1);
        kind_heads::SETTLED_FOR.with(|value| value.set(Some(std::time::Duration::ZERO)));
        let first = store.segments("c").unwrap();
        store.close_log("c");
        let events = store.dir("c").join("events");
        std::fs::remove_dir_all(&events).unwrap();
        assert!(store.segment_files("c").unwrap().is_empty());
        append(&store, 2);
        let recreated = store.segments("c").unwrap();
        assert!(!Arc::ptr_eq(&first.0, &recreated.0));
        assert_eq!(store.events("c", 0, 1).unwrap().first().unwrap().seq, 2);
    }
}
