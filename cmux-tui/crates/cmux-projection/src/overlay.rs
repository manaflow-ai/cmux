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
//!   hold a newline; an older file of newline-ended lines still reads);
//! - `cache/`: lower bytes fetched from the Mac, whole files as `cache/<entry>` and the chunks of a
//!   big file as `cache/<entry>.<chunk>`, with `cache/manifest-id` naming the manifest they belong
//!   to (a new manifest starts a fresh cache).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::Write as _;
use std::os::fd::AsRawFd as _;
use std::os::unix::fs::{FileExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, UNIX_EPOCH};

use crate::manifest::{Kind, Manifest, ROOT};
use crate::upper::{SetTime, Stat, Upper};
use crate::wire::Identity;
use crate::{Fetch, FetchError, Fresh};

/// The size of a chunk of a big file, and the largest file fetched whole.
pub const CHUNK: u64 = 4 * 1024 * 1024;
/// The most files one directory readahead batch asks for.
const BATCH_FILES: usize = 256;
/// The most bytes one directory readahead batch asks for.
const BATCH_BYTES: u64 = 16 * 1024 * 1024;

/// `errno` values (Linux numbers; the mount is Linux only).
pub mod errno {
    pub const EPERM: i32 = 1;
    pub const ENOENT: i32 = 2;
    pub const EIO: i32 = 5;
    pub const EBADF: i32 = 9;
    pub const EEXIST: i32 = 17;
    pub const EXDEV: i32 = 18;
    pub const ENOTDIR: i32 = 20;
    pub const EISDIR: i32 = 21;
    pub const EINVAL: i32 = 22;
    pub const ENAMETOOLONG: i32 = 36;
    pub const ENOTEMPTY: i32 = 39;
}
use errno::{
    EBADF, EEXIST, EINVAL, EIO, EISDIR, ENAMETOOLONG, ENOENT, ENOTDIR, ENOTEMPTY, EPERM, EXDEV,
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
        match mode & libc::S_IFMT {
            libc::S_IFDIR => Self::Dir,
            libc::S_IFLNK => Self::Link,
            libc::S_IFIFO => Self::Fifo,
            libc::S_IFSOCK => Self::Socket,
            libc::S_IFCHR => Self::Char,
            libc::S_IFBLK => Self::Block,
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
    inos: HashMap<String, u64>,
    /// The number of each upper file (by device and inode), so every name of a hard-linked file
    /// and a lower file copied up keep one number.
    by_upper: HashMap<(u64, u64), u64>,
    /// Numbers of paths deleted: never given out again (the kernel may still hold one for an open
    /// file, and must never see a new file under an old number).
    dead: HashSet<u64>,
    next: u64,
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

/// A lower file the Mac said changed since the manifest (RFD 0007 hard case 7): what it is now, and
/// its generation, which keeps its bytes in the cache apart from every earlier version's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Now {
    generation: u32,
    identity: Identity,
}

/// What [`Overlay::on_change`] calls with the number of a lower file that changed.
pub type Invalidate = Arc<dyn Fn(u64) + Send + Sync>;

/// Internal: a read found its file changed on the Mac and starts over as the file is now. Never
/// leaves the overlay (after a few changes in a row the read answers `ESTALE`).
const RENEWED: i32 = -1;
/// How many times a read starts over on a file that keeps changing under it.
const RENEW_TRIES: usize = 4;

/// The `cache/fresh` file: one line per changed file, `entry generation size mtime_ns mode`.
fn read_fresh(path: &Path) -> HashMap<u32, Now> {
    let Ok(text) = fs::read_to_string(path) else { return HashMap::new() };
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split(' ');
            let index = fields.next()?.parse().ok()?;
            let generation = fields.next()?.parse().ok()?;
            let size = fields.next()?.parse().ok()?;
            let mtime_ns = fields.next()?.parse().ok()?;
            let mode = fields.next()?.parse().ok()?;
            Some((index, Now { generation, identity: Identity { size, mtime_ns, mode } }))
        })
        .collect()
}

/// A projected folder as the machine sees it.
pub struct Overlay {
    manifest: Arc<Manifest>,
    fetch: Arc<dyn Fetch>,
    owner: (u32, u32),
    upper: Upper,
    cache: PathBuf,
    scratch: PathBuf,
    whiteouts_file: PathBuf,
    inner: Mutex<Inner>,
    handles: Mutex<HashMap<u64, Handle>>,
    next_handle: AtomicU64,
    inflight: Mutex<HashSet<Key>>,
    landed: Condvar,
    temp: AtomicU64,
    remote_reads: AtomicU64,
    remote_bytes: AtomicU64,
    cache_hits: AtomicU64,
    /// Lower files the Mac said changed since the manifest, as they are now ([`Now`]).
    fresh: Mutex<HashMap<u32, Now>>,
    fresh_file: PathBuf,
    /// Told the number of a lower file that changed, so the kernel drops its attributes and pages.
    invalidate: Mutex<Option<Invalidate>>,
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
    check(unsafe { libc::fchmod(file.as_raw_fd(), mode & 0o7777) })
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
        let id_file = cache.join("manifest-id");
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
        // Kept with the cache: a new manifest lists every file as it is now, and starts both over.
        let fresh_file = cache.join("fresh");
        let fresh = read_fresh(&fresh_file);
        let whiteouts = fs::read_to_string(&whiteouts_file)
            .map(|text| {
                let ends = if text.contains('\0') { '\0' } else { '\n' };
                text.split(ends).filter(|path| !path.is_empty()).map(str::to_owned).collect()
            })
            .unwrap_or_default();
        let next = manifest.len() as u64 + 2;
        Ok(Self {
            manifest,
            fetch,
            owner,
            upper,
            cache,
            scratch,
            whiteouts_file,
            inner: Mutex::new(Inner { whiteouts, next, ..Inner::default() }),
            handles: Mutex::new(HashMap::new()),
            next_handle: AtomicU64::new(1),
            inflight: Mutex::new(HashSet::new()),
            landed: Condvar::new(),
            temp: AtomicU64::new(0),
            remote_reads: AtomicU64::new(0),
            remote_bytes: AtomicU64::new(0),
            cache_hits: AtomicU64::new(0),
            fresh: Mutex::new(fresh),
            fresh_file,
            invalidate: Mutex::new(None),
        })
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
        if (index as usize) < self.manifest.len() {
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
        if let Some(index) = self.manifest.resolve(path) {
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
                .filter(|index| (*index as usize) < self.manifest.len())
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
            if ino <= self.manifest.len() as u64 {
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
                let entry = self.manifest.entry(*index);
                let kind = entry.map_or(Type::Dir, |entry| Type::of_kind(entry.kind));
                // A file the Mac said changed is what it is now.
                let (size, mtime, mode) = match (kind, self.fresh_of(*index)) {
                    (Type::File, Some(now)) => {
                        (now.identity.size, now.identity.mtime_ns, now.identity.mode)
                    }
                    _ => (
                        entry.map_or(0, |entry| entry.size),
                        entry.map_or(0, |entry| entry.mtime_ns),
                        entry.map_or(0o755, |entry| entry.mode),
                    ),
                };
                Attr {
                    ino,
                    kind,
                    size,
                    blocks: size.div_ceil(512),
                    mode,
                    atime_ns: mtime,
                    mtime_ns: mtime,
                    ctime_ns: mtime,
                    nlink: if kind == Type::Dir { 2 } else { 1 },
                    uid,
                    gid,
                    rdev: 0,
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
        }
    }

    fn attr(&self, path: &str, node: &Node) -> Attr {
        let ino = self.ino_of(path, node);
        self.attr_of(ino, node)
    }

    fn kind(node: &Node, manifest: &Manifest) -> Type {
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
        fs::write(&temp, text).map_err(|error| io_errno(&error))?;
        fs::rename(&temp, &self.whiteouts_file).map_err(|error| io_errno(&error))
    }

    fn set_whiteout(&self, path: &str, on: bool) -> Result<(), i32> {
        let mut inner = self.lock();
        let changed =
            if on { inner.whiteouts.insert(path.to_owned()) } else { inner.whiteouts.remove(path) };
        if !changed {
            return Ok(());
        }
        self.write_whiteouts(&inner)
    }

    /// Readies whited-out `path` for something new there: the whiteout goes, and when a lower
    /// folder was there its names stay hidden (the new path is opaque, as overlayfs makes it), so
    /// a folder deleted and made again comes back empty.
    fn unhide(&self, path: &str) -> Result<(), i32> {
        let mut inner = self.lock();
        if !inner.whiteouts.remove(path) {
            return Ok(());
        }
        if let Some(index) = self.manifest.resolve(path) {
            let (_, children) = self.manifest.children(index);
            for entry in children {
                inner.whiteouts.insert(join(path, &entry.name));
            }
        }
        self.write_whiteouts(&inner)
    }

    fn scratch_path(&self) -> PathBuf {
        self.scratch.join(format!("t{}", self.temp.fetch_add(1, Ordering::Relaxed)))
    }

    // MARK: Reads

    pub fn lookup(&self, parent: u64, name: &str) -> Result<Attr, i32> {
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

    pub fn getattr(&self, ino: u64) -> Result<Attr, i32> {
        if let Some((path, node)) = self.named(ino) {
            return Ok(self.attr(&path, &node));
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
        let path = self.path_of(ino)?;
        let node = self.node(&path).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Type::Dir {
            return Err(ENOTDIR);
        }
        let mut names: BTreeMap<String, (Type, Option<u64>)> = BTreeMap::new();
        if let Some(index) = self.lower(&path) {
            let (_, children) = self.manifest.children(index);
            let inner = self.lock();
            for entry in children {
                if !Self::hidden(&inner, &join(&path, &entry.name)) {
                    names.insert(entry.name.clone(), (Type::of_kind(entry.kind), None));
                }
            }
        }
        if let Node::Upper(stat) = &node {
            if stat.is_dir() {
                for (name, inode, kind) in self.upper.list(&path).unwrap_or_default() {
                    names.insert(name, (Type::of_mode(kind), Some(inode)));
                }
            }
        }
        let dev = match &node {
            Node::Upper(stat) => stat.dev,
            Node::Lower(_) => self.upper.stat("").map_or(0, |stat| stat.dev),
        };
        let mut inner = self.lock();
        Ok(names
            .into_iter()
            .map(|(name, (kind, inode))| {
                let child = join(&path, &name);
                let ino = match inode {
                    Some(inode) => self.upper_ino(&mut inner, &child, (dev, inode)),
                    None => self.name_ino(&mut inner, &child),
                };
                (ino, kind, name)
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

    /// Lower file `index`'s bytes. A file the Mac says changed since the manifest is read again as
    /// it is now (RFD 0007 hard case 7); one that keeps changing under the read answers `ESTALE`.
    fn read_lower(&self, index: u32, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        for _ in 0..RENEW_TRIES {
            match self.read_lower_now(index, offset, size) {
                Err(RENEWED) => {}
                done => return done,
            }
        }
        Err(FetchError::Changed.errno())
    }

    fn read_lower_now(&self, index: u32, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        let entry = self.manifest.entry(index).ok_or(ENOENT)?;
        match entry.kind {
            Kind::Dir => return Err(EISDIR),
            Kind::Link => return Err(EINVAL),
            Kind::File => {}
        }
        let now = self.now_of(index);
        let total = now.identity.size;
        let end = total.min(offset.saturating_add(u64::from(size)));
        if offset >= end {
            return Ok(Vec::new());
        }
        if total <= CHUNK {
            let whole = self.whole(index)?;
            if whole.len() as u64 != total {
                // It changed between the size read above and the fetch.
                return Err(RENEWED);
            }
            let from = usize::try_from(offset).unwrap_or(usize::MAX);
            let to = usize::try_from(end).unwrap_or(usize::MAX);
            return Ok(whole.get(from..to).unwrap_or_default().to_vec());
        }
        let mut out = Vec::with_capacity((end - offset) as usize);
        let mut at = offset;
        while at < end {
            let chunk = u32::try_from(at / CHUNK).map_err(|_| EIO)?;
            let bytes = self.chunk(index, chunk, now)?;
            let start = (at - u64::from(chunk) * CHUNK) as usize;
            let stop = ((end - u64::from(chunk) * CHUNK) as usize).min(bytes.len());
            out.extend_from_slice(bytes.get(start..stop).ok_or(EIO)?);
            at = u64::from(chunk + 1) * CHUNK;
        }
        Ok(out)
    }

    // MARK: Files changed on the Mac

    /// Lower file `index` as the manifest lists it.
    fn listed(&self, index: u32) -> Identity {
        let entry = self.manifest.entry(index);
        Identity {
            size: entry.map_or(0, |entry| entry.size),
            mtime_ns: entry.map_or(0, |entry| entry.mtime_ns),
            mode: entry.map_or(0, |entry| entry.mode),
        }
    }

    fn fresh_of(&self, index: u32) -> Option<Now> {
        self.fresh.lock().unwrap_or_else(PoisonError::into_inner).get(&index).copied()
    }

    /// Lower file `index` as this machine last heard it is: the manifest's, generation 0, until the
    /// Mac says it changed.
    fn now_of(&self, index: u32) -> Now {
        self.fresh_of(index).unwrap_or(Now { generation: 0, identity: self.listed(index) })
    }

    /// Records that lower file `index` is `identity` now, when that is news: a new generation (its
    /// earlier bytes leave the cache), kept across restarts, and the kernel told to drop the file's
    /// attributes and pages. The generation `identity` has.
    fn renew(&self, index: u32, identity: Identity) -> u32 {
        let mut fresh = self.fresh.lock().unwrap_or_else(PoisonError::into_inner);
        let was = fresh
            .get(&index)
            .copied()
            .unwrap_or(Now { generation: 0, identity: self.listed(index) });
        if was.identity == identity {
            return was.generation;
        }
        let generation = was.generation.wrapping_add(1);
        fresh.insert(index, Now { generation, identity });
        let mut text = String::new();
        for (entry, now) in fresh.iter() {
            let Identity { size, mtime_ns, mode } = now.identity;
            text.push_str(&format!("{entry} {} {size} {mtime_ns} {mode}\n", now.generation));
        }
        let temp = self.scratch_path();
        if fs::write(&temp, text).is_ok() && fs::rename(&temp, &self.fresh_file).is_err() {
            let _ = fs::remove_file(&temp);
        }
        drop(fresh);
        let _ = fs::remove_file(self.cache_path((index, WHOLE), was.generation));
        for chunk in 0..was.identity.size.div_ceil(CHUNK) {
            if let Ok(chunk) = u32::try_from(chunk) {
                let _ = fs::remove_file(self.cache_path((index, chunk), was.generation));
            }
        }
        let invalidate = self.invalidate.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(invalidate) = invalidate {
            invalidate(u64::from(index) + 1);
        }
        generation
    }

    /// Calls `invalidate` with the number of each lower file the Mac says changed, once it is
    /// recorded; the mount passes it on to the kernel. It must not block: it may run inside a read.
    pub fn on_change(&self, invalidate: Invalidate) {
        *self.invalidate.lock().unwrap_or_else(PoisonError::into_inner) = Some(invalidate);
    }

    // MARK: Cache

    fn cache_path(&self, (index, part): Key, generation: u32) -> PathBuf {
        let name =
            if generation == 0 { index.to_string() } else { format!("{index}~{generation}") };
        if part == WHOLE {
            self.cache.join(name)
        } else {
            self.cache.join(format!("{name}.{part}"))
        }
    }

    fn cached(&self, key: Key, generation: u32) -> Option<Vec<u8>> {
        let bytes = fs::read(self.cache_path(key, generation)).ok()?;
        self.cache_hits.fetch_add(1, Ordering::Relaxed);
        Some(bytes)
    }

    fn store(&self, key: Key, generation: u32, bytes: &[u8]) {
        let temp = self.scratch_path();
        if fs::write(&temp, bytes).is_ok()
            && fs::rename(&temp, self.cache_path(key, generation)).is_err()
        {
            let _ = fs::remove_file(&temp);
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

    /// A small file's bytes, as it is now: from the cache, else fetched with its folder's other
    /// uncached small files in one batch (directory readahead). [`RENEWED`] when the Mac said it
    /// changed and sent no bytes this read can use.
    fn whole(&self, index: u32) -> Result<Vec<u8>, i32> {
        let key = (index, WHOLE);
        let now = self.now_of(index);
        if let Some(bytes) = self.cached(key, now.generation) {
            return Ok(bytes);
        }
        let mut claim = self.claim(key);
        // Another thread may have fetched it, or heard it changed, while this one waited.
        let now = self.now_of(index);
        if let Some(bytes) = self.cached(key, now.generation) {
            return Ok(bytes);
        }
        if now.generation != 0 {
            // A file that changed is read alone at its new size: the Mac answers a batch only up
            // to each file's listed size.
            let len = u32::try_from(now.identity.size).map_err(|_| EIO)?;
            let answer = self.fetch.read_fresh(index, 0, len);
            let got = self.take_whole(index, now, answer);
            drop(claim);
            return got;
        }
        let mut batch = vec![(index, now)];
        let mut bytes = now.identity.size;
        if let Some(entry) = self.manifest.entry(index) {
            let folder = self.manifest.path_of(entry.parent);
            let (first, siblings) = self.manifest.children(entry.parent);
            let mut candidates = Vec::new();
            {
                let inner = self.lock();
                for (at, sibling) in siblings.iter().enumerate() {
                    if candidates.len() + 1 >= BATCH_FILES {
                        break;
                    }
                    let Ok(at) = u32::try_from(at) else { break };
                    let other = first + at;
                    if other == index || sibling.kind != Kind::File {
                        continue;
                    }
                    let sibling_now = self.now_of(other);
                    let size = sibling_now.identity.size;
                    if size > CHUNK || bytes + size > BATCH_BYTES {
                        continue;
                    }
                    let path = join(&folder, &sibling.name);
                    if Self::hidden(&inner, &path)
                        || self.cache_path((other, WHOLE), sibling_now.generation).exists()
                    {
                        continue;
                    }
                    candidates.push((other, path, sibling_now));
                    bytes += size;
                }
            }
            let mut inflight = self.inflight.lock().unwrap_or_else(PoisonError::into_inner);
            for (other, path, sibling_now) in candidates {
                if inflight.contains(&(other, WHOLE)) || self.upper.stat(&path).is_ok() {
                    continue;
                }
                inflight.insert((other, WHOLE));
                claim.keys.push((other, WHOLE));
                batch.push((other, sibling_now));
            }
        }
        let entries: Vec<u32> = batch.iter().map(|(other, _)| *other).collect();
        let answers = self.fetch.batch_fresh(&entries);
        let mut mine = Err(EIO);
        for ((other, asked), answer) in batch.iter().zip(answers) {
            let answer = self.take_whole(*other, *asked, answer);
            if *other == index {
                mine = answer;
            }
        }
        drop(claim);
        mine
    }

    /// The Mac's answer for all of small file `index`, asked for as `asked` says it is: cached and
    /// returned, or [`RENEWED`] when the file is something else now and the answer holds no bytes
    /// this read can use.
    fn take_whole(
        &self,
        index: u32,
        asked: Now,
        answer: Result<Fresh, FetchError>,
    ) -> Result<Vec<u8>, i32> {
        let Fresh { bytes, now } = answer.map_err(FetchError::errno)?;
        // No identity: the file the manifest listed (an older Mac says only "changed").
        let identity = now.unwrap_or_else(|| self.listed(index));
        let changed = identity != asked.identity;
        let generation = if changed { self.renew(index, identity) } else { asked.generation };
        if identity.size <= CHUNK && bytes.len() as u64 == identity.size {
            self.count(bytes.len() as u64);
            self.store((index, WHOLE), generation, &bytes);
            Ok(bytes)
        } else if changed {
            Err(RENEWED)
        } else {
            Err(EIO)
        }
    }

    /// Chunk `chunk` of big file `index`, as `now` (from [`Overlay::now_of`]) says the file is:
    /// from the cache, else fetched. [`RENEWED`] when the Mac says the file is something else now.
    fn chunk(&self, index: u32, chunk: u32, now: Now) -> Result<Vec<u8>, i32> {
        let key = (index, chunk);
        if let Some(bytes) = self.cached(key, now.generation) {
            return Ok(bytes);
        }
        let _claim = self.claim(key);
        if let Some(bytes) = self.cached(key, now.generation) {
            return Ok(bytes);
        }
        if self.now_of(index) != now {
            return Err(RENEWED);
        }
        let start = u64::from(chunk) * CHUNK;
        let len = CHUNK.min(now.identity.size.saturating_sub(start));
        let Fresh { bytes, now: told } = self
            .fetch
            .read_fresh(index, start, u32::try_from(len).map_err(|_| EIO)?)
            .map_err(FetchError::errno)?;
        let identity = told.unwrap_or_else(|| self.listed(index));
        if identity != now.identity {
            let generation = self.renew(index, identity);
            let fits = CHUNK.min(identity.size.saturating_sub(start));
            if identity.size > CHUNK && fits > 0 && bytes.len() as u64 == fits {
                self.count(fits);
                self.store(key, generation, &bytes);
            }
            return Err(RENEWED);
        }
        if bytes.len() as u64 != len {
            return Err(EIO);
        }
        self.count(len);
        self.store(key, now.generation, &bytes);
        Ok(bytes)
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
        let temp = self.scratch_path();
        // The file as it is now on the Mac; a change mid-copy starts the copy over.
        let mut copied = Err(RENEWED);
        for _ in 0..RENEW_TRIES {
            copied = self.copy_bytes(&temp, index);
            if copied != Err(RENEWED) {
                break;
            }
        }
        let identity = match copied {
            Ok(identity) => identity,
            Err(errno) => {
                let _ = fs::remove_file(&temp);
                return Err(if errno == RENEWED { FetchError::Changed.errno() } else { errno });
            }
        };
        let _ = fs::set_permissions(&temp, fs::Permissions::from_mode(identity.mode));
        let landed = self.in_folder(parent, || self.upper.adopt(&temp, path));
        if landed.is_err() {
            let _ = fs::remove_file(&temp);
        }
        landed
    }

    /// Writes lower file `index`'s bytes, as it is now, to `temp` with its modification time; what
    /// the file is. [`RENEWED`] when it changed on the Mac during the copy.
    fn copy_bytes(&self, temp: &Path, index: u32) -> Result<Identity, i32> {
        let now = self.now_of(index);
        let mut file = fs::File::create(temp).map_err(|error| io_errno(&error))?;
        if now.identity.size <= CHUNK {
            let bytes = self.whole(index)?;
            if bytes.len() as u64 != now.identity.size {
                return Err(RENEWED);
            }
            file.write_all(&bytes).map_err(|error| io_errno(&error))?;
        } else {
            for chunk in 0..now.identity.size.div_ceil(CHUNK) {
                let chunk = u32::try_from(chunk).map_err(|_| EIO)?;
                let bytes = self.chunk(index, chunk, now)?;
                file.write_all(&bytes).map_err(|error| io_errno(&error))?;
            }
        }
        let at = SetTime::At(now.identity.mtime_ns);
        let _ = fd_utimes(&file, Some(at), Some(at));
        Ok(now.identity)
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
        let path = self.path_of(ino)?;
        let write = flags & libc::O_ACCMODE != libc::O_RDONLY || flags & libc::O_TRUNC != 0;
        if write {
            self.ensure_upper(&path)?;
        }
        let (file, lower) = match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(stat) if stat.format() == libc::S_IFREG => {
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
        match self.handle_file(handle) {
            Some(file) => {
                file.write_all_at(data, offset).map_err(|error| io_errno(&error))?;
                u32::try_from(data.len()).map_err(|_| EINVAL)
            }
            None if self.handles().contains_key(&handle) => Err(EBADF),
            None => self.write(ino, offset, data),
        }
    }

    /// Writes `ino` by its path (no open handle), copying a lower file up first.
    pub fn write(&self, ino: u64, offset: u64, data: &[u8]) -> Result<u32, i32> {
        let path = self.path_of(ino)?;
        self.ensure_upper(&path)?;
        let file = self.upper.open_existing(&path, libc::O_WRONLY)?;
        file.write_all_at(data, offset).map_err(|error| io_errno(&error))?;
        u32::try_from(data.len()).map_err(|_| EINVAL)
    }

    /// `fallocate(2)` through open handle `handle`.
    pub fn fallocate(&self, handle: u64, offset: i64, length: i64, mode: i32) -> Result<(), i32> {
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
        let set_gid = parent_attr.is_some_and(|attr| attr.mode & libc::S_ISGID != 0);
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
                mode |= libc::S_ISGID;
            }
            self.upper.chmod(child, mode)?;
        }
        Ok(())
    }

    /// Makes file `name` in `parent` for `who` and opens it (read and write: the kernel enforces
    /// the caller's own access mode on its descriptor).
    pub fn create(&self, parent: u64, name: &str, mode: u32, who: Who) -> Result<(Attr, u64), i32> {
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        let file = self.in_folder(&parent, || {
            self.upper.open_file(&child, libc::O_CREAT | libc::O_EXCL | libc::O_RDWR, 0o600)
        })?;
        self.adopt_new(&parent, &child, who, Some(mode & 0o7777))?;
        let attr = self.lookup_path(&child)?;
        let handle =
            self.add_handle(Handle { ino: attr.ino, file: Some(Arc::new(file)), lower: None });
        Ok((attr, handle))
    }

    pub fn mkdir(&self, parent: u64, name: &str, mode: u32, who: Who) -> Result<Attr, i32> {
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        self.in_folder(&parent, || self.upper.mkdir(&child, 0o700))?;
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
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        let format = mode & libc::S_IFMT;
        match format {
            0 | libc::S_IFREG => {
                self.in_folder(&parent, || {
                    self.upper.open_file(
                        &child,
                        libc::O_CREAT | libc::O_EXCL | libc::O_WRONLY,
                        0o600,
                    )
                })?;
            }
            libc::S_IFIFO | libc::S_IFSOCK | libc::S_IFCHR | libc::S_IFBLK => {
                self.in_folder(&parent, || self.upper.mknod(&child, format | 0o600, rdev))?;
            }
            _ => return Err(EINVAL),
        }
        self.adopt_new(&parent, &child, who, Some(mode & 0o7777))?;
        self.lookup_path(&child)
    }

    pub fn symlink(&self, parent: u64, name: &str, target: &Path, who: Who) -> Result<Attr, i32> {
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        let target = target.as_os_str().as_encoded_bytes();
        self.in_folder(&parent, || self.upper.symlink(target, &child))?;
        self.adopt_new(&parent, &child, who, None)?;
        self.lookup_path(&child)
    }

    /// A new name `new_name` in `new_parent` for file `ino` (a hard link).
    pub fn link(&self, ino: u64, new_parent: u64, new_name: &str) -> Result<Attr, i32> {
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
        let (_, child) = self.child(parent, name)?;
        let node = self.node(&child).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) == Type::Dir {
            return Err(EISDIR);
        }
        self.remove(&child, &node, false)
    }

    pub fn rmdir(&self, parent: u64, name: &str) -> Result<(), i32> {
        let (_, child) = self.child(parent, name)?;
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
        let (_, from) = self.child(parent, name)?;
        let (to_parent, to) = self.child(new_parent, new_name)?;
        let exchange = flags & libc::RENAME_EXCHANGE != 0;
        let noreplace = flags & libc::RENAME_NOREPLACE != 0;
        if flags & !(libc::RENAME_EXCHANGE | libc::RENAME_NOREPLACE) != 0 || (exchange && noreplace)
        {
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
            if let (Node::Upper(a), Node::Upper(b)) = (&node, &target) {
                if (a.dev, a.ino) == (b.dev, b.ino) {
                    return Ok(());
                }
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
        let below: Vec<(String, u64)> = inner
            .inos
            .iter()
            .filter(|(path, _)| path.starts_with(&prefix))
            .map(|(path, ino)| (path.clone(), *ino))
            .collect();
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
        self.upper.rename(from, to, libc::RENAME_EXCHANGE)?;
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
        let by_handle = handle.and_then(|handle| self.handle_file(handle));
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
            self.ensure_upper(path)?;
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

#[cfg(test)]
#[path = "overlay_tests.rs"]
mod tests;
