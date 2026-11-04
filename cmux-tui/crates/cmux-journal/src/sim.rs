//! A simulated machine for crash tests (`sim` feature; always in this crate's tests): a page
//! cache over a disk, and the one process that uses them.
//!
//! Files: each file keeps what reads see (its page cache) apart from what its disk holds, per
//! [`SIM_PAGE`] page. A write dirties the pages it touches. A sync writes the dirty pages and the
//! length to the disk. A sync that fails ([`SimStorage::fail_after`]) writes a random part of the
//! dirty pages and drops the rest: those pages stay clean in the cache and never reach the disk,
//! so a later sync reports success without them (Linux's write-back error behavior). A write that
//! fails writes a random prefix of its bytes first.
//!
//! Names: folder and file creations and renames go to one ordered log, as a journaling file
//! system commits them. A folder sync makes durable every logged change up to the last one that
//! changed an entry of that folder, and so every change before it. A rename between two folders
//! is one change: it never comes back twice or not at all.
//!
//! [`SimStorage::fail_next_sync`] fails the next sync of a write that spans pages, and the disk
//! gets none of them (the worst case). The cache keeps the dropped pages until an eviction, which
//! [`SimStorage::evict_dropped_pages_after_read`] makes happen right after each read of them.
//! [`SimStorage::crash_after_failure`] puts the crash point right after an injected failure: in
//! the writer's backoff, at its first operation when it tries again.
//!
//! [`SimStorage::crash_after`] makes the n-th storage operation from now the crash point: an
//! append there writes a random prefix of its bytes, a create, rename, truncate or sync there
//! takes effect or not at random, and every later operation fails. [`SimStorage::restart`] then
//! builds the machine that the next process sees:
//!
//! - [`Crash::Process`] (kill -9 of any or all processes): the machine is unchanged: the cache,
//!   the disk and the unsynced names stay as they are. Only the process and its locks are gone,
//!   so a later OS crash or power loss still loses what it would have lost before.
//! - [`Crash::Os`] (a kernel panic): each file keeps its disk pages, and each dirty page is
//!   written whole, not at all, or a prefix of its 512-byte sectors, at random; its length is
//!   any length between its disk length and its cache length. The names keep a random prefix of
//!   the log that holds every durable change.
//! - [`Crash::PowerLoss`]: as `Os`, but a barrier sync is power-safe only once a later full sync
//!   ran (on any file: a drive cache flush covers every earlier write). So each file goes back to
//!   its disk content at a random common cut between the last full sync and the crash, and the
//!   first sync after the cut is kept in part.
//!
//! A run is deterministic for one seed and one sequence of operations.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use crate::storage::{OpenMode, Storage, StorageFile, StorageLock, SyncLevel};

mod machine;
use machine::{Change, Machine, SimFile};

/// The page size of the simulated cache.
pub const SIM_PAGE: usize = 4096;
/// The unit a page write tears at.
pub(super) const SECTOR: usize = 512;

/// What a simulated crash takes away ([`SimStorage::restart`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Crash {
    Process,
    Os,
    PowerLoss,
}

/// SplitMix64: small, seeded, the same on every host.
#[derive(Clone, Debug)]
pub struct SimRng(u64);

impl SimRng {
    pub fn new(seed: u64) -> Self {
        Self(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A value in `0..n` (0 when `n` is 0).
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64().checked_rem(n).unwrap_or(0)
    }

    /// `below` for lengths.
    pub fn index(&mut self, n: usize) -> usize {
        usize::try_from(self.below(u64::try_from(n).unwrap_or(u64::MAX))).unwrap_or(0)
    }

    fn coin(&mut self) -> bool {
        self.below(2) == 0
    }
}

/// The simulated storage of one process ([module docs](self)). Clones share it.
#[derive(Clone)]
pub struct SimStorage {
    fs: Arc<Mutex<Fs>>,
}

/// One process: its view of the machine.
struct Fs {
    machine: Machine,
    locks: BTreeSet<PathBuf>,
    /// Storage operations so far, the one that crashes, and one that fails once.
    ops: u64,
    crash_at: Option<u64>,
    fail_at: Option<(u64, io::ErrorKind)>,
    crashed: bool,
    /// Each sync sleeps this long (a slow disk, so batches form).
    sync_delay: Duration,
    /// Read operations per path.
    reads: BTreeMap<PathBuf, u64>,
    /// Open files now, and the most at once.
    open_files: u64,
    peak_open_files: u64,
    /// Failures `fail_after` and `fail_next_sync` caused.
    failures: u64,
    /// The next file sync with at least this many dirty pages fails once with this error.
    fail_sync: Option<(usize, io::ErrorKind)>,
    /// Once an injected failure happened, the operation this many after it crashes.
    crash_after_failure: Option<u64>,
    /// Each read evicts the dropped pages it read (`SimStorage::evict_dropped_pages_after_read`).
    evict_after_read: bool,
}

/// What an operation does: run, fail once, or crash the process.
enum Step {
    Run,
    Fail(io::ErrorKind),
    Crash,
}

impl Fs {
    fn new(machine: Machine, sync_delay: Duration) -> Self {
        Self {
            machine,
            locks: BTreeSet::new(),
            ops: 0,
            crash_at: None,
            fail_at: None,
            crashed: false,
            sync_delay,
            reads: BTreeMap::new(),
            open_files: 0,
            peak_open_files: 0,
            failures: 0,
            fail_sync: None,
            crash_after_failure: None,
            evict_after_read: false,
        }
    }

    /// An injected failure happened: count it, and arm the crash that waits for it.
    fn note_failure(&mut self) {
        self.failures = self.failures.saturating_add(1);
        if let Some(n) = self.crash_after_failure.take() {
            self.crash_at = Some(self.ops.saturating_add(n.max(1)));
        }
    }

    /// Counts one operation and says what it does.
    fn begin(&mut self) -> io::Result<Step> {
        if self.crashed {
            return Err(io::Error::other("simulated crash: the process is gone"));
        }
        self.ops = self.ops.saturating_add(1);
        if self.crash_at == Some(self.ops) {
            self.crashed = true;
            return Ok(Step::Crash);
        }
        if let Some((at, kind)) = self.fail_at
            && at == self.ops
        {
            self.fail_at = None;
            self.note_failure();
            return Ok(Step::Fail(kind));
        }
        Ok(Step::Run)
    }

    /// A change of names: done, failed with no effect, or at a crash done or not at random.
    fn change(&mut self, step: Step, change: Change) -> io::Result<()> {
        match step {
            Step::Run => {
                self.machine.change(change);
                Ok(())
            }
            Step::Fail(kind) => Err(failed(kind)),
            Step::Crash => {
                if self.machine.rng.coin() {
                    self.machine.change(change);
                }
                Err(crashed())
            }
        }
    }
}

/// Sleeps the sync delay with the lock released; `None` when the process crashed meanwhile.
fn slow_sync<'a>(mut guard: MutexGuard<'a, Fs>, fs: &'a Mutex<Fs>) -> Option<MutexGuard<'a, Fs>> {
    let delay = guard.sync_delay;
    if !delay.is_zero() {
        drop(guard);
        std::thread::sleep(delay);
        guard = lock(fs);
        if guard.crashed {
            return None;
        }
    }
    Some(guard)
}

fn crashed() -> io::Error {
    io::Error::other("simulated crash")
}

fn failed(kind: io::ErrorKind) -> io::Error {
    io::Error::new(kind, "simulated I/O failure")
}

fn lock(fs: &Mutex<Fs>) -> MutexGuard<'_, Fs> {
    fs.lock().unwrap_or_else(PoisonError::into_inner)
}

impl SimStorage {
    pub fn new(seed: u64) -> Self {
        Self { fs: Arc::new(Mutex::new(Fs::new(Machine::new(seed), Duration::ZERO))) }
    }

    /// The `n`-th storage operation from now (1 = the next one) is the crash point.
    pub fn crash_after(&self, n: u64) {
        let mut fs = lock(&self.fs);
        fs.crash_at = Some(fs.ops.saturating_add(n.max(1)));
    }

    /// The `n`-th storage operation from now fails once with `kind` (ENOSPC, EIO), with the
    /// partial effect the [module docs](self) name.
    pub fn fail_after(&self, n: u64, kind: io::ErrorKind) {
        let mut fs = lock(&self.fs);
        fs.fail_at = Some((fs.ops.saturating_add(n.max(1)), kind));
    }

    /// Each later sync sleeps `delay` first.
    pub fn set_sync_delay(&self, delay: Duration) {
        lock(&self.fs).sync_delay = delay;
    }

    pub fn is_crashed(&self) -> bool {
        lock(&self.fs).crashed
    }

    /// Storage operations so far.
    pub fn ops(&self) -> u64 {
        lock(&self.fs).ops
    }

    /// Read operations on `path` so far.
    pub fn reads(&self, path: &Path) -> u64 {
        lock(&self.fs).reads.get(path).copied().unwrap_or(0)
    }

    /// The next file sync that has at least `pages` dirty pages fails once with `kind`, and the
    /// disk gets none of them: the worst case of a write-back error ([module docs](self)).
    pub fn fail_next_sync(&self, pages: usize, kind: io::ErrorKind) {
        lock(&self.fs).fail_sync = Some((pages, kind));
    }

    /// Once the next injected failure happened, the `n`-th operation after it (1 = the next one)
    /// is the crash point: a crash in the writer's backoff, at its retry. It replaces a crash point
    /// set before.
    pub fn crash_after_failure(&self, n: u64) {
        let mut fs = lock(&self.fs);
        fs.crash_at = None;
        fs.crash_after_failure = Some(n);
    }

    /// From now on, in this process, each read returns the bytes the cache holds and then evicts
    /// the pages it read that a failed sync dropped: a second read of them sees the disk's bytes.
    /// The kernel may evict a clean page at any time; this is the worst time for a reader that
    /// reads twice.
    pub fn evict_dropped_pages_after_read(&self, on: bool) {
        lock(&self.fs).evict_after_read = on;
    }

    /// Operations that `fail_after` and `fail_next_sync` made fail.
    pub fn failures(&self) -> u64 {
        lock(&self.fs).failures
    }

    /// The most files this process held open at once.
    pub fn peak_open_files(&self) -> u64 {
        lock(&self.fs).peak_open_files
    }

    /// What a read of `path` sees now, if it exists.
    pub fn contents(&self, path: &Path) -> Option<Vec<u8>> {
        let fs = lock(&self.fs);
        let inode = fs.machine.names.files.get(path)?;
        fs.machine.files.get(inode).map(|file| file.data.clone())
    }

    /// The file names in `dir`, sorted.
    pub fn names_in(&self, dir: &Path) -> Vec<String> {
        let fs = lock(&self.fs);
        fs.machine
            .names
            .files
            .keys()
            .filter(|path| path.parent() == Some(dir))
            .filter_map(|path| path.file_name()?.to_str().map(str::to_owned))
            .collect()
    }

    /// Flips one byte of `path` in the cache, on the disk and in every synced copy (media
    /// damage), outside any crash.
    pub fn corrupt(&self, path: &Path, offset: usize) {
        let mut fs = lock(&self.fs);
        let Some(inode) = fs.machine.names.files.get(path).copied() else { return };
        if let Some(file) = fs.machine.files.get_mut(&inode) {
            let copies = std::iter::once(&mut file.data)
                .chain(std::iter::once(&mut file.disk))
                .chain(file.synced.iter_mut().map(|(_, content)| content));
            for content in copies {
                if let Some(byte) = content.get_mut(offset) {
                    *byte ^= 0x5A;
                }
            }
        }
    }

    /// Removes `path` and makes the removal durable (a person deleted the file).
    pub fn remove(&self, path: &Path) {
        let mut fs = lock(&self.fs);
        if let Some(inode) = fs.machine.names.files.get(path).copied() {
            fs.machine.change(Change::Remove(path.to_path_buf()));
            fs.machine.durable_changes = fs.machine.log.len();
            fs.machine.files.remove(&inode);
        }
    }

    /// The storage the next process sees after `crash` ([module docs](self)). This process is
    /// crashed from now on: every later operation fails.
    pub fn restart(&self, crash: Crash) -> Self {
        lock(&self.fs).crashed = true;
        self.snapshot(crash)
    }

    /// The storage a process would see after `crash` now, while this one goes on.
    pub fn snapshot(&self, crash: Crash) -> Self {
        let mut fs = lock(&self.fs);
        let delay = fs.sync_delay;
        let machine = match crash {
            Crash::Process => {
                let mut machine = fs.machine.clone();
                // The two processes draw apart from here.
                machine.rng = SimRng::new(fs.machine.rng.next_u64());
                machine
            }
            Crash::Os | Crash::PowerLoss => fs.machine.after_crash(crash),
        };
        Self { fs: Arc::new(Mutex::new(Fs::new(machine, delay))) }
    }
}

impl Storage for SimStorage {
    fn create_dir_all(&self, dir: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        let step = fs.begin()?;
        let mut missing: Vec<PathBuf> = dir
            .ancestors()
            .filter(|path| !fs.machine.names.dirs.contains(*path))
            .map(Path::to_path_buf)
            .collect();
        missing.reverse();
        match step {
            Step::Run => {
                for path in missing {
                    fs.machine.change(Change::Folder(path));
                }
                Ok(())
            }
            Step::Fail(kind) => Err(failed(kind)),
            Step::Crash => {
                let made = fs.machine.rng.index(missing.len().saturating_add(1));
                for path in missing.into_iter().take(made) {
                    fs.machine.change(Change::Folder(path));
                }
                Err(crashed())
            }
        }
    }

    fn list(&self, dir: &Path) -> io::Result<Vec<String>> {
        let mut fs = lock(&self.fs);
        match fs.begin()? {
            Step::Run => {}
            Step::Fail(kind) => return Err(failed(kind)),
            Step::Crash => return Err(crashed()),
        }
        let names = &fs.machine.names;
        if !names.dirs.contains(dir) {
            return Err(io::ErrorKind::NotFound.into());
        }
        let in_dir = |path: &&PathBuf| path.parent() == Some(dir);
        Ok(names
            .files
            .keys()
            .filter(in_dir)
            .chain(names.dirs.iter().filter(in_dir))
            .filter_map(|path| path.file_name()?.to_str().map(str::to_owned))
            .collect())
    }

    fn open(&self, path: &Path, mode: OpenMode) -> io::Result<Box<dyn StorageFile>> {
        let mut fs = lock(&self.fs);
        let step = fs.begin()?;
        let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
        if !fs.machine.names.dirs.contains(&parent) {
            return match step {
                Step::Crash => Err(crashed()),
                Step::Run | Step::Fail(_) => Err(io::ErrorKind::NotFound.into()),
            };
        }
        let existing = fs.machine.names.files.get(path).copied();
        let inode = match (existing, mode) {
            (None, OpenMode::Read | OpenMode::Write) => {
                return match step {
                    Step::Crash => Err(crashed()),
                    Step::Run | Step::Fail(_) => Err(io::ErrorKind::NotFound.into()),
                };
            }
            (Some(inode), OpenMode::Read | OpenMode::Write) => {
                match step {
                    Step::Run => {}
                    Step::Fail(kind) => return Err(failed(kind)),
                    Step::Crash => return Err(crashed()),
                }
                inode
            }
            (Some(inode), OpenMode::Create) => {
                let empty = match step {
                    Step::Run => true,
                    Step::Fail(kind) => return Err(failed(kind)),
                    Step::Crash => fs.machine.rng.coin(),
                };
                if empty {
                    fs.machine.file(inode)?.set_len(0);
                }
                if let Step::Crash = step {
                    return Err(crashed());
                }
                inode
            }
            (None, OpenMode::Create) => {
                let inode = fs.machine.next_inode;
                fs.machine.next_inode = inode.saturating_add(1);
                fs.machine.files.insert(inode, SimFile::empty());
                fs.change(step, Change::Create(path.to_path_buf(), inode))?;
                inode
            }
        };
        fs.open_files = fs.open_files.saturating_add(1);
        fs.peak_open_files = fs.peak_open_files.max(fs.open_files);
        Ok(Box::new(SimHandle {
            fs: self.fs.clone(),
            inode,
            path: path.to_path_buf(),
            writable: mode != OpenMode::Read,
        }))
    }

    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        let step = fs.begin()?;
        let parent = to.parent().map(Path::to_path_buf).unwrap_or_default();
        if !fs.machine.names.dirs.contains(&parent) || !fs.machine.names.files.contains_key(from) {
            return match step {
                Step::Crash => Err(crashed()),
                Step::Run | Step::Fail(_) => Err(io::ErrorKind::NotFound.into()),
            };
        }
        fs.change(step, Change::Rename(from.to_path_buf(), to.to_path_buf()))
    }

    fn remove_file(&self, path: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        let step = fs.begin()?;
        if !fs.machine.names.files.contains_key(path) {
            return match step {
                Step::Crash => Err(crashed()),
                Step::Run | Step::Fail(_) => Err(io::ErrorKind::NotFound.into()),
            };
        }
        // The file's bytes stay while a name or an open handle may still need them; a crash
        // keeps only the files its surviving names point to.
        fs.change(step, Change::Remove(path.to_path_buf()))
    }

    fn sync_dir(&self, dir: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        let done = match fs.begin()? {
            Step::Run => true,
            Step::Fail(kind) => return Err(failed(kind)),
            Step::Crash => fs.machine.rng.coin(),
        };
        if fs.crashed {
            if done {
                fs.machine.sync_folder(dir);
            }
            return Err(crashed());
        }
        let Some(mut fs) = slow_sync(fs, &self.fs) else { return Err(crashed()) };
        fs.machine.sync_folder(dir);
        Ok(())
    }

    fn try_lock(&self, path: &Path) -> io::Result<Option<Box<dyn StorageLock>>> {
        let mut fs = lock(&self.fs);
        match fs.begin()? {
            Step::Run => {}
            Step::Fail(kind) => return Err(failed(kind)),
            Step::Crash => return Err(crashed()),
        }
        if !fs.locks.insert(path.to_path_buf()) {
            return Ok(None);
        }
        Ok(Some(Box::new(SimLock { fs: self.fs.clone(), path: path.to_path_buf() })))
    }
}

struct SimLock {
    fs: Arc<Mutex<Fs>>,
    path: PathBuf,
}

impl StorageLock for SimLock {}

impl Drop for SimLock {
    fn drop(&mut self) {
        lock(&self.fs).locks.remove(&self.path);
    }
}

struct SimHandle {
    fs: Arc<Mutex<Fs>>,
    inode: u64,
    path: PathBuf,
    writable: bool,
}

impl SimHandle {
    fn check_writable(&self) -> io::Result<()> {
        if self.writable { Ok(()) } else { Err(io::ErrorKind::PermissionDenied.into()) }
    }
}

impl Drop for SimHandle {
    fn drop(&mut self) {
        let mut fs = lock(&self.fs);
        fs.open_files = fs.open_files.saturating_sub(1);
    }
}

impl StorageFile for SimHandle {
    fn size(&self) -> io::Result<u64> {
        let mut fs = lock(&self.fs);
        match fs.begin()? {
            Step::Run => {}
            Step::Fail(kind) => return Err(failed(kind)),
            Step::Crash => return Err(crashed()),
        }
        Ok(u64::try_from(fs.machine.file(self.inode)?.data.len()).unwrap_or(u64::MAX))
    }

    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        match fs.begin()? {
            Step::Run => {}
            Step::Fail(kind) => return Err(failed(kind)),
            Step::Crash => return Err(crashed()),
        }
        let count = fs.reads.entry(self.path.clone()).or_default();
        *count = count.saturating_add(1);
        let evict = fs.evict_after_read;
        let file = fs.machine.file(self.inode)?;
        let start = usize::try_from(offset).map_err(|_| io::ErrorKind::UnexpectedEof)?;
        let end = start.checked_add(buf.len()).ok_or(io::ErrorKind::UnexpectedEof)?;
        let src = file.data.get(start..end).ok_or(io::ErrorKind::UnexpectedEof)?;
        buf.copy_from_slice(src);
        if evict {
            file.evict(start, end);
        }
        Ok(())
    }

    fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.check_writable()?;
        let mut fs = lock(&self.fs);
        let step = fs.begin()?;
        let written = match step {
            Step::Run => bytes,
            Step::Fail(_) | Step::Crash => {
                let keep = fs.machine.rng.index(bytes.len().saturating_add(1));
                bytes.get(..keep).unwrap_or_default()
            }
        };
        fs.machine.file(self.inode)?.append(written);
        match step {
            Step::Run => Ok(()),
            Step::Fail(kind) => Err(failed(kind)),
            Step::Crash => Err(crashed()),
        }
    }

    fn truncate(&mut self, size: u64) -> io::Result<()> {
        self.check_writable()?;
        let mut fs = lock(&self.fs);
        let done = match fs.begin()? {
            Step::Run => true,
            Step::Fail(kind) => return Err(failed(kind)),
            Step::Crash => fs.machine.rng.coin(),
        };
        let size = usize::try_from(size).map_err(|_| io::ErrorKind::InvalidInput)?;
        if done {
            fs.machine.file(self.inode)?.set_len(size);
        }
        if fs.crashed { Err(crashed()) } else { Ok(()) }
    }

    fn sync(&mut self, level: SyncLevel) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        let step = fs.begin()?;
        if let (Step::Run, Some((pages, kind))) = (&step, fs.fail_sync) {
            let file = fs.machine.file(self.inode)?;
            if file.dirty.len() >= pages {
                file.failed_sync(None);
                fs.fail_sync = None;
                fs.note_failure();
                return Err(failed(kind));
            }
        }
        let done = match step {
            Step::Run => true,
            Step::Fail(kind) => {
                let Fs { machine, .. } = &mut *fs;
                let file = machine
                    .files
                    .get_mut(&self.inode)
                    .ok_or_else(|| failed(io::ErrorKind::Other))?;
                file.failed_sync(Some(&mut machine.rng));
                return Err(failed(kind));
            }
            Step::Crash => fs.machine.rng.coin(),
        };
        if !fs.crashed {
            let Some(guard) = slow_sync(fs, &self.fs) else { return Err(crashed()) };
            fs = guard;
        }
        if done {
            let number = fs.machine.sync_number(level);
            let last_full = fs.machine.last_full;
            fs.machine.file(self.inode)?.good_sync(number, last_full);
        }
        if fs.crashed { Err(crashed()) } else { Ok(()) }
    }
}
