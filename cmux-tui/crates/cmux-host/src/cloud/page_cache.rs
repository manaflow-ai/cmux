//! `cmux host cloud drop-page-cache [--deadline-ms N]`: the guest's half of the platform's pre-pause step
//! (cmuxterm-hq docs/rfd/0063-one-vm-per-agent.md, "Sizes": "page cache is dropped before a pause so the saved image
//! and the resume's page-in (0.85 s per GiB touched) follow real memory").
//!
//! Right before the provider pause, cmux-platform runs this as root over the guest exec channel (CloudCore's pause
//! pass, under the aggressive pause policy only). It writes dirty pages back (`sync`), then drops the clean page cache
//! (`1` to `/proc/sys/vm/drop_caches`). Only clean file pages go: anonymous memory, dirty pages and slab stay, so
//! nothing a process holds is lost; a file read after the resume comes from disk, as on a fresh boot.
//!
//! Why not a cgroup `memory.reclaim`: it takes a size, not "the clean cache", and with swap or zswap configured it
//! reclaims anonymous memory too, which the resume would then page back in. Why not `posix_fadvise(DONTNEED)`: it is
//! per open file, and the cache worth dropping (a build's object files, a clone's packs) is mostly files no process
//! still has open.
//!
//! The step is bounded: `sync` can block behind a slow disk, so the work runs on its own thread and the verb answers by
//! its deadline whatever the thread is doing (`dropped: false, why: "deadline"`). The process then exits, and the
//! platform's pause proceeds; the platform bounds the whole exec too, so a guest that never answers holds nothing.
//! The answer is one JSON line with the page cache before and after (kB, from `/proc/meminfo`), for the pause's log.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// The verb's deadline when the platform names none: well inside the platform's own bound on the exec.
pub const DEFAULT_DEADLINE: Duration = Duration::from_millis(1500);
/// The longest deadline the verb takes: a pause is never held longer than this by its guest.
pub const MAX_DEADLINE: Duration = Duration::from_secs(10);

/// `Cached` and `Dirty` of `/proc/meminfo`, in kB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheSize {
    pub cached_kb: u64,
    pub dirty_kb: u64,
}

/// `Cached:` and `Dirty:` of a `/proc/meminfo` text; None when either is missing.
pub fn parse_meminfo(text: &str) -> Option<CacheSize> {
    let field = |name: &str| {
        text.lines().find_map(|line| {
            let rest = line.strip_prefix(name)?.strip_prefix(':')?;
            rest.split_whitespace().next()?.parse::<u64>().ok()
        })
    };
    Some(CacheSize { cached_kb: field("Cached")?, dirty_kb: field("Dirty")? })
}

/// The two files the verb reads and writes: `/proc`'s on a machine, a temporary directory's in tests.
#[derive(Debug, Clone)]
pub struct Proc {
    /// `/proc/meminfo`.
    pub meminfo: PathBuf,
    /// `/proc/sys/vm/drop_caches`.
    pub drop_caches: PathBuf,
}

impl Proc {
    pub fn system() -> Self {
        Self {
            meminfo: PathBuf::from("/proc/meminfo"),
            drop_caches: PathBuf::from("/proc/sys/vm/drop_caches"),
        }
    }
    fn meminfo(&self) -> Option<CacheSize> {
        parse_meminfo(&std::fs::read_to_string(&self.meminfo).ok()?)
    }
}

/// The whole system's `sync(2)`: every dirty page written back, so the drop that follows frees all of the cache.
#[cfg(unix)]
pub fn sync_all() {
    // SAFETY: sync(2) takes no arguments and cannot fail.
    unsafe { libc::sync() }
}

#[cfg(not(unix))]
pub fn sync_all() {}

/// The `--deadline-ms` argument, clamped to [`MAX_DEADLINE`]; [`DEFAULT_DEADLINE`] when absent.
pub fn parse_deadline(args: &[String]) -> Result<Duration, String> {
    match args {
        [] => Ok(DEFAULT_DEADLINE),
        [flag, n] if flag == "--deadline-ms" => n
            .parse::<u64>()
            .map(|ms| Duration::from_millis(ms).min(MAX_DEADLINE))
            .map_err(|_| "--deadline-ms takes a whole number of milliseconds".to_owned()),
        _ => Err("drop-page-cache takes --deadline-ms N only".to_owned()),
    }
}

/// Sync, then drop the clean page cache, answering by `deadline`. `sync` is the write-back (injected so a test can
/// stand in a slow disk). Never fails: every outcome is a JSON answer, and the caller pauses either way.
pub fn drop_page_cache(
    proc: &Proc,
    sync: impl FnOnce() + Send + 'static,
    deadline: Duration,
) -> serde_json::Value {
    let started = Instant::now();
    let before = proc.meminfo();
    let (tx, rx) = mpsc::channel::<Result<(), String>>();
    let target = proc.drop_caches.clone();
    // A named thread of this one-shot verb, not a task of a long-lived owner: past the deadline the verb answers and
    // its process exits, and the thread (still in `sync`) ends with it.
    let worker = std::thread::Builder::new().name("drop-page-cache".into()).spawn(move || {
        sync();
        let _ = tx.send(write_drop(&target));
    });
    let outcome = match worker {
        Ok(_) => rx.recv_timeout(deadline).map_err(|_| "deadline".to_owned()).and_then(|r| r),
        Err(e) => Err(format!("no thread: {e}")),
    };
    let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    let mut fields = serde_json::Map::new();
    fields.insert("ms".into(), ms.into());
    match outcome {
        Ok(()) => {
            fields.insert("dropped".into(), true.into());
        }
        Err(why) => {
            fields.insert("dropped".into(), false.into());
            fields.insert("why".into(), why.into());
        }
    }
    if let Some(b) = before {
        fields.insert("cached_kb_before".into(), b.cached_kb.into());
        fields.insert("dirty_kb_before".into(), b.dirty_kb.into());
    }
    if let Some(a) = proc.meminfo() {
        fields.insert("cached_kb_after".into(), a.cached_kb.into());
    }
    serde_json::Value::Object(fields)
}

fn write_drop(target: &Path) -> Result<(), String> {
    // `1`: the clean page cache only (2 would also drop dentries and inodes, which every resumed shell walks again).
    std::fs::write(target, b"1").map_err(|e| format!("{}: {e}", target.display()))
}

#[cfg(all(test, unix))]
#[path = "page_cache_tests.rs"]
mod tests;
