//! The machine's on-disk chunk cache.
//!
//! A file's bytes are cached in [`CHUNK`]-sized pieces (a small file is one chunk). A chunk's key
//! is a SHA-256 over the file's path, its version (size, modification and change times) and the
//! chunk number, so a file that changed on the Mac, or another file, can never hit a chunk that
//! is not its own: the old keys simply stop matching and age out.
//!
//! Each chunk is one file, `DIR/<first two hex digits>/<64 hex digits>`, holding a short header
//! (magic, length, SHA-256 of the bytes) and the bytes. Writes go to a temporary file that is
//! renamed into place. The first read of a chunk in a process checks the whole file against its
//! header; a short or corrupt chunk is a miss and is removed. The cache survives a remount, and
//! holds at most a configured number of bytes, evicting the least recently used chunks.
//! Recency starts from the files' modification times when the cache is opened.

use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::SystemTime;

use sha2::{Digest, Sha256};

use crate::manifest::Version;

/// The size of one cached chunk, and the largest file fetched whole.
pub const CHUNK: u64 = 4 << 20;

const MAGIC: [u8; 4] = *b"CPFC";
const FORMAT: u32 = 1;
/// Magic, format, data length, SHA-256 of the data.
const HEADER: u64 = 4 + 4 + 8 + 32;
const KEY_DOMAIN: &[u8] = b"cmux-projfs chunk v1\0";

/// How many chunks a file of `size` bytes has (an empty file has one, of length zero).
pub fn chunk_count(size: u64) -> u32 {
    size.div_ceil(CHUNK).max(1) as u32
}

/// The length of chunk `chunk` of a file of `size` bytes.
pub fn chunk_len(size: u64, chunk: u32) -> u64 {
    let start = u64::from(chunk) * CHUNK;
    size.saturating_sub(start).min(CHUNK)
}

/// The cache key of one chunk of one version of one file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ChunkKey([u8; 32]);

impl ChunkKey {
    pub fn new(path: &str, version: Version, chunk: u32) -> ChunkKey {
        let mut h = Sha256::new();
        h.update(KEY_DOMAIN);
        h.update((path.len() as u64).to_le_bytes());
        h.update(path.as_bytes());
        h.update(version.size.to_le_bytes());
        h.update(version.mtime_ns.to_le_bytes());
        h.update(version.ctime_ns.to_le_bytes());
        h.update(chunk.to_le_bytes());
        ChunkKey(h.finalize().into())
    }

    /// The key as 64 lowercase hex digits (the chunk's file name).
    pub fn hex(&self) -> String {
        to_hex(&self.0)
    }

    fn from_hex(s: &str) -> Option<ChunkKey> {
        if s.len() != 64 {
            return None;
        }
        let mut out = [0u8; 32];
        for (i, byte) in out.iter_mut().enumerate() {
            *byte = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
        }
        Some(ChunkKey(out))
    }
}

fn to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(DIGITS[usize::from(b >> 4)] as char);
        s.push(DIGITS[usize::from(b & 15)] as char);
    }
    s
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
    fn touch(&mut self, key: &ChunkKey) {
        let tick = self.next_tick;
        if let Some(meta) = self.map.get_mut(key) {
            self.lru.remove(&meta.tick);
            meta.tick = tick;
            self.lru.insert(tick, *key);
            self.next_tick += 1;
        }
    }

    fn insert(&mut self, key: ChunkKey, len: u64, verified: bool) {
        self.forget(&key);
        let tick = self.next_tick;
        self.next_tick += 1;
        self.map.insert(key, Meta { len, tick, verified });
        self.lru.insert(tick, key);
        self.bytes += len + HEADER;
    }

    fn forget(&mut self, key: &ChunkKey) -> bool {
        match self.map.remove(key) {
            Some(meta) => {
                self.lru.remove(&meta.tick);
                self.bytes -= meta.len + HEADER;
                true
            }
            None => false,
        }
    }
}

/// The on-disk chunk cache. Safe to share between threads.
pub struct ChunkCache {
    dir: PathBuf,
    max_bytes: u64,
    state: Mutex<State>,
    tmp_seq: AtomicU64,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl ChunkCache {
    /// Opens (or creates) the cache in `dir`, holding at most `max_bytes` on disk.
    ///
    /// Leftover temporary files and files that cannot be chunks are removed; chunks beyond the
    /// bound are evicted oldest first.
    pub fn open(dir: &Path, max_bytes: u64) -> io::Result<ChunkCache> {
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
        let cache = ChunkCache {
            dir: dir.to_owned(),
            max_bytes,
            state: Mutex::new(state),
            tmp_seq: AtomicU64::new(0),
        };
        cache.evict_to_fit(&mut lock(&cache.state), 0, None);
        Ok(cache)
    }

    /// The bound given to [`ChunkCache::open`].
    pub fn max_bytes(&self) -> u64 {
        self.max_bytes
    }

    /// How many chunks and bytes the cache holds now.
    pub fn usage(&self) -> CacheUsage {
        let s = lock(&self.state);
        CacheUsage { chunks: s.map.len() as u64, bytes: s.bytes }
    }

    /// Whether the cache believes it has this chunk. A later read can still miss if the file
    /// turns out short or corrupt, or is evicted in between.
    pub fn contains(&self, key: &ChunkKey) -> bool {
        lock(&self.state).map.contains_key(key)
    }

    fn path(&self, key: &ChunkKey) -> PathBuf {
        let hex = key.hex();
        self.dir.join(&hex[..2]).join(hex)
    }

    /// Reads `len` bytes at `offset` of a chunk whose full length must be `chunk_len`.
    ///
    /// Returns `None` on a miss. A chunk whose length or checksum is wrong is removed.
    pub fn read(&self, key: &ChunkKey, chunk_len: u64, offset: u64, len: u64) -> Option<Vec<u8>> {
        let verified = {
            let mut s = lock(&self.state);
            let meta = s.map.get(key)?;
            if meta.len != chunk_len {
                drop(s);
                self.remove(key);
                return None;
            }
            let verified = meta.verified;
            s.touch(key);
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
        let mut buf = vec![0u8; (end - start) as usize];
        file.read_exact_at(&mut buf, HEADER + start).ok()?;
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
        if raw.len() as u64 != HEADER + chunk_len || raw[..4] != MAGIC {
            return None;
        }
        let format = u32::from_le_bytes(raw[4..8].try_into().ok()?);
        let len = u64::from_le_bytes(raw[8..16].try_into().ok()?);
        let data = &raw[HEADER as usize..];
        if format != FORMAT || len != chunk_len || raw[16..48] != Sha256::digest(data)[..] {
            return None;
        }
        if let Some(meta) = lock(&self.state).map.get_mut(key) {
            meta.verified = true;
        }
        Some(data[start as usize..end as usize].to_vec())
    }

    /// Stores a chunk. Returns `false` (and stores nothing) when one chunk is larger than the
    /// whole cache. Older chunks are evicted to make room.
    pub fn put(&self, key: &ChunkKey, bytes: &[u8]) -> io::Result<bool> {
        let len = bytes.len() as u64;
        if len + HEADER > self.max_bytes {
            return Ok(false);
        }
        let path = self.path(key);
        let parent = path.parent().unwrap_or(&self.dir);
        fs::create_dir_all(parent)?;
        let seq = self.tmp_seq.fetch_add(1, Ordering::Relaxed);
        let tmp = parent.join(format!("{}.{}.{seq}.tmp", key.hex(), std::process::id()));
        let written = write_chunk(&tmp, bytes).and_then(|()| fs::rename(&tmp, &path));
        if let Err(e) = written {
            let _ = fs::remove_file(&tmp);
            return Err(e);
        }
        let mut s = lock(&self.state);
        s.forget(key);
        self.evict_to_fit(&mut s, len + HEADER, Some(key));
        s.insert(*key, len, true);
        Ok(true)
    }

    /// Removes one chunk, if present.
    pub fn remove(&self, key: &ChunkKey) {
        let mut s = lock(&self.state);
        if s.forget(key) {
            let _ = fs::remove_file(self.path(key));
        }
    }

    /// Evicts least recently used chunks until `extra` more bytes fit. Runs under the state lock
    /// so an eviction never deletes a chunk another thread has just stored under the same key.
    fn evict_to_fit(&self, s: &mut State, extra: u64, keep: Option<&ChunkKey>) {
        while s.bytes + extra > self.max_bytes {
            let Some((_, victim)) =
                s.lru.iter().find(|(_, k)| Some(*k) != keep).map(|(t, k)| (*t, *k))
            else {
                break;
            };
            s.forget(&victim);
            let _ = fs::remove_file(self.path(&victim));
        }
    }
}

fn write_chunk(tmp: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut f = File::create(tmp)?;
    let mut header = Vec::with_capacity(HEADER as usize);
    header.extend_from_slice(&MAGIC);
    header.extend_from_slice(&FORMAT.to_le_bytes());
    header.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
    header.extend_from_slice(&Sha256::digest(bytes));
    f.write_all(&header)?;
    f.write_all(bytes)
}

/// Collects the chunks in one `DIR/xx` directory and removes what cannot be one.
fn scan_subdir(sub: &Path, found: &mut Vec<(SystemTime, ChunkKey, u64)>) -> io::Result<()> {
    for f in fs::read_dir(sub)? {
        let f = f?;
        let path = f.path();
        let key = f.file_name().to_str().and_then(ChunkKey::from_hex);
        let md = f.metadata()?;
        match key {
            Some(key) if md.is_file() && md.len() >= HEADER => {
                let when = md.modified().unwrap_or(SystemTime::UNIX_EPOCH);
                found.push((when, key, md.len() - HEADER));
            }
            _ if md.is_file() => {
                let _ = fs::remove_file(&path);
            }
            _ => {}
        }
    }
    Ok(())
}
