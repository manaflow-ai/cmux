//! The machine's on-disk cache of lower bytes fetched from the Mac (carried from Austin's
//! `cmux-projfs` chunk cache).
//!
//! A file's bytes are cached in [`CHUNK`]-sized pieces (a small file is one chunk). A chunk's key
//! is a SHA-256 over the file's path, its version (size and modification time, from the
//! manifest) and the chunk number, never the manifest's entry number: a new manifest finds the
//! chunks of every file that did not change, and a file that changed on the Mac can never hit a
//! chunk that is not its own (its old keys stop matching and age out).
//!
//! Each chunk is one file, `DIR/<first two hex digits>/<64 hex digits>`, holding a short header
//! (magic, length, SHA-256 of the bytes) and the bytes. Writes go to a temporary file that is
//! renamed into place. The first read of a chunk in a process checks the whole file against its
//! header; a short or corrupt chunk is a miss and is removed, so the caller fetches it again.
//! The cache survives a remount and holds at most a bound of bytes on disk, evicting the least
//! recently used chunks; recency starts from the files' modification times when it is opened.

use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::{self, Write as _};
use std::os::unix::fs::FileExt as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::SystemTime;

use sha2::{Digest as _, Sha256};

/// The size of one cached chunk, and the largest file fetched whole.
pub const CHUNK: u64 = 4 * 1024 * 1024;

/// The most the cache holds by default (RFD 0007): this, or a quarter of the free disk, if less.
pub const DEFAULT_MAX_BYTES: u64 = 8 * 1024 * 1024 * 1024;

const MAGIC: [u8; 4] = *b"CPFC";
const FORMAT: u32 = 1;
/// Magic, format, data length, SHA-256 of the data.
const HEADER: u64 = 4 + 4 + 8 + 32;
const KEY_DOMAIN: &[u8] = b"cmux-projection chunk v1\0";

/// The cache key of one chunk of one version of one file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChunkKey([u8; 32]);

impl ChunkKey {
    /// The key of chunk `chunk` of the file at `path` (relative) with this size and mtime.
    #[must_use]
    pub fn new(path: &str, size: u64, mtime_ns: i64, chunk: u32) -> Self {
        let mut hash = Sha256::new();
        hash.update(KEY_DOMAIN);
        hash.update((path.len() as u64).to_le_bytes());
        hash.update(path.as_bytes());
        hash.update(size.to_le_bytes());
        hash.update(mtime_ns.to_le_bytes());
        hash.update(chunk.to_le_bytes());
        Self(hash.finalize().into())
    }

    /// The key as 64 lowercase hex digits (the chunk's file name).
    #[must_use]
    pub fn hex(&self) -> String {
        let mut text = String::with_capacity(64);
        for byte in self.0 {
            for nibble in [byte >> 4, byte & 15] {
                // A nibble is always below 16, so this is always a digit.
                text.extend(char::from_digit(u32::from(nibble), 16));
            }
        }
        text
    }

    fn from_hex(text: &str) -> Option<Self> {
        if text.len() != 64 || !text.is_ascii() {
            return None;
        }
        let mut out = [0u8; 32];
        for (byte, pair) in out.iter_mut().zip(text.as_bytes().chunks_exact(2)) {
            *byte = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
        }
        Some(Self(out))
    }
}

/// How full the cache is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CacheUsage {
    pub chunks: u64,
    /// Bytes on disk, headers included.
    pub bytes: u64,
}

struct Meta {
    len: u64,
    tick: u64,
    verified: bool,
}

#[derive(Default)]
struct State {
    map: HashMap<ChunkKey, Meta>,
    lru: BTreeMap<u64, ChunkKey>,
    bytes: u64,
    next_tick: u64,
}

impl State {
    fn tick(&mut self) -> u64 {
        let tick = self.next_tick;
        self.next_tick = self.next_tick.saturating_add(1);
        tick
    }

    fn touch(&mut self, key: &ChunkKey) {
        let tick = self.tick();
        if let Some(meta) = self.map.get_mut(key) {
            self.lru.remove(&meta.tick);
            meta.tick = tick;
            self.lru.insert(tick, *key);
        }
    }

    fn insert(&mut self, key: ChunkKey, len: u64, verified: bool) {
        self.forget(&key);
        let tick = self.tick();
        self.map.insert(key, Meta { len, tick, verified });
        self.lru.insert(tick, key);
        self.bytes = self.bytes.saturating_add(len.saturating_add(HEADER));
    }

    fn forget(&mut self, key: &ChunkKey) -> bool {
        let Some(meta) = self.map.remove(key) else { return false };
        self.lru.remove(&meta.tick);
        self.bytes = self.bytes.saturating_sub(meta.len.saturating_add(HEADER));
        true
    }
}

/// The on-disk chunk cache. Safe to share between threads.
pub struct ChunkCache {
    dir: PathBuf,
    max_bytes: u64,
    state: Mutex<State>,
    tmp_seq: AtomicU64,
}

impl ChunkCache {
    /// Opens (or makes) the cache in `dir`, holding at most `max_bytes` on disk, or with `None`
    /// the default: [`DEFAULT_MAX_BYTES`] or a quarter of the free disk (counting what the cache
    /// already holds as free), whichever is less.
    ///
    /// Leftover temporary files and files that cannot be chunks are removed; chunks beyond the
    /// bound are evicted oldest first.
    pub fn open(dir: &Path, max_bytes: Option<u64>) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let mut found: Vec<(SystemTime, ChunkKey, u64)> = Vec::new();
        for sub in fs::read_dir(dir)? {
            let sub = sub?;
            let name = sub.file_name();
            let Some(name) = name.to_str() else { continue };
            if name.len() != 2 || !sub.file_type()?.is_dir() {
                continue;
            }
            scan_subdir(&sub.path(), &mut found)?;
        }
        found.sort();
        let mut state = State::default();
        for (_, key, len) in found {
            state.insert(key, len, false);
        }
        let max_bytes = max_bytes.unwrap_or_else(|| default_max_bytes(dir, state.bytes));
        let cache = Self {
            dir: dir.to_owned(),
            max_bytes,
            state: Mutex::new(state),
            tmp_seq: AtomicU64::new(0),
        };
        cache.evict_to_fit(&mut cache.lock(), 0, None);
        Ok(cache)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The bound the cache holds to.
    #[must_use]
    pub fn max_bytes(&self) -> u64 {
        self.max_bytes
    }

    /// How many chunks and bytes the cache holds now.
    #[must_use]
    pub fn usage(&self) -> CacheUsage {
        let state = self.lock();
        CacheUsage { chunks: state.map.len() as u64, bytes: state.bytes }
    }

    /// Whether the cache believes it has this chunk. A later read can still miss if the file
    /// turns out short or corrupt, or is evicted in between.
    #[must_use]
    pub fn contains(&self, key: &ChunkKey) -> bool {
        self.lock().map.contains_key(key)
    }

    fn path(&self, key: &ChunkKey) -> PathBuf {
        let hex = key.hex();
        let sub = hex.get(..2).unwrap_or_default().to_owned();
        self.dir.join(sub).join(hex)
    }

    /// Reads `len` bytes at `offset` of a chunk whose full length must be `chunk_len` (fewer at
    /// its end). `None` is a miss; a chunk whose length or checksum is wrong is removed.
    pub fn read(&self, key: &ChunkKey, chunk_len: u64, offset: u64, len: u64) -> Option<Vec<u8>> {
        let verified = {
            let mut state = self.lock();
            let meta = state.map.get(key)?;
            if meta.len != chunk_len {
                drop(state);
                self.remove(key);
                return None;
            }
            let verified = meta.verified;
            state.touch(key);
            verified
        };
        let start = offset.min(chunk_len);
        let end = offset.saturating_add(len).min(chunk_len);
        let got = if verified {
            self.read_range(key, start, end)
        } else {
            self.read_and_verify(key, chunk_len, start, end)
        };
        if got.is_none() {
            self.remove(key);
        }
        got
    }

    fn read_range(&self, key: &ChunkKey, start: u64, end: u64) -> Option<Vec<u8>> {
        let file = File::open(self.path(key)).ok()?;
        let mut buf = vec![0u8; usize::try_from(end.saturating_sub(start)).ok()?];
        file.read_exact_at(&mut buf, HEADER.saturating_add(start)).ok()?;
        Some(buf)
    }

    fn read_and_verify(
        &self,
        key: &ChunkKey,
        chunk_len: u64,
        start: u64,
        end: u64,
    ) -> Option<Vec<u8>> {
        let raw = fs::read(self.path(key)).ok()?;
        if raw.len() as u64 != HEADER.saturating_add(chunk_len) {
            return None;
        }
        let (magic, rest) = raw.split_first_chunk::<4>()?;
        let (format, rest) = rest.split_first_chunk::<4>()?;
        let (len, rest) = rest.split_first_chunk::<8>()?;
        let (sum, data) = rest.split_first_chunk::<32>()?;
        let (format, len) = (u32::from_le_bytes(*format), u64::from_le_bytes(*len));
        if *magic != MAGIC || format != FORMAT || len != chunk_len {
            return None;
        }
        let digest: [u8; 32] = Sha256::digest(data).into();
        if *sum != digest {
            return None;
        }
        if let Some(meta) = self.lock().map.get_mut(key) {
            meta.verified = true;
        }
        let range = usize::try_from(start).ok()?..usize::try_from(end).ok()?;
        data.get(range).map(<[u8]>::to_vec)
    }

    /// Stores a chunk. Returns `false` (and stores nothing) when one chunk is larger than the
    /// whole cache. Older chunks are evicted to make room.
    pub fn put(&self, key: &ChunkKey, bytes: &[u8]) -> io::Result<bool> {
        let size = (bytes.len() as u64).saturating_add(HEADER);
        if size > self.max_bytes {
            return Ok(false);
        }
        let path = self.path(key);
        let parent = path.parent().unwrap_or(&self.dir);
        fs::create_dir_all(parent)?;
        let seq = self.tmp_seq.fetch_add(1, Ordering::Relaxed);
        let tmp = parent.join(format!("{}.{}.{seq}.tmp", key.hex(), std::process::id()));
        let written = write_chunk(&tmp, bytes).and_then(|()| fs::rename(&tmp, &path));
        if let Err(error) = written {
            let _ = fs::remove_file(&tmp);
            return Err(error);
        }
        let mut state = self.lock();
        state.forget(key);
        self.evict_to_fit(&mut state, size, Some(key));
        state.insert(*key, bytes.len() as u64, true);
        Ok(true)
    }

    /// Removes one chunk, if present.
    pub fn remove(&self, key: &ChunkKey) {
        let mut state = self.lock();
        if state.forget(key) {
            let _ = fs::remove_file(self.path(key));
        }
    }

    /// Evicts least recently used chunks until `extra` more bytes fit. Runs under the state lock
    /// so an eviction never deletes a chunk another thread has just stored under the same key.
    fn evict_to_fit(&self, state: &mut State, extra: u64, keep: Option<&ChunkKey>) {
        while state.bytes.saturating_add(extra) > self.max_bytes {
            let Some(victim) = state.lru.values().find(|key| Some(*key) != keep).copied() else {
                break;
            };
            state.forget(&victim);
            let _ = fs::remove_file(self.path(&victim));
        }
    }
}

/// [`DEFAULT_MAX_BYTES`], or a quarter of the free disk under `dir` plus the `held` bytes the
/// cache already has there, whichever is less. With no answer from the disk, the default.
fn default_max_bytes(dir: &Path, held: u64) -> u64 {
    match available_bytes(dir) {
        Some(free) => DEFAULT_MAX_BYTES.min(free.saturating_add(held) / 4),
        None => DEFAULT_MAX_BYTES,
    }
}

/// The bytes an unprivileged writer may still use on the filesystem holding `path`.
#[cfg(target_os = "linux")]
fn available_bytes(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt as _;
    let mut bytes = path.as_os_str().as_bytes().to_vec();
    bytes.push(0);
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
    // SAFETY: `bytes` is NUL-terminated and outlives the call; `stat` is written by statvfs(3)
    // before it is read.
    let status = unsafe { libc::statvfs(bytes.as_ptr().cast(), stat.as_mut_ptr()) };
    if status != 0 {
        return None;
    }
    // SAFETY: statvfs returned 0, so it filled `stat`.
    let stat = unsafe { stat.assume_init() };
    Some(stat.f_bavail.saturating_mul(stat.f_frsize.max(1)))
}

/// Off Linux (the mount is Linux only) the default bound stands.
#[cfg(not(target_os = "linux"))]
fn available_bytes(_path: &Path) -> Option<u64> {
    None
}

fn write_chunk(tmp: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = File::create(tmp)?;
    let mut header = Vec::with_capacity(48);
    header.extend_from_slice(&MAGIC);
    header.extend_from_slice(&FORMAT.to_le_bytes());
    header.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
    header.extend_from_slice(&Sha256::digest(bytes));
    file.write_all(&header)?;
    file.write_all(bytes)
}

/// Collects the chunks in one `DIR/xx` folder and removes what cannot be one.
fn scan_subdir(sub: &Path, found: &mut Vec<(SystemTime, ChunkKey, u64)>) -> io::Result<()> {
    for file in fs::read_dir(sub)? {
        let file = file?;
        let key = file.file_name().to_str().and_then(ChunkKey::from_hex);
        let meta = file.metadata()?;
        match key {
            Some(key) if meta.is_file() && meta.len() >= HEADER => {
                let when = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                found.push((when, key, meta.len().saturating_sub(HEADER)));
            }
            _ if meta.is_file() => {
                let _ = fs::remove_file(file.path());
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "cache_tests.rs"]
mod tests;
