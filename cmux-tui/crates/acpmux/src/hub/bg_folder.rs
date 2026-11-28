//! Part of `Hub`; see `hub/mod.rs`. What a chat's background-task folder (`bg_tasks.rs`) holds,
//! read once and kept: its generation, its task records, each task's output segments, and the
//! list view of each ended task.
//!
//! Why: Leo's NIGHTLY daemon ran at 144% of a core (cmux NEXT 4533834483401, 2026-11-23) with
//! `Hub::bg_list_as` → `bg_records` / `bg_view` → `bg_run::read_output` → `segments` on its busiest
//! worker. One coordinator chat had run 5,646 tasks (22,533 files in one folder). Every list read
//! every record, and every task's view listed the whole folder again to find its segments: about
//! 127 million directory entries per list. Every idle look (`sessions_at_work`, `in_use`) also
//! read every record of every chat's folder, ended tasks included. Leo: "Root-fix anything slow,
//! stalling, uncached, growing".
//!
//! A folder changes only by entries that come and go: a record is replaced whole by a rename
//! (`bg_run::write_record`), a segment is made or removed whole, the generation is renamed in.
//! Each changes the folder's modify time; an append to a segment or a lock taken does not, and a
//! view reads those live. So a look whose folder has the same device, inode and modify time as
//! the last reuses it whole: one `stat` per chat. Otherwise the folder is listed once, and a
//! record ended by the last look (an ended task's record is never written again) is kept by its
//! file's inode, which the listing gives without a `stat`; every other record is read again.
//! A folder changed within [`RACY`] of its look may change again within the same modify-time
//! tick, so that look is not reused (git's racy-index rule).
//!
//! A running task's liveness (its runner's lock, `bg_tasks::bg_gone`) is kept on its record's
//! look too ([`BgTask::gone`]): every count and list of every chat opened and probed each running
//! task's lock, about 1,000 lock probes a second on Leo's dev Mac (cmux#62401: `bg_gone` ->
//! `liveness_of` 541 of 8,879 on-CPU samples, 492 opening files). A runner takes its lock before
//! it writes its first record and holds it for its whole life, and a task id is never started
//! again, so a lock found free stays free: kept for good. A lock found held is looked at again
//! after [`LIVE_FOR`]. A runner that ends well rewrites its record, which a look reads afresh;
//! only a runner that died without a word is seen by its lock, at most [`LIVE_FOR`] late.

use super::*;
use crate::bg_run::{self, Record};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// A modify time this close to a look may hide a later change in the same tick: such a look is
/// listed again next time.
const RACY: std::time::Duration = std::time::Duration::from_secs(1);

/// How long a running task's held lock is taken as held before it is probed again.
pub(super) const LIVE_FOR: std::time::Duration = std::time::Duration::from_secs(1);

/// One task's record as the folder's last look found it.
pub(super) struct BgTask {
    /// The record file's inode (0 where the platform gives none: always read again).
    ino: u64,
    pub(super) record: Record,
    /// Its list view (`bg_view` with [`LIST_TAIL`](super::bg_tasks)), made once the task ended.
    view: OnceLock<Value>,
    /// Its runner's lock was found free: the runner is gone for good.
    gone: std::sync::atomic::AtomicBool,
    /// When its runner's lock was last found held.
    held_at: StdMutex<Option<std::time::Instant>>,
}

impl BgTask {
    fn new(ino: u64, record: Record) -> Self {
        Self {
            ino,
            record,
            view: OnceLock::new(),
            gone: std::sync::atomic::AtomicBool::new(false),
            held_at: StdMutex::new(None),
        }
    }

    /// Whether the task's runner is surely gone (`bg_tasks::bg_gone`), probing its lock at most
    /// once per [`LIVE_FOR`] while it is held and never again once it is free.
    pub(super) fn gone(&self, dir: &Path) -> bool {
        use std::sync::atomic::Ordering;
        if self.gone.load(Ordering::Relaxed) {
            return true;
        }
        let mut held_at = self.held_at.lock().unwrap_or_else(|e| e.into_inner());
        if held_at.is_some_and(|at| at.elapsed() < LIVE_FOR) {
            return false;
        }
        let gone = super::bg_tasks::bg_gone(dir, &self.record.id);
        if gone {
            self.gone.store(true, Ordering::Relaxed);
        } else {
            *held_at = Some(std::time::Instant::now());
        }
        gone
    }
}

/// A chat's task folder at one look.
#[derive(Default)]
pub(super) struct BgFolder {
    /// The folder's device, inode and modify time (ns), when the look may be reused.
    stamp: Option<(u64, u64, i128)>,
    /// The tasks of the folder's generation, oldest first.
    pub(super) tasks: Vec<Arc<BgTask>>,
    /// Every record the look read, by id, of any generation: the next look keeps the ended ones.
    by_id: HashMap<String, Arc<BgTask>>,
    /// Each task's output segment starts, oldest first.
    segments: HashMap<String, Vec<u64>>,
}

impl BgFolder {
    /// The task's segment starts at this look (none: it had none).
    pub(super) fn segments(&self, id: &str) -> Option<&[u64]> {
        Some(self.segments.get(id).map_or(&[][..], Vec::as_slice))
    }

    /// The task's list view: kept once it ended (its record and output never change again),
    /// made afresh while it runs or was lost.
    pub(super) fn view(&self, dir: &Path, task: &BgTask, tail: u64) -> Value {
        let make = || {
            super::bg_tasks::bg_view_with(
                dir,
                &task.record,
                tail,
                self.segments(&task.record.id),
                || task.gone(dir),
            )
        };
        if task.record.ended_at.is_none() || tail != super::bg_tasks::LIST_TAIL {
            return make();
        }
        task.view.get_or_init(make).clone()
    }
}

#[cfg(unix)]
fn stamp_of(meta: &std::fs::Metadata) -> (u64, u64, i128) {
    use std::os::unix::fs::MetadataExt;
    (
        meta.dev(),
        meta.ino(),
        i128::from(meta.mtime()) * 1_000_000_000 + i128::from(meta.mtime_nsec()),
    )
}

#[cfg(unix)]
fn entry_ino(entry: &std::fs::DirEntry) -> u64 {
    std::os::unix::fs::DirEntryExt::ino(entry)
}

#[cfg(not(unix))]
fn entry_ino(_: &std::fs::DirEntry) -> u64 {
    0
}

/// Lists `dir` once, keeping what `prev` read of records that had ended.
fn scan(dir: &Path, prev: Option<&BgFolder>) -> BgFolder {
    let looked = std::time::SystemTime::now();
    #[cfg(unix)]
    let stamp = std::fs::metadata(dir).ok().and_then(|meta| {
        let fresh = meta.modified().ok().and_then(|m| looked.duration_since(m).ok());
        fresh.is_some_and(|age| age >= RACY).then(|| stamp_of(&meta))
    });
    #[cfg(not(unix))]
    let stamp = {
        let _ = looked;
        None
    };
    let Ok(generation) = super::bg_tasks::bg_generation(dir, false) else {
        return BgFolder { stamp, ..BgFolder::default() };
    };
    let mut folder = BgFolder { stamp, ..BgFolder::default() };
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let Ok(name) = entry.file_name().into_string() else { continue };
        if let Some(id) = name.strip_suffix(".json") {
            let ino = entry_ino(&entry);
            let kept = prev
                .and_then(|p| p.by_id.get(id))
                .filter(|t| ino != 0 && t.ino == ino && t.record.ended_at.is_some());
            let task = match kept {
                Some(task) => task.clone(),
                None => match bg_run::read_record(dir, id) {
                    Some(record) => Arc::new(BgTask::new(ino, record)),
                    None => continue,
                },
            };
            folder.by_id.insert(id.to_owned(), task);
        } else if let Some((id, start)) = name.split_once(".out.")
            && let Ok(start) = start.parse::<u64>()
        {
            folder.segments.entry(id.to_owned()).or_default().push(start);
        }
    }
    for starts in folder.segments.values_mut() {
        starts.sort_unstable();
    }
    folder.tasks =
        folder.by_id.values().filter(|t| t.record.generation == generation).cloned().collect();
    folder.tasks.sort_by_key(|t| t.record.started_at);
    folder
}

/// The chat folders' last looks, by path.
#[derive(Default)]
pub(crate) struct BgFolders(StdMutex<HashMap<PathBuf, Arc<BgFolder>>>);

impl BgFolders {
    /// `dir` now: its last look when the folder has not changed since, else a new one. A folder
    /// that is gone (never made, purged) is empty and forgotten.
    pub(super) fn look(&self, dir: &Path) -> Arc<BgFolder> {
        let prev = self.0.lock().unwrap_or_else(|e| e.into_inner()).get(dir).cloned();
        let meta = match std::fs::metadata(dir) {
            Ok(meta) => meta,
            Err(_) => {
                if prev.is_some() {
                    self.0.lock().unwrap_or_else(|e| e.into_inner()).remove(dir);
                }
                return Arc::default();
            }
        };
        #[cfg(unix)]
        if let Some(prev) = &prev
            && prev.stamp == Some(stamp_of(&meta))
        {
            return prev.clone();
        }
        #[cfg(not(unix))]
        let _ = meta;
        let folder = Arc::new(scan(dir, prev.as_deref()));
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(dir.to_owned(), folder.clone());
        folder
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn record(id: &str, generation: &str, ended: bool) -> Record {
        Record {
            id: id.into(),
            generation: generation.into(),
            started_at: id.len() as u64,
            ended_at: ended.then_some(1),
            ..Record::default()
        }
    }

    fn folder() -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("chat");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join(".generation"), "g1").unwrap();
        (root, dir)
    }

    /// Ages the folder's modify time past [`RACY`], as a folder nobody wrote to for a while.
    fn settle(dir: &Path) {
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(10);
        std::fs::File::open(dir).unwrap().set_modified(old).unwrap();
    }

    #[test]
    fn an_unchanged_folder_is_not_listed_again_and_a_changed_one_is() {
        let (_root, dir) = folder();
        bg_run::write_record(&dir, &record("a", "g1", true)).unwrap();
        settle(&dir);
        let folders = BgFolders::default();
        let first = folders.look(&dir);
        assert_eq!(first.tasks.len(), 1);
        assert!(Arc::ptr_eq(&first, &folders.look(&dir)), "an unchanged folder was listed again");
        bg_run::write_record(&dir, &record("bb", "g1", false)).unwrap();
        let second = folders.look(&dir);
        assert_eq!(
            second.tasks.iter().map(|t| t.record.id.as_str()).collect::<Vec<_>>(),
            ["a", "bb"]
        );
        assert!(Arc::ptr_eq(&first.tasks[0], &second.tasks[0]), "an ended record was read again");
    }

    #[test]
    fn a_running_record_rewritten_is_read_again_and_other_generations_stay_out() {
        let (_root, dir) = folder();
        bg_run::write_record(&dir, &record("a", "g1", false)).unwrap();
        bg_run::write_record(&dir, &record("old", "g0", true)).unwrap();
        let folders = BgFolders::default();
        assert_eq!(folders.look(&dir).tasks.len(), 1);
        bg_run::write_record(&dir, &record("a", "g1", true)).unwrap();
        let now = folders.look(&dir);
        assert!(now.tasks[0].record.ended_at.is_some(), "a rewritten record was not read again");
    }

    #[test]
    fn a_change_inside_the_racy_window_is_seen_even_with_the_same_modify_time() {
        let (_root, dir) = folder();
        bg_run::write_record(&dir, &record("a", "g1", false)).unwrap();
        let folders = BgFolders::default();
        let first = folders.look(&dir);
        let mtime = std::fs::metadata(&dir).unwrap().modified().unwrap();
        bg_run::write_record(&dir, &record("a", "g1", true)).unwrap();
        // The same tick: the folder's modify time put back to what the first look saw.
        std::fs::File::open(&dir).unwrap().set_modified(mtime).unwrap();
        let second = folders.look(&dir);
        assert!(!Arc::ptr_eq(&first, &second));
        assert!(second.tasks[0].record.ended_at.is_some());
    }

    #[test]
    fn segments_come_from_the_one_listing_and_a_gone_folder_is_forgotten() {
        let (_root, dir) = folder();
        bg_run::write_record(&dir, &record("a", "g1", true)).unwrap();
        for start in [20, 10] {
            std::fs::write(dir.join(format!("a.out.{start}")), b"x").unwrap();
        }
        let folders = BgFolders::default();
        assert_eq!(folders.look(&dir).segments("a"), Some(&[10, 20][..]));
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(folders.look(&dir).tasks.is_empty());
        assert!(folders.0.lock().unwrap().is_empty());
    }

    #[test]
    fn a_free_lock_is_kept_for_good_and_a_held_one_for_live_for() {
        use std::os::fd::AsRawFd;
        let (_root, dir) = folder();
        bg_run::write_record(&dir, &record("a", "g1", false)).unwrap();
        let lock = std::fs::File::create(bg_run::lock_path(&dir, "a")).unwrap();
        // SAFETY: flock on a descriptor this test owns.
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        let folders = BgFolders::default();
        let look = folders.look(&dir);
        let task = &look.tasks[0];
        assert!(!task.gone(&dir));
        drop(lock);
        assert!(!task.gone(&dir), "a held lock was probed again within LIVE_FOR");
        // Past LIVE_FOR.
        *task.held_at.lock().unwrap() = Some(std::time::Instant::now() - LIVE_FOR);
        assert!(task.gone(&dir), "a free lock was not seen past LIVE_FOR");
        let again = std::fs::File::open(bg_run::lock_path(&dir, "a")).unwrap();
        // SAFETY: as above.
        assert_eq!(unsafe { libc::flock(again.as_raw_fd(), libc::LOCK_EX) }, 0);
        assert!(task.gone(&dir), "a lock once free was probed again");
    }
}
