//! The content store under a projection's cache (RFD 0065, piece 5): every blob the overlay
//! fetched, kept on the machine's disk by the SHA-256 of its bytes, with an index from what the
//! listing says of it (path, size, mtime, part) to that hash. A new listing of unchanged files
//! names the same (path, size, mtime), so a warm scan reads them off the disk instead of fetching
//! them again, however big the tree; the per-listing `cache/` (keyed by entry number, emptied by a
//! new listing, capped by [`super::DEFAULT_CACHE_MAX_BYTES`]) is a view of hard links into it.
//!
//! The store is sized to the free disk: a blob is admitted only while the disk keeps
//! [`DEFAULT_CONTENT_FLOOR`] free (or [`super::Overlay::with_content_floor`]), and the least
//! recently used blobs go first to make room. Listings carry no content hash yet (piece 6), so
//! the hash is computed here, on arrival.
//!
//! On disk, in `content/` of the state folder (outside `cache/`, so a new listing keeps it):
//! - `blobs/<sha256 hex>`: the bytes;
//! - `index`: one record per name, `<hash> <size> <mtime_ns> <part> <path>` each ended by a NUL
//!   (a path may hold a newline), appended as blobs land; a later record wins, and the file is
//!   rewritten with only live names when the dead ones outnumber them.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use sha2::Digest as _;

/// The free bytes the store leaves on its disk by default: room for the upper layer, a build and
/// a pin ([`super::pin::DEFAULT_PIN_RESERVE`]) beside it.
pub const DEFAULT_CONTENT_FLOOR: u64 = 8 * 1024 * 1024 * 1024;

/// A blob's identity: the SHA-256 of its bytes.
pub(super) type Hash = [u8; 32];

/// What a listing says of one blob: the file's path, size and mtime, and which part of it
/// (`super::WHOLE`, a chunk or a pack block).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) struct Name {
    pub path: String,
    pub size: u64,
    pub mtime_ns: i64,
    pub part: u32,
}

#[derive(Default)]
struct Inner {
    names: HashMap<Name, Hash>,
    /// Each blob's bytes and the tick it was last used at, and the blobs by that tick.
    blobs: HashMap<Hash, (u64, u64)>,
    order: BTreeMap<u64, Hash>,
    tick: u64,
    /// Records in the index file, live or not.
    records: usize,
    index: Option<fs::File>,
}

impl Inner {
    fn touch(&mut self, hash: Hash) {
        let Some(entry) = self.blobs.get_mut(&hash) else { return };
        self.order.remove(&entry.1);
        self.tick += 1;
        entry.1 = self.tick;
        self.order.insert(self.tick, hash);
    }

    fn add(&mut self, hash: Hash, bytes: u64) {
        self.tick += 1;
        if let Some((_, old)) = self.blobs.insert(hash, (bytes, self.tick)) {
            self.order.remove(&old);
        }
        self.order.insert(self.tick, hash);
    }

    fn forget(&mut self, hash: &Hash) {
        if let Some((_, tick)) = self.blobs.remove(hash) {
            self.order.remove(&tick);
        }
    }
}

/// The store of one projection's state folder.
pub(super) struct Content {
    blobs: PathBuf,
    index_file: PathBuf,
    floor: AtomicU64,
    temp: AtomicU64,
    inner: Mutex<Inner>,
}

fn hex(hash: &Hash) -> String {
    hash.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(text: &str) -> Option<Hash> {
    if text.len() != 64 {
        return None;
    }
    let mut hash = [0u8; 32];
    for (at, byte) in hash.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(at * 2..at * 2 + 2)?, 16).ok()?;
    }
    Some(hash)
}

pub(super) fn hash_of(bytes: &[u8]) -> Hash {
    sha2::Sha256::digest(bytes).into()
}

fn record(name: &Name, hash: &Hash) -> Vec<u8> {
    let mut out =
        format!("{} {} {} {} {}", hex(hash), name.size, name.mtime_ns, name.part, name.path)
            .into_bytes();
    out.push(0);
    out
}

fn parse_record(bytes: &[u8]) -> Option<(Name, Hash)> {
    let text = std::str::from_utf8(bytes).ok()?;
    let mut fields = text.splitn(5, ' ');
    let hash = unhex(fields.next()?)?;
    let size = fields.next()?.parse().ok()?;
    let mtime_ns = fields.next()?.parse().ok()?;
    let part = fields.next()?.parse().ok()?;
    let path = fields.next()?.to_owned();
    Some((Name { path, size, mtime_ns, part }, hash))
}

/// Free bytes on `path`'s disk for an unprivileged writer (0 when it cannot be read).
fn disk_free(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt as _;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else { return 0 };
    // SAFETY: a zeroed statvfs is a valid out buffer; `path` is NUL-terminated.
    let mut out: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the call.
    if unsafe { libc::statvfs(path.as_ptr(), &mut out) } != 0 {
        return 0;
    }
    #[allow(clippy::useless_conversion)] // u64 on 64-bit Linux, narrower elsewhere
    u64::from(out.f_bavail).saturating_mul(u64::from(out.f_frsize))
}

impl Content {
    /// The store in `dir` (made when missing), with what an earlier daemon left in it. A store
    /// that cannot be made is `None`: the overlay works without it, fetching as before.
    pub(super) fn open(dir: &Path) -> Option<Self> {
        use std::os::unix::fs::MetadataExt as _;
        let blobs = dir.join("blobs");
        fs::create_dir_all(&blobs).ok()?;
        let index_file = dir.join("index");
        let mut inner = Inner::default();
        // Blobs, oldest written first, so the least recently used go first again.
        let mut found: Vec<(i64, Hash, u64)> = fs::read_dir(&blobs)
            .ok()?
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let name = entry.file_name();
                let Some(hash) = name.to_str().and_then(unhex) else {
                    // A temp file a crash left behind.
                    let _ = fs::remove_file(entry.path());
                    return None;
                };
                let meta = entry.metadata().ok()?;
                let written = meta.mtime().saturating_mul(1_000_000_000) + meta.mtime_nsec();
                meta.is_file().then_some((written, hash, meta.len()))
            })
            .collect();
        found.sort_unstable();
        for (_, hash, bytes) in found {
            inner.add(hash, bytes);
        }
        let bytes = fs::read(&index_file).unwrap_or_default();
        for piece in bytes.split_inclusive(|byte| *byte == 0) {
            // A last record without its NUL is a torn append: no record.
            let Some(piece) = piece.strip_suffix(&[0]) else { continue };
            inner.records += 1;
            if let Some((name, hash)) = parse_record(piece) {
                inner.names.insert(name, hash);
            }
        }
        inner.names.retain(|_, hash| inner.blobs.contains_key(hash));
        let store = Self {
            blobs,
            index_file,
            floor: AtomicU64::new(DEFAULT_CONTENT_FLOOR),
            temp: AtomicU64::new(0),
            inner: Mutex::new(inner),
        };
        {
            let mut inner = store.lock();
            if inner.records > 2 * inner.names.len() + 1024 || bytes.last().is_some_and(|b| *b != 0)
            {
                store.rewrite(&mut inner);
            }
        }
        Some(store)
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn set_floor(&self, bytes: u64) {
        self.floor.store(bytes, Ordering::Relaxed);
    }

    fn blob_path(&self, hash: &Hash) -> PathBuf {
        self.blobs.join(hex(hash))
    }

    /// Writes the index again with only the live names.
    fn rewrite(&self, inner: &mut Inner) {
        let mut bytes = Vec::new();
        for (name, hash) in &inner.names {
            bytes.extend_from_slice(&record(name, hash));
        }
        let temp = self.index_file.with_extension("new");
        if fs::write(&temp, &bytes).and_then(|()| fs::rename(&temp, &self.index_file)).is_ok() {
            inner.records = inner.names.len();
        } else {
            let _ = fs::remove_file(&temp);
        }
        inner.index = None;
    }

    /// Whether the store holds `name`'s bytes, by the index alone.
    pub(super) fn has(&self, name: &Name) -> bool {
        let inner = self.lock();
        inner.names.get(name).is_some_and(|hash| inner.blobs.contains_key(hash))
    }

    /// `name`'s bytes, checked against their hash (a damaged blob is dropped, never served).
    pub(super) fn get(&self, name: &Name) -> Option<(Hash, Vec<u8>)> {
        let hash = {
            let mut inner = self.lock();
            let hash = *inner.names.get(name)?;
            if !inner.blobs.contains_key(&hash) {
                inner.names.remove(name);
                return None;
            }
            inner.touch(hash);
            hash
        };
        let bytes = fs::read(self.blob_path(&hash)).ok();
        match bytes {
            Some(bytes) if hash_of(&bytes) == hash => Some((hash, bytes)),
            _ => {
                let mut inner = self.lock();
                inner.forget(&hash);
                inner.names.remove(name);
                let _ = fs::remove_file(self.blob_path(&hash));
                None
            }
        }
    }

    /// Hard-links blob `hash` at `to` (a file of the same disk); false when it is gone.
    pub(super) fn link(&self, hash: &Hash, to: &Path) -> bool {
        fs::hard_link(self.blob_path(hash), to).is_ok()
    }

    /// Keeps `bytes` as `name`'s, making room down to the floor first (least recently used blobs
    /// go). Returns the hash it is kept under, or `None` when the disk has no room for it.
    pub(super) fn put(&self, name: Name, bytes: &[u8]) -> Option<Hash> {
        let hash = hash_of(bytes);
        let size = bytes.len() as u64;
        let have = self.lock().blobs.contains_key(&hash);
        if !have {
            let temp = self.blobs.join(format!(
                "tmp-{}-{}",
                std::process::id(),
                self.temp.fetch_add(1, Ordering::Relaxed)
            ));
            if fs::write(&temp, bytes).is_err() {
                let _ = fs::remove_file(&temp);
                return None;
            }
            let mut inner = self.lock();
            // The temp file already took its bytes: room means the floor holds with it written.
            let floor = self.floor.load(Ordering::Relaxed);
            while disk_free(&self.blobs) < floor {
                let Some((_, oldest)) = inner.order.iter().next().map(|(t, h)| (*t, *h)) else {
                    break;
                };
                inner.forget(&oldest);
                let _ = fs::remove_file(self.blob_path(&oldest));
            }
            if disk_free(&self.blobs) < floor || fs::rename(&temp, self.blob_path(&hash)).is_err() {
                drop(inner);
                let _ = fs::remove_file(&temp);
                return None;
            }
            inner.add(hash, size);
        }
        let mut inner = self.lock();
        if !inner.blobs.contains_key(&hash) {
            // Evicted between the check and here: nothing kept.
            return None;
        }
        inner.touch(hash);
        if inner.names.get(&name) != Some(&hash) {
            let line = record(&name, &hash);
            inner.names.insert(name, hash);
            self.append(&mut inner, &line);
        }
        Some(hash)
    }

    fn append(&self, inner: &mut Inner, line: &[u8]) {
        if inner.index.is_none() {
            inner.index =
                fs::OpenOptions::new().create(true).append(true).open(&self.index_file).ok();
        }
        let Some(file) = inner.index.as_mut() else { return };
        if file.write_all(line).is_ok() {
            inner.records += 1;
        } else {
            // A torn record: the next open drops it and rewrites the file.
            inner.index = None;
        }
        if inner.records > 2 * inner.names.len() + 1024 {
            self.rewrite(inner);
        }
    }

    /// The blobs held now and their bytes.
    pub(super) fn bytes(&self) -> u64 {
        self.lock().blobs.values().map(|(bytes, _)| *bytes).sum()
    }
}
