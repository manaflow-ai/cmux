//! A simulated file system for crash tests (`sim` feature; always in this crate's tests).
//!
//! Each file keeps its current bytes (what a read sees, and what a process crash keeps) apart
//! from the bytes of each sync. Each directory keeps its current entries apart from its synced
//! entries. [`SimStorage::crash_after`] makes the n-th storage operation from now the crash
//! point: an append there writes a random prefix of its bytes (a torn write), any other
//! operation does nothing, and every later operation fails. [`SimStorage::restart`] then builds
//! the storage that the next process sees:
//!
//! - [`Crash::Process`] (kill -9 of any or all processes): every written byte and entry stays.
//! - [`Crash::Os`] (a kernel panic): each file keeps its content at its last sync, plus a random
//!   prefix of what it got since (some of it zeroed or flipped: pages written back out of
//!   order); each directory keeps its synced entries or, at random, its current ones.
//! - [`Crash::PowerLoss`]: as `Os`, but a barrier sync is power-safe only once a later full sync
//!   ran (on any file: a drive cache flush covers every earlier write), so the content of each
//!   file goes back to a random common cut between the last full sync and the crash.
//!
//! A run is deterministic for one seed and one sequence of operations.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use crate::storage::{OpenMode, Storage, StorageFile, StorageLock, SyncLevel};

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
}

/// The simulated file system ([module docs](self)). Clones share one file system.
#[derive(Clone)]
pub struct SimStorage {
    fs: Arc<Mutex<Fs>>,
}

struct SimFile {
    data: Vec<u8>,
    /// (global sync number, content) at each sync, oldest first.
    synced: Vec<(u64, Vec<u8>)>,
}

struct Fs {
    rng: SimRng,
    files: BTreeMap<u64, SimFile>,
    next_inode: u64,
    /// Current and synced directory entries: path to inode.
    names: BTreeMap<PathBuf, u64>,
    durable_names: BTreeMap<PathBuf, u64>,
    dirs: BTreeSet<PathBuf>,
    locks: BTreeSet<PathBuf>,
    /// Storage operations so far, and the one that crashes.
    ops: u64,
    crash_at: Option<u64>,
    /// One operation that fails with this error, once.
    fail_at: Option<(u64, io::ErrorKind)>,
    crashed: bool,
    /// Syncs so far (file and directory), and the number of the last full one.
    syncs: u64,
    last_full: u64,
    /// Each sync sleeps this long (a slow disk, so batches form).
    sync_delay: Duration,
    /// Read operations per path.
    reads: BTreeMap<PathBuf, u64>,
}

enum Step {
    Run,
    Crash,
}

impl Fs {
    /// Counts one operation and says whether it runs, crashes or fails.
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
            return Err(io::Error::new(kind, "simulated I/O failure"));
        }
        Ok(Step::Run)
    }

    fn file(&mut self, inode: u64) -> io::Result<&mut SimFile> {
        self.files.get_mut(&inode).ok_or_else(|| io::Error::other("simulated file is gone"))
    }

    fn sync_number(&mut self, level: SyncLevel) -> u64 {
        self.syncs = self.syncs.saturating_add(1);
        if level == SyncLevel::Full {
            self.last_full = self.syncs;
        }
        self.syncs
    }
}

fn crashed() -> io::Error {
    io::Error::other("simulated crash")
}

fn lock(fs: &Mutex<Fs>) -> std::sync::MutexGuard<'_, Fs> {
    fs.lock().unwrap_or_else(PoisonError::into_inner)
}

impl SimStorage {
    pub fn new(seed: u64) -> Self {
        Self {
            fs: Arc::new(Mutex::new(Fs {
                rng: SimRng::new(seed),
                files: BTreeMap::new(),
                next_inode: 1,
                names: BTreeMap::new(),
                durable_names: BTreeMap::new(),
                dirs: BTreeSet::new(),
                locks: BTreeSet::new(),
                ops: 0,
                crash_at: None,
                fail_at: None,
                crashed: false,
                syncs: 0,
                last_full: 0,
                sync_delay: Duration::ZERO,
                reads: BTreeMap::new(),
            })),
        }
    }

    /// The `n`-th storage operation from now (1 = the next one) is the crash point.
    pub fn crash_after(&self, n: u64) {
        let mut fs = lock(&self.fs);
        fs.crash_at = Some(fs.ops.saturating_add(n.max(1)));
    }

    /// The `n`-th storage operation from now fails once with `kind` (ENOSPC, EIO).
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

    /// The current bytes of `path`, if it exists.
    pub fn contents(&self, path: &Path) -> Option<Vec<u8>> {
        let fs = lock(&self.fs);
        let inode = fs.names.get(path)?;
        fs.files.get(inode).map(|file| file.data.clone())
    }

    /// The names in `dir`, sorted.
    pub fn names_in(&self, dir: &Path) -> Vec<String> {
        let fs = lock(&self.fs);
        fs.names
            .keys()
            .filter(|path| path.parent() == Some(dir))
            .filter_map(|path| path.file_name()?.to_str().map(str::to_owned))
            .collect()
    }

    /// Flips one durable and current byte of `path` (media damage), outside any crash.
    pub fn corrupt(&self, path: &Path, offset: usize) {
        let mut fs = lock(&self.fs);
        let Some(inode) = fs.names.get(path).copied() else { return };
        if let Some(file) = fs.files.get_mut(&inode) {
            if let Some(byte) = file.data.get_mut(offset) {
                *byte ^= 0x5A;
            }
            for (_, content) in &mut file.synced {
                if let Some(byte) = content.get_mut(offset) {
                    *byte ^= 0x5A;
                }
            }
        }
    }

    /// Removes `path` and makes the removal durable (a person deleted the file).
    pub fn remove(&self, path: &Path) {
        let mut fs = lock(&self.fs);
        if let Some(inode) = fs.names.remove(path) {
            fs.durable_names.remove(path);
            fs.files.remove(&inode);
        }
    }

    /// The storage the next process sees after `crash` ([module docs](self)). This one is
    /// crashed from now on: every later operation fails.
    pub fn restart(&self, crash: Crash) -> Self {
        lock(&self.fs).crashed = true;
        self.snapshot(crash)
    }

    /// The storage a process would see after `crash` now, while this one goes on.
    pub fn snapshot(&self, crash: Crash) -> Self {
        let mut old = lock(&self.fs);
        let seed = old.rng.next_u64();
        let mut rng = SimRng::new(seed);
        let cut = match crash {
            Crash::Process | Crash::Os => None,
            Crash::PowerLoss => {
                let span = old.syncs.saturating_sub(old.last_full);
                Some(old.last_full.saturating_add(rng.below(span.saturating_add(1))))
            }
        };
        let names = match crash {
            Crash::Process => old.names.clone(),
            Crash::Os | Crash::PowerLoss => surviving_names(&old, &mut rng),
        };
        let mut files = BTreeMap::new();
        for inode in names.values() {
            if files.contains_key(inode) {
                continue;
            }
            let Some(file) = old.files.get(inode) else { continue };
            let data = match crash {
                Crash::Process => file.data.clone(),
                Crash::Os | Crash::PowerLoss => surviving_bytes(file, cut, &mut rng),
            };
            files.insert(*inode, SimFile { synced: vec![(0, data.clone())], data });
        }
        let next = Fs {
            rng,
            files,
            next_inode: old.next_inode,
            durable_names: names.clone(),
            names,
            dirs: old.dirs.clone(),
            locks: BTreeSet::new(),
            ops: 0,
            crash_at: None,
            fail_at: None,
            crashed: false,
            syncs: 0,
            last_full: 0,
            sync_delay: old.sync_delay,
            reads: BTreeMap::new(),
        };
        Self { fs: Arc::new(Mutex::new(next)) }
    }
}

/// Each directory's synced entries, or at random its current ones (its rename or create may
/// have reached the disk).
fn surviving_names(fs: &Fs, rng: &mut SimRng) -> BTreeMap<PathBuf, u64> {
    let mut parents = BTreeSet::new();
    for path in fs.names.keys().chain(fs.durable_names.keys()) {
        if let Some(parent) = path.parent() {
            parents.insert(parent.to_path_buf());
        }
    }
    let mut out = BTreeMap::new();
    for parent in parents {
        let in_dir = |path: &&PathBuf| path.parent() == Some(parent.as_path());
        let source = if rng.below(2) == 0 { &fs.durable_names } else { &fs.names };
        for (path, inode) in source.iter().filter(|(path, _)| in_dir(path)) {
            out.insert(path.clone(), *inode);
        }
    }
    out
}

/// The content at the last sync (at or before `cut`, for a power loss), plus a random prefix of
/// the bytes appended since, of which a random tail may be zeroed or one byte flipped.
fn surviving_bytes(file: &SimFile, cut: Option<u64>, rng: &mut SimRng) -> Vec<u8> {
    let base = file
        .synced
        .iter()
        .rev()
        .find(|(number, _)| cut.is_none_or(|cut| *number <= cut))
        .map(|(_, content)| content.clone())
        .unwrap_or_default();
    let Some(extra) = file.data.strip_prefix(base.as_slice()) else {
        // A truncation since the sync: it may not have reached the disk.
        return base;
    };
    let keep = rng.index(extra.len().saturating_add(1));
    let mut out = base.clone();
    out.extend_from_slice(extra.get(..keep).unwrap_or_default());
    if keep > 0 {
        match rng.below(3) {
            0 => {
                let from = base.len().saturating_add(rng.index(keep));
                if let Some(tail) = out.get_mut(from..) {
                    tail.fill(0);
                }
            }
            1 => {
                let at = base.len().saturating_add(rng.index(keep));
                if let Some(byte) = out.get_mut(at) {
                    *byte ^= 0xA5;
                }
            }
            _ => {}
        }
    }
    out
}

impl Storage for SimStorage {
    fn create_dir_all(&self, dir: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        for ancestor in dir.ancestors() {
            fs.dirs.insert(ancestor.to_path_buf());
        }
        Ok(())
    }

    fn list(&self, dir: &Path) -> io::Result<Vec<String>> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        if !fs.dirs.contains(dir) {
            return Err(io::ErrorKind::NotFound.into());
        }
        let mut out = Vec::new();
        for path in fs.names.keys() {
            if path.parent() == Some(dir)
                && let Some(name) = path.file_name().and_then(|name| name.to_str())
            {
                out.push(name.to_owned());
            }
        }
        for path in &fs.dirs {
            if path.parent() == Some(dir)
                && let Some(name) = path.file_name().and_then(|name| name.to_str())
            {
                out.push(name.to_owned());
            }
        }
        Ok(out)
    }

    fn open(&self, path: &Path, mode: OpenMode) -> io::Result<Box<dyn StorageFile>> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
        if !fs.dirs.contains(&parent) {
            return Err(io::ErrorKind::NotFound.into());
        }
        let inode = match (fs.names.get(path).copied(), mode) {
            (Some(inode), OpenMode::Create) => {
                fs.file(inode)?.data.clear();
                inode
            }
            (Some(inode), OpenMode::Read | OpenMode::Write) => inode,
            (None, OpenMode::Create) => {
                let inode = fs.next_inode;
                fs.next_inode = inode.saturating_add(1);
                fs.files.insert(inode, SimFile { data: Vec::new(), synced: Vec::new() });
                fs.names.insert(path.to_path_buf(), inode);
                inode
            }
            (None, OpenMode::Read | OpenMode::Write) => return Err(io::ErrorKind::NotFound.into()),
        };
        Ok(Box::new(SimHandle {
            fs: self.fs.clone(),
            inode,
            path: path.to_path_buf(),
            writable: mode != OpenMode::Read,
        }))
    }

    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        let parent = to.parent().map(Path::to_path_buf).unwrap_or_default();
        if !fs.dirs.contains(&parent) {
            return Err(io::ErrorKind::NotFound.into());
        }
        let inode = fs.names.remove(from).ok_or(io::ErrorKind::NotFound)?;
        fs.names.insert(to.to_path_buf(), inode);
        Ok(())
    }

    fn sync_dir(&self, dir: &Path) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        let delay = fs.sync_delay;
        if !delay.is_zero() {
            drop(fs);
            std::thread::sleep(delay);
            fs = lock(&self.fs);
            if fs.crashed {
                return Err(crashed());
            }
        }
        fs.durable_names.retain(|path, _| path.parent() != Some(dir));
        let current: Vec<(PathBuf, u64)> = fs
            .names
            .iter()
            .filter(|(path, _)| path.parent() == Some(dir))
            .map(|(path, inode)| (path.clone(), *inode))
            .collect();
        fs.durable_names.extend(current);
        // A directory sync flushes the drive like a full sync (FsStorage uses F_FULLFSYNC).
        fs.sync_number(SyncLevel::Full);
        Ok(())
    }

    fn try_lock(&self, path: &Path) -> io::Result<Option<Box<dyn StorageLock>>> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
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

impl StorageFile for SimHandle {
    fn size(&self) -> io::Result<u64> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        Ok(u64::try_from(fs.file(self.inode)?.data.len()).unwrap_or(u64::MAX))
    }

    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        let count = fs.reads.entry(self.path.clone()).or_default();
        *count = count.saturating_add(1);
        let file = fs.file(self.inode)?;
        let start = usize::try_from(offset).map_err(|_| io::ErrorKind::UnexpectedEof)?;
        let end = start.checked_add(buf.len()).ok_or(io::ErrorKind::UnexpectedEof)?;
        let src = file.data.get(start..end).ok_or(io::ErrorKind::UnexpectedEof)?;
        buf.copy_from_slice(src);
        Ok(())
    }

    fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.check_writable()?;
        let mut fs = lock(&self.fs);
        match fs.begin()? {
            Step::Run => {
                fs.file(self.inode)?.data.extend_from_slice(bytes);
                Ok(())
            }
            Step::Crash => {
                let keep = fs.rng.index(bytes.len().saturating_add(1));
                fs.file(self.inode)?.data.extend_from_slice(bytes.get(..keep).unwrap_or_default());
                Err(crashed())
            }
        }
    }

    fn truncate(&mut self, size: u64) -> io::Result<()> {
        self.check_writable()?;
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        let size = usize::try_from(size).map_err(|_| io::ErrorKind::InvalidInput)?;
        fs.file(self.inode)?.data.truncate(size);
        Ok(())
    }

    fn sync(&mut self, level: SyncLevel) -> io::Result<()> {
        let mut fs = lock(&self.fs);
        if let Step::Crash = fs.begin()? {
            return Err(crashed());
        }
        let delay = fs.sync_delay;
        if !delay.is_zero() {
            drop(fs);
            std::thread::sleep(delay);
            fs = lock(&self.fs);
            if fs.crashed {
                return Err(crashed());
            }
        }
        let number = fs.sync_number(level);
        let file = fs.file(self.inode)?;
        let content = file.data.clone();
        file.synced.push((number, content));
        Ok(())
    }
}
