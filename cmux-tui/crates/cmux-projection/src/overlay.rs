//! The machine's view of a projected folder: the manifest's tree (the lower layer, read only, its
//! bytes fetched from the Mac on first read) under an upper folder on the machine's disk that holds
//! everything the agent writes. Every `stat` and listing of the lower layer is answered from the
//! manifest. The mount ([`crate::mount`], Linux) calls these ops; they are plain `&self` methods,
//! safe from many threads, and never hold a lock across a fetch.
//!
//! The upper layer is a plain folder and keeps every POSIX property of what lands there: owner,
//! group, permission bits (set-id and sticky included), the three times, hard links, fifos,
//! sockets and device nodes. Its calls go through [`Upper`], one name at a time, so a path of any
//! length works. An open file is read and written through its own descriptor ([`Overlay::open_handle`]),
//! so it keeps working after it is renamed or deleted, as on any disk.
//!
//! The state folder holds:
//! - `upper/`: every file or folder the agent made or changed, at its relative path;
//! - `whiteouts`: lower paths the agent deleted or renamed away, each ended by a NUL (a name may
//!   hold a newline; an older file of newline-ended lines still reads). A new one is appended; the
//!   file is rewritten only when one goes away, so deleting a big lower tree is linear in its
//!   size, not quadratic, and a path without its end (a crash inside an append) is no whiteout;
//! - `cache/`: lower bytes fetched from the Mac, whole files as `cache/<entry>` and the chunks of a
//!   big file as `cache/<entry>.<chunk>`, with `cache/manifest-id` naming the manifest they belong
//!   to (a new manifest starts a fresh cache). The cache holds only clean copies of the Mac's
//!   bytes, so it is capped ([`DEFAULT_CACHE_MAX_BYTES`], [`Overlay::with_cache_max`]): before a
//!   new blob is admitted the least recently used ones go, and a later read fetches them again.
//!   A pinned folder's bytes ([`Overlay::pin`], the `pins` file) are kept apart: fetched whole,
//!   never evicted and not counted against the cap, so they read with the Mac away.
//!   Each cached blob is a hard link into `content/` ([`content`], RFD 0065 piece 5): every
//!   fetched blob by the hash of its bytes, sized to the free disk and kept across listings, so a
//!   blob the cap let go or a new listing forgot is read off the disk again, not fetched.
//!   The upper layer is never evicted; it goes only once its edits are safe ([`crate::state`],
//!   [`crate::reap`]).

use anyhow::Context as _;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::Write as _;
use std::os::fd::AsRawFd as _;
use std::os::unix::fs::{FileExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, RwLock};
use std::time::{Duration, Instant, UNIX_EPOCH};

use crate::lower::Lower;
use crate::manifest::{Entry, Kind, Manifest, ROOT};
use crate::upper::{RENAME_EXCHANGE, RENAME_NOREPLACE, SetTime, Stat, Upper, fmt};
use crate::wire::Restat;
use crate::{Fetch, FetchError, Fetched};

/// Not an `errno`: the file was re-listed during the read, which starts over at its new version.
const RETRY: i32 = -1;
/// How many times a read starts over after the file changed under it, before it fails with EIO
/// (a file rewritten all the time).
const RETRIES: u32 = 2;
/// The file in `cache/` that keeps the re-listed stats (RFD 0007, hard case 7).
const RESTATED_FILE: &str = "restated";

#[path = "overlay_room.rs"]
mod room;

/// The size of a chunk of a big file, and the largest file fetched whole.
pub const CHUNK: u64 = 4 * 1024 * 1024;

/// What one uncached read of a big git pack fetches at least ([`Overlay::pack_range`]).
pub const PACK_BLOCK: u64 = 128 * 1024;

/// The first cache part of a pack's blocks (chunk numbers stay far below it).
const PACK_BLOCKS: u32 = 1 << 31;

/// A git pack (`.git/objects/pack/*.pack`, the folder's own repository or a nested one).
fn is_git_pack(path: &str) -> bool {
    path.ends_with(".pack")
        && path.rsplit_once('/').is_some_and(|(dir, _)| {
            dir == ".git/objects/pack" || dir.ends_with("/.git/objects/pack")
        })
}

/// The most files one readahead batch asks for, by default ([`crate::tune::readahead_files`]).
const BATCH_FILES: usize = crate::tune::DEFAULT_READAHEAD_FILES;
/// The most entries one readahead pick looks at, skipped ones included, so a fault never walks a
/// big folder for nothing.
const BATCH_SCAN: usize = 4096;
/// The files that mark a project's folder: a fault's read-ahead takes the files of the marked
/// folders beside its own (see [`read_ahead`]).
const MARKERS: [&str; 2] = ["Cargo.toml", "package.json"];
/// The most bytes of the Mac's files one projection keeps cached on the machine's disk (RFD 0007,
/// hard case 8).
pub const DEFAULT_CACHE_MAX_BYTES: u64 = 512 * 1024 * 1024;
/// The cache's own file naming the manifest it belongs to (never evicted).
pub const CACHE_ID_FILE: &str = "manifest-id";

/// `errno` values, the system's own numbers (Linux's under the FUSE mount, macOS's under the NFS
/// one).
pub mod errno {
    pub const EPERM: i32 = libc::EPERM;
    pub const ENOENT: i32 = libc::ENOENT;
    pub const EIO: i32 = libc::EIO;
    pub const EBADF: i32 = libc::EBADF;
    pub const EACCES: i32 = libc::EACCES;
    pub const EEXIST: i32 = libc::EEXIST;
    pub const EXDEV: i32 = libc::EXDEV;
    pub const ENOTDIR: i32 = libc::ENOTDIR;
    pub const EISDIR: i32 = libc::EISDIR;
    pub const EINVAL: i32 = libc::EINVAL;
    pub const ENAMETOOLONG: i32 = libc::ENAMETOOLONG;
    pub const ENOTEMPTY: i32 = libc::ENOTEMPTY;
    pub const ENOSPC: i32 = libc::ENOSPC;
}
use errno::{
    EACCES, EBADF, EEXIST, EINVAL, EIO, EISDIR, ENAMETOOLONG, ENOENT, ENOTDIR, ENOTEMPTY, EPERM,
    EXDEV,
};
/// The longest name a folder holds, in bytes (Linux's `NAME_MAX`).
const NAME_MAX: usize = 255;

/// Which file (entry) and which part of it: a chunk number, or [`WHOLE`] / [`COPY_UP`].
type Key = (u32, u32);
const WHOLE: u32 = u32::MAX;
const COPY_UP: u32 = u32::MAX - 1;

/// What a path is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Type {
    File,
    Dir,
    Link,
    Fifo,
    Socket,
    Char,
    Block,
}

impl Type {
    fn of_kind(kind: Kind) -> Self {
        match kind {
            Kind::File => Self::File,
            Kind::Dir => Self::Dir,
            Kind::Link => Self::Link,
        }
    }

    /// The type an `st_mode`'s `S_IFMT` bits name.
    #[must_use]
    pub fn of_mode(mode: u32) -> Self {
        match mode & fmt::S_IFMT {
            fmt::S_IFDIR => Self::Dir,
            fmt::S_IFLNK => Self::Link,
            fmt::S_IFIFO => Self::Fifo,
            fmt::S_IFSOCK => Self::Socket,
            fmt::S_IFCHR => Self::Char,
            fmt::S_IFBLK => Self::Block,
            _ => Self::File,
        }
    }
}

/// One path's attributes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Attr {
    pub ino: u64,
    pub kind: Type,
    pub size: u64,
    /// 512-byte blocks the bytes take.
    pub blocks: u64,
    /// Permission bits, set-id and sticky bits included (`0o7777` at most).
    pub mode: u32,
    pub atime_ns: i64,
    pub mtime_ns: i64,
    pub ctime_ns: i64,
    pub nlink: u32,
    pub uid: u32,
    pub gid: u32,
    pub rdev: u64,
    /// Whether the path is in the upper folder (the machine's disk), not only in the manifest.
    pub upper: bool,
}

/// What a file's bytes are at one moment. A lower file is its manifest entry (fixed for the life
/// of an [`Overlay`]: a new manifest is a new mount); an upper file is its inode on the machine's
/// disk with its size and times, which every write moves (with multigrain timestamps a write after
/// a `stat` always gets a new `ctime`). Equal versions mean the same bytes, so the mount lets the
/// kernel keep the pages it cached since the earlier open (`FOPEN_KEEP_CACHE`) and drops them on
/// any other.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Version {
    Lower { entry: u32, size: u64, mtime_ns: i64 },
    Upper { dev: u64, ino: u64, size: u64, mtime_ns: i64, ctime_ns: i64 },
}

/// Who asks: the caller's file system user and group (what a new path is owned by).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Who {
    pub uid: u32,
    pub gid: u32,
}

/// What a `setattr` changes; `None` leaves a field alone.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Set {
    pub size: Option<u64>,
    pub mode: Option<u32>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub atime: Option<SetTime>,
    pub mtime: Option<SetTime>,
}

/// How many reads went to the Mac, how many bytes came back, and how many reads the cache served.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub remote_reads: u64,
    pub remote_bytes: u64,
    pub cache_hits: u64,
}

/// The cached blobs, least recently used first, and their bytes; a pinned file's blobs apart.
#[derive(Default)]
struct CacheIndex {
    /// Each blob's bytes and the tick it was last used at.
    blobs: HashMap<Key, (u64, u64)>,
    order: BTreeMap<u64, Key>,
    bytes: u64,
    tick: u64,
    /// Files under a pin: their blobs go to `kept`, never to the LRU.
    pinned: HashSet<u32>,
    kept: HashMap<Key, u64>,
    kept_bytes: u64,
}

impl CacheIndex {
    fn insert(&mut self, key: Key, bytes: u64) {
        self.remove(key);
        if self.pinned.contains(&key.0) {
            self.kept.insert(key, bytes);
            self.kept_bytes += bytes;
            return;
        }
        self.tick += 1;
        self.blobs.insert(key, (bytes, self.tick));
        self.order.insert(self.tick, key);
        self.bytes += bytes;
    }

    fn touch(&mut self, key: Key) {
        if let Some(&(bytes, _)) = self.blobs.get(&key) {
            self.insert(key, bytes);
        }
    }

    fn remove(&mut self, key: Key) -> Option<u64> {
        if let Some(bytes) = self.kept.remove(&key) {
            self.kept_bytes = self.kept_bytes.saturating_sub(bytes);
            return Some(bytes);
        }
        let (bytes, tick) = self.blobs.remove(&key)?;
        self.order.remove(&tick);
        self.bytes = self.bytes.saturating_sub(bytes);
        Some(bytes)
    }

    fn oldest(&self) -> Option<Key> {
        self.order.values().next().copied()
    }

    /// Whether `key`'s bytes are on disk, by the index alone.
    fn has(&self, key: Key) -> bool {
        self.kept.contains_key(&key) || self.blobs.contains_key(&key)
    }

    /// Pins `files`: their blobs already cached leave the LRU for `kept`.
    fn pin(&mut self, files: &HashSet<u32>) {
        self.pinned.extend(files.iter().copied());
        let moving: Vec<(Key, u64)> = self
            .blobs
            .iter()
            .filter(|(key, _)| files.contains(&key.0))
            .map(|(key, (bytes, _))| (*key, *bytes))
            .collect();
        for (key, bytes) in moving {
            self.insert(key, bytes);
        }
    }

    /// Unpins `files`: their kept blobs join the LRU as the most recently used.
    fn unpin(&mut self, files: &HashSet<u32>) {
        self.pinned.retain(|file| !files.contains(file));
        let moving: Vec<(Key, u64)> = self
            .kept
            .iter()
            .filter(|(key, _)| files.contains(&key.0))
            .map(|(key, bytes)| (*key, *bytes))
            .collect();
        for (key, bytes) in moving {
            self.insert(key, bytes);
        }
    }
}

/// The key a cache file's name stands for (`<entry>` or `<entry>.<chunk>`).
fn cache_key(name: &str) -> Option<Key> {
    match name.split_once('.') {
        None => Some((name.parse().ok()?, WHOLE)),
        Some((index, part)) => Some((index.parse().ok()?, part.parse().ok()?)),
    }
}

/// What an earlier daemon cached in `cache`, oldest written first.
fn cache_on_disk(cache: &Path) -> CacheIndex {
    use std::os::unix::fs::MetadataExt as _;
    let mut blobs: Vec<(i64, Key, u64)> = fs::read_dir(cache)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let key = cache_key(entry.file_name().to_str()?)?;
            let meta = entry.metadata().ok()?;
            let written = meta.mtime().saturating_mul(1_000_000_000) + meta.mtime_nsec();
            meta.is_file().then_some((written, key, meta.len()))
        })
        .collect();
    blobs.sort_unstable();
    let mut index = CacheIndex::default();
    for (_, key, bytes) in blobs {
        index.insert(key, bytes);
    }
    index
}

/// The re-listed stats `cache/restated` kept (`entry size mtime_ns mode` per line), each with a
/// generation of its own; a line that does not parse is left out (its file is fetched again).
fn load_restated(file: &Path) -> HashMap<u32, (Restat, u64)> {
    let text = fs::read_to_string(file).unwrap_or_default();
    text.lines()
        .filter_map(|line| {
            let mut words = line.split(' ');
            let entry = words.next()?.parse().ok()?;
            let size = words.next()?.parse().ok()?;
            let mtime_ns = words.next()?.parse().ok()?;
            let mode = words.next()?.parse().ok()?;
            Some((entry, Restat { size, mtime_ns, mode }))
        })
        .zip(1u64..)
        .map(|((entry, stat), generation)| (entry, (stat, generation)))
        .collect()
}

/// The names in `inos` that start with `prefix` (a folder's `<path>/`), in order: they sort
/// together, so the walk starts at the prefix and stops at the first name past it.
fn names_below(inos: &BTreeMap<String, u64>, prefix: &str) -> Vec<(String, u64)> {
    inos.range::<str, _>((std::ops::Bound::Included(prefix), std::ops::Bound::Unbounded))
        .take_while(|(path, _)| path.starts_with(prefix))
        .map(|(path, ino)| (path.clone(), *ino))
        .collect()
}

/// Where a path lives now.
enum Node {
    Upper(Stat),
    Lower(u32),
}

#[derive(Default)]
struct Inner {
    whiteouts: BTreeSet<String>,
    /// Numbers whose path is not the manifest's own: upper-only paths, lower paths moved by a
    /// rename, and a hard-linked file's surviving name.
    paths: HashMap<u64, String>,
    /// Ordered, so a rename finds the names below the moved path by one range walk
    /// ([`names_below`]), not a walk of every upper-only name (a build tree holds 100k).
    inos: BTreeMap<String, u64>,
    /// The number of each upper file (by device and inode), so every name of a hard-linked file
    /// and a lower file copied up keep one number.
    by_upper: HashMap<(u64, u64), u64>,
    /// Numbers of paths deleted: never given out again (the kernel may still hold one for an open
    /// file, and must never see a new file under an old number).
    dead: HashSet<u64>,
    next: u64,
    /// Lower folders a swap put a link in place of ([`Overlay::swap_to_link`]), by their old
    /// number: a process that already holds one goes on reading the manifest's tree below it.
    retired: HashMap<u64, u32>,
}

/// An open file: its number, and the upper file's descriptor when it has one (a lower file
/// opened for reading has none until a write copies it up).
struct Handle {
    ino: u64,
    file: Option<Arc<fs::File>>,
    /// The manifest entry a read-only handle of a lower file was opened on: it keeps reading
    /// those bytes after the path is deleted, as an open file on a disk does.
    lower: Option<u32>,
}

struct MutationGate {
    state: Mutex<MutationState>,
    drained: Condvar,
    #[cfg(test)]
    pause: Mutex<Option<TestMutationPause>>,
}

struct MutationState {
    sealed: bool,
    active: usize,
    /// A write can hold a descriptor or a transaction between FUSE requests. Once any
    /// mutation was admitted, replacing a directory can strand that later work.
    admitted: bool,
    replacing: bool,
}

#[cfg(test)]
struct TestMutationPause {
    entered: std::sync::mpsc::Sender<()>,
    release: std::sync::mpsc::Receiver<()>,
}

struct MutationGuard<'a> {
    gate: &'a MutationGate,
    replacing: bool,
}

impl MutationGuard<'_> {
    fn replacement_committed(&self) {
        debug_assert!(self.replacing);
        self.gate.state.lock().unwrap_or_else(PoisonError::into_inner).admitted = true;
    }
}

impl Drop for MutationGuard<'_> {
    fn drop(&mut self) {
        let mut state = self.gate.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.active -= 1;
        if self.replacing {
            state.replacing = false;
        }
        if state.active == 0 {
            self.gate.drained.notify_all();
        }
    }
}

impl MutationGate {
    fn new() -> Self {
        Self {
            state: Mutex::new(MutationState {
                sealed: false,
                active: 0,
                admitted: false,
                replacing: false,
            }),
            drained: Condvar::new(),
            #[cfg(test)]
            pause: Mutex::new(None),
        }
    }

    fn enter(&self) -> Result<MutationGuard<'_>, i32> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        while state.replacing && !state.sealed {
            state = self.drained.wait(state).unwrap_or_else(PoisonError::into_inner);
        }
        if state.sealed {
            return Err(libc::EROFS);
        }
        state.admitted = true;
        state.active += 1;
        let admitted = MutationGuard { gate: self, replacing: false };
        drop(state);
        #[cfg(test)]
        let pause = { self.pause.lock().unwrap_or_else(PoisonError::into_inner).take() };
        #[cfg(test)]
        if let Some(pause) = pause {
            let _ = pause.entered.send(());
            let _ = pause.release.recv();
        }
        Ok(admitted)
    }

    /// An opportunistic directory replacement may run only before the first mutation.
    /// The guard excludes other admissions without holding the mutex across filesystem
    /// work, so a concurrent seal still has a bounded wait. A fingerprint alone cannot
    /// protect an open temporary file or a Git transaction.
    fn replace_pristine(&self) -> Result<MutationGuard<'_>, i32> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.sealed {
            return Err(libc::EROFS);
        }
        if state.admitted || state.replacing {
            return Err(libc::EBUSY);
        }
        state.replacing = true;
        state.active += 1;
        Ok(MutationGuard { gate: self, replacing: true })
    }

    fn seal(&self, timeout: Duration) -> bool {
        let started = Instant::now();
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        // Sticky even on timeout: a concurrent or retried detach must never reopen admission.
        state.sealed = true;
        self.drained.notify_all();
        while state.active != 0 {
            let remaining = timeout.saturating_sub(started.elapsed());
            if remaining.is_zero() {
                return false;
            }
            let (next, _) =
                self.drained.wait_timeout(state, remaining).unwrap_or_else(PoisonError::into_inner);
            state = next;
        }
        true
    }

    fn is_sealed(&self) -> bool {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).sealed
    }

    #[cfg(test)]
    fn pause_next(&self) -> (std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
        let (entered, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release) = std::sync::mpsc::channel();
        *self.pause.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(TestMutationPause { entered, release });
        (entered_rx, release_tx)
    }
}

/// One folder entry: inode, type, name, and its attributes when the manifest alone answers them.
pub type Listed = (u64, Type, String, Option<Attr>);

/// A projected folder as the machine sees it.
pub struct Overlay {
    /// The lower layer: the manifest the overlay opened on, and the fuller one after
    /// [`Overlay::extend`] (ids stay the same, [`crate::lower`]).
    manifest: Lower,
    fetch: Arc<dyn Fetch>,
    owner: (u32, u32),
    upper: Upper,
    cache: PathBuf,
    scratch: PathBuf,
    whiteouts_file: PathBuf,
    /// The whiteouts file may end in a torn entry (an append and both its repairs failed): the
    /// next change writes the whole file, not one more entry.
    whiteouts_stale: AtomicBool,
    inner: Mutex<Inner>,
    handles: Mutex<HashMap<u64, Handle>>,
    next_handle: AtomicU64,
    inflight: Mutex<HashSet<Key>>,
    landed: Condvar,
    temp: AtomicU64,
    /// Unique to this overlay (see [`Overlay::scratch_path`]).
    temp_prefix: u64,
    remote_reads: AtomicU64,
    remote_bytes: AtomicU64,
    cache_hits: AtomicU64,
    /// Files kept on the Mac whose refusal was logged already (once each, not once per open).
    told: Mutex<HashSet<u32>>,
    /// Told of every read the agent asked for that failed because the Mac is away.
    away: Option<Arc<crate::away::Away>>,
    cache_index: Mutex<CacheIndex>,
    cache_max: u64,
    /// Every fetched blob by the hash of its bytes, kept across listings ([`content`]); `None`
    /// for a source that is not cached, or a store that could not be made.
    content: Option<content::Content>,
    cache_evicted: AtomicU64,
    /// A failed cache store means readahead would repeatedly fetch bytes it cannot retain.
    cache_failing: AtomicBool,
    /// The pinned paths, written to `pins_file` (one per NUL) on every change.
    pins: Mutex<BTreeSet<String>>,
    pins_file: PathBuf,
    /// The free disk a pin leaves untouched ([`pin::DEFAULT_PIN_RESERVE`]).
    pin_reserve: u64,
    /// Held for reading while a name is looked up, and for writing while a swap
    /// replaces one ([`Overlay::swap_to_link`]), so no lookup pairs the old kind with the new
    /// number.
    swap: RwLock<()>,
    mutation: MutationGate,
    /// The access list this overlay records and replays ([`replay`]); `None` unless
    /// [`Overlay::with_replay`] asked for it.
    replay: Option<replay::Replay>,
    /// Files the Mac re-listed after a change: their stat now, and a generation that changes with
    /// each re-listing (bytes fetched under an older one are not cached).
    restated: Mutex<HashMap<u32, (Restat, u64)>>,
    generation: AtomicU64,
    /// Empty files a fault at open found unchanged (they have no bytes to cache).
    checked_empty: Mutex<HashSet<u32>>,
    /// Inodes re-listed since the mount last asked, for it to tell the kernel.
    to_invalidate: Mutex<Vec<u64>>,
}

/// Keys this thread is fetching; dropping it lets others waiting on them go on.
struct Claim<'a> {
    overlay: &'a Overlay,
    keys: Vec<Key>,
}

impl Drop for Claim<'_> {
    fn drop(&mut self) {
        let mut inflight = self.overlay.inflight.lock().unwrap_or_else(PoisonError::into_inner);
        for key in &self.keys {
            inflight.remove(key);
        }
        drop(inflight);
        self.overlay.landed.notify_all();
    }
}

/// The log line's words for a file kept on the Mac for `reason`.
fn kept_text(reason: &str) -> String {
    format!("kept on the Mac ({reason}); `cmux link access request PATH` asks the person for it")
}

fn io_errno(error: &std::io::Error) -> i32 {
    error.raw_os_error().unwrap_or(EIO)
}

fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() { name.to_owned() } else { format!("{parent}/{name}") }
}

/// FNV-1a over `bytes`: the manifest's id in the cache (stable across builds).
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

fn check(ret: libc::c_int) -> Result<(), i32> {
    if ret < 0 {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(EIO))
    } else {
        Ok(())
    }
}

fn fd_chmod(file: &fs::File, mode: u32) -> Result<(), i32> {
    // SAFETY: the descriptor is open for the call.
    check(unsafe { libc::fchmod(file.as_raw_fd(), crate::upper::mode_t(mode & 0o7777)) })
}

fn fd_chown(file: &fs::File, uid: u32, gid: u32) -> Result<(), i32> {
    // SAFETY: the descriptor is open for the call.
    check(unsafe { libc::fchown(file.as_raw_fd(), uid, gid) })
}

fn fd_utimes(file: &fs::File, atime: Option<SetTime>, mtime: Option<SetTime>) -> Result<(), i32> {
    let spec = |time: Option<SetTime>| match time {
        None => libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_OMIT },
        Some(SetTime::Now) => libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_NOW },
        Some(SetTime::At(ns)) => libc::timespec {
            tv_sec: ns.div_euclid(1_000_000_000),
            tv_nsec: ns.rem_euclid(1_000_000_000),
        },
    };
    let times = [spec(atime), spec(mtime)];
    // SAFETY: the descriptor is open and `times` has the two elements futimens reads.
    check(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })
}

/// Reads up to `size` bytes at `offset`, fewer at the end of the file.
fn read_at(file: &fs::File, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
    let mut bytes = vec![0u8; size as usize];
    let mut got = 0usize;
    while let Some(rest) = bytes.get_mut(got..).filter(|rest| !rest.is_empty()) {
        match file.read_at(rest, offset.saturating_add(got as u64)) {
            Ok(0) => break,
            Ok(read) => got += read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(io_errno(&error)),
        }
    }
    bytes.truncate(got);
    Ok(bytes)
}

/// `len` bytes of `file` at `offset`, or `None` when it has fewer (a damaged cache file).
fn read_range(file: &fs::File, offset: u64, len: usize) -> Option<Vec<u8>> {
    let mut bytes = vec![0u8; len];
    let mut filled = 0;
    while filled < len {
        match file.read_at(bytes.get_mut(filled..)?, offset + filled as u64) {
            Ok(0) => return None,
            Ok(read) => filled += read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
    Some(bytes)
}

/// The whole whiteouts of `bytes` (each ended by a NUL, or by a newline in an older file); a last
/// one without its end is a torn append, cut off as bytes (a crash can tear a name inside a
/// multi-byte character). Each entry is decoded alone: one that is not UTF-8 is skipped, never
/// the file with it. Says too whether the file must be written again (a torn tail to cut, an
/// entry skipped, or the older format, so the next append starts an entry of its own).
fn parse_whiteouts(bytes: &[u8]) -> (BTreeSet<String>, bool) {
    let ends = if bytes.contains(&0) { 0 } else { b'\n' };
    let mut skipped = false;
    let whole = bytes
        .split_inclusive(|byte| *byte == ends)
        .filter_map(|path| path.strip_suffix(&[ends]))
        .filter(|path| !path.is_empty())
        .filter_map(|path| {
            let path = String::from_utf8(path.to_vec()).ok();
            skipped |= path.is_none();
            path
        })
        .collect();
    (whole, !bytes.is_empty() && (ends != 0 || bytes.last() != Some(&0) || skipped))
}

/// Appends `bytes` to `file` through `write`; when that fails part way (a full disk), cuts the
/// file back to where it was, so no unterminated entry is left for the next append to glue onto.
fn append_entry(
    file: &mut fs::File,
    bytes: &[u8],
    write: impl FnOnce(&mut fs::File, &[u8]) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let len = file.metadata()?.len();
    let written = write(file, bytes);
    if written.is_err() {
        // A cut that fails too leaves the caller's full rewrite to end the torn entry.
        file.set_len(len)?;
    }
    written
}

/// Whether `folder` holds a [`MARKERS`] file (a project's folder).
fn marked(manifest: &Lower, folder: u32) -> bool {
    MARKERS.iter().any(|name| {
        manifest
            .lookup(folder, name)
            .and_then(|child| manifest.entry(child))
            .is_some_and(|child| child.kind == Kind::File)
    })
}

/// The small files a fault on file `index` reads ahead with it, in the order to ask for them: the
/// other files of its own folder, then the files (not the subfolders) of each folder beside its
/// own, in name order, that holds a [`MARKERS`] file. A build reads one project folder after
/// another (cargo reads every workspace member's `Cargo.toml`, a resolver every package's
/// `package.json`), one round trip each when only the own folder is read ahead; the folders under
/// a project (its sources) are left for their own faults, as most are never read.
///
/// `skip` names what is not to be read (a hidden path, and for a file a cached one); a skipped
/// folder is not looked into. The faulting file's size counts against
/// [`crate::tune::readahead_bytes`], the batch
/// holds at most [`BATCH_FILES`] files with the faulting one, and a pick looks at most
/// [`BATCH_SCAN`] entries. Each folder is looked into once, so no file is picked twice.
fn read_ahead(manifest: &Lower, index: u32, skip: impl Fn(u32, &Entry) -> bool) -> Vec<u32> {
    let Some(faulting) = manifest.entry(index) else { return Vec::new() };
    let own = faulting.parent;
    let mut pick =
        Pick { manifest, index, skip, picked: Vec::new(), bytes: faulting.size, scanned: 0 };
    pick.files(own);
    if own == ROOT {
        return pick.picked;
    }
    let Some(up) = manifest.parent(own) else { return pick.picked };
    for (other, folder) in manifest.children(up) {
        if pick.full() {
            break;
        }
        pick.scanned += 1;
        if folder.kind != Kind::Dir
            || other == own
            || (pick.skip)(other, folder)
            || !marked(manifest, other)
        {
            continue;
        }
        pick.files(other);
    }
    pick.picked
}

/// The state of one [`read_ahead`] walk.
struct Pick<'a, F> {
    manifest: &'a Lower,
    index: u32,
    skip: F,
    picked: Vec<u32>,
    bytes: u64,
    scanned: usize,
}

impl<F: Fn(u32, &Entry) -> bool> Pick<'_, F> {
    fn full(&self) -> bool {
        self.picked.len() + 1 >= crate::tune::readahead_files() || self.scanned >= BATCH_SCAN
    }

    /// Looks at the children of `folder` in name order and takes its small files.
    fn files(&mut self, folder: u32) {
        for (other, child) in self.manifest.children(folder) {
            if self.full() {
                return;
            }
            self.scanned += 1;
            if (self.skip)(other, child) {
                continue;
            }
            if child.kind == Kind::File
                && other != self.index
                && child.size <= CHUNK
                && self.bytes + child.size <= crate::tune::readahead_bytes()
            {
                self.bytes += child.size;
                self.picked.push(other);
            }
        }
    }
}

impl Overlay {
    /// The overlay of `manifest` with its state in `state`, fetching bytes through `fetch`, every
    /// lower path owned by `owner` (uid, gid).
    pub fn open(
        manifest: Arc<Manifest>,
        state: &Path,
        fetch: Arc<dyn Fetch>,
        owner: (u32, u32),
    ) -> anyhow::Result<Self> {
        let upper = Upper::open(&state.join("upper"))?;
        let cache = state.join("cache");
        let scratch = state.join("scratch");
        let whiteouts_file = state.join("whiteouts");
        let id = format!("{:016x}\n", fnv(&bincode::serialize(manifest.as_ref())?));
        let id_file = cache.join(CACHE_ID_FILE);
        if fs::read_to_string(&id_file).ok().as_deref() != Some(id.as_str()) {
            if cache.exists() {
                fs::remove_dir_all(&cache)?;
            }
            fs::create_dir_all(&cache)?;
            fs::write(&id_file, &id)?;
        }
        if scratch.exists() {
            fs::remove_dir_all(&scratch)?;
        }
        fs::create_dir_all(&scratch)?;
        // Only a file not there is no whiteouts: one that cannot be read fails the open, never
        // shows every deleted lower path again.
        let bytes = match fs::read(&whiteouts_file) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            read => read.with_context(|| format!("reading {}", whiteouts_file.display()))?,
        };
        let (whiteouts, rewrite) = parse_whiteouts(&bytes);
        let next = manifest.len() as u64 + 2;
        let cache_index = Mutex::new(cache_on_disk(&cache));
        let content =
            if fetch.cache() { content::Content::open(&state.join("content")) } else { None };
        // RFD 0065 piece 12: no shared store unless the environment turns one on.
        let content = content.map(|content| content.with_shared(shared::from_env()));
        let pins_file = state.join(pin::PINS_FILE);
        let pins = pin::read_pins(&pins_file)?;
        let restated = load_restated(&cache.join(RESTATED_FILE));
        let generation = AtomicU64::new(restated.len() as u64 + 1);
        let overlay = Self {
            manifest: Lower::new(manifest),
            fetch,
            owner,
            upper,
            cache,
            scratch,
            whiteouts_file,
            whiteouts_stale: AtomicBool::new(false),
            inner: Mutex::new(Inner { whiteouts, next, ..Inner::default() }),
            handles: Mutex::new(HashMap::new()),
            next_handle: AtomicU64::new(1),
            inflight: Mutex::new(HashSet::new()),
            landed: Condvar::new(),
            temp: AtomicU64::new(0),
            temp_prefix: {
                static OPENED: AtomicU64 = AtomicU64::new(0);
                let now =
                    std::time::SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
                fnv(&[
                    now.as_nanos().to_le_bytes().as_slice(),
                    &OPENED.fetch_add(1, Ordering::Relaxed).to_le_bytes(),
                    &std::process::id().to_le_bytes(),
                ]
                .concat())
            },
            remote_reads: AtomicU64::new(0),
            remote_bytes: AtomicU64::new(0),
            cache_hits: AtomicU64::new(0),
            told: Mutex::new(HashSet::new()),
            away: None,
            cache_index,
            cache_max: DEFAULT_CACHE_MAX_BYTES,
            content,
            cache_evicted: AtomicU64::new(0),
            cache_failing: AtomicBool::new(false),
            pins: Mutex::new(BTreeSet::new()),
            pins_file,
            pin_reserve: pin::DEFAULT_PIN_RESERVE,
            swap: RwLock::new(()),
            mutation: MutationGate::new(),
            replay: None,
            restated: Mutex::new(restated),
            generation,
            checked_empty: Mutex::new(HashSet::new()),
            to_invalidate: Mutex::new(Vec::new()),
        };
        // Pins an earlier daemon recorded hold before anything is evicted (their paths are
        // resolved in this manifest; one it no longer has pins nothing).
        overlay.restore_pins(pins);
        if rewrite {
            // Cut a torn tail off now (or end an older file's entries with NULs), or the next
            // append would glue a path onto it.
            let inner = overlay.lock();
            overlay.write_whiteouts(&inner).map_err(std::io::Error::from_raw_os_error)?;
        }
        // A cache an earlier daemon (or a bigger cap) left goes down to the cap now.
        overlay.evict_to_fit(&mut overlay.cache_lock(), 0);
        Ok(overlay)
    }

    /// Tells `away` of each read of a file that failed because the Mac is away (a file read ahead
    /// beside it is no read of the agent's, and is not told).
    #[must_use]
    pub fn with_away(mut self, away: Arc<crate::away::Away>) -> Self {
        self.away = Some(away);
        self
    }

    /// `errno` of a fetch of file `index` that failed; an away one is told to [`Self::with_away`]'s.
    fn fetch_failed(&self, index: u32, error: FetchError) -> i32 {
        if error == FetchError::Away
            && let Some(away) = &self.away
        {
            away.failed(&self.manifest.path_of(index));
        }
        error.errno()
    }

    /// This overlay with its cache capped at `bytes` (what is over goes now).
    #[must_use]
    pub fn with_cache_max(mut self, bytes: u64) -> Self {
        self.cache_max = bytes;
        self.evict_to_fit(&mut self.cache_lock(), 0);
        self
    }

    /// This overlay with its content store leaving `bytes` of its disk free
    /// ([`content::DEFAULT_CONTENT_FLOOR`] by default); `u64::MAX` keeps nothing in it.
    #[must_use]
    pub fn with_content_floor(self, bytes: u64) -> Self {
        if let Some(content) = &self.content {
            content.set_floor(bytes);
        }
        self
    }

    /// The bytes the content store holds now (every listing's blobs, by hash).
    #[must_use]
    pub fn content_bytes(&self) -> u64 {
        self.content.as_ref().map_or(0, content::Content::bytes)
    }

    /// What the content store read through from the shared store (RFD 0065 piece 12; all zero
    /// while `CMUX_PROJECTION_SHARED_STORE` is off, the default).
    #[must_use]
    pub fn shared_transfer(&self) -> shared::Transfer {
        self.content.as_ref().map(content::Content::transfer).unwrap_or_default()
    }

    /// The bytes of the Mac's files cached on the machine now.
    #[must_use]
    pub fn cache_bytes(&self) -> u64 {
        self.cache_lock().bytes
    }

    /// The bytes the cache let go to stay under its cap so far.
    #[must_use]
    pub fn cache_evicted(&self) -> u64 {
        self.cache_evicted.load(Ordering::Relaxed)
    }

    fn cache_lock(&self) -> MutexGuard<'_, CacheIndex> {
        self.cache_index.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Drops the least recently used blobs until `incoming` more bytes fit under the cap.
    fn evict_to_fit(&self, index: &mut CacheIndex, incoming: u64) {
        while index.bytes.saturating_add(incoming) > self.cache_max {
            let Some(oldest) = index.oldest() else { break };
            let bytes = index.remove(oldest).unwrap_or(0);
            // Gone already (the reaper freed it) is as good as removed.
            let _ = fs::remove_file(self.cache_path(oldest));
            self.cache_evicted.fetch_add(bytes, Ordering::Relaxed);
        }
    }

    /// Whether reads leave access times as they are (the mount's `noatime`, the default), or let
    /// the machine's disk keep them as its own mount says (`relatime`).
    pub fn keep_atime(&self, keep: bool) {
        self.upper.set_keep_atime(keep);
    }

    /// The folder that holds what the agent wrote.
    #[must_use]
    pub fn upper_dir(&self) -> &Path {
        self.upper.path()
    }

    /// The lower paths the agent deleted or renamed away.
    #[must_use]
    pub fn whiteouts(&self) -> Vec<String> {
        self.lock().whiteouts.iter().cloned().collect()
    }

    /// The counters so far.
    #[must_use]
    pub fn stats(&self) -> Stats {
        Stats {
            remote_reads: self.remote_reads.load(Ordering::Relaxed),
            remote_bytes: self.remote_bytes.load(Ordering::Relaxed),
            cache_hits: self.cache_hits.load(Ordering::Relaxed),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn handles(&self) -> MutexGuard<'_, HashMap<u64, Handle>> {
        self.handles.lock().unwrap_or_else(PoisonError::into_inner)
    }

    // MARK: Paths and numbers

    fn path_of(&self, ino: u64) -> Result<String, i32> {
        let inner = self.lock();
        if let Some(path) = inner.paths.get(&ino) {
            return Ok(path.clone());
        }
        if inner.dead.contains(&ino) {
            return Err(ENOENT);
        }
        drop(inner);
        let index = ino.checked_sub(1).and_then(|index| u32::try_from(index).ok()).ok_or(ENOENT)?;
        // Only a head path's number is its index + 1; the rest were handed out from the counter.
        if (index as usize) < self.manifest.head_len() {
            Ok(self.manifest.path_of(index))
        } else {
            Err(ENOENT)
        }
    }

    /// The number of `path` by its name alone: one it already has, else the manifest's when no
    /// other path or deleted file holds that one, else a new one.
    fn name_ino(&self, inner: &mut Inner, path: &str) -> u64 {
        if let Some(ino) = inner.inos.get(path) {
            return *ino;
        }
        if let Some(index) =
            self.manifest.resolve(path).filter(|index| (*index as usize) < self.manifest.head_len())
        {
            let ino = u64::from(index) + 1;
            if !inner.paths.contains_key(&ino) && !inner.dead.contains(&ino) {
                return ino;
            }
        }
        let ino = inner.next;
        inner.next += 1;
        inner.paths.insert(ino, path.to_owned());
        inner.inos.insert(path.to_owned(), ino);
        ino
    }

    /// The number of `path`, which is `node`.
    fn ino_of(&self, path: &str, node: &Node) -> u64 {
        let mut inner = self.lock();
        let Node::Upper(stat) = node else { return self.name_ino(&mut inner, path) };
        Self::upper_ino(self, &mut inner, path, (stat.dev, stat.ino))
    }

    fn upper_ino(&self, inner: &mut Inner, path: &str, key: (u64, u64)) -> u64 {
        if let Some(ino) = inner.by_upper.get(&key).copied() {
            // Another name of a hard-linked file: remember it under this name too.
            if inner.inos.get(path) != Some(&ino) {
                inner.inos.insert(path.to_owned(), ino);
            }
            return ino;
        }
        let ino = self.name_ino(inner, path);
        inner.by_upper.insert(key, ino);
        ino
    }

    /// The path the number of `ino` now answers to, when `gone` was its name.
    fn repoint(&self, inner: &mut Inner, ino: u64, gone: &str) {
        let primary = inner.paths.get(&ino).cloned().or_else(|| {
            ino.checked_sub(1)
                .and_then(|index| u32::try_from(index).ok())
                .filter(|index| (*index as usize) < self.manifest.head_len())
                .map(|index| self.manifest.path_of(index))
        });
        if primary.as_deref() != Some(gone) {
            return;
        }
        let other = inner.inos.iter().find(|(path, at)| **at == ino && *path != gone);
        if let Some((other, _)) = other {
            let other = other.clone();
            inner.paths.insert(ino, other);
        }
    }

    /// Forgets `path`'s name; `last` says it was the file's last name, so its number dies.
    fn forget_name(&self, path: &str, ino: u64, upper: Option<(u64, u64)>, last: bool) {
        let mut inner = self.lock();
        inner.inos.remove(path);
        if last {
            inner.paths.remove(&ino);
            // A number from the counter is never handed out twice; only a manifest path's own
            // number could be, so only those are kept (at most one per manifest entry).
            if ino <= self.manifest.head_len() as u64 {
                inner.dead.insert(ino);
            }
            if let Some(key) = upper {
                inner.by_upper.remove(&key);
            }
        } else {
            self.repoint(&mut inner, ino, path);
        }
    }

    /// Whether `path` or a folder above it is whited out.
    fn hidden(inner: &Inner, path: &str) -> bool {
        let mut at = path;
        loop {
            if inner.whiteouts.contains(at) {
                return true;
            }
            match at.rfind('/') {
                Some(cut) => at = at.get(..cut).unwrap_or_default(),
                None => return false,
            }
        }
    }

    /// The lower entry at `path`, when the agent has not hidden it.
    fn lower(&self, path: &str) -> Option<u32> {
        if !path.is_empty() && Self::hidden(&self.lock(), path) {
            return None;
        }
        self.manifest.resolve(path)
    }

    fn node(&self, path: &str) -> Option<Node> {
        if let Ok(stat) = self.upper.stat(path) {
            return Some(Node::Upper(stat));
        }
        self.lower(path).map(Node::Lower)
    }

    fn attr_of(&self, ino: u64, node: &Node) -> Attr {
        let (uid, gid) = self.owner;
        match node {
            Node::Upper(stat) => Self::upper_attr(ino, stat),
            Node::Lower(index) => {
                let kind = self
                    .manifest
                    .entry(*index)
                    .map_or(Type::Dir, |entry| Type::of_kind(entry.kind));
                let stat = self.stat_of(*index).map(|(stat, _)| stat);
                let size = stat.map_or(0, |stat| stat.size);
                let mtime = stat.map_or(0, |stat| stat.mtime_ns);
                Attr {
                    ino,
                    kind,
                    size,
                    blocks: size.div_ceil(512),
                    mode: stat.map_or(0o755, |stat| stat.mode),
                    atime_ns: mtime,
                    mtime_ns: mtime,
                    ctime_ns: mtime,
                    nlink: if kind == Type::Dir { 2 } else { 1 },
                    uid,
                    gid,
                    rdev: 0,
                    upper: false,
                }
            }
        }
    }

    fn upper_attr(ino: u64, stat: &Stat) -> Attr {
        Attr {
            ino,
            kind: Type::of_mode(stat.mode),
            size: stat.size,
            blocks: stat.blocks,
            mode: stat.mode & 0o7777,
            atime_ns: stat.atime_ns,
            mtime_ns: stat.mtime_ns,
            ctime_ns: stat.ctime_ns,
            nlink: stat.nlink,
            uid: stat.uid,
            gid: stat.gid,
            rdev: stat.rdev,
            upper: true,
        }
    }

    /// The version of file `ino`'s bytes now ([`Version`]); `None` for anything but a file.
    pub fn version(&self, ino: u64) -> Result<Option<Version>, i32> {
        let path = self.path_of(ino)?;
        Ok(match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(stat) if stat.format() == fmt::S_IFREG => Some(Version::Upper {
                dev: stat.dev,
                ino: stat.ino,
                size: stat.size,
                mtime_ns: stat.mtime_ns,
                ctime_ns: stat.ctime_ns,
            }),
            Node::Upper(_) => None,
            Node::Lower(index) => {
                let file = self.manifest.entry(index).is_some_and(|entry| entry.kind == Kind::File);
                self.stat_of(index).filter(|_| file).map(|(stat, _)| Version::Lower {
                    entry: index,
                    size: stat.size,
                    mtime_ns: stat.mtime_ns,
                })
            }
        })
    }

    fn attr(&self, path: &str, node: &Node) -> Attr {
        let ino = self.ino_of(path, node);
        self.attr_of(ino, node)
    }

    fn kind(node: &Node, manifest: &Lower) -> Type {
        match node {
            Node::Upper(stat) => Type::of_mode(stat.mode),
            Node::Lower(index) => {
                manifest.entry(*index).map_or(Type::Dir, |entry| Type::of_kind(entry.kind))
            }
        }
    }

    fn child(&self, parent: u64, name: &str) -> Result<(String, String), i32> {
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            return Err(EINVAL);
        }
        // The kernel passes a longer name through to a FUSE file system; a disk refuses it.
        if name.len() > NAME_MAX {
            return Err(ENAMETOOLONG);
        }
        let parent = self.path_of(parent)?;
        let node = self.node(&parent).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Type::Dir {
            return Err(ENOTDIR);
        }
        let child = join(&parent, name);
        Ok((parent, child))
    }

    fn write_whiteouts(&self, inner: &Inner) -> Result<(), i32> {
        let mut text = String::new();
        for path in &inner.whiteouts {
            text.push_str(path);
            text.push('\0');
        }
        let temp = self.scratch_path();
        let written = fs::write(&temp, text).and_then(|()| fs::rename(&temp, &self.whiteouts_file));
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        self.whiteouts_stale.store(written.is_err(), Ordering::Relaxed);
        written.map_err(|error| io_errno(&error))
    }

    fn set_whiteout(&self, path: &str, on: bool) -> Result<(), i32> {
        let mut inner = self.lock();
        let changed =
            if on { inner.whiteouts.insert(path.to_owned()) } else { inner.whiteouts.remove(path) };
        if !changed {
            return Ok(());
        }
        if on && !self.whiteouts_stale.load(Ordering::Relaxed) {
            // A new whiteout is one appended entry (one write: a crash leaves it whole or not
            // there), not a rewrite of every whiteout so far.
            let entry = format!("{path}\0");
            let appended = fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(&self.whiteouts_file)
                .and_then(|mut file| {
                    append_entry(&mut file, entry.as_bytes(), |file, bytes| file.write_all(bytes))
                });
            if appended.is_ok() {
                return Ok(());
            }
        }
        let saved = self.write_whiteouts(&inner);
        if saved.is_err() {
            // A full disk means the on-disk whiteout did not change. Keep memory aligned with
            // the state a reopen would observe.
            if on {
                inner.whiteouts.remove(path);
            } else {
                inner.whiteouts.insert(path.to_owned());
            }
        }
        saved
    }

    /// Readies whited-out `path` for something new there: the whiteout goes, and when a lower
    /// folder was there its names stay hidden (the new path is opaque, as overlayfs makes it), so
    /// a folder deleted and made again comes back empty.
    fn unhide(&self, path: &str) -> Result<(), i32> {
        let mut inner = self.lock();
        if !inner.whiteouts.contains(path) {
            return Ok(());
        }
        let before = inner.whiteouts.clone();
        inner.whiteouts.remove(path);
        if let Some(index) = self.manifest.resolve(path) {
            for (_, entry) in self.manifest.children(index) {
                inner.whiteouts.insert(join(path, &entry.name));
            }
        }
        let written = self.write_whiteouts(&inner);
        if written.is_err() {
            // What the file on disk still says: the path stays deleted.
            inner.whiteouts = before;
        }
        written
    }

    fn scratch_path(&self) -> PathBuf {
        // The overlay's own prefix: an old overlay's thread still landing a fetch after a remount
        // reopened this state never shares a scratch name with the new one.
        let n = self.temp.fetch_add(1, Ordering::Relaxed);
        self.scratch.join(format!("t{:x}-{n}", self.temp_prefix))
    }

    // MARK: Reads

    pub fn lookup(&self, parent: u64, name: &str) -> Result<Attr, i32> {
        // A lookup through an existing directory handle must use the same view from its
        // retirement check through resolving the child (including .git/index).
        let _swap = self.swap.read().unwrap_or_else(PoisonError::into_inner);
        if let Some(found) = self.lookup_retired(parent, name) {
            return found;
        }
        let (_, child) = self.child(parent, name)?;
        let node = self.node(&child).ok_or(ENOENT)?;
        Ok(self.attr(&child, &node))
    }

    /// The upper file an open handle of `ino` holds (a path deleted while open).
    fn open_file_of(&self, ino: u64) -> Option<Arc<fs::File>> {
        self.handles()
            .values()
            .filter(|handle| handle.ino == ino)
            .find_map(|handle| handle.file.clone())
    }

    /// The lower entry an open read-only handle of `ino` reads (a path deleted while open).
    fn open_lower_of(&self, ino: u64) -> Option<u32> {
        self.handles().values().filter(|handle| handle.ino == ino).find_map(|handle| handle.lower)
    }

    /// `ino`'s path and where it lives, when it still has a name.
    fn named(&self, ino: u64) -> Option<(String, Node)> {
        let path = self.path_of(ino).ok()?;
        let node = self.node(&path)?;
        // A name the number no longer answers to (its path now holds another file).
        (self.ino_of(&path, &node) == ino).then_some((path, node))
    }

    /// The number of the folder that holds `ino` (the folder itself for the root): what an NFS
    /// client's lookup of `..` answers, which a FUSE kernel answers by itself.
    pub fn parent(&self, ino: u64) -> Result<u64, i32> {
        let path = self.path_of(ino)?;
        if path.is_empty() {
            return Ok(self.root());
        }
        Ok(self.lookup_path(Self::parent_of(&path))?.ino)
    }

    /// Whether folder `ino` is only in the manifest (no upper folder under it): its names change
    /// only through the mount, which the kernel sees, so the kernel may keep its listing.
    pub fn lower_only(&self, ino: u64) -> bool {
        matches!(self.named(ino), Some((_, Node::Lower(_))))
    }

    /// Whether this file already has local bytes, including a file unlinked while open.
    pub fn is_upper(&self, ino: u64) -> bool {
        match self.named(ino) {
            Some((_, node)) => matches!(node, Node::Upper(_)),
            None => self.open_file_of(ino).is_some(),
        }
    }

    pub fn getattr(&self, ino: u64) -> Result<Attr, i32> {
        if let Some((path, node)) = self.named(ino) {
            return Ok(self.attr(&path, &node));
        }
        if let Some(index) = self.retired_index(ino) {
            return Ok(self.attr_of(ino, &Node::Lower(index)));
        }
        if let Some(file) = self.open_file_of(ino) {
            return Ok(Self::upper_attr(ino, &Upper::fstat(&file)?));
        }
        let index = self.open_lower_of(ino).ok_or(ENOENT)?;
        let mut attr = self.attr_of(ino, &Node::Lower(index));
        attr.nlink = 0;
        Ok(attr)
    }

    /// The merged listing of folder `ino`: upper names, then lower names not hidden or shadowed.
    pub fn readdir(&self, ino: u64) -> Result<Vec<(u64, Type, String)>, i32> {
        if let Some(index) = self.retired_index(ino) {
            return Ok(self.readdir_retired(index));
        }
        Ok(self
            .list(ino, false)?
            .into_iter()
            .map(|(ino, kind, name, _)| (ino, kind, name))
            .collect())
    }

    /// [`Self::readdir`] with each entry's attributes where the manifest alone answers them (a
    /// folder only in the manifest: no upper file can shadow a child), the ones [`Self::lookup`]
    /// would give; `None` for an entry that needs a lookup. One pass, no `stat` of the disk per
    /// name: what `READDIRPLUS` hands the kernel for a whole folder.
    pub fn readdir_plus(&self, ino: u64) -> Result<Vec<Listed>, i32> {
        if let Some(index) = self.retired_index(ino) {
            let entries = self.readdir_retired(index);
            return Ok(entries
                .into_iter()
                .map(|(ino, kind, name)| (ino, kind, name, None))
                .collect());
        }
        self.list(ino, true)
    }

    fn list(&self, ino: u64, attrs: bool) -> Result<Vec<Listed>, i32> {
        let path = self.path_of(ino)?;
        let node = self.node(&path).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Type::Dir {
            return Err(ENOTDIR);
        }
        // The value: kind, the upper inode (an upper name), the manifest index (a lower name).
        let mut names: BTreeMap<String, (Type, Option<u64>, Option<u32>)> = BTreeMap::new();
        if let Some(index) = self.lower(&path) {
            let inner = self.lock();
            for (at, entry) in self.manifest.children(index) {
                if !Self::hidden(&inner, &join(&path, &entry.name)) {
                    names.insert(entry.name.clone(), (Type::of_kind(entry.kind), None, Some(at)));
                }
            }
        }
        let lower_only = matches!(node, Node::Lower(_));
        if let Node::Upper(stat) = &node
            && stat.is_dir()
        {
            for (name, inode, kind) in self.upper.list(&path).unwrap_or_default() {
                names.insert(name, (Type::of_mode(kind), Some(inode), None));
            }
        }
        let dev = match &node {
            Node::Upper(stat) => stat.dev,
            Node::Lower(_) => self.upper.stat("").map_or(0, |stat| stat.dev),
        };
        let mut inner = self.lock();
        Ok(names
            .into_iter()
            .map(|(name, (kind, inode, index))| {
                let child = join(&path, &name);
                let ino = match inode {
                    Some(inode) => self.upper_ino(&mut inner, &child, (dev, inode)),
                    None => self.name_ino(&mut inner, &child),
                };
                let attr = index
                    .filter(|_| attrs && lower_only)
                    .map(|index| self.attr_of(ino, &Node::Lower(index)));
                (ino, kind, name, attr)
            })
            .collect())
    }

    pub fn readlink(&self, ino: u64) -> Result<Vec<u8>, i32> {
        let path = self.path_of(ino)?;
        match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(_) => self.upper.readlink(&path).map_err(|_| EINVAL),
            Node::Lower(index) => self
                .manifest
                .entry(index)
                .and_then(|entry| entry.link.clone())
                .map(String::into_bytes)
                .ok_or(EINVAL),
        }
    }

    /// Reads `ino` by its path (no open handle).
    pub fn read(&self, ino: u64, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        let path = self.path_of(ino)?;
        match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(stat) => {
                if stat.is_dir() {
                    return Err(EISDIR);
                }
                let file = self.upper.open_existing(&path, libc::O_RDONLY)?;
                read_at(&file, offset, size)
            }
            Node::Lower(index) => self.read_lower(index, offset, size),
        }
    }

    /// `EACCES` for a file the Mac keeps home (listed with its stat, its bytes never sent), with
    /// why in this machine's log, once per file.
    fn refuse_kept(&self, index: u32) -> Result<(), i32> {
        let Some(reason) = self.manifest.kept(index) else { return Ok(()) };
        if self.told.lock().unwrap_or_else(PoisonError::into_inner).insert(index) {
            eprintln!(
                "cmux-projection: {}: {} (EACCES)",
                self.manifest.path_of(index),
                kept_text(reason)
            );
        }
        Err(EACCES)
    }

    fn read_lower(&self, index: u32, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        self.refuse_kept(index)?;
        let entry = self.manifest.entry(index).ok_or(ENOENT)?;
        match entry.kind {
            Kind::Dir => return Err(EISDIR),
            Kind::Link => return Err(EINVAL),
            Kind::File => {}
        }
        self.replay_touch(index);
        let mut retries = 0;
        loop {
            match self.read_version(index, offset, size) {
                // Re-listed under the read: again at the new version.
                Err(RETRY) if retries < RETRIES => retries += 1,
                Err(RETRY) => return Err(EIO),
                done => return done,
            }
        }
    }

    /// [`Overlay::read_lower`] at the file's version now; [`RETRY`] when it changed meanwhile.
    fn read_version(&self, index: u32, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        let (stat, _) = self.stat_of(index).ok_or(ENOENT)?;
        let total = stat.size;
        let end = total.min(offset.saturating_add(u64::from(size)));
        if offset >= end {
            return Ok(Vec::new());
        }
        let len = (end - offset) as usize;
        if total <= CHUNK {
            // Only the asked range off the disk, not the whole cached file per request.
            if let Some(bytes) = self.cached_range((index, WHOLE), offset, len) {
                return Ok(bytes);
            }
            // The whole file at the version it was fetched at: sliced by its own length.
            let whole = self.whole(index)?;
            let have = whole.len() as u64;
            let from = usize::try_from(offset.min(have)).unwrap_or(usize::MAX);
            let to = usize::try_from(offset.saturating_add(u64::from(size)).min(have))
                .unwrap_or(usize::MAX);
            return Ok(whole.get(from..to).unwrap_or_default().to_vec());
        }
        let mut out = Vec::with_capacity(len);
        let pack = is_git_pack(&self.manifest.path_of(index));
        let mut at = offset;
        while at < end {
            let chunk = u32::try_from(at / CHUNK).map_err(|_| EIO)?;
            let base = u64::from(chunk) * CHUNK;
            let (start, stop) = (at - base, (end - base).min(CHUNK));
            // A cached chunk gives only the asked range, not its 4 MiB per 128 KiB request.
            if let Some(bytes) = self.cached_range((index, chunk), start, (stop - start) as usize) {
                out.extend_from_slice(&bytes);
            } else if pack {
                out.extend_from_slice(&self.pack_range(index, base + start, base + stop)?);
            } else {
                let bytes = self.chunk(index, chunk)?;
                let stop = (stop as usize).min(bytes.len());
                out.extend_from_slice(bytes.get(start as usize..stop).ok_or(EIO)?);
            }
            at = base + CHUNK;
        }
        Ok(out)
    }

    /// Lower entry `index`'s stat now (the manifest's, or the Mac's re-listing of it) and the
    /// generation of that re-listing (0: the manifest's).
    fn stat_of(&self, index: u32) -> Option<(Restat, u64)> {
        let entry = self.manifest.entry(index)?;
        let restated = self.restated.lock().unwrap_or_else(PoisonError::into_inner);
        Some(restated.get(&index).copied().unwrap_or((
            Restat { size: entry.size, mtime_ns: entry.mtime_ns, mode: entry.mode },
            0,
        )))
    }

    fn generation_of(&self, index: u32) -> u64 {
        self.stat_of(index).map_or(0, |(_, generation)| generation)
    }

    fn is_restated(&self, index: u32) -> bool {
        self.restated.lock().unwrap_or_else(PoisonError::into_inner).contains_key(&index)
    }

    /// Takes the Mac's re-listing of file `index` (hard case 7): its stat from now on, the bytes
    /// cached of the version before forgotten, and its inode queued for the kernel. False when the
    /// overlay had that stat already.
    fn restat(&self, index: u32, stat: Restat) -> bool {
        {
            let mut restated = self.restated.lock().unwrap_or_else(PoisonError::into_inner);
            if self.manifest.entry(index).is_none()
                || restated.get(&index).map(|(old, _)| *old) == Some(stat)
            {
                return false;
            }
            let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
            restated.insert(index, (stat, generation));
            self.keep_restated(&restated);
        }
        self.checked_empty.lock().unwrap_or_else(PoisonError::into_inner).remove(&index);
        // Every blob of the old version, whatever its part (whole, chunk, pack block).
        let mut cache = self.cache_lock();
        let keys: Vec<Key> = cache
            .blobs
            .keys()
            .chain(cache.kept.keys())
            .filter(|key| key.0 == index)
            .copied()
            .collect();
        for key in keys {
            cache.remove(key);
            let _ = fs::remove_file(self.cache_path(key));
        }
        // One the index lost track of (a store mid-rename) goes too.
        let _ = fs::remove_file(self.cache_path((index, WHOLE)));
        drop(cache);
        let path = self.manifest.path_of(index);
        let ino = {
            let mut inner = self.lock();
            self.name_ino(&mut inner, &path)
        };
        self.to_invalidate.lock().unwrap_or_else(PoisonError::into_inner).push(ino);
        true
    }

    /// Writes the re-listed stats to `cache/restated`, so a daemon restart keeps them with the
    /// bytes cached at their versions.
    fn keep_restated(&self, restated: &HashMap<u32, (Restat, u64)>) {
        let mut text = String::new();
        for (entry, (stat, _)) in restated {
            text.push_str(&format!("{entry} {} {} {}\n", stat.size, stat.mtime_ns, stat.mode));
        }
        let temp = self.scratch_path();
        if fs::write(&temp, text).is_err()
            || fs::rename(&temp, self.cache.join(RESTATED_FILE)).is_err()
        {
            let _ = fs::remove_file(&temp);
        }
    }

    /// The inodes the Mac re-listed since the last call: the mount tells the kernel to drop their
    /// cached attributes and pages.
    pub fn take_restated(&self) -> Vec<u64> {
        std::mem::take(&mut *self.to_invalidate.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// The fault at `open` of lower file `ino` whose bytes are not on the machine yet: fetches its
    /// first bytes (which a reader asks for next), so a file changed on the Mac is re-listed before
    /// the opener can `fstat` it. True when it was re-listed. A file already on the machine is the
    /// session's base and is not asked about.
    pub fn open_lower(&self, ino: u64) -> bool {
        if !self.fetch.cache() {
            return false;
        }
        let Ok(path) = self.path_of(ino) else { return false };
        let Some(Node::Lower(index)) = self.node(&path) else { return false };
        if self.manifest.entry(index).map(|entry| entry.kind) != Some(Kind::File)
            || self.manifest.kept(index).is_some()
        {
            return false;
        }
        let Some((stat, generation)) = self.stat_of(index) else { return false };
        if stat.size == 0 {
            // No bytes to cache: one ask, remembered, says whether it is still empty.
            if self.checked_empty.lock().unwrap_or_else(PoisonError::into_inner).contains(&index) {
                return false;
            }
            match self.fetch.read_fresh(index, 0, 0) {
                Ok(Fetched::Restated(stat, _)) => return self.restat(index, stat),
                Ok(Fetched::Same(_)) => {
                    self.checked_empty.lock().unwrap_or_else(PoisonError::into_inner).insert(index);
                }
                Err(_) => {}
            }
            return false;
        }
        let key = if stat.size <= CHUNK { (index, WHOLE) } else { (index, 0) };
        if self.cache_lock().has(key) || self.cache_path(key).exists() || self.in_content(key) {
            return false;
        }
        let _ = self.read_lower(index, 0, 1);
        self.generation_of(index) != generation
    }

    /// `key`'s cached bytes when they are the `len` its file's version now has.
    fn cached_of(&self, key: Key, len: u64) -> Option<Vec<u8>> {
        self.cached(key).filter(|bytes| bytes.len() as u64 == len)
    }

    fn cache_path(&self, (index, part): Key) -> PathBuf {
        if part == WHOLE {
            self.cache.join(index.to_string())
        } else {
            self.cache.join(format!("{index}.{part}"))
        }
    }

    fn cached(&self, key: Key) -> Option<Vec<u8>> {
        if !self.fetch.cache() {
            return None;
        }
        let Ok(bytes) = fs::read(self.cache_path(key)) else {
            self.cache_lock().remove(key);
            return self.content_read(key);
        };
        self.cache_hits.fetch_add(1, Ordering::Relaxed);
        self.cache_lock().touch(key);
        Some(bytes)
    }

    /// `len` bytes at `offset` of cached `key`, read off the disk without the rest of it.
    fn cached_range(&self, key: Key, offset: u64, len: usize) -> Option<Vec<u8>> {
        if !self.fetch.cache() {
            return None;
        }
        let Ok(file) = fs::File::open(self.cache_path(key)) else {
            self.cache_lock().remove(key);
            let bytes = self.content_read(key)?;
            let from = usize::try_from(offset).ok()?;
            return bytes.get(from..from.checked_add(len)?).map(<[u8]>::to_vec);
        };
        let bytes = read_range(&file, offset, len)?;
        self.cache_hits.fetch_add(1, Ordering::Relaxed);
        self.cache_lock().touch(key);
        Some(bytes)
    }

    /// What the listing says of `key`'s blob: the content store's name for it.
    fn content_name(&self, (index, part): Key) -> Option<content::Name> {
        let entry = self.manifest.entry(index)?;
        // A re-listed file is named by its stat now, not the listing's.
        let (stat, _) = self.stat_of(index)?;
        (entry.kind == Kind::File).then(|| content::Name {
            path: self.manifest.path_of(index),
            size: stat.size,
            mtime_ns: stat.mtime_ns,
            part,
        })
    }

    /// Whether the content store holds `key`'s bytes (by its index alone).
    fn in_content(&self, key: Key) -> bool {
        let Some(content) = self.content.as_ref() else { return false };
        self.listed_hash(key).is_some_and(|hash| content.has_hash(&hash))
            || self.content_name(key).is_some_and(|name| content.has(&name))
    }

    /// The hash the listing gives a whole file's bytes (RFD 0065, piece 6): with it the store
    /// answers by content, whatever the path or mtime.
    fn listed_hash(&self, (index, part): Key) -> Option<[u8; 32]> {
        // A re-listed file's bytes are no longer the ones the listing hashed.
        if part != WHOLE || self.is_restated(index) {
            return None;
        }
        self.manifest.hash(index).copied()
    }

    /// `key`'s bytes from the content store (an earlier listing, or a blob the cap let go),
    /// put back in the cache; a hit, never a fetch.
    fn content_read(&self, key: Key) -> Option<Vec<u8>> {
        let content = self.content.as_ref()?;
        let listed = self
            .listed_hash(key)
            .and_then(|hash| content.get_hash(&hash).map(|bytes| (hash, bytes)));
        let (hash, bytes) = match listed {
            Some(found) => found,
            None => content.get(&self.content_name(key)?)?,
        };
        let temp = self.scratch_path();
        if content.link(&hash, &temp) || fs::write(&temp, &bytes).is_ok() {
            self.admit(key, &temp, bytes.len() as u64);
        } else {
            let _ = fs::remove_file(&temp);
        }
        self.cache_hits.fetch_add(1, Ordering::Relaxed);
        Some(bytes)
    }

    /// Caches `bytes` as `key`, fetched at its file's `generation`: not when the file was
    /// re-listed since (they are an older version's).
    fn store(&self, key: Key, bytes: &[u8], generation: u64) {
        if !self.fetch.cache() {
            return;
        }
        if !self.cache_has_room(bytes.len() as u64) {
            self.cache_failing.store(true, Ordering::Relaxed);
            return;
        }
        let temp = self.scratch_path();
        // The content store keeps the bytes once, by hash; the cache's file is a hard link to it.
        let linked = self
            .content
            .as_ref()
            .zip(self.content_name(key))
            .and_then(|(content, name)| content.put(name, bytes).map(|hash| (content, hash)))
            .is_some_and(|(content, hash)| content.link(&hash, &temp));
        if !linked && fs::write(&temp, bytes).is_err() {
            let _ = fs::remove_file(&temp);
            self.cache_failing.store(true, Ordering::Relaxed);
            return;
        }
        self.admit_at(key, &temp, bytes.len() as u64, Some(generation));
        self.cache_failing.store(false, Ordering::Relaxed);
    }

    /// Lands scratch file `temp` (`size` bytes) as cached `key`, under the cap.
    fn admit(&self, key: Key, temp: &Path, size: u64) {
        self.admit_at(key, temp, size, None);
    }

    /// [`Overlay::admit`] of bytes fetched at `generation` of their file: dropped when the file was
    /// re-listed since, checked under the cache lock a re-listing takes to forget the old bytes.
    fn admit_at(&self, key: Key, temp: &Path, size: u64, generation: Option<u64>) {
        // Room first, then the blob lands and is counted, under one lock: the cache never holds
        // more than its cap, and no eviction races a blob landing. A pinned file's blob is kept
        // apart and makes no room.
        let mut index = self.cache_lock();
        if generation.is_some_and(|generation| self.generation_of(key.0) != generation) {
            drop(index);
            let _ = fs::remove_file(temp);
            return;
        }
        let pinned = index.pinned.contains(&key.0);
        if !pinned && size > self.cache_max {
            // Never fits: it is served, not kept.
            drop(index);
            let _ = fs::remove_file(temp);
            return;
        }
        index.remove(key);
        if !pinned {
            self.evict_to_fit(&mut index, size);
        }
        if fs::rename(temp, self.cache_path(key)).is_ok() {
            index.insert(key, size);
        } else {
            let _ = fs::remove_file(temp);
        }
    }

    /// Waits until no other thread fetches `key`, then claims it.
    fn claim(&self, key: Key) -> Claim<'_> {
        let mut inflight = self.inflight.lock().unwrap_or_else(PoisonError::into_inner);
        while inflight.contains(&key) {
            inflight = self
                .landed
                .wait_timeout(inflight, Duration::from_secs(1))
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        inflight.insert(key);
        Claim { overlay: self, keys: vec![key] }
    }

    fn count(&self, bytes: u64) {
        self.remote_reads.fetch_add(1, Ordering::Relaxed);
        self.remote_bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    /// A small file's bytes: from the cache, else fetched with the other uncached small files
    /// [`read_ahead`] picks for it, in one batch (readahead).
    fn whole(&self, index: u32) -> Result<Vec<u8>, i32> {
        let key = (index, WHOLE);
        let (stat, _) = self.stat_of(index).ok_or(ENOENT)?;
        if let Some(bytes) = self.cached_of(key, stat.size) {
            return Ok(bytes);
        }
        let mut claim = self.claim(key);
        let (stat, generation) = self.stat_of(index).ok_or(ENOENT)?;
        if let Some(bytes) = self.cached_of(key, stat.size) {
            return Ok(bytes);
        }
        if stat.size > CHUNK {
            // Re-listed bigger since the caller looked: read in chunks.
            return Err(RETRY);
        }
        // Each file asked, with its size and generation when asked.
        let mut batch = vec![(index, stat.size, generation)];
        // A source with no cache answers one file at a time: read ahead would be thrown away. With
        // a replayed access list, the folder is read ahead only during a scan ([`replay`]).
        // The replay check runs first: it counts the misses that detect a scan.
        if self.fetch.cache()
            && self.replay_read_ahead(index)
            && !self.cache_failing.load(Ordering::Relaxed)
        {
            let picked = {
                let inner = self.lock();
                read_ahead(&self.manifest, index, |other, entry| {
                    self.manifest.kept(other).is_some()
                        || Self::hidden(&inner, &self.manifest.path_of(other))
                        || (entry.kind == Kind::File
                            && (self.cache_path((other, WHOLE)).exists()
                                || self.in_content((other, WHOLE))))
                })
            };
            let mut inflight = self.inflight.lock().unwrap_or_else(PoisonError::into_inner);
            for other in picked {
                let path = self.manifest.path_of(other);
                if inflight.contains(&(other, WHOLE)) || self.upper.stat(&path).is_ok() {
                    continue;
                }
                // Read ahead by its stat now: one re-listed big is left to its own read.
                let Some((stat, generation)) = self.stat_of(other) else { continue };
                if stat.size > CHUNK {
                    continue;
                }
                inflight.insert((other, WHOLE));
                claim.keys.push((other, WHOLE));
                batch.push((other, stat.size, generation));
            }
        }
        let entries: Vec<u32> = batch.iter().map(|(other, _, _)| *other).collect();
        let answers = self.fetch.batch_fresh(&entries);
        let mut mine = Err(EIO);
        for ((other, expected, generation), answer) in batch.into_iter().zip(answers) {
            let answer = match answer {
                Err(error) if other == index => Err(self.fetch_failed(index, error)),
                Err(error) => Err(error.errno()),
                Ok(Fetched::Same(bytes)) if bytes.len() as u64 == expected => {
                    self.count(expected);
                    self.store((other, WHOLE), &bytes, generation);
                    Ok(bytes)
                }
                Ok(Fetched::Same(_)) => Err(EIO),
                Ok(Fetched::Restated(stat, bytes)) => {
                    self.restat(other, stat);
                    if stat.size <= CHUNK && bytes.len() as u64 == stat.size {
                        self.count(stat.size);
                        self.store((other, WHOLE), &bytes, self.generation_of(other));
                        Ok(bytes)
                    } else {
                        // Now a big file, or its bytes did not fit the answer: asked again.
                        Err(RETRY)
                    }
                }
            };
            if other == index {
                mine = answer;
            }
        }
        drop(claim);
        mine
    }

    /// Bytes `from..to` of git pack `index` (inside one chunk), by [`PACK_BLOCK`]: git reads a
    /// pack at random (an object's header, a delta chain's bases), a few KiB per object across
    /// the whole file, so a 4 MiB chunk per touch fetched the whole pack for a few objects. Each
    /// block is cached as part [`PACK_BLOCKS`] + its number; a chunk already cached (a pin's)
    /// answers first.
    fn pack_range(&self, index: u32, from: u64, to: u64) -> Result<Vec<u8>, i32> {
        let total = self.manifest.entry(index).map_or(0, |entry| entry.size);
        let mut out = Vec::with_capacity((to - from) as usize);
        let mut at = from;
        while at < to {
            let block = at / PACK_BLOCK;
            let base = block * PACK_BLOCK;
            let stop = to.min(base + PACK_BLOCK);
            let part = u32::try_from(block).ok().and_then(|block| PACK_BLOCKS.checked_add(block));
            let key = (index, part.ok_or(EIO)?);
            let (start, len) = (at - base, (stop - at) as usize);
            if let Some(bytes) = self.cached_range(key, start, len) {
                out.extend_from_slice(&bytes);
            } else {
                let _claim = self.claim(key);
                let bytes = match self.cached(key) {
                    Some(bytes) => bytes,
                    None => {
                        let size = PACK_BLOCK.min(total.saturating_sub(base));
                        let generation = self.generation_of(index);
                        let bytes = self
                            .fetch
                            .read(index, base, u32::try_from(size).map_err(|_| EIO)?)
                            .map_err(FetchError::errno)?;
                        if bytes.len() as u64 != size {
                            return Err(EIO);
                        }
                        self.count(size);
                        self.store(key, &bytes, generation);
                        bytes
                    }
                };
                let end = (start as usize + len).min(bytes.len());
                out.extend_from_slice(bytes.get(start as usize..end).ok_or(EIO)?);
            }
            at = stop;
        }
        Ok(out)
    }

    /// Chunk `chunk` of big file `index`: from the cache, else fetched. [`RETRY`] when the Mac
    /// re-listed the file (its chunks are then those of its new size).
    fn chunk(&self, index: u32, chunk: u32) -> Result<Vec<u8>, i32> {
        let key = (index, chunk);
        let start = u64::from(chunk) * CHUNK;
        let (stat, _) = self.stat_of(index).ok_or(ENOENT)?;
        if let Some(bytes) = self.cached_of(key, CHUNK.min(stat.size.saturating_sub(start))) {
            return Ok(bytes);
        }
        let _claim = self.claim(key);
        let (stat, generation) = self.stat_of(index).ok_or(ENOENT)?;
        let len = CHUNK.min(stat.size.saturating_sub(start));
        if let Some(bytes) = self.cached_of(key, len) {
            return Ok(bytes);
        }
        match self
            .fetch
            .read_fresh(index, start, u32::try_from(len).map_err(|_| EIO)?)
            .map_err(|error| self.fetch_failed(index, error))?
        {
            Fetched::Same(bytes) if bytes.len() as u64 == len => {
                self.count(len);
                self.store(key, &bytes, generation);
                Ok(bytes)
            }
            Fetched::Same(_) => Err(EIO),
            Fetched::Restated(stat, bytes) => {
                let new = self.restat(index, stat);
                // This chunk at the new version, when the answer carried all of it.
                let whole = stat.size > CHUNK
                    && bytes.len() as u64 == CHUNK.min(stat.size.saturating_sub(start));
                if whole {
                    self.count(bytes.len() as u64);
                    self.store(key, &bytes, self.generation_of(index));
                }
                // The version this read is at already (the Mac answers a changed file so for as
                // long as it differs from the manifest): the chunk is the answer.
                if whole && !new && len == bytes.len() as u64 { Ok(bytes) } else { Err(RETRY) }
            }
        }
    }

    // MARK: Writes

    /// Runs `make` in upper folder `dir`, lifting the owner's write and search bits for it when
    /// the folder's own mode lacks them (a lower folder made read only, copied up: the kernel
    /// already allowed the change, and the machine's user must still be able to land it).
    fn in_folder<T>(&self, dir: &str, make: impl Fn() -> Result<T, i32>) -> Result<T, i32> {
        match make() {
            Err(libc::EACCES) => {}
            other => return other,
        }
        let mode = self.upper.stat(dir)?.mode & 0o7777;
        self.upper.chmod(dir, mode | 0o300)?;
        let made = make();
        let _ = self.upper.chmod(dir, mode);
        made
    }

    /// Makes `path` (a folder) in the upper layer, and every folder above it, with the lower
    /// folders' modes and times.
    fn upper_folder(&self, path: &str) -> Result<(), i32> {
        if path.is_empty() {
            return Ok(());
        }
        let mut at = String::new();
        for name in path.split('/') {
            let parent = at.clone();
            at = join(&at, name);
            match self.upper.stat(&at) {
                Ok(stat) if stat.is_dir() => continue,
                Ok(_) => return Err(ENOTDIR),
                Err(_) => {}
            }
            let entry = self.manifest.resolve(&at).and_then(|index| self.manifest.entry(index));
            let mode = entry.map_or(0o755, |entry| entry.mode);
            match self.in_folder(&parent, || self.upper.mkdir(&at, 0o700)) {
                Ok(()) | Err(EEXIST) => {}
                Err(error) => return Err(error),
            }
            if let Some(entry) = entry {
                let _ = self.upper.utimes(&at, None, Some(SetTime::At(entry.mtime_ns)));
            }
            let _ = self.upper.chmod(&at, mode);
        }
        Ok(())
    }

    fn parent_of(path: &str) -> &str {
        path.rfind('/').map_or("", |cut| path.get(..cut).unwrap_or_default())
    }

    /// Copies lower `path` (entry `index`) into the upper layer, unless it is there already.
    fn copy_up(&self, path: &str, index: u32) -> Result<(), i32> {
        self.refuse_kept(index)?;
        self.copy_up_keeping(path, index, true)
    }

    /// Copies `path` up; with `bytes` false a file lands empty, never fetched: an open that
    /// truncates throws the old bytes away, so it must not fail because the Mac changed them.
    fn copy_up_keeping(&self, path: &str, index: u32, bytes: bool) -> Result<(), i32> {
        let _claim = self.claim((index, COPY_UP));
        if self.upper.stat(path).is_ok() {
            return Ok(());
        }
        let entry = self.manifest.entry(index).ok_or(ENOENT)?.clone();
        let parent = Self::parent_of(path);
        self.upper_folder(parent)?;
        match entry.kind {
            Kind::Dir => return self.upper_folder(path),
            Kind::Link => {
                let target = entry.link.unwrap_or_default();
                self.in_folder(parent, || self.upper.symlink(target.as_bytes(), path))?;
                let at = SetTime::At(entry.mtime_ns);
                let _ = self.upper.utimes(path, Some(at), Some(at));
                return Ok(());
            }
            Kind::File => {}
        }
        let mut retries = 0;
        loop {
            let temp = self.scratch_path();
            // A fill that fails half way (a full disk, a fetch that failed) must not leave its
            // scratch file behind holding the space until the next mount.
            let landed = self.fill_scratch(&temp, index, bytes).and_then(|mode| {
                let _ = fs::set_permissions(&temp, fs::Permissions::from_mode(mode));
                self.in_folder(parent, || self.upper.adopt(&temp, path))
            });
            if landed.is_err() {
                let _ = fs::remove_file(&temp);
            }
            match landed {
                // Re-listed under the copy: again at the new version.
                Err(RETRY) if retries < RETRIES => retries += 1,
                Err(RETRY) => return Err(EIO),
                done => return done,
            }
        }
    }

    /// Writes lower file `index` at its version now (its bytes when `bytes`) into the new scratch
    /// file `temp`, with that version's modification time; its mode, or [`RETRY`] when the Mac
    /// re-listed it meanwhile.
    fn fill_scratch(&self, temp: &Path, index: u32, bytes: bool) -> Result<u32, i32> {
        let (stat, generation) = self.stat_of(index).ok_or(ENOENT)?;
        let mut file = fs::File::create(temp).map_err(|error| io_errno(&error))?;
        if bytes && stat.size <= CHUNK {
            file.write_all(&self.whole(index)?).map_err(|error| io_errno(&error))?;
        } else if bytes {
            let chunks = stat.size.div_ceil(CHUNK);
            for chunk in 0..chunks {
                let chunk = u32::try_from(chunk).map_err(|_| EIO)?;
                let bytes = self.chunk(index, chunk)?;
                file.write_all(&bytes).map_err(|error| io_errno(&error))?;
            }
        }
        if self.generation_of(index) != generation {
            // Fetched at the new version: its stat goes with it.
            return Err(RETRY);
        }
        let at = SetTime::At(stat.mtime_ns);
        let _ = fd_utimes(&file, Some(at), Some(at));
        Ok(stat.mode)
    }

    /// Brings `path` into the upper layer when it is only in the lower one.
    fn ensure_upper(&self, path: &str) -> Result<(), i32> {
        match self.node(path).ok_or(ENOENT)? {
            Node::Upper(_) => Ok(()),
            Node::Lower(index) => self.copy_up(path, index),
        }
    }

    /// Opens `ino` with open(2) `flags`. A write open copies a lower file up first; the handle
    /// then reads and writes the upper file's own descriptor.
    pub fn open_handle(&self, ino: u64, flags: i32) -> Result<u64, i32> {
        let write = flags & libc::O_ACCMODE != libc::O_RDONLY || flags & libc::O_TRUNC != 0;
        // Admission precedes resolving an inode: a directory swap that wins the gate may
        // retire it, so the write must not continue from a path resolved before that swap.
        let _mutation = write.then(|| self.mutation.enter()).transpose()?;
        if let Some(index) = self.retired_index(ino) {
            if flags & libc::O_ACCMODE != libc::O_RDONLY {
                return Err(EISDIR);
            }
            return Ok(self.add_handle(Handle { ino, file: None, lower: Some(index) }));
        }
        let path = self.path_of(ino)?;
        // A file the Mac keeps home: its stat is listed, an open of it is refused.
        if let Some(Node::Lower(index)) = self.node(&path) {
            self.refuse_kept(index)?;
        }
        if write {
            match self.node(&path).ok_or(ENOENT)? {
                Node::Lower(index) if flags & libc::O_TRUNC != 0 => {
                    self.copy_up_keeping(&path, index, false)?;
                }
                _ => self.ensure_upper(&path)?,
            }
        }
        let (file, lower) = match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(stat) if stat.format() == fmt::S_IFREG => {
                let access = flags & libc::O_ACCMODE;
                let file = self.upper.open_existing(&path, access)?;
                if flags & libc::O_TRUNC != 0 {
                    file.set_len(0).map_err(|error| io_errno(&error))?;
                }
                (Some(Arc::new(file)), None)
            }
            // An open folder keeps its attributes after it is deleted or renamed over (the
            // descriptor's fstat); one this daemon may not open still lists by its path.
            Node::Upper(stat) if stat.is_dir() => {
                let opened = self.upper.open_file(&path, libc::O_RDONLY | libc::O_DIRECTORY, 0);
                (opened.ok().map(Arc::new), None)
            }
            Node::Upper(_) => (None, None),
            Node::Lower(index) => (None, Some(index)),
        };
        Ok(self.add_handle(Handle { ino, file, lower }))
    }

    fn add_handle(&self, open: Handle) -> u64 {
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.handles().insert(handle, open);
        handle
    }

    fn handle_file(&self, handle: u64) -> Option<Arc<fs::File>> {
        self.handles().get(&handle).and_then(|handle| handle.file.clone())
    }

    /// Refuses new changes (`EROFS`) and waits at most `timeout` for admitted mutations.
    /// Returns true only once they have drained, when the upper layer is safe to mark and
    /// unmount. On timeout, admission stays sealed but admitted edits can still finish;
    /// retain the mount and state and retry. Reads remain available throughout.
    #[must_use]
    pub fn seal(&self, timeout: Duration) -> bool {
        self.mutation.seal(timeout)
    }

    /// Whether [`Overlay::seal`] was called.
    #[must_use]
    pub fn is_sealed(&self) -> bool {
        self.mutation.is_sealed()
    }

    #[cfg(test)]
    pub(crate) fn pause_next_mutation(
        &self,
    ) -> (std::sync::mpsc::Receiver<()>, std::sync::mpsc::Sender<()>) {
        self.mutation.pause_next()
    }

    /// Ends open handle `handle`.
    pub fn release(&self, handle: u64) {
        self.handles().remove(&handle);
    }

    /// Reads through open handle `handle` of `ino`.
    pub fn read_handle(
        &self,
        handle: u64,
        ino: u64,
        offset: u64,
        size: u32,
    ) -> Result<Vec<u8>, i32> {
        if let Some(file) = self.handle_file(handle) {
            return read_at(&file, offset, size);
        }
        // A lower file read only: its current bytes (an upper copy once another open wrote it),
        // else, its name gone, the bytes it was opened on.
        if self.named(ino).is_some() {
            return self.read(ino, offset, size);
        }
        let lower = self.handles().get(&handle).and_then(|open| open.lower);
        match lower {
            Some(index) => self.read_lower(index, offset, size),
            None => Err(ENOENT),
        }
    }

    /// Writes through open handle `handle` of `ino`.
    pub fn write_handle(
        &self,
        handle: u64,
        ino: u64,
        offset: u64,
        data: &[u8],
    ) -> Result<u32, i32> {
        let _mutation = self.mutation.enter()?;
        match self.handle_file(handle) {
            Some(file) => self.with_room(|| {
                file.write_all_at(data, offset).map_err(|error| io_errno(&error))?;
                u32::try_from(data.len()).map_err(|_| EINVAL)
            }),
            None if self.handles().contains_key(&handle) => Err(EBADF),
            None => self.write_inner(ino, offset, data),
        }
    }

    /// Writes `ino` by its path (no open handle), copying a lower file up first.
    pub fn write(&self, ino: u64, offset: u64, data: &[u8]) -> Result<u32, i32> {
        let _mutation = self.mutation.enter()?;
        self.write_inner(ino, offset, data)
    }

    fn write_inner(&self, ino: u64, offset: u64, data: &[u8]) -> Result<u32, i32> {
        self.with_room(|| {
            let path = self.path_of(ino)?;
            self.ensure_upper(&path)?;
            let file = self.upper.open_existing(&path, libc::O_WRONLY)?;
            file.write_all_at(data, offset).map_err(|error| io_errno(&error))?;
            u32::try_from(data.len()).map_err(|_| EINVAL)
        })
    }

    /// `fallocate(2)` through open handle `handle` (Linux).
    #[cfg(target_os = "linux")]
    pub fn fallocate(&self, handle: u64, offset: i64, length: i64, mode: i32) -> Result<(), i32> {
        let _mutation = self.mutation.enter()?;
        let file = self.handle_file(handle).ok_or(EBADF)?;
        // SAFETY: the descriptor is open for the call.
        check(unsafe { libc::fallocate(file.as_raw_fd(), mode, offset, length) })
    }

    /// Readies `child` (in folder `parent`) for a new path: nothing there, its folder in upper.
    fn make_room(&self, parent: &str, child: &str) -> Result<(), i32> {
        if self.node(child).is_some() {
            return Err(EEXIST);
        }
        self.upper_folder(parent)?;
        self.unhide(child)
    }

    /// Gives a path just made the caller's owner and group (the group of a set-group-id folder
    /// instead, whose new folders are set-group-id too) and its mode, as the kernel does on a disk.
    fn adopt_new(&self, parent: &str, child: &str, who: Who, mode: Option<u32>) -> Result<(), i32> {
        let parent_attr = self.node(parent).map(|node| self.attr(parent, &node));
        let set_gid = parent_attr.is_some_and(|attr| attr.mode & fmt::S_ISGID != 0);
        let gid = match parent_attr {
            Some(attr) if set_gid => attr.gid,
            _ => who.gid,
        };
        let stat = self.upper.stat(child)?;
        if stat.uid != who.uid || stat.gid != gid {
            // Refused for a caller other than this machine's user unless it runs as root: the
            // only callers a non-root mount lets in are its own user's.
            let _ = self.upper.chown(child, who.uid, gid);
        }
        if let Some(mut mode) = mode {
            if stat.is_dir() && set_gid {
                mode |= fmt::S_ISGID;
            }
            self.upper.chmod(child, mode)?;
        }
        Ok(())
    }

    /// Makes file `name` in `parent` for `who` and opens it (read and write: the kernel enforces
    /// the caller's own access mode on its descriptor).
    /// The upper folder is made only when the first try finds it missing (one `stat` per folder
    /// level saved on every create after the first in a folder); an upper path already there is
    /// the disk's own `EEXIST`.
    pub fn create(&self, parent: u64, name: &str, mode: u32, who: Who) -> Result<(Attr, u64), i32> {
        let _mutation = self.mutation.enter()?;
        self.with_room(|| self.create_once(parent, name, mode, who))
    }

    fn create_once(
        &self,
        parent: u64,
        name: &str,
        mode: u32,
        who: Who,
    ) -> Result<(Attr, u64), i32> {
        let (parent, child) = self.child(parent, name)?;
        if self.lower(&child).is_some() {
            return Err(EEXIST);
        }
        let open =
            || self.upper.open_file(&child, libc::O_CREAT | libc::O_EXCL | libc::O_RDWR, 0o600);
        let file = match self.in_folder(&parent, open) {
            Err(ENOENT) => {
                self.upper_folder(&parent)?;
                self.in_folder(&parent, open)?
            }
            opened => opened?,
        };
        // After the file is there: a failed create leaves a deleted lower path deleted, and no
        // new upper file to show through it.
        if let Err(error) = self.unhide(&child) {
            drop(file);
            let _ = self.in_folder(&parent, || self.upper.unlink(&child));
            return Err(error);
        }
        self.adopt_new(&parent, &child, who, Some(mode & 0o7777))?;
        let attr = self.lookup_path(&child)?;
        let handle =
            self.add_handle(Handle { ino: attr.ino, file: Some(Arc::new(file)), lower: None });
        Ok((attr, handle))
    }

    pub fn mkdir(&self, parent: u64, name: &str, mode: u32, who: Who) -> Result<Attr, i32> {
        let _mutation = self.mutation.enter()?;
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        self.with_room(|| self.in_folder(&parent, || self.upper.mkdir(&child, 0o700)))?;
        self.adopt_new(&parent, &child, who, Some(mode & 0o7777))?;
        self.lookup_path(&child)
    }

    /// A fifo, socket, device node or empty file (`mode` carries the type), as mknod(2).
    pub fn mknod(
        &self,
        parent: u64,
        name: &str,
        mode: u32,
        rdev: u64,
        who: Who,
    ) -> Result<Attr, i32> {
        let _mutation = self.mutation.enter()?;
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        let format = mode & fmt::S_IFMT;
        match format {
            0 | fmt::S_IFREG => {
                self.in_folder(&parent, || {
                    self.upper.open_file(
                        &child,
                        libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY,
                        0o600,
                    )
                })?;
            }
            fmt::S_IFIFO | fmt::S_IFSOCK | fmt::S_IFCHR | fmt::S_IFBLK => {
                self.in_folder(&parent, || self.upper.mknod(&child, format | 0o600, rdev))?;
            }
            _ => return Err(EINVAL),
        }
        self.adopt_new(&parent, &child, who, Some(mode & 0o7777))?;
        self.lookup_path(&child)
    }

    pub fn symlink(&self, parent: u64, name: &str, target: &Path, who: Who) -> Result<Attr, i32> {
        let _mutation = self.mutation.enter()?;
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        let target = target.as_os_str().as_encoded_bytes();
        self.in_folder(&parent, || self.upper.symlink(target, &child))?;
        self.adopt_new(&parent, &child, who, None)?;
        self.lookup_path(&child)
    }

    /// A new name `new_name` in `new_parent` for file `ino` (a hard link).
    pub fn link(&self, ino: u64, new_parent: u64, new_name: &str) -> Result<Attr, i32> {
        let _mutation = self.mutation.enter()?;
        let from = self.path_of(ino)?;
        let node = self.node(&from).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) == Type::Dir {
            return Err(EPERM);
        }
        let (to_parent, to) = self.child(new_parent, new_name)?;
        if self.node(&to).is_some() {
            return Err(EEXIST);
        }
        self.ensure_upper(&from)?;
        // The copy-up keeps the file's number for its upper inode before the second name.
        let _ = self.lookup_path(&from)?;
        self.make_room(&to_parent, &to)?;
        self.in_folder(&to_parent, || self.upper.link(&from, &to))?;
        self.lookup_path(&to)
    }

    fn lookup_path(&self, path: &str) -> Result<Attr, i32> {
        let node = self.node(path).ok_or(ENOENT)?;
        Ok(self.attr(path, &node))
    }

    /// Hides the lower path at `path` when there is one.
    fn hide_lower(&self, path: &str) -> Result<(), i32> {
        if self.lower(path).is_some() { self.set_whiteout(path, true) } else { Ok(()) }
    }

    /// Removes the upper path at `path` (a file, link or node; `dir` for a folder) and forgets
    /// its name; a lower path there is whited out.
    fn remove(&self, path: &str, node: &Node, dir: bool) -> Result<(), i32> {
        let ino = self.ino_of(path, node);
        let parent = Self::parent_of(path);
        if let Node::Upper(stat) = node {
            if dir {
                self.in_folder(parent, || self.upper.rmdir(path))?;
            } else {
                self.in_folder(parent, || self.upper.unlink(path))?;
            }
            self.forget_name(path, ino, Some((stat.dev, stat.ino)), dir || stat.nlink <= 1);
        } else {
            self.forget_name(path, ino, None, true);
        }
        self.hide_lower(path)
    }

    pub fn unlink(&self, parent: u64, name: &str) -> Result<(), i32> {
        let _mutation = self.mutation.enter()?;
        let (_, child) = self.child(parent, name)?;
        // The upper path first: the manifest is asked only when the disk has nothing there, and
        // the disk's refusal (EPERM in a sticky folder and the rest) is the answer as it said it.
        let node = match self.upper.stat(&child) {
            Ok(stat) => Node::Upper(stat),
            Err(ENOENT) => Node::Lower(self.lower(&child).ok_or(ENOENT)?),
            Err(errno) => return Err(errno),
        };
        if Self::kind(&node, &self.manifest) == Type::Dir {
            return Err(EISDIR);
        }
        self.remove(&child, &node, false)
    }

    pub fn rmdir(&self, parent: u64, name: &str) -> Result<(), i32> {
        let _mutation = self.mutation.enter()?;
        let (_, child) = self.child(parent, name)?;
        if self.lower(&child).is_none() {
            // Only in the upper layer: one rmdir, the disk checks that it is a folder and empty.
            let stat = self.upper.stat(&child)?;
            if !stat.is_dir() {
                return Err(ENOTDIR);
            }
            return self.remove(&child, &Node::Upper(stat), true);
        }
        let node = self.node(&child).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Type::Dir {
            return Err(ENOTDIR);
        }
        if !self.readdir(self.ino_of(&child, &node))?.is_empty() {
            return Err(ENOTEMPTY);
        }
        self.remove(&child, &node, true)
    }

    /// rename(2), with `RENAME_NOREPLACE` or `RENAME_EXCHANGE` in `flags`.
    pub fn rename(
        &self,
        parent: u64,
        name: &str,
        new_parent: u64,
        new_name: &str,
        flags: u32,
    ) -> Result<(), i32> {
        let _mutation = self.mutation.enter()?;
        let (_, from) = self.child(parent, name)?;
        let (to_parent, to) = self.child(new_parent, new_name)?;
        let exchange = flags & RENAME_EXCHANGE != 0;
        let noreplace = flags & RENAME_NOREPLACE != 0;
        if flags & !(RENAME_EXCHANGE | RENAME_NOREPLACE) != 0 || (exchange && noreplace) {
            return Err(EINVAL);
        }
        let node = self.node(&from).ok_or(ENOENT)?;
        let target = self.node(&to);
        if exchange && target.is_none() {
            return Err(ENOENT);
        }
        if noreplace && target.is_some() {
            return Err(EEXIST);
        }
        if from == to {
            return Ok(());
        }
        // A folder can never move below itself.
        if to.starts_with(&format!("{from}/")) || (exchange && from.starts_with(&format!("{to}/")))
        {
            return Err(EINVAL);
        }
        let is_dir = Self::kind(&node, &self.manifest) == Type::Dir;
        // A lower folder would need every path below it moved: refused, so tools copy instead.
        if is_dir && self.lower(&from).is_some() {
            return Err(EXDEV);
        }
        if exchange {
            return self.exchange(&from, &to, &to_parent, node, target);
        }
        let mut replaced = None;
        if let Some(target) = target {
            let target_dir = Self::kind(&target, &self.manifest) == Type::Dir;
            match (is_dir, target_dir) {
                (false, true) => return Err(EISDIR),
                (true, false) => return Err(ENOTDIR),
                (true, true) => {
                    if !self.readdir(self.ino_of(&to, &target))?.is_empty() {
                        return Err(ENOTEMPTY);
                    }
                    if self.lower(&to).is_some() {
                        return Err(EXDEV);
                    }
                }
                (false, false) => {}
            }
            // Two names of one file: rename does nothing.
            if let (Node::Upper(a), Node::Upper(b)) = (&node, &target)
                && (a.dev, a.ino) == (b.dev, b.ino)
            {
                return Ok(());
            }
            replaced = Some((self.ino_of(&to, &target), target));
        }
        self.ensure_upper(&from)?;
        let moved_node = self.node(&from).ok_or(ENOENT)?;
        let moved = self.ino_of(&from, &moved_node);
        self.upper_folder(&to_parent)?;
        let from_parent = Self::parent_of(&from).to_owned();
        self.in_folder(&from_parent, || {
            self.in_folder(&to_parent, || self.upper.rename(&from, &to, 0))
        })?;
        if let Some((ino, target)) = replaced {
            let (key, last) = match &target {
                Node::Upper(stat) => (Some((stat.dev, stat.ino)), stat.is_dir() || stat.nlink <= 1),
                Node::Lower(_) => (None, true),
            };
            self.forget_name(&to, ino, key, last);
        }
        self.hide_lower(&from)?;
        self.unhide(&to)?;
        self.move_names(&from, &to, moved);
        Ok(())
    }

    /// The moved path keeps its number under its new name, and so does everything below it.
    fn move_names(&self, from: &str, to: &str, moved: u64) {
        let mut inner = self.lock();
        let prefix = format!("{from}/");
        let below = names_below(&inner.inos, &prefix);
        inner.inos.remove(from);
        inner.paths.insert(moved, to.to_owned());
        inner.inos.insert(to.to_owned(), moved);
        for (path, ino) in below {
            let renamed = format!("{to}/{}", path.get(prefix.len()..).unwrap_or_default());
            inner.inos.remove(&path);
            inner.paths.insert(ino, renamed.clone());
            inner.inos.insert(renamed, ino);
        }
    }

    fn exchange(
        &self,
        from: &str,
        to: &str,
        to_parent: &str,
        node: Node,
        target: Option<Node>,
    ) -> Result<(), i32> {
        let target = target.ok_or(ENOENT)?;
        if Self::kind(&target, &self.manifest) == Type::Dir && self.lower(to).is_some() {
            return Err(EXDEV);
        }
        let a = self.ino_of(from, &node);
        let b = self.ino_of(to, &target);
        self.ensure_upper(from)?;
        self.ensure_upper(to)?;
        self.upper_folder(to_parent)?;
        self.upper.rename(from, to, RENAME_EXCHANGE)?;
        // Swap the two names' numbers (and everything below each).
        let temp = format!("\0exchange\0{a}");
        self.move_names(from, &temp, a);
        self.move_names(to, from, b);
        self.move_names(&temp, to, a);
        Ok(())
    }

    /// setattr(2)-family changes to `ino`, through open handle `handle` when the kernel names one
    /// (an `ftruncate` of a file deleted while open).
    pub fn setattr(&self, ino: u64, handle: Option<u64>, set: Set) -> Result<Attr, i32> {
        let _mutation = (set != Set::default()).then(|| self.mutation.enter()).transpose()?;
        self.with_room(|| self.setattr_once(ino, handle, set))
    }

    fn setattr_once(&self, ino: u64, handle: Option<u64>, set: Set) -> Result<Attr, i32> {
        let by_handle = handle.and_then(|handle| self.handle_file(handle));
        // A change through an open handle goes to the file it holds: no lookup, no open.
        if let Some(file) = &by_handle
            && set != Set::default()
        {
            return Self::setattr_open(ino, file, set);
        }
        let path = match self.path_of(ino) {
            Ok(path) if self.node(&path).is_some() => Some(path),
            _ => None,
        };
        let file = match (&path, by_handle) {
            (_, Some(file)) => Some(file),
            (None, None) => Some(self.open_file_of(ino).ok_or(ENOENT)?),
            (Some(_), None) => None,
        };
        if set == Set::default() {
            return self.getattr(ino);
        }
        if let Some(path) = &path {
            match self.node(path) {
                // Truncated to nothing: the old bytes are dropped, so none are fetched.
                Some(Node::Lower(index)) if set.size == Some(0) => {
                    self.copy_up_keeping(path, index, false)?;
                }
                _ => self.ensure_upper(path)?,
            }
        }
        if let Some(size) = set.size {
            match (&file, &path) {
                (Some(file), _) => file.set_len(size).map_err(|error| io_errno(&error))?,
                (None, Some(path)) => {
                    let opened = self.upper.open_existing(path, libc::O_WRONLY)?;
                    opened.set_len(size).map_err(|error| io_errno(&error))?;
                }
                (None, None) => return Err(ENOENT),
            }
        }
        if set.uid.is_some() || set.gid.is_some() {
            let (uid, gid) = (set.uid.unwrap_or(u32::MAX), set.gid.unwrap_or(u32::MAX));
            match (&path, &file) {
                (Some(path), _) => self.upper.chown(path, uid, gid)?,
                (None, Some(file)) => fd_chown(file, uid, gid)?,
                (None, None) => return Err(ENOENT),
            }
        }
        if let Some(mode) = set.mode {
            match (&path, &file) {
                (Some(path), _) => self.upper.chmod(path, mode)?,
                (None, Some(file)) => fd_chmod(file, mode)?,
                (None, None) => return Err(ENOENT),
            }
        }
        if set.atime.is_some() || set.mtime.is_some() {
            match (&path, &file) {
                (Some(path), _) => self.upper.utimes(path, set.atime, set.mtime)?,
                (None, Some(file)) => fd_utimes(file, set.atime, set.mtime)?,
                (None, None) => return Err(ENOENT),
            }
        }
        self.getattr(ino)
    }

    /// [`Self::setattr`] through `file`, the upper file a handle of `ino` holds open: every field
    /// of `set` on that descriptor, and its attributes from it (the path may name another file by
    /// now, a save by rename, or none).
    fn setattr_open(ino: u64, file: &fs::File, set: Set) -> Result<Attr, i32> {
        if let Some(size) = set.size {
            file.set_len(size).map_err(|error| io_errno(&error))?;
        }
        if set.uid.is_some() || set.gid.is_some() {
            fd_chown(file, set.uid.unwrap_or(u32::MAX), set.gid.unwrap_or(u32::MAX))?;
        }
        if let Some(mode) = set.mode {
            fd_chmod(file, mode)?;
        }
        if set.atime.is_some() || set.mtime.is_some() {
            fd_utimes(file, set.atime, set.mtime)?;
        }
        Ok(Self::upper_attr(ino, &Upper::fstat(file)?))
    }

    /// Flushes open handle `handle`'s file to disk.
    pub fn fsync(&self, handle: u64) -> Result<(), i32> {
        match self.handle_file(handle) {
            Some(file) => file.sync_all().map_err(|error| io_errno(&error)),
            None => Ok(()),
        }
    }

    /// The upper disk's sizes: what the agent may still write.
    pub fn statfs(&self) -> Result<libc::statvfs, i32> {
        self.upper.statvfs()
    }

    /// The number of the folder itself.
    #[must_use]
    pub fn root(&self) -> u64 {
        u64::from(ROOT) + 1
    }

    /// When `UNIX_EPOCH + ns`, for callers that hold times as nanoseconds.
    #[must_use]
    pub fn time_of(ns: i64) -> std::time::SystemTime {
        if ns >= 0 {
            UNIX_EPOCH + Duration::from_nanos(u64::try_from(ns).unwrap_or(0))
        } else {
            UNIX_EPOCH - Duration::from_nanos(ns.unsigned_abs())
        }
    }
}

#[path = "pin.rs"]
pub mod pin;

#[path = "overlay_swap.rs"]
mod swap;

#[path = "overlay_content.rs"]
pub mod content;

#[path = "overlay_replay.rs"]
pub mod replay;

#[path = "overlay_shared.rs"]
pub mod shared;

#[path = "overlay_age.rs"]
mod age;

#[path = "overlay_bulk.rs"]
pub mod bulk;

#[path = "overlay_extend.rs"]
mod extend;
pub use extend::Extended;

#[cfg(test)]
#[path = "overlay_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "overlay_names_tests.rs"]
mod names_tests;

#[cfg(test)]
#[path = "remanifest_tests.rs"]
mod remanifest_tests;
