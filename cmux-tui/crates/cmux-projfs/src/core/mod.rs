//! The read path, independent of FUSE.
//!
//! [`Core::read`] answers a read of a manifest entry from the chunk cache, and faults what is
//! missing in from the [`Source`]:
//!
//! - concurrent readers of one chunk share one fetch;
//! - the first fault of a small file in a directory also asks for that directory's other uncached
//!   small files in the same call, up to a count and a byte bound;
//! - a read of a big file fetches the next chunks ahead in the background;
//! - a file that changed on the Mac gets its new stat (the kernel is told to forget the old
//!   attributes and pages through the invalidate callback), and the read is retried once against
//!   the new version, so the reader sees the new bytes rather than an error;
//! - while the Mac is unreachable a read waits up to a bound for it to come back, asking again,
//!   then fails with "host is down"; a later read asks again;
//! - a withheld file is "permission denied", a gone file "no such file" (and is marked gone), and
//!   any other failure an I/O error for that one call.

mod fetch;
mod stats;

use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard};
use std::time::{Duration, Instant};

pub use stats::Stats;

use crate::cache::{CHUNK, ChunkCache, ChunkKey, chunk_len};
use crate::manifest::{Delta, Index, Kind, Manifest, ManifestError, Version};
use crate::source::Source;
use fetch::{Inflight, Miss};
use stats::Counters;

/// Tuning for the read path. [`Config::default`] holds the design's values.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// How long a read waits for an unreachable Mac before failing with "host is down".
    pub away_wait: Duration,
    /// How often a waiting read asks again when nothing signals that the Mac is back.
    pub away_retry: Duration,
    /// The most files one directory batch asks for, the faulting file included.
    pub batch_files: usize,
    /// The most bytes one directory batch asks for, the faulting file included.
    pub batch_bytes: u64,
    /// How many chunks past a read of a big file are fetched ahead.
    pub readahead_chunks: u32,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            away_wait: Duration::from_secs(5),
            away_retry: Duration::from_millis(250),
            batch_files: 512,
            batch_bytes: 16 << 20,
            readahead_chunks: 2,
        }
    }
}

/// Why a read failed. [`ReadError::errno`] gives the error a filesystem returns for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReadError {
    /// The entry does not exist or is gone.
    NotFound,
    /// The entry is a directory or a symlink.
    NotAFile,
    /// The file's bytes stay on the Mac.
    Withheld,
    /// The Mac stayed unreachable for the whole wait.
    HostDown,
    /// Anything else; the next read asks again.
    Io(String),
}

/// The errno of [`ReadError::HostDown`]: `EHOSTDOWN` where the platform has it.
#[cfg(unix)]
const HOST_DOWN: i32 = libc::EHOSTDOWN;
/// The errno of [`ReadError::HostDown`]: this platform has no `EHOSTDOWN`, so a plain I/O error.
#[cfg(not(unix))]
const HOST_DOWN: i32 = libc::EIO;

impl ReadError {
    pub fn errno(&self) -> i32 {
        match self {
            ReadError::NotFound => libc::ENOENT,
            ReadError::NotAFile => libc::EISDIR,
            ReadError::Withheld => libc::EACCES,
            ReadError::HostDown => HOST_DOWN,
            ReadError::Io(_) => libc::EIO,
        }
    }
}

/// Called with an entry's index after its stat changed or it went away, so the filesystem can
/// drop the kernel's cached attributes and pages for it. It must not block on a read in flight.
pub type InvalidateFn = Arc<dyn Fn(Index) + Send + Sync>;

/// What a read needs to know about its file, copied out of the manifest.
#[derive(Clone, Debug)]
pub(crate) struct Target {
    pub idx: Index,
    pub parent: Index,
    pub path: String,
    pub version: Version,
}

/// The projection's shared state: the manifest, the cache, the source and the fetches in flight.
pub struct Core {
    manifest: RwLock<Manifest>,
    cache: ChunkCache,
    source: Arc<dyn Source>,
    config: Config,
    inflight: Inflight,
    invalidate: RwLock<Option<InvalidateFn>>,
    link_epoch: Mutex<u64>,
    link_back: Condvar,
    counters: Counters,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Core {
    pub fn new(
        manifest: Manifest,
        cache: ChunkCache,
        source: Arc<dyn Source>,
        config: Config,
    ) -> Arc<Core> {
        Arc::new(Core {
            manifest: RwLock::new(manifest),
            cache,
            source,
            config,
            inflight: Inflight::default(),
            invalidate: RwLock::new(None),
            link_epoch: Mutex::new(0),
            link_back: Condvar::new(),
            counters: Counters::default(),
        })
    }

    /// The manifest as it is now. Hold the guard briefly: deltas wait for it.
    pub fn manifest(&self) -> RwLockReadGuard<'_, Manifest> {
        self.manifest.read().unwrap_or_else(PoisonError::into_inner)
    }

    pub fn cache(&self) -> &ChunkCache {
        &self.cache
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn stats(&self) -> Stats {
        self.counters.snapshot()
    }

    /// Sets (or with `None` clears) the callback told about changed and gone entries.
    pub fn set_invalidate(&self, f: Option<InvalidateFn>) {
        *self.invalidate.write().unwrap_or_else(PoisonError::into_inner) = f;
    }

    /// Tells waiting reads that the Mac is reachable again, so they ask at once.
    pub fn source_back(&self) {
        *lock(&self.link_epoch) += 1;
        self.link_back.notify_all();
    }

    /// Applies a change that arrived from the Mac (for example from its watcher) and tells the
    /// invalidate callback. Cached chunks are kept: the old version's keys no longer match.
    pub fn apply_delta(&self, path: &str, delta: Delta) -> Result<Option<Index>, ManifestError> {
        let changed = self
            .manifest
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .apply_delta(path, delta)?;
        if let Some(idx) = changed {
            let f = self.invalidate.read().unwrap_or_else(PoisonError::into_inner).clone();
            if let Some(f) = f {
                f(idx);
            }
        }
        Ok(changed)
    }

    fn target(&self, idx: Index) -> Result<(Target, u64), ReadError> {
        let m = self.manifest();
        let e = m.entry(idx).ok_or(ReadError::NotFound)?;
        if e.gone {
            return Err(ReadError::NotFound);
        }
        if e.stat.kind != Kind::File {
            return Err(ReadError::NotAFile);
        }
        if e.stat.withheld {
            return Err(ReadError::Withheld);
        }
        let path = m.path_of(idx).ok_or(ReadError::NotFound)?;
        let target = Target { idx, parent: e.parent, path, version: e.stat.version() };
        Ok((target, e.stat.size))
    }

    /// Reads up to `len` bytes at `offset` of entry `idx`, faulting in what the cache lacks.
    /// Short only at the end of the file; empty past it.
    pub fn read(self: &Arc<Self>, idx: Index, offset: u64, len: u32) -> Result<Vec<u8>, ReadError> {
        let mut retried_change = false;
        let mut away_deadline: Option<Instant> = None;
        loop {
            let (target, size) = self.target(idx)?;
            if offset >= size || len == 0 {
                return Ok(Vec::new());
            }
            // Taken before asking, so a `source_back` that lands while the answer is on its way
            // still wakes the wait below.
            let epoch = *lock(&self.link_epoch);
            match self.read_version(&target, size, offset, len, true) {
                Ok(bytes) => return Ok(bytes),
                Err(Miss::Changed) if !retried_change => retried_change = true,
                Err(Miss::Changed) => {
                    return Err(ReadError::Io("the file changed again while it was read".into()));
                }
                Err(Miss::Away) => {
                    let now = Instant::now();
                    let deadline = *away_deadline.get_or_insert(now + self.config.away_wait);
                    if now >= deadline {
                        return Err(ReadError::HostDown);
                    }
                    self.wait_for_link(epoch, deadline.min(now + self.config.away_retry));
                }
                Err(Miss::Gone) => return Err(ReadError::NotFound),
                Err(Miss::Withheld) => return Err(ReadError::Withheld),
                Err(Miss::Failed(why)) => return Err(ReadError::Io(why)),
                Err(Miss::NotLocal) => {
                    return Err(ReadError::Io("chunk missing from the cache".into()));
                }
            }
        }
    }

    /// Like [`Core::read`], but only from the cache: `None` when any part is missing (or the
    /// read would fail), so the caller can do the full read on another thread.
    pub fn read_cached(self: &Arc<Self>, idx: Index, offset: u64, len: u32) -> Option<Vec<u8>> {
        let (target, size) = self.target(idx).ok()?;
        if offset >= size || len == 0 {
            return Some(Vec::new());
        }
        self.read_version(&target, size, offset, len, false).ok()
    }

    fn read_version(
        self: &Arc<Self>,
        target: &Target,
        size: u64,
        offset: u64,
        len: u32,
        remote_ok: bool,
    ) -> Result<Vec<u8>, Miss> {
        let end = offset.saturating_add(u64::from(len)).min(size);
        let (c0, c1) = ((offset / CHUNK) as u32, ((end - 1) / CHUNK) as u32);
        let mut out = Vec::with_capacity((end - offset) as usize);
        let mut remote = false;
        for c in c0..=c1 {
            let base = u64::from(c) * CHUNK;
            let clen = chunk_len(size, c);
            let lo = offset.max(base) - base;
            let hi = end.min(base + clen) - base;
            let key = ChunkKey::new(&target.path, target.version, c);
            let piece = if remote_ok {
                self.chunk_range(target, size, c, key, clen, lo..hi, &mut remote)?
            } else {
                self.cache.read(&key, clen, lo, hi - lo).ok_or(Miss::NotLocal)?
            };
            out.extend_from_slice(&piece);
        }
        let counter = if remote { &self.counters.remote_reads } else { &self.counters.hits };
        Counters::bump(counter, 1);
        self.read_ahead(target, size, c1);
        Ok(out)
    }

    /// Waits until [`Core::source_back`] has been called since `since` was read, or `until`
    /// passes.
    fn wait_for_link(&self, since: u64, until: Instant) {
        let mut epoch = lock(&self.link_epoch);
        while *epoch == since {
            let now = Instant::now();
            if now >= until {
                return;
            }
            epoch = self
                .link_back
                .wait_timeout(epoch, until - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}
