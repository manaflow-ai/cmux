//! The phone's own read-first store: what a surface last showed, kept on the phone so the next
//! cold launch draws it at once and the Mac's answer only refreshes it (Leo, 2026-11-22: "being
//! able to sync up my phone reading from mac but also from what the phone itself is storing").
//!
//! One directory, one file per key. A key is the account (or team) the data belongs to, the
//! device it came from (a Mac id) and the surface's kind (`agent_chats`; later Home rows and
//! terminal frames). The value is opaque bytes the app encodes; the store never reads them.
//!
//! Bounded and constant cost: a value larger than [`ReadStoreLimits::max_value_bytes`] is
//! refused (a surface keeps only its first screen), and past [`ReadStoreLimits::max_entries`]
//! files the ones written longest ago leave. A write is atomic (a temp file, fsync, rename), so
//! a crash leaves the old value or the new one, never half of one. A file whose header names
//! another key (a hash collision) or that does not parse reads as nothing.
//!
//! This is the one module of the crate that does I/O: plain `std::fs` on the directory it is
//! given, no threads, no runtime. The app picks the directory (on iOS: Application Support,
//! excluded from backups, readable after first unlock) and clears it on sign-out
//! ([`ReadStore::remove_all`]).

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

/// The first bytes of every entry file (and its format version).
const MAGIC: &[u8] = b"cmux-read/1\n";
const ENTRY_EXTENSION: &str = "entry";
const TEMP_EXTENSION: &str = "tmp";

/// Who and what one entry is: the account or team, the device the data came from and the
/// surface's kind.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ReadKey {
    /// The account (or team) the data belongs to: another account never reads it.
    pub scope: String,
    /// The device the data came from (a Mac id).
    pub device: String,
    /// The surface (`agent_chats`).
    pub kind: String,
}

impl ReadKey {
    pub fn new(
        scope: impl Into<String>,
        device: impl Into<String>,
        kind: impl Into<String>,
    ) -> Self {
        Self { scope: scope.into(), device: device.into(), kind: kind.into() }
    }

    /// The header bytes: each field's length (u32 LE) and bytes.
    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for field in [&self.scope, &self.device, &self.kind] {
            let len = u32::try_from(field.len()).unwrap_or(u32::MAX);
            out.extend_from_slice(&len.to_le_bytes());
            out.extend_from_slice(field.as_bytes());
        }
        out
    }

    /// The entry's file name: a stable hash of the key (FNV-1a 64), so no account or Mac id
    /// shows in a file name.
    fn file_name(&self) -> String {
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in self.encode() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("{hash:016x}.{ENTRY_EXTENSION}")
    }
}

/// How much the store keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadStoreLimits {
    /// Entries kept; past it the ones written longest ago leave.
    pub max_entries: usize,
    /// The largest value kept; a larger one is refused.
    pub max_value_bytes: usize,
}

impl Default for ReadStoreLimits {
    /// 64 entries of at most 256 KiB: a few accounts' Macs and surfaces, 16 MiB at the very most.
    fn default() -> Self {
        Self { max_entries: 64, max_value_bytes: 256 * 1024 }
    }
}

/// Why a write was refused.
#[derive(Debug)]
pub enum ReadStoreError {
    /// The value is larger than [`ReadStoreLimits::max_value_bytes`].
    TooLarge {
        size: usize,
        limit: usize,
    },
    Io(io::Error),
}

impl std::fmt::Display for ReadStoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooLarge { size, limit } => {
                write!(f, "value of {size} bytes is over the {limit} byte limit")
            }
            Self::Io(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for ReadStoreError {}

impl From<io::Error> for ReadStoreError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// The store on one directory. Calls from several threads take turns.
#[derive(Debug)]
pub struct ReadStore {
    directory: PathBuf,
    limits: ReadStoreLimits,
    /// Writes, removals and eviction take turns (reads need no lock: a rename is atomic).
    lock: Mutex<()>,
}

impl ReadStore {
    /// The store on `directory`, created if missing.
    pub fn open(directory: impl Into<PathBuf>, limits: ReadStoreLimits) -> io::Result<Self> {
        let directory = directory.into();
        fs::create_dir_all(&directory)?;
        Ok(Self { directory, limits, lock: Mutex::new(()) })
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn limits(&self) -> ReadStoreLimits {
        self.limits
    }

    /// The value kept for `key`, if any. A missing, unreadable or foreign file reads as nothing.
    pub fn get(&self, key: &ReadKey) -> Option<Vec<u8>> {
        let bytes = fs::read(self.directory.join(key.file_name())).ok()?;
        let rest = bytes.strip_prefix(MAGIC)?;
        let header = key.encode();
        let value = rest.strip_prefix(header.as_slice())?;
        // A file larger than the limit was not written by this store's rules: nothing.
        (value.len() <= self.limits.max_value_bytes).then(|| value.to_vec())
    }

    /// Keeps `value` for `key`, replacing what was there, atomically. Past the entry limit the
    /// entries written longest ago leave.
    pub fn put(&self, key: &ReadKey, value: &[u8]) -> Result<(), ReadStoreError> {
        if value.len() > self.limits.max_value_bytes {
            return Err(ReadStoreError::TooLarge {
                size: value.len(),
                limit: self.limits.max_value_bytes,
            });
        }
        let _turn = self.lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Signed out (remove_all) or deleted by the system: start the directory again.
        fs::create_dir_all(&self.directory)?;
        let name = key.file_name();
        let target = self.directory.join(&name);
        let temp = self.directory.join(temp_name(&name));
        let written = (|| -> io::Result<()> {
            let mut file = fs::File::create(&temp)?;
            file.write_all(MAGIC)?;
            file.write_all(&key.encode())?;
            file.write_all(value)?;
            file.sync_all()?;
            fs::rename(&temp, &target)
        })();
        if let Err(error) = written {
            let _ = fs::remove_file(&temp);
            return Err(error.into());
        }
        self.evict(&name);
        Ok(())
    }

    /// Forgets `key`.
    pub fn remove(&self, key: &ReadKey) -> io::Result<()> {
        let _turn = self.lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match fs::remove_file(self.directory.join(key.file_name())) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    /// Sign-out: every entry (and any leftover temp file) goes. Only this store's files are
    /// removed; the directory stays.
    pub fn remove_all(&self) -> io::Result<()> {
        let _turn = self.lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let entries = match fs::read_dir(&self.directory) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        };
        let mut first_error = None;
        for entry in entries.flatten() {
            let path = entry.path();
            if !is_store_file(&path) {
                continue;
            }
            if let Err(error) = fs::remove_file(&path)
                && error.kind() != io::ErrorKind::NotFound
            {
                first_error.get_or_insert(error);
            }
        }
        first_error.map_or(Ok(()), Err)
    }

    /// The entries kept now (their count, for tests and the app's log).
    pub fn len(&self) -> usize {
        fs::read_dir(&self.directory)
            .map(|entries| {
                entries
                    .flatten()
                    .filter(|entry| has_extension(&entry.path(), ENTRY_EXTENSION))
                    .count()
            })
            .unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Past `max_entries`, removes the entries written longest ago (never `keep`, the one just
    /// written). The directory holds at most `max_entries + 1` entries, so this is constant cost.
    fn evict(&self, keep: &str) {
        let Ok(entries) = fs::read_dir(&self.directory) else { return };
        let mut kept: Vec<(SystemTime, PathBuf)> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| has_extension(path, ENTRY_EXTENSION))
            .filter(|path| path.file_name().is_some_and(|name| name != keep))
            .map(|path| {
                let modified = fs::metadata(&path)
                    .and_then(|m| m.modified())
                    .unwrap_or(SystemTime::UNIX_EPOCH);
                (modified, path)
            })
            .collect();
        // `keep` counts as one.
        let limit = self.limits.max_entries.saturating_sub(1);
        if kept.len() <= limit {
            return;
        }
        kept.sort();
        let excess = kept.len() - limit;
        for (_, path) in kept.into_iter().take(excess) {
            let _ = fs::remove_file(path);
        }
    }
}

fn temp_name(name: &str) -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{name}.{}.{n}.{TEMP_EXTENSION}", std::process::id())
}

fn has_extension(path: &Path, extension: &str) -> bool {
    path.extension().is_some_and(|ext| ext == extension)
}

fn is_store_file(path: &Path) -> bool {
    has_extension(path, ENTRY_EXTENSION)
        || (has_extension(path, TEMP_EXTENSION)
            && path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.contains(&format!(".{ENTRY_EXTENSION}."))))
}
