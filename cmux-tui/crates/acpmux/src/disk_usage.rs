//! What fills this machine's root disk, for `acpmux machine load` (`host_load.rs`): the root
//! filesystem's size, use and free space (statvfs, every sample), and a split of the used bytes
//! into `system`, `project` and `caches` (RFD 0068, "What to build next" 2 and 3). cmux Cloud's
//! server grows a Cloud machine's disk from these numbers and its machine card draws them.
//!
//! The split is a walk of the home directory, so it is never taken on a sample: a sample reads
//! the last walk from `$ACPMUX_HOME/disk-split.json`, and when that is older than [`WALK_EVERY`]
//! it starts one walk in the background (`acpmux host disk-walk`, its own process group, at the
//! lowest CPU priority) and reports the older split until it lands. One walk at a time
//! (`disk-split.walking`, taken with `create_new`); the walk stops at [`WALK_BUDGET`] or
//! [`WALK_MAX_ENTRIES`] and says it is `complete: false`. Linux only: off Linux nothing walks.
//!
//! The split, from a fixed list:
//! - `caches`: under the home directory, the package stores and build caches of [`CACHE_DIRS`],
//!   every `node_modules`, and every directory holding a `CACHEDIR.TAG` (cargo's `target`).
//! - `project`: the rest of the home directory, the project checkouts and their `.git` objects.
//! - `system`: the root filesystem's used bytes less the two above: everything outside home.
//!
//! Sizes are allocated bytes (`st_blocks`), a hard-linked file once, never across a mount.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How old the last split may be before a sample starts a new walk.
pub const WALK_EVERY: Duration = Duration::from_secs(5 * 60);
/// The longest one walk runs; past it the split is `complete: false`.
pub const WALK_BUDGET: Duration = Duration::from_secs(60);
/// The most entries one walk reads.
pub const WALK_MAX_ENTRIES: u64 = 3_000_000;
/// A walk lock older than this belongs to a walk that died: it is taken over.
const LOCK_STALE: Duration = Duration::from_secs(10 * 60);
/// How many of the largest home directories the split names.
pub const TOP: usize = 3;

/// The caches under the home directory, relative to it: package stores and build caches.
pub const CACHE_DIRS: &[&str] = &[
    ".cache",
    ".npm",
    ".bun/install/cache",
    ".pnpm-store",
    ".local/share/pnpm",
    ".yarn/berry/cache",
    ".cargo/registry",
    ".cargo/git",
    ".rustup",
    "go/pkg/mod",
    ".gradle/caches",
    ".m2/repository",
    "Library/Caches",
];

/// Directories that are caches wherever they sit under home.
const CACHE_NAMES: &[&str] = &["node_modules"];

/// The root filesystem, from statvfs. `used` is blocks less free blocks, so `used + free` can
/// be under `total` by the blocks reserved for root.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Root {
    pub total: u64,
    pub used: u64,
    pub free: u64,
}

/// One of the largest directories under home, at most two levels down (`~/src/app`, `~/.cache`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopDir {
    pub path: String,
    pub bytes: u64,
}

/// The last walk's split of the root disk's used bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiskSplit {
    /// When the walk ended, milliseconds since the epoch.
    pub at: u64,
    pub system_bytes: u64,
    pub project_bytes: u64,
    pub caches_bytes: u64,
    /// False when the walk stopped at its budget: `project` and `caches` are then low.
    pub complete: bool,
    /// The [`TOP`] largest directories under home, largest first.
    pub top: Vec<TopDir>,
}

/// The filesystem holding `path`.
#[cfg(unix)]
pub fn statvfs(path: &Path) -> Option<Root> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    // SAFETY: an all-zero statvfs is a valid value of this plain C struct.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is NUL-terminated and `st` is writable storage of the right type.
    if unsafe { libc::statvfs(c.as_ptr(), &raw mut st) } != 0 {
        return None;
    }
    let frsize = st.f_frsize as u64;
    let total = (st.f_blocks as u64).saturating_mul(frsize);
    let used = (st.f_blocks as u64).saturating_sub(st.f_bfree as u64).saturating_mul(frsize);
    let free = (st.f_bavail as u64).saturating_mul(frsize);
    Some(Root { total, used, free })
}

#[cfg(not(unix))]
pub fn statvfs(_: &Path) -> Option<Root> {
    None
}

fn cache_path() -> PathBuf {
    crate::config::home().join("disk-split.json")
}

fn lock_path() -> PathBuf {
    crate::config::home().join("disk-split.walking")
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from)
}

/// The last split, if any, and whether it is due for a new walk at `now_ms`.
pub fn read_cached(path: &Path, now_ms: u64) -> (Option<DiskSplit>, bool) {
    let split: Option<DiskSplit> =
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok());
    let due =
        split.as_ref().is_none_or(|s| now_ms.saturating_sub(s.at) >= WALK_EVERY.as_millis() as u64);
    (split, due)
}

/// The last split for a sample; starts a background walk when it is due (Linux only).
pub fn split_for_sample() -> Option<DiskSplit> {
    let (split, due) = read_cached(&cache_path(), crate::store::now_ms());
    if due && cfg!(target_os = "linux") && home_dir().is_some() {
        start_walk();
    }
    split
}

/// Takes the walk lock: false when a live walk holds it.
fn take_lock(lock: &Path) -> bool {
    let open = || std::fs::OpenOptions::new().write(true).create_new(true).open(lock);
    if open().is_ok() {
        return true;
    }
    let stale = std::fs::metadata(lock)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age >= LOCK_STALE);
    stale && std::fs::remove_file(lock).is_ok() && open().is_ok()
}

#[cfg(unix)]
fn start_walk() {
    let lock = lock_path();
    if let Some(dir) = lock.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if !take_lock(&lock) {
        return;
    }
    let Ok(exe) = std::env::current_exe() else {
        let _ = std::fs::remove_file(&lock);
        return;
    };
    let started = cmux_process::Command::new(exe)
        .args(["host", "disk-walk"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .process_group(0)
        .spawn();
    match started {
        // The sample exits at once; the walk writes its file and lets go of the lock after.
        Ok(mut child) => {
            child.detach("the disk walk outlives the one-shot `host load` that started it");
        }
        Err(_) => {
            let _ = std::fs::remove_file(&lock);
        }
    }
}

#[cfg(not(unix))]
fn start_walk() {}

/// `acpmux host disk-walk`: one walk, written to the cache file; the lock is let go after.
pub fn walk_and_store() -> anyhow::Result<()> {
    #[cfg(unix)]
    // SAFETY: setpriority on this process only.
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, 19);
    }
    let result = (|| {
        let home = home_dir().ok_or_else(|| anyhow::anyhow!("no HOME"))?;
        let root = statvfs(Path::new("/")).ok_or_else(|| anyhow::anyhow!("statvfs / failed"))?;
        let walked = walk(&home, WALK_BUDGET, WALK_MAX_ENTRIES);
        let same_disk = same_device(Path::new("/"), &home);
        let split = split_of(&home, root, same_disk, walked, crate::store::now_ms());
        let path = cache_path();
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(&split)?)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    })();
    let _ = std::fs::remove_file(lock_path());
    result
}

#[cfg(unix)]
fn same_device(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    matches!((std::fs::metadata(a), std::fs::metadata(b)), (Ok(x), Ok(y)) if x.dev() == y.dev())
}

#[cfg(not(unix))]
fn same_device(_: &Path, _: &Path) -> bool {
    false
}

/// What one walk of home found.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Walked {
    pub project: u64,
    pub caches: u64,
    pub complete: bool,
    /// Bytes per directory at most two levels under home (a file directly in home: its own).
    pub buckets: Vec<(PathBuf, u64)>,
}

/// Whether `dir` (at `rel` under home) is a cache.
fn is_cache(dir: &Path, rel: &Path) -> bool {
    CACHE_DIRS.iter().any(|c| rel == Path::new(c))
        || dir.file_name().and_then(|n| n.to_str()).is_some_and(|n| CACHE_NAMES.contains(&n))
        || dir.join("CACHEDIR.TAG").exists()
}

/// Walks `home` on its own filesystem, never following a symlink.
#[cfg(unix)]
pub fn walk(home: &Path, budget: Duration, max_entries: u64) -> Walked {
    use std::collections::{HashMap, HashSet};
    use std::os::unix::fs::MetadataExt;
    let started = std::time::Instant::now();
    let Ok(top) = std::fs::symlink_metadata(home) else { return Walked::default() };
    let dev = top.dev();
    let mut out = Walked { complete: true, ..Walked::default() };
    let mut buckets: HashMap<PathBuf, u64> = HashMap::new();
    let mut linked: HashSet<u64> = HashSet::new();
    let mut entries: u64 = 0;
    // (directory, whether it is inside a cache)
    let mut stack: Vec<(PathBuf, bool)> = vec![(home.to_path_buf(), false)];
    'walk: while let Some((dir, in_cache)) = stack.pop() {
        let Ok(read) = std::fs::read_dir(&dir) else { continue };
        for entry in read.flatten() {
            entries += 1;
            if entries >= max_entries
                || (entries.is_multiple_of(1024) && started.elapsed() >= budget)
            {
                out.complete = false;
                break 'walk;
            }
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
            if meta.dev() != dev {
                continue;
            }
            if !meta.is_dir() && meta.nlink() > 1 && !linked.insert(meta.ino()) {
                continue;
            }
            let rel = path.strip_prefix(home).unwrap_or(&path);
            let bytes = meta.blocks().saturating_mul(512);
            let cache = in_cache || (meta.is_dir() && is_cache(&path, rel));
            if cache {
                out.caches += bytes;
            } else {
                out.project += bytes;
            }
            let key: PathBuf = rel.components().take(2).collect();
            let key = if meta.is_dir() || rel.components().count() > 2 {
                key
            } else {
                // A file directly in home, or directly in a top-level directory: that directory.
                rel.parent().filter(|p| !p.as_os_str().is_empty()).map_or(key, Path::to_path_buf)
            };
            *buckets.entry(key).or_default() += bytes;
            if meta.is_dir() {
                stack.push((path, cache));
            }
        }
    }
    let mut buckets: Vec<(PathBuf, u64)> = buckets.into_iter().collect();
    buckets.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    out.buckets = buckets;
    out
}

#[cfg(not(unix))]
pub fn walk(_: &Path, _: Duration, _: u64) -> Walked {
    Walked::default()
}

/// The split from a walk of home and the root filesystem at its end. `same_disk`: home is on the
/// root filesystem; else all of root's used bytes are `system`.
pub fn split_of(home: &Path, root: Root, same_disk: bool, walked: Walked, at: u64) -> DiskSplit {
    let home_bytes = walked.project.saturating_add(walked.caches);
    let system = if same_disk { root.used.saturating_sub(home_bytes) } else { root.used };
    // Only the deepest buckets name a directory: `~/src` and `~/src/app` would count twice.
    let deepest: Vec<&(PathBuf, u64)> = walked
        .buckets
        .iter()
        .filter(|(p, _)| !walked.buckets.iter().any(|(q, _)| q != p && q.starts_with(p)))
        .collect();
    let top = deepest
        .into_iter()
        .take(TOP)
        .map(|(p, bytes)| TopDir {
            path: home.join(p).to_string_lossy().into_owned(),
            bytes: *bytes,
        })
        .collect();
    DiskSplit {
        at,
        system_bytes: system,
        project_bytes: walked.project,
        caches_bytes: walked.caches,
        complete: walked.complete,
        top,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_split_is_camel_case() {
        let split = DiskSplit {
            at: 5,
            system_bytes: 1,
            project_bytes: 2,
            caches_bytes: 3,
            complete: true,
            top: vec![TopDir { path: "/home/u/src/app".into(), bytes: 2 }],
        };
        assert_eq!(
            serde_json::to_value(&split).unwrap(),
            json!({"at": 5, "systemBytes": 1, "projectBytes": 2, "cachesBytes": 3,
                   "complete": true, "top": [{"path": "/home/u/src/app", "bytes": 2}]})
        );
    }

    #[test]
    fn system_is_what_home_does_not_hold() {
        let root = Root { total: 100, used: 60, free: 40 };
        let walked = Walked {
            project: 20,
            caches: 10,
            complete: true,
            buckets: vec![
                (PathBuf::from("src"), 20),
                (PathBuf::from("src/app"), 19),
                (PathBuf::from(".cache"), 10),
                (PathBuf::from(".zshrc"), 1),
            ],
        };
        let split = split_of(Path::new("/h"), root, true, walked.clone(), 9);
        assert_eq!((split.system_bytes, split.project_bytes, split.caches_bytes), (30, 20, 10));
        let paths: Vec<&str> = split.top.iter().map(|t| t.path.as_str()).collect();
        assert_eq!(paths, ["/h/src/app", "/h/.cache", "/h/.zshrc"], "the deepest, largest first");
        assert_eq!(split_of(Path::new("/h"), root, false, walked, 9).system_bytes, 60);
    }

    #[test]
    fn a_split_is_due_when_missing_or_old() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("disk-split.json");
        assert_eq!(read_cached(&path, 1_000), (None, true));
        let split = split_of(
            dir.path(),
            Root { total: 1, used: 1, free: 0 },
            true,
            Walked::default(),
            1_000,
        );
        std::fs::write(&path, serde_json::to_vec(&split).unwrap()).unwrap();
        assert!(!read_cached(&path, 1_000 + 60_000).1);
        assert!(read_cached(&path, 1_000 + WALK_EVERY.as_millis() as u64).1);
    }

    #[cfg(unix)]
    #[test]
    fn the_walk_sorts_caches_from_the_project() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let write = |rel: &str, len: usize| {
            let p = h.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, vec![7u8; len]).unwrap();
        };
        write("src/app/main.rs", 64 * 1024);
        write("src/app/node_modules/x/index.js", 128 * 1024);
        write("src/app/target/CACHEDIR.TAG", 10);
        write("src/app/target/debug/big", 256 * 1024);
        write(".cache/bun/blob", 32 * 1024);
        let walked = walk(h, Duration::from_secs(30), 1_000_000);
        assert!(walked.complete);
        assert!(walked.caches >= (128 + 256 + 32) * 1024, "{walked:?}");
        assert!(walked.project >= 64 * 1024 && walked.project < 128 * 1024, "{walked:?}");
        let cut = walk(h, Duration::from_secs(30), 3);
        assert!(!cut.complete, "the entry budget stops the walk");
    }

    #[test]
    fn one_walk_holds_the_lock() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join("disk-split.walking");
        assert!(take_lock(&lock));
        assert!(!take_lock(&lock), "a live walk holds it");
    }
}
