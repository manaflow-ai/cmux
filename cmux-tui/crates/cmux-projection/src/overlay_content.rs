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
//!   rewritten with only live names when the dead ones outnumber them;
//! - `cold/<sha256 hex>-<bytes>.zst`: a blob nobody read for [`COLD_AFTER`], zstd-compressed
//!   ([`Content::age`]). A read thaws it back into `blobs/`; one still unread [`DELETE_AFTER`]
//!   after its last read is deleted unless a pin covers it. A blob's file mtime is its last read
//!   (kept to the hour), so the ages outlive the daemon.
//! - `recipes/<sha256 hex>`: for a blob over [`crate::cdc::PROJECTION_MIN_FILE`], its
//!   content-defined chunks (RFD 0065 piece 13), so a chunk of a blob held here is found by its
//!   own hash when a shared store ([`super::shared`], piece 12, off by default) sends a newer
//!   version of the file as a recipe.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::shared::{Shared, Transfer, decode_recipe, encode_recipe};

use sha2::Digest as _;

/// The free bytes the store leaves on its disk by default: room for the upper layer, a build and
/// a pin ([`super::pin::DEFAULT_PIN_RESERVE`]) beside it.
pub const DEFAULT_CONTENT_FLOOR: u64 = 8 * 1024 * 1024 * 1024;
/// How long a blob stays unread before it goes cold (compressed, off the hot tier).
pub const COLD_AFTER: Duration = Duration::from_secs(3 * 24 * 60 * 60);
/// How long after its last read a cold blob is deleted, unless a pin covers it (the reaper's
/// orphan grace, `crate::reap::ORPHAN_GRACE`).
pub const DELETE_AFTER: Duration = Duration::from_secs(14 * 24 * 60 * 60);
/// The most blobs one aging pass compresses; the rest wait for the next pass.
pub const MAX_COLD_PER_PASS: usize = 4096;
/// How stale a blob's on-disk read time may get before a read writes it again.
const READ_AT_SLACK: u64 = 60 * 60;
/// The zstd level cold blobs are written at.
const COLD_LEVEL: i32 = 3;

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
    /// Each hot blob's last read, in seconds since the epoch.
    read_at: HashMap<Hash, u64>,
    /// The cold blobs: their bytes, the bytes their compressed file takes, and their last read.
    cold: HashMap<Hash, Cold>,
    /// Records in the index file, live or not.
    records: usize,
    index: Option<fs::File>,
    /// Each chunk of a chunked blob: the blob, its offset and length; and each blob's chunks.
    chunks: HashMap<Hash, (Hash, u64, u32)>,
    recipes: HashMap<Hash, Vec<Hash>>,
}

#[derive(Clone, Copy, Debug)]
struct Cold {
    bytes: u64,
    stored: u64,
    read_at: u64,
}

impl Inner {
    /// Marks `hash` used now; returns the read time it had.
    fn touch(&mut self, hash: Hash) -> Option<u64> {
        let entry = self.blobs.get_mut(&hash)?;
        self.order.remove(&entry.1);
        self.tick += 1;
        entry.1 = self.tick;
        self.order.insert(self.tick, hash);
        self.read_at.insert(hash, now_secs())
    }

    fn add(&mut self, hash: Hash, bytes: u64, read_at: u64) {
        self.tick += 1;
        if let Some((_, old)) = self.blobs.insert(hash, (bytes, self.tick)) {
            self.order.remove(&old);
        }
        self.order.insert(self.tick, hash);
        self.read_at.insert(hash, read_at);
    }

    fn forget(&mut self, hash: &Hash) {
        if let Some((_, tick)) = self.blobs.remove(hash) {
            self.order.remove(&tick);
        }
        for chunk in self.recipes.remove(hash).unwrap_or_default() {
            if self.chunks.get(&chunk).is_some_and(|(blob, _, _)| blob == hash) {
                self.chunks.remove(&chunk);
            }
        }
        self.read_at.remove(hash);
    }

    fn index_recipe(&mut self, blob: Hash, chunks: &[(Hash, u32)]) {
        let mut offset = 0u64;
        for (chunk, len) in chunks {
            self.chunks.insert(*chunk, (blob, offset, *len));
            offset += u64::from(*len);
        }
        self.recipes.insert(blob, chunks.iter().map(|(chunk, _)| *chunk).collect());
    }

    fn holds(&self, hash: &Hash) -> bool {
        self.blobs.contains_key(hash) || self.cold.contains_key(hash)
    }
}

fn now_secs() -> u64 {
    secs_of(SystemTime::now())
}

fn secs_of(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// What one aging pass ([`Content::age`]) found and did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct AgeReport {
    /// Held after the pass: hot blobs and their bytes.
    pub hot_blobs: u64,
    pub hot_bytes: u64,
    /// Held after the pass: cold blobs, their bytes, and what their compressed files take.
    pub cold_blobs: u64,
    pub cold_bytes: u64,
    pub cold_stored_bytes: u64,
    /// This pass: blobs that went cold, their bytes, and the disk that saved.
    pub went_cold_blobs: u64,
    pub went_cold_bytes: u64,
    pub went_cold_saved_bytes: u64,
    /// This pass: cold blobs deleted, their bytes, and the disk that freed.
    pub deleted_blobs: u64,
    pub deleted_bytes: u64,
    pub deleted_stored_bytes: u64,
    /// Old enough to age, kept: under a pin, or still linked from the cache (in use).
    pub kept_pinned: u64,
    pub kept_linked: u64,
    /// Old enough to go cold, left for the next pass ([`MAX_COLD_PER_PASS`]).
    pub deferred: u64,
}

impl AgeReport {
    /// The disk the store takes after the pass.
    #[must_use]
    pub fn held_bytes(&self) -> u64 {
        self.hot_bytes + self.cold_stored_bytes
    }

    /// The disk this pass gave back.
    #[must_use]
    pub fn aged_out_bytes(&self) -> u64 {
        self.went_cold_saved_bytes + self.deleted_stored_bytes
    }
}

/// When blobs go cold and are deleted.
#[derive(Clone, Copy, Debug)]
pub struct Aging {
    pub cold_after: Duration,
    pub delete_after: Duration,
    pub max_cold: usize,
}

impl Default for Aging {
    fn default() -> Self {
        Self { cold_after: COLD_AFTER, delete_after: DELETE_AFTER, max_cold: MAX_COLD_PER_PASS }
    }
}

fn cold_name(hash: &Hash, bytes: u64) -> String {
    format!("{}-{bytes}.zst", hex(hash))
}

/// A cold file's hash and bytes, from its name.
pub(crate) fn parse_cold(name: &str) -> Option<(Hash, u64)> {
    let (hash, rest) = name.strip_suffix(".zst")?.split_once('-')?;
    Some((unhex(hash)?, rest.parse().ok()?))
}

fn mtime_secs(meta: &fs::Metadata) -> u64 {
    meta.modified().map(secs_of).unwrap_or(0)
}

/// The store of one projection's state folder.
pub(super) struct Content {
    blobs: PathBuf,
    recipes: PathBuf,
    shared: Option<Arc<dyn Shared>>,
    hits: AtomicU64,
    fetched: AtomicU64,
    reused: AtomicU64,
    cold: PathBuf,
    index_file: PathBuf,
    floor: AtomicU64,
    temp: AtomicU64,
    inner: Mutex<Inner>,
}

fn hex(hash: &Hash) -> String {
    hash.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(crate) fn unhex(text: &str) -> Option<Hash> {
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

/// The recipe of `bytes` when the projection chunks them (over
/// [`crate::cdc::PROJECTION_MIN_FILE`]): each chunk's hash and length.
fn recipe_of(bytes: &[u8]) -> Option<Vec<(Hash, u32)>> {
    use crate::cdc::{PROJECTION, PROJECTION_MIN_FILE, spans};
    if (bytes.len() as u64) <= PROJECTION_MIN_FILE {
        return None;
    }
    spans(&PROJECTION, bytes)
        .into_iter()
        .map(|(at, len)| Some((hash_of(bytes.get(at..at + len)?), u32::try_from(len).ok()?)))
        .collect()
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
        let recipes = dir.join("recipes");
        fs::create_dir_all(&recipes).ok()?;
        let cold = dir.join("cold");
        let index_file = dir.join("index");
        let mut inner = Inner::default();
        // Blobs, oldest written first, so the least recently used go first again.
        let mut found: Vec<(i64, Hash, u64, u64)> = fs::read_dir(&blobs)
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
                meta.is_file().then_some((written, hash, meta.len(), mtime_secs(&meta)))
            })
            .collect();
        found.sort_unstable();
        for (_, hash, bytes, read_at) in found {
            inner.add(hash, bytes, read_at);
        }
        for entry in fs::read_dir(&cold).into_iter().flatten().filter_map(Result::ok) {
            let name = entry.file_name();
            let Some((hash, bytes)) = name.to_str().and_then(parse_cold) else {
                let _ = fs::remove_file(entry.path());
                continue;
            };
            let Ok(meta) = entry.metadata() else { continue };
            if inner.blobs.contains_key(&hash) {
                // Thawed, and the daemon stopped before the cold copy went.
                let _ = fs::remove_file(entry.path());
                continue;
            }
            inner.cold.insert(hash, Cold { bytes, stored: meta.len(), read_at: mtime_secs(&meta) });
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
        for entry in fs::read_dir(&recipes).ok()?.filter_map(Result::ok) {
            let blob = entry.file_name().to_str().and_then(unhex);
            let recipe = fs::read(entry.path()).ok().and_then(|bytes| decode_recipe(&bytes));
            match (blob, recipe) {
                (Some(blob), Some((_, chunks))) if inner.holds(&blob) => {
                    inner.index_recipe(blob, &chunks);
                }
                _ => {
                    let _ = fs::remove_file(entry.path());
                }
            }
        }
        let Inner { names, blobs: hot, cold: frozen, .. } = &mut inner;
        names.retain(|_, hash| hot.contains_key(hash) || frozen.contains_key(hash));
        let store = Self {
            blobs,
            recipes,
            shared: None,
            hits: AtomicU64::new(0),
            fetched: AtomicU64::new(0),
            reused: AtomicU64::new(0),
            cold,
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

    fn recipe_path(&self, hash: &Hash) -> PathBuf {
        self.recipes.join(hex(hash))
    }

    /// Drops blob `hash` and its recipe from the disk.
    fn drop_blob(&self, inner: &mut Inner, hash: &Hash) {
        inner.forget(hash);
        let _ = fs::remove_file(self.blob_path(hash));
        let _ = fs::remove_file(self.recipe_path(hash));
    }

    /// This store reading through to `shared` (RFD 0065 piece 12; `None`, the default, reads
    /// nothing from and publishes nothing to any shared store).
    pub(super) fn with_shared(mut self, shared: Option<Arc<dyn Shared>>) -> Self {
        self.shared = shared;
        self
    }

    /// What reads through to the shared store moved.
    pub(super) fn transfer(&self) -> Transfer {
        Transfer {
            hits: self.hits.load(Ordering::Relaxed),
            fetched: self.fetched.load(Ordering::Relaxed),
            reused: self.reused.load(Ordering::Relaxed),
        }
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
        inner.names.get(name).is_some_and(|hash| inner.holds(hash))
    }

    /// `name`'s bytes, checked against their hash (a damaged blob is dropped, never served).
    pub(super) fn get(&self, name: &Name) -> Option<(Hash, Vec<u8>)> {
        let (hash, was) = {
            let mut inner = self.lock();
            let hash = *inner.names.get(name)?;
            if let Some(cold) = inner.cold.get(&hash).copied() {
                drop(inner);
                return self.thaw(name, hash, cold);
            }
            if !inner.blobs.contains_key(&hash) {
                inner.names.remove(name);
                return None;
            }
            (hash, inner.touch(hash))
        };
        if was.is_some_and(|was| now_secs().saturating_sub(was) > READ_AT_SLACK) {
            self.mark_read(&hash);
        }
        let bytes = fs::read(self.blob_path(&hash)).ok();
        match bytes {
            Some(bytes) if hash_of(&bytes) == hash => Some((hash, bytes)),
            _ => {
                let mut inner = self.lock();
                self.drop_blob(&mut inner, &hash);
                inner.names.remove(name);
                None
            }
        }
    }

    /// Whether the store holds the blob `hash` (a listing's hash of a whole file, RFD 0065 piece
    /// 6): found by what the bytes are, so a renamed or touched file is a hit with no index record.
    pub(super) fn has_hash(&self, hash: &Hash) -> bool {
        self.lock().blobs.contains_key(hash)
    }

    /// Blob `hash`'s bytes, checked against it (a damaged blob is dropped, never served).
    pub(super) fn get_hash(&self, hash: &Hash) -> Option<Vec<u8>> {
        {
            let mut inner = self.lock();
            if !inner.blobs.contains_key(hash) {
                return None;
            }
            inner.touch(*hash);
        }
        match fs::read(self.blob_path(hash)) {
            Ok(bytes) if hash_of(&bytes) == *hash => Some(bytes),
            _ => {
                self.lock().forget(hash);
                let _ = fs::remove_file(self.blob_path(hash));
                None
            }
        }
    }

    /// Writes now as blob `hash`'s last read on disk (its mtime), for the next daemon's aging.
    fn mark_read(&self, hash: &Hash) {
        if let Ok(file) = fs::File::options().write(true).open(self.blob_path(hash)) {
            let _ = file.set_modified(SystemTime::now());
        }
    }

    /// A cold blob read again: decompressed back into `blobs/`, checked against its hash.
    fn thaw(&self, name: &Name, hash: Hash, cold: Cold) -> Option<(Hash, Vec<u8>)> {
        let path = self.cold.join(cold_name(&hash, cold.bytes));
        let bytes = fs::read(&path).ok().and_then(|packed| zstd::decode_all(&packed[..]).ok());
        let Some(bytes) = bytes.filter(|bytes| hash_of(bytes) == hash) else {
            let mut inner = self.lock();
            inner.cold.remove(&hash);
            inner.names.remove(name);
            drop(inner);
            let _ = fs::remove_file(&path);
            return None;
        };
        // `put` keeps it hot again (room by the floor) and drops the cold copy; with no room it
        // stays cold, and the read is served all the same.
        let _ = self.put(name.clone(), &bytes);
        Some((hash, bytes))
    }

    /// Hard-links blob `hash` at `to` (a file of the same disk); false when it is gone.
    pub(super) fn link(&self, hash: &Hash, to: &Path) -> bool {
        fs::hard_link(self.blob_path(hash), to).is_ok()
    }

    /// Keeps `bytes` as `name`'s, making room down to the floor first (least recently used blobs
    /// go). Returns the hash it is kept under, or `None` when the disk has no room for it. A new
    /// blob is published to the shared store when this machine publishes.
    pub(super) fn put(&self, name: Name, bytes: &[u8]) -> Option<Hash> {
        let hash = hash_of(bytes);
        let have = self.lock().blobs.contains_key(&hash);
        let recipe = if have { None } else { self.keep(hash, bytes)? };
        let mut inner = self.lock();
        if let Some(cold) = inner.cold.remove(&hash) {
            let _ = fs::remove_file(self.cold.join(cold_name(&hash, cold.bytes)));
        }
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
        drop(inner);
        if !have {
            self.publish(&hash, bytes, recipe.as_deref());
        }
        Some(hash)
    }

    /// Writes blob `hash` (`bytes`) and, when it is chunked, its recipe, which it returns.
    /// `None` when the disk has no room for it.
    fn keep(&self, hash: Hash, bytes: &[u8]) -> Option<Option<Vec<(Hash, u32)>>> {
        let temp = self.blobs.join(format!(
            "tmp-{}-{}",
            std::process::id(),
            self.temp.fetch_add(1, Ordering::Relaxed)
        ));
        if fs::write(&temp, bytes).is_err() {
            let _ = fs::remove_file(&temp);
            return None;
        }
        let recipe = recipe_of(bytes);
        let mut inner = self.lock();
        // The temp file already took its bytes: room means the floor holds with it written.
        let floor = self.floor.load(Ordering::Relaxed);
        while disk_free(&self.blobs) < floor {
            let Some(oldest) = inner.order.values().next().copied() else { break };
            self.drop_blob(&mut inner, &oldest);
        }
        if disk_free(&self.blobs) < floor || fs::rename(&temp, self.blob_path(&hash)).is_err() {
            drop(inner);
            let _ = fs::remove_file(&temp);
            return None;
        }
        inner.add(hash, bytes.len() as u64, now_secs());
        if let Some(chunks) = &recipe {
            let size = bytes.len() as u64;
            if fs::write(self.recipe_path(&hash), encode_recipe(size, chunks)).is_ok() {
                inner.index_recipe(hash, chunks);
            }
        }
        Some(recipe)
    }

    /// Puts blob `hash` in the shared store when this machine publishes: a chunked blob as the
    /// chunks the store lacks and its recipe under the blob's hash, any other whole.
    fn publish(&self, hash: &Hash, bytes: &[u8], recipe: Option<&[(Hash, u32)]>) {
        let Some(shared) = self.shared.as_ref().filter(|shared| shared.publishes()) else {
            return;
        };
        if shared.has(hash) {
            return;
        }
        let Some(chunks) = recipe else {
            shared.put(hash, bytes);
            return;
        };
        let mut at = 0usize;
        for (chunk, len) in chunks {
            let len = *len as usize;
            let Some(piece) = bytes.get(at..at + len) else { return };
            if !shared.has(chunk) && !shared.put(chunk, piece) {
                // A recipe naming a chunk the store lacks would fail every reader.
                return;
            }
            at += len;
        }
        shared.put(hash, &encode_recipe(bytes.len() as u64, chunks));
    }

    /// Blob `hash`'s bytes, checked against it: from this disk, else read through to the shared
    /// store (a chunked blob takes only the chunks this disk lacks) and kept here. `None` when
    /// neither holds it.
    // The overlay asks by the listing's hash of a file (RFD 0065 piece 6, cmux#54805, where it
    // takes the place of `get_hash`); until that lands only the tests ask by hash.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(super) fn fetch(&self, hash: &Hash) -> Option<Vec<u8>> {
        let local = {
            let mut inner = self.lock();
            let held = inner.blobs.contains_key(hash);
            if held {
                inner.touch(*hash);
            }
            held
        };
        if local {
            match fs::read(self.blob_path(hash)) {
                Ok(bytes) if hash_of(&bytes) == *hash => return Some(bytes),
                _ => self.drop_blob(&mut self.lock(), hash),
            }
        }
        let shared = self.shared.as_ref()?;
        let answer = shared.get(hash)?;
        let bytes = if hash_of(&answer) == *hash {
            self.fetched.fetch_add(answer.len() as u64, Ordering::Relaxed);
            answer
        } else {
            let (size, chunks) = decode_recipe(&answer)?;
            let mut bytes = Vec::with_capacity(usize::try_from(size).ok()?);
            for (chunk, len) in &chunks {
                let piece = match self.chunk(chunk, *len) {
                    Some(piece) => {
                        self.reused.fetch_add(u64::from(*len), Ordering::Relaxed);
                        piece
                    }
                    None => {
                        let piece = shared.get(chunk).filter(|piece| hash_of(piece) == *chunk)?;
                        self.fetched.fetch_add(piece.len() as u64, Ordering::Relaxed);
                        piece
                    }
                };
                bytes.extend_from_slice(&piece);
            }
            if hash_of(&bytes) != *hash {
                return None;
            }
            bytes
        };
        self.hits.fetch_add(1, Ordering::Relaxed);
        // Kept when the disk has room; served either way.
        let _ = self.keep(*hash, &bytes);
        Some(bytes)
    }

    /// Chunk `chunk` (`len` bytes) from a blob this disk holds, checked against its hash.
    #[cfg_attr(not(test), allow(dead_code))]
    fn chunk(&self, chunk: &Hash, len: u32) -> Option<Vec<u8>> {
        use std::io::{Read as _, Seek as _, SeekFrom};
        let (blob, offset, held) = {
            let inner = self.lock();
            let found = *inner.chunks.get(chunk)?;
            inner.blobs.contains_key(&found.0).then_some(found)?
        };
        if held != len {
            return None;
        }
        let mut file = fs::File::open(self.blob_path(&blob)).ok()?;
        file.seek(SeekFrom::Start(offset)).ok()?;
        let mut piece = vec![0u8; len as usize];
        file.read_exact(&mut piece).ok()?;
        (hash_of(&piece) == *chunk).then_some(piece)
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

    /// One aging pass at `now`: hot blobs unread for `aging.cold_after` go cold (compressed into
    /// `cold/`), cold blobs unread for `aging.delete_after` are deleted. Blobs `pinned` names
    /// are never aged; a hot blob the cache still links (its file has more than one link) is in
    /// use and stays hot. Bounded by `aging.max_cold` compressions.
    pub(super) fn age(&self, now: SystemTime, aging: &Aging, pinned: &HashSet<Name>) -> AgeReport {
        use std::os::unix::fs::MetadataExt as _;
        let now = secs_of(now);
        let cold_before = now.saturating_sub(aging.cold_after.as_secs());
        let delete_before = now.saturating_sub(aging.delete_after.as_secs());
        let mut report = AgeReport::default();
        let (pins, old, dead) = {
            let inner = self.lock();
            let pins: HashSet<Hash> =
                pinned.iter().filter_map(|name| inner.names.get(name).copied()).collect();
            let mut old: Vec<(u64, Hash, u64)> = inner
                .read_at
                .iter()
                .filter(|(_, at)| **at <= cold_before)
                .filter_map(|(hash, at)| Some((*at, *hash, inner.blobs.get(hash)?.0)))
                .collect();
            old.sort_unstable();
            let dead: Vec<(Hash, Cold)> = inner
                .cold
                .iter()
                .filter(|(_, cold)| cold.read_at <= delete_before)
                .map(|(hash, cold)| (*hash, *cold))
                .collect();
            (pins, old, dead)
        };
        let mut compressed = 0;
        for (read_at, hash, bytes) in old {
            if pins.contains(&hash) {
                report.kept_pinned += 1;
                continue;
            }
            let from = self.blob_path(&hash);
            if fs::metadata(&from).is_ok_and(|meta| meta.nlink() > 1) {
                report.kept_linked += 1;
                continue;
            }
            if compressed == aging.max_cold {
                report.deferred += 1;
                continue;
            }
            compressed += 1;
            let Some(stored) = self.freeze(&hash, bytes, read_at) else { continue };
            let mut inner = self.lock();
            if inner.read_at.get(&hash) != Some(&read_at) {
                // Read while it was being compressed: it stays hot.
                drop(inner);
                let _ = fs::remove_file(self.cold.join(cold_name(&hash, bytes)));
                continue;
            }
            inner.forget(&hash);
            inner.cold.insert(hash, Cold { bytes, stored, read_at });
            drop(inner);
            let _ = fs::remove_file(&from);
            report.went_cold_blobs += 1;
            report.went_cold_bytes += bytes;
            report.went_cold_saved_bytes += bytes.saturating_sub(stored);
        }
        let mut gone = HashSet::new();
        for (hash, cold) in dead {
            if pins.contains(&hash) {
                report.kept_pinned += 1;
                continue;
            }
            let mut inner = self.lock();
            if inner.cold.get(&hash).is_none_or(|now| now.read_at != cold.read_at) {
                continue;
            }
            inner.cold.remove(&hash);
            drop(inner);
            let _ = fs::remove_file(self.cold.join(cold_name(&hash, cold.bytes)));
            gone.insert(hash);
            report.deleted_blobs += 1;
            report.deleted_bytes += cold.bytes;
            report.deleted_stored_bytes += cold.stored;
        }
        let mut inner = self.lock();
        if !gone.is_empty() {
            inner.names.retain(|_, hash| !gone.contains(hash));
            self.rewrite(&mut inner);
        }
        report.hot_blobs = inner.blobs.len() as u64;
        report.hot_bytes = inner.blobs.values().map(|(bytes, _)| *bytes).sum();
        report.cold_blobs = inner.cold.len() as u64;
        report.cold_bytes = inner.cold.values().map(|cold| cold.bytes).sum();
        report.cold_stored_bytes = inner.cold.values().map(|cold| cold.stored).sum();
        report
    }

    /// Writes blob `hash`'s compressed copy into `cold/`, its mtime its last read; the bytes
    /// the copy takes, or `None` when it could not be written.
    fn freeze(&self, hash: &Hash, bytes: u64, read_at: u64) -> Option<u64> {
        fs::create_dir_all(&self.cold).ok()?;
        let raw = fs::read(self.blob_path(hash)).ok()?;
        if raw.len() as u64 != bytes {
            return None;
        }
        let packed = zstd::encode_all(&raw[..], COLD_LEVEL).ok()?;
        let temp = self.cold.join(format!(
            "tmp-{}-{}",
            std::process::id(),
            self.temp.fetch_add(1, Ordering::Relaxed)
        ));
        let to = self.cold.join(cold_name(hash, bytes));
        let written = fs::write(&temp, &packed)
            .and_then(|()| {
                fs::File::options()
                    .write(true)
                    .open(&temp)?
                    .set_modified(UNIX_EPOCH + Duration::from_secs(read_at))
            })
            .and_then(|()| fs::rename(&temp, &to));
        if written.is_err() {
            let _ = fs::remove_file(&temp);
            return None;
        }
        Some(packed.len() as u64)
    }

    /// Sets `name`'s last read (tests and the harness: a store whose reads happened days ago).
    #[cfg(test)]
    pub(super) fn set_read_at(&self, name: &Name, at: SystemTime) {
        let mut inner = self.lock();
        let Some(hash) = inner.names.get(name).copied() else { return };
        if let Some(read_at) = inner.read_at.get_mut(&hash) {
            *read_at = secs_of(at);
        }
        if let Some(cold) = inner.cold.get_mut(&hash) {
            cold.read_at = secs_of(at);
        }
    }
}
