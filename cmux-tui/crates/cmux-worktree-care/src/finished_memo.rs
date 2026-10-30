//! Bounded finished answers, persisted as checks complete so daemon restarts
//! retain progress. Failed and skipped checks never enter this store.

use crate::git::is_object_id;
use crate::inventory::Finish;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

type Answers = HashMap<(PathBuf, String, String), Option<Finish>>;
/// The most pairs a [`FinishedMemo`] keeps; past it, it starts over.
const MAX_REMEMBERED: usize = 16_384;
const MAX_MEMO_BYTES: u64 = 16 << 20;
const FLUSH_INTERVAL: usize = 1024;

#[derive(Debug, Serialize, Deserialize)]
struct StoredAnswer {
    root: PathBuf,
    head: String,
    base: String,
    answer: Option<Finish>,
}

/// The finished answers for one pass. A path is optional so ordinary library
/// scans stay memory-only; the daemon gives it its private state file.
#[derive(Debug)]
pub struct FinishedMemo {
    path: Option<PathBuf>,
    answers: Mutex<Answers>,
    pending: AtomicUsize,
    _writer: Option<std::fs::File>,
}

impl FinishedMemo {
    /// Starts an in-memory memo for callers that do not own a state dir.
    pub fn memory() -> Self {
        Self { path: None, answers: Mutex::default(), pending: AtomicUsize::new(0), _writer: None }
    }

    /// Loads valid answers from `path`; corrupt or oversized state is ignored.
    pub fn load(path: PathBuf) -> Self {
        let writer = (|| {
            std::fs::create_dir_all(path.parent()?).ok()?;
            let mut options = std::fs::OpenOptions::new();
            options.read(true).write(true).create(true).truncate(false);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
            }
            let file = options.open(path.with_extension("lock")).ok()?;
            file.try_lock().ok()?;
            Some(file)
        })();
        let answers = read_memo(&path)
            .map(|entries| {
                entries
                    .into_iter()
                    .take(MAX_REMEMBERED)
                    .map(|entry| ((entry.root, entry.head, entry.base), entry.answer))
                    .collect()
            })
            .unwrap_or_default();
        Self {
            path: Some(path),
            answers: Mutex::new(answers),
            pending: AtomicUsize::new(0),
            _writer: writer,
        }
    }

    /// Flushes answers atomically. Each new answer is also flushed so an
    /// interrupted pass retains completed checks across a daemon update.
    pub fn flush(&self) {
        let Some(path) = &self.path else { return };
        // A reader retains the memo path for host-lock selection, but only
        // the process that owns the writer lock may replace the file.
        if self._writer.is_none() {
            return;
        }
        let memo = self.answers.lock().unwrap_or_else(|e| e.into_inner());
        let entries: Vec<_> = memo
            .clone()
            .into_iter()
            .map(|((root, head, base), answer)| StoredAnswer { root, head, base, answer })
            .collect();
        let Ok(bytes) = serde_json::to_vec(&entries) else { return };
        if bytes.len() as u64 > MAX_MEMO_BYTES {
            return;
        }
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let serial = NEXT.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let temporary =
            path.with_extension(format!("{}.{}.{}.tmp", std::process::id(), nanos, serial));
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        if let Ok(mut file) = options.open(&temporary) {
            use std::io::Write;
            if file.write_all(&bytes).is_ok() && file.sync_all().is_ok() {
                let _ = std::fs::rename(&temporary, path);
            }
            let _ = std::fs::remove_file(temporary);
        }
    }

    fn key(root: &Path, head: &str, base: &str) -> (PathBuf, String, String) {
        (root.to_path_buf(), head.to_string(), base.to_string())
    }

    pub(crate) fn remembered(&self, root: &Path, head: &str, base: &str) -> Option<Option<Finish>> {
        let memo = self.answers.lock().unwrap_or_else(|e| e.into_inner());
        memo.get(&Self::key(root, head, base)).copied()
    }

    pub(crate) fn remember(&self, root: &Path, head: &str, base: &str, answer: Option<Finish>) {
        let mut memo = self.answers.lock().unwrap_or_else(|e| e.into_inner());
        if memo.len() >= MAX_REMEMBERED {
            memo.clear();
        }
        memo.insert(Self::key(root, head, base), answer);
        drop(memo);
        let pending = self.pending.fetch_add(1, Ordering::Relaxed) + 1;
        // Keep the first answer durable for restart safety, then amortize the
        // bounded whole-file rewrite while a large pass is in progress.
        if pending == 1 || pending.is_multiple_of(FLUSH_INTERVAL) {
            self.flush();
        }
    }

    pub(crate) fn lock_dir(&self) -> Option<PathBuf> {
        self.path
            .as_ref()
            .and_then(|path| path.parent())
            .map(Path::to_path_buf)
            .or_else(crate::Store::default_dir)
    }
}

fn read_memo(path: &Path) -> Option<Vec<StoredAnswer>> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path).ok()?;
    let metadata = file.metadata().ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no preconditions.
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o022 != 0 {
            return None;
        }
    }
    if !metadata.is_file() || metadata.len() > MAX_MEMO_BYTES {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(MAX_MEMO_BYTES + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > MAX_MEMO_BYTES {
        return None;
    }
    let entries: Vec<StoredAnswer> = serde_json::from_slice(&bytes).ok()?;
    (entries.len() <= MAX_REMEMBERED
        && entries.iter().all(|e| is_object_id(&e.head) && is_object_id(&e.base)))
    .then_some(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oversized_and_corrupt_memos_are_ignored() {
        let dir = crate::store::care_tests::scratch("bounded-memo");
        let path = dir.join("memo.json");
        let file = std::fs::File::create(&path).unwrap();
        file.set_len(MAX_MEMO_BYTES + 1).unwrap();
        assert!(read_memo(&path).is_none());
        std::fs::write(&path, "invalid json").unwrap();
        assert!(read_memo(&path).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn completed_answer_is_durable_without_a_pass_flush() {
        let dir = crate::store::care_tests::scratch("incremental-memo");
        let path = dir.join("memo.json");
        let memo = FinishedMemo::load(path.clone());
        let root = Path::new("/worktrees/a");
        let head = "1".repeat(40);
        let base = "2".repeat(40);
        memo.remember(root, &head, &base, None);
        let reader = FinishedMemo::load(path);
        assert_eq!(reader.remembered(root, &head, &base), Some(None));
        assert!(reader._writer.is_none(), "a second writer cannot overwrite progress");
        drop(reader);
        drop(memo);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
