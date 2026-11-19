//! The machine's view of a projected folder: the manifest's tree (the lower layer, read only, its
//! bytes fetched from the Mac on first read) under an upper folder on the machine's disk that holds
//! everything the agent writes. Every `stat` and listing of the lower layer is answered from the
//! manifest. The mount ([`crate::mount`], Linux) calls these ops; they are plain `&self` methods,
//! safe from many threads, and never hold a lock across a fetch.
//!
//! The state folder holds:
//! - `upper/`: every file or folder the agent made or changed, at its relative path;
//! - `whiteouts`: lower paths the agent deleted or renamed away, one per line;
//! - `cache/`: lower bytes fetched from the Mac, whole files as `cache/<entry>` and the chunks of a
//!   big file as `cache/<entry>.<chunk>`, with `cache/manifest-id` naming the manifest they belong
//!   to (a new manifest starts a fresh cache), and `cache/restated` the files re-listed since
//!   (below).
//!
//! A file that changed on the Mac after the manifest (RFD 0007, hard case 7): every fault asks the
//! Mac, which checks the file against the manifest and, on a change, answers with its stat now and
//! the bytes as they are now ([`Fetched::Restated`]). The overlay takes that stat as the file's
//! from then on (`restated`), forgets the bytes it cached of the old version, queues the inode for
//! the mount to tell the kernel ([`Overlay::take_restated`]), and answers the read at the new
//! version, asking again when the answer did not carry all of it. Opening a file whose bytes are
//! not on the machine yet is a fault too ([`Overlay::open_lower`]), so a reader that sizes the file
//! by `fstat` right after `open` (git and its index) sees the new size. Bytes already on the
//! machine stay the session's base: a later change reaches the machine with the next fault.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::Write as _;
use std::os::unix::fs::{FileExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::manifest::{Kind, Manifest, ROOT};
use crate::wire::Restat;
use crate::{Fetch, FetchError, Fetched};

/// Not an `errno`: the file was re-listed during the read, which starts over at its new version.
const RETRY: i32 = -1;
/// How many times a read starts over after the file changed under it, before it fails with EIO
/// (a file rewritten all the time).
const RETRIES: u32 = 2;
/// The file in `cache/` that keeps the re-listed stats.
const RESTATED_FILE: &str = "restated";

/// The size of a chunk of a big file, and the largest file fetched whole.
pub const CHUNK: u64 = 4 * 1024 * 1024;
/// The lower-byte cache is bounded per projection so a broad search cannot fill the machine disk.
pub const CACHE_BUDGET_BYTES: u64 = 512 * 1024 * 1024;
/// The most files one directory readahead batch asks for.
const BATCH_FILES: usize = 256;
/// The most bytes one directory readahead batch asks for.
const BATCH_BYTES: u64 = 16 * 1024 * 1024;

/// `errno` values (Linux numbers; the mount is Linux only).
pub mod errno {
    pub const ENOENT: i32 = 2;
    pub const EIO: i32 = 5;
    pub const EEXIST: i32 = 17;
    pub const EXDEV: i32 = 18;
    pub const ENOTDIR: i32 = 20;
    pub const EISDIR: i32 = 21;
    pub const EINVAL: i32 = 22;
    pub const ENOTEMPTY: i32 = 39;
}
use errno::{EEXIST, EINVAL, EIO, EISDIR, ENOENT, ENOTDIR, ENOTEMPTY, EXDEV};

/// Which file (entry) and which part of it: a chunk number, or [`WHOLE`] / [`COPY_UP`].
type Key = (u32, u32);
const WHOLE: u32 = u32::MAX;
const COPY_UP: u32 = u32::MAX - 1;

/// One path's attributes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Attr {
    pub ino: u64,
    pub kind: Kind,
    pub size: u64,
    pub mode: u32,
    pub mtime_ns: i64,
    pub nlink: u32,
    pub uid: u32,
    pub gid: u32,
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
    Upper(fs::Metadata),
    Lower(u32),
}

#[derive(Default)]
struct Inner {
    whiteouts: BTreeSet<String>,
    /// Paths given a number of their own (upper-only paths, and lower paths moved by a rename).
    paths: HashMap<u64, String>,
    inos: HashMap<String, u64>,
    next: u64,
}

#[derive(Clone, Copy)]
struct CacheEntry {
    modified: SystemTime,
    size: u64,
}

/// The lower cache's admission index. It is built once when an overlay opens, then updated while
/// the admission mutex is held; a store therefore never rescans or resorts the cache directory.
#[derive(Default)]
struct CacheIndex {
    entries: BTreeMap<PathBuf, CacheEntry>,
    order: BTreeSet<(SystemTime, PathBuf)>,
    bytes: u64,
}

impl CacheIndex {
    fn load(cache: &Path) -> anyhow::Result<Self> {
        let mut index = Self::default();
        for entry in fs::read_dir(cache)? {
            let entry = entry?;
            let path = entry.path();
            if matches!(
                path.file_name().and_then(|name| name.to_str()),
                Some("manifest-id" | RESTATED_FILE)
            ) {
                continue;
            }
            let metadata = fs::symlink_metadata(&path)?;
            if !metadata.file_type().is_file() {
                continue;
            }
            index.insert(path, metadata.modified()?, metadata.len());
        }
        Ok(index)
    }

    fn insert(&mut self, path: PathBuf, modified: SystemTime, size: u64) {
        self.remove(&path);
        self.bytes = self.bytes.saturating_add(size);
        self.order.insert((modified, path.clone()));
        self.entries.insert(path, CacheEntry { modified, size });
    }

    fn remove(&mut self, path: &Path) -> Option<CacheEntry> {
        let entry = self.entries.remove(path)?;
        self.order.remove(&(entry.modified, path.to_owned()));
        self.bytes = self.bytes.saturating_sub(entry.size);
        Some(entry)
    }

    /// Makes room for `incoming`, excluding `protected` from eviction. A failed deletion refuses
    /// admission, so the caller cannot rename a new object past the budget.
    fn admit(&mut self, incoming: u64, protected: &Path, budget: u64) -> bool {
        let replacing = self.entries.get(protected).map_or(0, |entry| entry.size);
        let mut used = self.bytes.saturating_sub(replacing);
        while used.saturating_add(incoming) > budget {
            let Some((_, path)) = (match self.order.iter().next().cloned() {
                Some((_, path)) if path.as_path() == protected => self.order.iter().nth(1).cloned(),
                first => first,
            }) else {
                return false;
            };
            let size = self.entries.get(&path).map_or(0, |entry| entry.size);
            match fs::remove_file(&path) {
                Ok(()) => {
                    self.remove(&path);
                    used = used.saturating_sub(size);
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.remove(&path);
                    used = used.saturating_sub(size);
                }
                Err(_) => return false,
            }
        }
        true
    }

    fn trim(&mut self, budget: u64) -> anyhow::Result<()> {
        while self.bytes > budget {
            let Some((_, path)) = self.order.iter().next().cloned() else {
                anyhow::bail!("cache occupancy cannot be reduced to its budget");
            };
            let before = self.entries.len();
            match fs::remove_file(&path) {
                Ok(()) => {
                    self.remove(&path);
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    self.remove(&path);
                }
                Err(error) => {
                    return Err(anyhow::anyhow!(
                        "cannot trim cache entry {}: {error}",
                        path.display()
                    ));
                }
            }
            anyhow::ensure!(
                self.entries.len() < before || self.bytes <= budget,
                "cache trim made no progress"
            );
        }
        Ok(())
    }
}

/// A projected folder as the machine sees it.
pub struct Overlay {
    manifest: Arc<Manifest>,
    fetch: Arc<dyn Fetch>,
    owner: (u32, u32),
    upper: PathBuf,
    cache: PathBuf,
    cache_admission: Mutex<CacheIndex>,
    scratch: PathBuf,
    whiteouts_file: PathBuf,
    inner: Mutex<Inner>,
    inflight: Mutex<HashSet<Key>>,
    landed: Condvar,
    temp: AtomicU64,
    remote_reads: AtomicU64,
    remote_bytes: AtomicU64,
    cache_hits: AtomicU64,
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

/// Opens an upper file for writing, its mode notwithstanding. The kernel already checked the
/// caller's right at its own open (a file made read only, as git makes its objects, is written
/// through the descriptor its create returned); each write here opens the file again, so a mode
/// without the owner's write bit is lifted for that open and put back.
fn open_for_write(path: &Path) -> Result<fs::File, i32> {
    match fs::OpenOptions::new().write(true).open(path) {
        Ok(file) => Ok(file),
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            let mode = fs::metadata(path).map_err(|error| io_errno(&error))?.mode() & 0o7777;
            fs::set_permissions(path, fs::Permissions::from_mode(mode | 0o200))
                .map_err(|error| io_errno(&error))?;
            let opened = fs::OpenOptions::new().write(true).open(path);
            let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
            opened.map_err(|error| io_errno(&error))
        }
        Err(error) => Err(io_errno(&error)),
    }
}

fn mtime_of(meta: &fs::Metadata) -> i64 {
    meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
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

impl Overlay {
    /// The overlay of `manifest` with its state in `state`, fetching bytes through `fetch`, every
    /// path owned by `owner` (uid, gid).
    pub fn open(
        manifest: Arc<Manifest>,
        state: &Path,
        fetch: Arc<dyn Fetch>,
        owner: (u32, u32),
    ) -> anyhow::Result<Self> {
        let upper = state.join("upper");
        let cache = state.join("cache");
        let scratch = state.join("scratch");
        let whiteouts_file = state.join("whiteouts");
        fs::create_dir_all(&upper)?;
        let id = format!("{:016x}\n", fnv(&bincode::serialize(manifest.as_ref())?));
        let id_file = cache.join("manifest-id");
        if fs::read_to_string(&id_file).ok().as_deref() != Some(id.as_str()) {
            if cache.exists() {
                fs::remove_dir_all(&cache)?;
            }
            fs::create_dir_all(&cache)?;
            fs::write(&id_file, &id)?;
        }
        let mut cache_index = CacheIndex::load(&cache)?;
        cache_index.trim(CACHE_BUDGET_BYTES)?;
        if scratch.exists() {
            fs::remove_dir_all(&scratch)?;
        }
        fs::create_dir_all(&scratch)?;
        let whiteouts = fs::read_to_string(&whiteouts_file)
            .map(|text| text.lines().filter(|line| !line.is_empty()).map(str::to_owned).collect())
            .unwrap_or_default();
        let restated = load_restated(&cache.join(RESTATED_FILE));
        let generation = AtomicU64::new(restated.len() as u64 + 1);
        let next = manifest.len() as u64 + 2;
        Ok(Self {
            manifest,
            fetch,
            owner,
            upper,
            cache,
            cache_admission: Mutex::new(cache_index),
            scratch,
            whiteouts_file,
            inner: Mutex::new(Inner { whiteouts, next, ..Inner::default() }),
            inflight: Mutex::new(HashSet::new()),
            landed: Condvar::new(),
            temp: AtomicU64::new(0),
            remote_reads: AtomicU64::new(0),
            remote_bytes: AtomicU64::new(0),
            cache_hits: AtomicU64::new(0),
            restated: Mutex::new(restated),
            generation,
            checked_empty: Mutex::new(HashSet::new()),
            to_invalidate: Mutex::new(Vec::new()),
        })
    }

    /// The folder that holds what the agent wrote.
    #[must_use]
    pub fn upper_dir(&self) -> &Path {
        &self.upper
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

    fn up(&self, path: &str) -> PathBuf {
        if path.is_empty() { self.upper.clone() } else { self.upper.join(path) }
    }

    // MARK: Paths and numbers

    fn path_of(&self, ino: u64) -> Result<String, i32> {
        if let Some(path) = self.lock().paths.get(&ino) {
            return Ok(path.clone());
        }
        let index = ino.checked_sub(1).and_then(|index| u32::try_from(index).ok()).ok_or(ENOENT)?;
        if (index as usize) < self.manifest.len() {
            Ok(self.manifest.path_of(index))
        } else {
            Err(ENOENT)
        }
    }

    fn ino_of(&self, path: &str) -> u64 {
        let mut inner = self.lock();
        if let Some(ino) = inner.inos.get(path) {
            return *ino;
        }
        if let Some(index) = self.manifest.resolve(path) {
            let ino = u64::from(index) + 1;
            if !inner.paths.contains_key(&ino) {
                return ino;
            }
        }
        let ino = inner.next;
        inner.next += 1;
        inner.paths.insert(ino, path.to_owned());
        inner.inos.insert(path.to_owned(), ino);
        ino
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
        if let Ok(meta) = fs::symlink_metadata(self.up(path)) {
            return Some(Node::Upper(meta));
        }
        self.lower(path).map(Node::Lower)
    }

    fn attr(&self, path: &str, node: &Node) -> Attr {
        let (uid, gid) = self.owner;
        let ino = self.ino_of(path);
        match node {
            Node::Upper(meta) => {
                let kind = if meta.is_dir() {
                    Kind::Dir
                } else if meta.file_type().is_symlink() {
                    Kind::Link
                } else {
                    Kind::File
                };
                Attr {
                    ino,
                    kind,
                    size: meta.len(),
                    mode: meta.mode() & 0o7777,
                    mtime_ns: mtime_of(meta),
                    nlink: if kind == Kind::Dir { 2 } else { 1 },
                    uid,
                    gid,
                }
            }
            Node::Lower(index) => {
                let kind = self.manifest.entry(*index).map_or(Kind::Dir, |entry| entry.kind);
                let stat = self.stat_of(*index).map(|(stat, _)| stat);
                Attr {
                    ino,
                    kind,
                    size: stat.map_or(0, |stat| stat.size),
                    mode: stat.map_or(0o755, |stat| stat.mode),
                    mtime_ns: stat.map_or(0, |stat| stat.mtime_ns),
                    nlink: if kind == Kind::Dir { 2 } else { 1 },
                    uid,
                    gid,
                }
            }
        }
    }

    fn kind(node: &Node, manifest: &Manifest) -> Kind {
        match node {
            Node::Upper(meta) if meta.is_dir() => Kind::Dir,
            Node::Upper(meta) if meta.file_type().is_symlink() => Kind::Link,
            Node::Upper(_) => Kind::File,
            Node::Lower(index) => manifest.entry(*index).map_or(Kind::Dir, |entry| entry.kind),
        }
    }

    fn child(&self, parent: u64, name: &str) -> Result<(String, String), i32> {
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            return Err(EINVAL);
        }
        let parent = self.path_of(parent)?;
        let node = self.node(&parent).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Kind::Dir {
            return Err(ENOTDIR);
        }
        let child = join(&parent, name);
        Ok((parent, child))
    }

    fn set_whiteout(&self, path: &str, on: bool) -> Result<(), i32> {
        let mut inner = self.lock();
        let changed =
            if on { inner.whiteouts.insert(path.to_owned()) } else { inner.whiteouts.remove(path) };
        if !changed {
            return Ok(());
        }
        let mut text = String::new();
        for path in &inner.whiteouts {
            text.push_str(path);
            text.push('\n');
        }
        let temp = self.scratch_path();
        fs::write(&temp, text).map_err(|error| io_errno(&error))?;
        fs::rename(&temp, &self.whiteouts_file).map_err(|error| io_errno(&error))
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

    pub fn getattr(&self, ino: u64) -> Result<Attr, i32> {
        let path = self.path_of(ino)?;
        let node = self.node(&path).ok_or(ENOENT)?;
        Ok(self.attr(&path, &node))
    }

    /// The merged listing of folder `ino`: upper names, then lower names not hidden or shadowed.
    pub fn readdir(&self, ino: u64) -> Result<Vec<(u64, Kind, String)>, i32> {
        let path = self.path_of(ino)?;
        let node = self.node(&path).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Kind::Dir {
            return Err(ENOTDIR);
        }
        let mut names: BTreeMap<String, Kind> = BTreeMap::new();
        if let Some(index) = self.lower(&path) {
            let (_, children) = self.manifest.children(index);
            let inner = self.lock();
            for entry in children {
                if !inner.whiteouts.contains(&join(&path, &entry.name)) {
                    names.insert(entry.name.clone(), entry.kind);
                }
            }
        }
        if let Ok(read) = fs::read_dir(self.up(&path)) {
            for entry in read.flatten() {
                let Some(name) = entry.file_name().to_str().map(str::to_owned) else { continue };
                let kind = match entry.file_type() {
                    Ok(kind) if kind.is_dir() => Kind::Dir,
                    Ok(kind) if kind.is_symlink() => Kind::Link,
                    _ => Kind::File,
                };
                names.insert(name, kind);
            }
        }
        Ok(names
            .into_iter()
            .map(|(name, kind)| (self.ino_of(&join(&path, &name)), kind, name))
            .collect())
    }

    pub fn readlink(&self, ino: u64) -> Result<Vec<u8>, i32> {
        let path = self.path_of(ino)?;
        match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(_) => fs::read_link(self.up(&path))
                .map(|target| target.into_os_string().into_encoded_bytes())
                .map_err(|_| EINVAL),
            Node::Lower(index) => self
                .manifest
                .entry(index)
                .and_then(|entry| entry.link.clone())
                .map(String::into_bytes)
                .ok_or(EINVAL),
        }
    }

    pub fn read(&self, ino: u64, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        let path = self.path_of(ino)?;
        match self.node(&path).ok_or(ENOENT)? {
            Node::Upper(meta) => {
                if meta.is_dir() {
                    return Err(EISDIR);
                }
                let file = fs::File::open(self.up(&path)).map_err(|error| io_errno(&error))?;
                let end = meta.len().min(offset.saturating_add(u64::from(size)));
                let mut bytes = vec![0u8; end.saturating_sub(offset) as usize];
                file.read_exact_at(&mut bytes, offset).map_err(|error| io_errno(&error))?;
                Ok(bytes)
            }
            Node::Lower(index) => self.read_lower(index, offset, size),
        }
    }

    fn read_lower(&self, index: u32, offset: u64, size: u32) -> Result<Vec<u8>, i32> {
        let entry = self.manifest.entry(index).ok_or(ENOENT)?;
        match entry.kind {
            Kind::Dir => return Err(EISDIR),
            Kind::Link => return Err(EINVAL),
            Kind::File => {}
        }
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
        if total <= CHUNK {
            // The whole file at the version it was fetched at: sliced by its own length.
            let whole = self.whole(index)?;
            let len = whole.len() as u64;
            let from = usize::try_from(offset.min(len)).unwrap_or(usize::MAX);
            let to = usize::try_from(offset.saturating_add(u64::from(size)).min(len))
                .unwrap_or(usize::MAX);
            return Ok(whole.get(from..to).unwrap_or_default().to_vec());
        }
        let mut out = Vec::with_capacity((end - offset) as usize);
        let mut at = offset;
        while at < end {
            let chunk = u32::try_from(at / CHUNK).map_err(|_| EIO)?;
            let bytes = self.chunk(index, chunk)?;
            let start = (at - u64::from(chunk) * CHUNK) as usize;
            let stop = ((end - u64::from(chunk) * CHUNK) as usize).min(bytes.len());
            out.extend_from_slice(bytes.get(start..stop).ok_or(EIO)?);
            at = u64::from(chunk + 1) * CHUNK;
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

    /// Takes the Mac's re-listing of file `index` (hard case 7): its stat from now on, the bytes
    /// cached of the version before forgotten, and its inode queued for the kernel. False when the
    /// overlay had that stat already.
    fn restat(&self, index: u32, stat: Restat) -> bool {
        let old_size = {
            let mut restated = self.restated.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(entry) = self.manifest.entry(index) else { return false };
            let old = restated.get(&index).map_or(entry.size, |(old, _)| old.size);
            if restated.get(&index).map(|(old, _)| *old) == Some(stat) {
                return false;
            }
            let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
            restated.insert(index, (stat, generation));
            self.keep_restated(&restated);
            old
        };
        self.checked_empty.lock().unwrap_or_else(PoisonError::into_inner).remove(&index);
        let chunks = old_size.max(stat.size).div_ceil(CHUNK);
        let keys = std::iter::once((index, WHOLE))
            .chain((0..chunks).filter_map(|chunk| u32::try_from(chunk).ok().map(|c| (index, c))));
        let mut admission = self.cache_admission.lock().unwrap_or_else(PoisonError::into_inner);
        for key in keys {
            let path = self.cache_path(key);
            let _ = fs::remove_file(&path);
            admission.remove(&path);
        }
        drop(admission);
        let ino = self.ino_of(&self.manifest.path_of(index));
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
        if self.manifest.entry(index).map(|entry| entry.kind) != Some(Kind::File) {
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
        if self.cache_path(key).exists() {
            return false;
        }
        let _ = self.read_lower(index, 0, 1);
        self.generation_of(index) != generation
    }

    fn cache_path(&self, (index, part): Key) -> PathBuf {
        if part == WHOLE {
            self.cache.join(index.to_string())
        } else {
            self.cache.join(format!("{index}.{part}"))
        }
    }

    /// `key`'s cached bytes when they are the `len` the file's version now has.
    fn cached(&self, key: Key, len: u64) -> Option<Vec<u8>> {
        if !self.fetch.cache() {
            return None;
        }
        let bytes =
            fs::read(self.cache_path(key)).ok().filter(|bytes| bytes.len() as u64 == len)?;
        self.cache_hits.fetch_add(1, Ordering::Relaxed);
        Some(bytes)
    }

    /// Caches `bytes` as `key`, fetched at its file's `generation`: not when the file was
    /// re-listed since (they are an older version's).
    fn store(&self, key: Key, bytes: &[u8], generation: u64) {
        if !self.fetch.cache() {
            return;
        }
        let Ok(size) = u64::try_from(bytes.len()) else { return };
        if size == 0 || size > CACHE_BUDGET_BYTES {
            return;
        }
        let temp = self.scratch_path();
        if fs::write(&temp, bytes).is_ok() {
            let target = self.cache_path(key);
            let mut admission = self.cache_admission.lock().unwrap_or_else(PoisonError::into_inner);
            // Checked under the admission lock, which a re-listing takes to forget the old bytes.
            if self.generation_of(key.0) != generation
                || !admission.admit(size, &target, CACHE_BUDGET_BYTES)
            {
                let _ = fs::remove_file(&temp);
                return;
            }
            if fs::rename(&temp, &target).is_err() {
                let _ = fs::remove_file(&temp);
            } else {
                let modified = fs::metadata(&target)
                    .and_then(|metadata| metadata.modified())
                    .unwrap_or_else(|_| SystemTime::now());
                admission.insert(target, modified, size);
            }
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

    /// A small file's bytes: from the cache, else fetched with its folder's other uncached small
    /// files in one batch (directory readahead).
    fn whole(&self, index: u32) -> Result<Vec<u8>, i32> {
        let key = (index, WHOLE);
        let (stat, _) = self.stat_of(index).ok_or(ENOENT)?;
        if let Some(bytes) = self.cached(key, stat.size) {
            return Ok(bytes);
        }
        let mut claim = self.claim(key);
        let (stat, generation) = self.stat_of(index).ok_or(ENOENT)?;
        if let Some(bytes) = self.cached(key, stat.size) {
            return Ok(bytes);
        }
        if stat.size > CHUNK {
            // Re-listed bigger since the caller looked: read in chunks.
            return Err(RETRY);
        }
        // Each file asked, with its size and generation when asked.
        let mut batch = vec![(index, stat.size, generation)];
        let mut bytes = stat.size;
        // A source with no cache answers one file at a time: read ahead would be thrown away.
        if let Some(entry) = self.manifest.entry(index).filter(|_| self.fetch.cache()) {
            let folder = self.manifest.path_of(entry.parent);
            let (first, siblings) = self.manifest.children(entry.parent);
            let mut inflight = self.inflight.lock().unwrap_or_else(PoisonError::into_inner);
            let inner = self.lock();
            for (at, sibling) in siblings.iter().enumerate() {
                if batch.len() >= BATCH_FILES {
                    break;
                }
                let Ok(at) = u32::try_from(at) else { break };
                let other = first + at;
                if other == index || sibling.kind != Kind::File {
                    continue;
                }
                let Some((stat, generation)) = self.stat_of(other) else { continue };
                if stat.size > CHUNK
                    || bytes + stat.size > BATCH_BYTES
                    || inflight.contains(&(other, WHOLE))
                {
                    continue;
                }
                let path = join(&folder, &sibling.name);
                if inner.whiteouts.contains(&path)
                    || self.upper.join(&path).exists()
                    || self.cache_path((other, WHOLE)).exists()
                {
                    continue;
                }
                inflight.insert((other, WHOLE));
                claim.keys.push((other, WHOLE));
                batch.push((other, stat.size, generation));
                bytes += stat.size;
            }
        }
        let entries: Vec<u32> = batch.iter().map(|(other, _, _)| *other).collect();
        let answers = self.fetch.batch_fresh(&entries);
        let mut mine = Err(EIO);
        for ((other, expected, generation), answer) in batch.into_iter().zip(answers) {
            let answer = match answer {
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

    /// Chunk `chunk` of big file `index`: from the cache, else fetched. [`RETRY`] when the Mac
    /// re-listed the file (its chunks are then those of its new size).
    fn chunk(&self, index: u32, chunk: u32) -> Result<Vec<u8>, i32> {
        let key = (index, chunk);
        let start = u64::from(chunk) * CHUNK;
        let (stat, _) = self.stat_of(index).ok_or(ENOENT)?;
        if let Some(bytes) = self.cached(key, CHUNK.min(stat.size.saturating_sub(start))) {
            return Ok(bytes);
        }
        let _claim = self.claim(key);
        let (stat, generation) = self.stat_of(index).ok_or(ENOENT)?;
        let len = CHUNK.min(stat.size.saturating_sub(start));
        if let Some(bytes) = self.cached(key, len) {
            return Ok(bytes);
        }
        match self
            .fetch
            .read_fresh(index, start, u32::try_from(len).map_err(|_| EIO)?)
            .map_err(FetchError::errno)?
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

    /// Makes `path` (a folder) in the upper layer, and every folder above it, with the lower
    /// folders' modes.
    fn upper_folder(&self, path: &str) -> Result<(), i32> {
        if path.is_empty() {
            return Ok(());
        }
        let mut at = String::new();
        for name in path.split('/') {
            at = join(&at, name);
            let target = self.up(&at);
            match fs::symlink_metadata(&target) {
                Ok(meta) if meta.is_dir() => continue,
                Ok(_) => return Err(ENOTDIR),
                Err(_) => {}
            }
            let mode = self
                .manifest
                .resolve(&at)
                .and_then(|index| self.manifest.entry(index))
                .map_or(0o755, |entry| entry.mode);
            match fs::create_dir(&target) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(io_errno(&error)),
            }
            let _ = fs::set_permissions(&target, fs::Permissions::from_mode(mode | 0o700));
        }
        Ok(())
    }

    fn parent_of(path: &str) -> &str {
        path.rfind('/').map_or("", |cut| path.get(..cut).unwrap_or_default())
    }

    /// Copies lower `path` (entry `index`) into the upper layer, unless it is there already.
    fn copy_up(&self, path: &str, index: u32) -> Result<(), i32> {
        let _claim = self.claim((index, COPY_UP));
        if fs::symlink_metadata(self.up(path)).is_ok() {
            return Ok(());
        }
        let entry = self.manifest.entry(index).ok_or(ENOENT)?.clone();
        self.upper_folder(Self::parent_of(path))?;
        match entry.kind {
            Kind::Dir => return self.upper_folder(path),
            Kind::Link => {
                let target = entry.link.unwrap_or_default();
                return std::os::unix::fs::symlink(target, self.up(path))
                    .map_err(|error| io_errno(&error));
            }
            Kind::File => {}
        }
        let mut retries = 0;
        loop {
            let temp = self.scratch_path();
            match self.copy_version(index, &temp) {
                Ok(()) => {
                    return fs::rename(&temp, self.up(path)).map_err(|error| io_errno(&error));
                }
                Err(errno) => {
                    let _ = fs::remove_file(&temp);
                    match errno {
                        RETRY if retries < RETRIES => retries += 1,
                        RETRY => return Err(EIO),
                        errno => return Err(errno),
                    }
                }
            }
        }
    }

    /// Writes lower file `index` at its version now to `temp`, with that version's mode and
    /// modification time; [`RETRY`] when the Mac re-listed it meanwhile.
    fn copy_version(&self, index: u32, temp: &Path) -> Result<(), i32> {
        let (stat, generation) = self.stat_of(index).ok_or(ENOENT)?;
        let mut file = fs::File::create(temp).map_err(|error| io_errno(&error))?;
        if stat.size <= CHUNK {
            let bytes = self.whole(index)?;
            if self.generation_of(index) != generation {
                // Fetched at the new version: its stat goes with it.
                return Err(RETRY);
            }
            file.write_all(&bytes).map_err(|error| io_errno(&error))?;
        } else {
            let chunks = stat.size.div_ceil(CHUNK);
            for chunk in 0..chunks {
                let chunk = u32::try_from(chunk).map_err(|_| EIO)?;
                let bytes = self.chunk(index, chunk)?;
                file.write_all(&bytes).map_err(|error| io_errno(&error))?;
            }
        }
        if self.generation_of(index) != generation {
            return Err(RETRY);
        }
        let modified = UNIX_EPOCH + Duration::from_nanos(u64::try_from(stat.mtime_ns).unwrap_or(0));
        let _ = file.set_modified(modified);
        drop(file);
        let _ = fs::set_permissions(temp, fs::Permissions::from_mode(stat.mode));
        Ok(())
    }

    /// Brings `path` into the upper layer when it is only in the lower one.
    fn ensure_upper(&self, path: &str) -> Result<(), i32> {
        match self.node(path).ok_or(ENOENT)? {
            Node::Upper(_) => Ok(()),
            Node::Lower(index) => self.copy_up(path, index),
        }
    }

    pub fn write(&self, ino: u64, offset: u64, data: &[u8]) -> Result<u32, i32> {
        let path = self.path_of(ino)?;
        self.ensure_upper(&path)?;
        let file = open_for_write(&self.up(&path))?;
        file.write_all_at(data, offset).map_err(|error| io_errno(&error))?;
        u32::try_from(data.len()).map_err(|_| EINVAL)
    }

    /// Readies `child` (in folder `parent`) for a new path: nothing there, its folder in upper.
    fn make_room(&self, parent: &str, child: &str) -> Result<(), i32> {
        if self.node(child).is_some() {
            return Err(EEXIST);
        }
        self.upper_folder(parent)?;
        self.set_whiteout(child, false)
    }

    pub fn create(&self, parent: u64, name: &str, mode: u32) -> Result<Attr, i32> {
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.up(&child))
            .map_err(|error| io_errno(&error))?;
        let _ = fs::set_permissions(self.up(&child), fs::Permissions::from_mode(mode & 0o7777));
        self.lookup_path(&child)
    }

    pub fn mkdir(&self, parent: u64, name: &str, mode: u32) -> Result<Attr, i32> {
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        fs::create_dir(self.up(&child)).map_err(|error| io_errno(&error))?;
        let _ = fs::set_permissions(self.up(&child), fs::Permissions::from_mode(mode & 0o7777));
        self.lookup_path(&child)
    }

    pub fn symlink(&self, parent: u64, name: &str, target: &Path) -> Result<Attr, i32> {
        let (parent, child) = self.child(parent, name)?;
        self.make_room(&parent, &child)?;
        std::os::unix::fs::symlink(target, self.up(&child)).map_err(|error| io_errno(&error))?;
        self.lookup_path(&child)
    }

    fn lookup_path(&self, path: &str) -> Result<Attr, i32> {
        let node = self.node(path).ok_or(ENOENT)?;
        Ok(self.attr(path, &node))
    }

    /// Hides the lower path at `path` when there is one.
    fn hide_lower(&self, path: &str) -> Result<(), i32> {
        if self.lower(path).is_some() { self.set_whiteout(path, true) } else { Ok(()) }
    }

    pub fn unlink(&self, parent: u64, name: &str) -> Result<(), i32> {
        let (_, child) = self.child(parent, name)?;
        let node = self.node(&child).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) == Kind::Dir {
            return Err(EISDIR);
        }
        if let Node::Upper(_) = node {
            fs::remove_file(self.up(&child)).map_err(|error| io_errno(&error))?;
        }
        self.hide_lower(&child)
    }

    pub fn rmdir(&self, parent: u64, name: &str) -> Result<(), i32> {
        let (_, child) = self.child(parent, name)?;
        let node = self.node(&child).ok_or(ENOENT)?;
        if Self::kind(&node, &self.manifest) != Kind::Dir {
            return Err(ENOTDIR);
        }
        if !self.readdir(self.ino_of(&child))?.is_empty() {
            return Err(ENOTEMPTY);
        }
        if let Node::Upper(_) = node {
            fs::remove_dir(self.up(&child)).map_err(|error| io_errno(&error))?;
        }
        self.hide_lower(&child)
    }

    pub fn rename(
        &self,
        parent: u64,
        name: &str,
        new_parent: u64,
        new_name: &str,
    ) -> Result<(), i32> {
        let (_, from) = self.child(parent, name)?;
        let (to_parent, to) = self.child(new_parent, new_name)?;
        if from == to {
            return Ok(());
        }
        let node = self.node(&from).ok_or(ENOENT)?;
        let is_dir = Self::kind(&node, &self.manifest) == Kind::Dir;
        // A lower folder would need every path below it moved: refused, so tools copy instead.
        if is_dir && self.lower(&from).is_some() {
            return Err(EXDEV);
        }
        if let Some(target) = self.node(&to) {
            let target_dir = Self::kind(&target, &self.manifest) == Kind::Dir;
            match (is_dir, target_dir) {
                (false, true) => return Err(EISDIR),
                (true, false) => return Err(ENOTDIR),
                (true, true) => {
                    if !self.readdir(self.ino_of(&to))?.is_empty() {
                        return Err(ENOTEMPTY);
                    }
                    if self.lower(&to).is_some() {
                        return Err(EXDEV);
                    }
                }
                (false, false) => {}
            }
        }
        self.ensure_upper(&from)?;
        self.upper_folder(&to_parent)?;
        fs::rename(self.up(&from), self.up(&to)).map_err(|error| io_errno(&error))?;
        self.hide_lower(&from)?;
        self.set_whiteout(&to, false)?;
        // The moved inode keeps its number under its new path, and so does everything below it.
        let moved = self.ino_of(&from);
        let mut inner = self.lock();
        let prefix = format!("{from}/");
        let below: Vec<(String, u64)> = inner
            .inos
            .iter()
            .filter(|(path, _)| path.starts_with(&prefix))
            .map(|(path, ino)| (path.clone(), *ino))
            .collect();
        inner.inos.remove(&from);
        inner.inos.remove(&to);
        inner.paths.insert(moved, to.clone());
        inner.inos.insert(to.clone(), moved);
        for (path, ino) in below {
            let renamed = format!("{to}/{}", path.get(prefix.len()..).unwrap_or_default());
            inner.inos.remove(&path);
            inner.paths.insert(ino, renamed.clone());
            inner.inos.insert(renamed, ino);
        }
        Ok(())
    }

    pub fn setattr(
        &self,
        ino: u64,
        size: Option<u64>,
        mode: Option<u32>,
        mtime_ns: Option<i64>,
    ) -> Result<Attr, i32> {
        let path = self.path_of(ino)?;
        if size.is_none() && mode.is_none() && mtime_ns.is_none() {
            return self.getattr(ino);
        }
        self.ensure_upper(&path)?;
        let target = self.up(&path);
        if let Some(size) = size {
            let file = open_for_write(&target)?;
            file.set_len(size).map_err(|error| io_errno(&error))?;
        }
        if let Some(mode) = mode {
            fs::set_permissions(&target, fs::Permissions::from_mode(mode & 0o7777))
                .map_err(|error| io_errno(&error))?;
        }
        if let Some(mtime_ns) = mtime_ns {
            let file = fs::File::open(&target).map_err(|error| io_errno(&error))?;
            let at = UNIX_EPOCH + Duration::from_nanos(u64::try_from(mtime_ns).unwrap_or(0));
            file.set_modified(at).map_err(|error| io_errno(&error))?;
        }
        self.getattr(ino)
    }

    /// Nothing to do: upper files are plain files on the machine's disk.
    pub fn fsync(&self, _ino: u64) -> Result<(), i32> {
        Ok(())
    }

    /// The number of the folder itself.
    #[must_use]
    pub fn root(&self) -> u64 {
        u64::from(ROOT) + 1
    }
}

#[cfg(test)]
#[path = "overlay_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "remanifest_tests.rs"]
mod remanifest_tests;
