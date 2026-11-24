//! Where the cache lives and how it is read and written. The read is on the launch's first-frame
//! path, so it is one bounded file read and one parse; the write is off it, atomic (a reader never
//! sees half a file), and coalesced so a drag or a stream of resizes writes once, not per frame.
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::model::LayoutCache;

/// A cache file larger than this is ignored unread; the writer refuses to exceed it.
pub const MAX_BYTES: u64 = 512 * 1024;
/// A change is written once nothing else changed for this long (a drag ends, a resize settles).
pub const DEBOUNCE_MS: u64 = 250;
/// ...and never later than this after the first unwritten change, so a long stream of changes
/// (a live resize, a streaming chat) is still on disk if the app dies mid-stream.
pub const MAX_DELAY_MS: u64 = 2_000;

/// `<state_dir>/layout-cache/v1.json`: the version is in the name, so a later format sits beside
/// this one and a downgrade reads its own file.
pub fn cache_path(state_dir: &Path) -> PathBuf {
    state_dir.join("layout-cache").join("v1.json")
}

/// The cache at `path`; None when missing, over `MAX_BYTES`, not version 1 or not JSON. Never
/// panics: a bad cache only costs the launch its head start.
pub fn read(path: &Path) -> Option<LayoutCache> {
    let file = File::open(path).ok()?;
    if file.metadata().ok()?.len() > MAX_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    // `take` bounds the read even if the file grows between the size check and the read.
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > MAX_BYTES {
        return None;
    }
    LayoutCache::from_json(std::str::from_utf8(&bytes).ok()?)
}

/// Writes `cache` (capped) to `path` atomically: a temporary file in the same folder, fsynced,
/// renamed over the old one. On any failure the old file is left as it was.
pub fn write(path: &Path, cache: &LayoutCache) -> io::Result<()> {
    let bytes = serde_json::to_vec(&cache.clone().capped()).map_err(io::Error::other)?;
    write_bytes(path, &bytes, |_| Ok(()))
}

/// The atomic write. `before_rename` runs on the full, synced temporary file; tests fail there
/// to prove a failed write never touches the old file.
pub(crate) fn write_bytes(
    path: &Path,
    bytes: &[u8],
    before_rename: impl FnOnce(&File) -> io::Result<()>,
) -> io::Result<()> {
    if bytes.len() as u64 > MAX_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "layout cache over its cap"));
    }
    let dir = path.parent().ok_or_else(|| io::Error::other("cache path has no folder"))?;
    fs::create_dir_all(dir)?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("cache");
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    let temporary = dir.join(format!(".{name}.{}.{nanos}.tmp", std::process::id()));
    let result = (|| {
        let mut file = File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        before_rename(&file)?;
        fs::rename(&temporary, path)?;
        // The rename itself is durable only once the folder is synced.
        if let Ok(d) = File::open(dir) {
            let _ = d.sync_all();
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// FNV-1a: stable across runs and builds (std's hasher is not), and enough to tell "same bytes".
pub fn content_hash(bytes: &[u8]) -> u64 {
    bytes
        .iter()
        .fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3))
}

/// Decides when a layout change is persisted: a trailing `DEBOUNCE_MS` debounce bounded by
/// `MAX_DELAY_MS`, and no write at all when the content equals what is on disk. The app calls
/// `note_change` on every layout change (cheap: two integers), asks `due` from a timer at
/// `next_due_ms`, and `flush_now` at quit.
#[derive(Debug, Clone, Default)]
pub struct WriteCoalescer {
    first_unwritten_ms: Option<u64>,
    last_change_ms: u64,
    last_written: Option<u64>,
}

impl WriteCoalescer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn note_change(&mut self, now_ms: u64) {
        self.first_unwritten_ms.get_or_insert(now_ms);
        self.last_change_ms = self.last_change_ms.max(now_ms);
    }

    pub fn pending(&self) -> bool {
        self.first_unwritten_ms.is_some()
    }

    /// When the pending change becomes due; None when nothing is pending.
    pub fn next_due_ms(&self) -> Option<u64> {
        let first = self.first_unwritten_ms?;
        Some(
            (self.last_change_ms.saturating_add(DEBOUNCE_MS))
                .min(first.saturating_add(MAX_DELAY_MS)),
        )
    }

    pub fn due(&self, now_ms: u64) -> bool {
        self.next_due_ms().is_some_and(|at| now_ms >= at)
    }

    /// At quit: whether anything is pending, whatever the clock says.
    pub fn flush_now(&self) -> bool {
        self.pending()
    }

    /// Whether `cache` differs from what was last written (by content, `written_at_ms` aside).
    /// A false answer clears the pending change: nothing needs writing.
    pub fn needs_write(&mut self, cache: &LayoutCache) -> bool {
        let changed = self.last_written != Some(content_hash(&cache.capped_content()));
        if !changed {
            self.first_unwritten_ms = None;
        }
        changed
    }

    /// Records that `cache` reached disk: the pending change is cleared and later identical
    /// content skips its write.
    pub fn wrote(&mut self, cache: &LayoutCache) {
        self.last_written = Some(content_hash(&cache.capped_content()));
        self.first_unwritten_ms = None;
    }

    /// `needs_write`, then the atomic write, then `wrote`: Ok(true) written, Ok(false) unchanged.
    /// A failed write stays pending, so the next due write retries it.
    pub fn write(&mut self, path: &Path, cache: &LayoutCache) -> io::Result<bool> {
        if !self.needs_write(cache) {
            return Ok(false);
        }
        write(path, cache)?;
        self.wrote(cache);
        Ok(true)
    }
}

impl LayoutCache {
    fn capped_content(&self) -> Vec<u8> {
        self.clone().capped().content_bytes()
    }
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
