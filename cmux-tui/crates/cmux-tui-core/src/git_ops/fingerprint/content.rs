//! What stands for a work tree file's content in a fingerprint: its SHA-256,
//! kept by the file's stat entry.
//!
//! A file is hashed again only when its stat entry (size, the two time
//! stamps, inode, device, mode) is not the kept one, or when the kept hash is
//! "racy" by git's own rule: made less than [`RACY`] after the file's last
//! change, when a later write could still carry the same time stamp. So a
//! read of a work tree at rest reads no file.
//!
//! One read hashes a bounded part of its list: the first [`MAX_FILES`] files,
//! while their sizes stay below [`MAX_BYTES`], and no file above
//! [`MAX_FILE_BYTES`]. A file past a bound counts by its stat entry, so a
//! folder of build output that no ignore rule covers costs one `lstat` a
//! file, never a read.
//!
//! Each file is looked at and read as an [`Entry`] of the daemon's one walk
//! of a work tree (`git_ops/work_tree_entry.rs`): through the open folders of
//! the work tree, never through a link in a folder's place.

use std::collections::HashMap;
use std::io::{ErrorKind, Read as _};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use sha2::{Digest as _, Sha256};

use crate::git_ops::work_tree_entry::{Entry, Kind, Stat, kind_in, stat_of};

/// Files one read gives a content hash.
const MAX_FILES: usize = 8192;
/// Bytes of the files one read gives a content hash, by their sizes.
const MAX_BYTES: u64 = 256 * 1024 * 1024;
/// The largest file that gets a content hash.
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;
/// Kept hashes, in the daemon: enough for the lists of several work trees.
const MAX_KEPT: usize = 65536;
/// git's bound for a racy entry on a file system with coarse time stamps.
const RACY: Duration = Duration::from_secs(2);

/// What `lstat` says of a file, as far as a write to the file moves it.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    size: u64,
    modified: Option<SystemTime>,
    node: Node,
}

/// The parts of a stat entry that only Unix has.
#[derive(Clone, Copy, PartialEq, Eq, Default)]
struct Node {
    changed_seconds: i64,
    changed_nanoseconds: i64,
    inode: u64,
    device: u64,
    mode: u32,
}

impl Stamp {
    /// The later of the two time stamps: a write moves both, and a caller
    /// can set the first back.
    fn last_change(&self) -> Option<SystemTime> {
        let seconds = u64::try_from(self.node.changed_seconds).unwrap_or(0);
        let nanoseconds = u32::try_from(self.node.changed_nanoseconds).unwrap_or(0);
        let changed = UNIX_EPOCH.checked_add(Duration::new(seconds, nanoseconds))?;
        Some(self.modified?.max(changed))
    }

    /// Whether a hash made at `hashed` stays true while this entry stays.
    fn settled_at(&self, hashed: SystemTime) -> bool {
        self.last_change()
            .and_then(|changed| hashed.duration_since(changed).ok())
            .is_some_and(|age| age >= RACY)
    }

    fn executable(&self) -> bool {
        self.node.mode & 0o100 != 0
    }

    fn bytes(&self) -> Vec<u8> {
        let modified =
            self.modified.and_then(|time| time.duration_since(UNIX_EPOCH).ok()).unwrap_or_default();
        let Node { changed_seconds, changed_nanoseconds, inode, device, mode } = self.node;
        format!(
            "{} {}.{} {changed_seconds}.{changed_nanoseconds} {inode} {device} {mode}",
            self.size,
            modified.as_secs(),
            modified.subsec_nanos(),
        )
        .into_bytes()
    }
}

/// The kind and the stamp that a stat entry gives. The entry of a name and
/// the entry of the open file come from the same system struct, so a kept
/// stamp is equal to the next look at the same file.
#[cfg(unix)]
fn seen(stat: &Stat) -> (Kind, Stamp) {
    /// The system's number types differ by platform; each fits here.
    fn wide<T: Into<i128>>(value: T) -> i128 {
        value.into()
    }
    /// A number that the system gives as signed or shorter, as its 64 bits.
    fn bits(value: i128) -> u64 {
        u64::try_from(value & i128::from(u64::MAX)).unwrap_or(0)
    }
    /// A time stamp of the system: seconds since 1970, which can be before
    /// it, and the nanoseconds after that second.
    fn time(seconds: i128, nanoseconds: i128) -> Option<SystemTime> {
        let whole = Duration::from_secs(u64::try_from(seconds.unsigned_abs()).ok()?);
        let second =
            if seconds < 0 { UNIX_EPOCH.checked_sub(whole) } else { UNIX_EPOCH.checked_add(whole) };
        second?.checked_add(Duration::from_nanos(u64::try_from(nanoseconds).ok()?))
    }
    let node = Node {
        changed_seconds: i64::try_from(wide(stat.st_ctime)).unwrap_or(0),
        changed_nanoseconds: i64::try_from(wide(stat.st_ctime_nsec)).unwrap_or(0),
        inode: bits(wide(stat.st_ino)),
        device: bits(wide(stat.st_dev)),
        mode: u32::try_from(wide(stat.st_mode)).unwrap_or(0),
    };
    let stamp = Stamp {
        size: u64::try_from(wide(stat.st_size)).unwrap_or(0),
        modified: time(wide(stat.st_mtime), wide(stat.st_mtime_nsec)),
        node,
    };
    (kind_in(stat), stamp)
}

#[cfg(not(unix))]
fn seen(stat: &Stat) -> (Kind, Stamp) {
    let stamp = Stamp { size: stat.len(), modified: stat.modified().ok(), node: Node::default() };
    (kind_in(stat), stamp)
}

struct Kept {
    stamp: Stamp,
    hash: [u8; 32],
    settled: bool,
    /// The last read that used it.
    read: u64,
}

#[derive(Default)]
struct Cache {
    files: HashMap<PathBuf, Kept>,
    reads: u64,
}

impl Cache {
    /// Keeps `kept` for `path` in a cache of at most `bound` hashes. A full
    /// cache first drops the hashes of the read that is longest ago, and so
    /// on; never those of the read that `kept` is of. So the work tree that
    /// was checked longest ago pays, and a read keeps the hashes that it
    /// comes to next.
    fn keep(&mut self, path: &Path, kept: Kept, bound: usize) {
        while self.files.len() >= bound && !self.files.contains_key(path) {
            let Some(oldest) = self.files.values().map(|held| held.read).min() else { break };
            if oldest == kept.read {
                return;
            }
            self.files.retain(|_, held| held.read != oldest);
        }
        self.files.insert(path.to_path_buf(), kept);
    }
}

/// The kept hashes. The lock is never held while a file is read.
fn cache() -> MutexGuard<'static, Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default).lock().unwrap_or_else(PoisonError::into_inner)
}

/// The content side of one read, with what it cost.
pub(super) struct Reader {
    read: u64,
    files: usize,
    bytes: u64,
    /// Files this read opened and hashed.
    pub(super) files_read: u64,
    /// Bytes of file content this read hashed.
    pub(super) bytes_read: u64,
}

impl Reader {
    pub(super) fn new() -> Self {
        let mut cache = cache();
        cache.reads = cache.reads.wrapping_add(1);
        Self { read: cache.reads, files: 0, bytes: 0, files_read: 0, bytes_read: 0 }
    }

    /// What stands for the content of `entry`, whose hash is kept by `path`.
    /// A link is never followed.
    pub(super) fn token(&mut self, path: &Path, entry: &Entry<'_>) -> Vec<u8> {
        let Some(stat) = entry.stat() else { return b"none".to_vec() };
        let (kind, stamp) = seen(&stat);
        match kind {
            Kind::File => {}
            Kind::Link => {
                let mut token = b"link ".to_vec();
                token.extend_from_slice(&Sha256::digest(entry.link_target().unwrap_or_default()));
                return token;
            }
            Kind::Folder => return b"folder".to_vec(),
            Kind::Other => return b"special".to_vec(),
        }
        if let Some(hash) =
            self.within_bounds(stamp.size).then(|| self.hash(path, entry, stamp)).flatten()
        {
            let mut token =
                if stamp.executable() { b"program ".to_vec() } else { b"file ".to_vec() };
            token.extend_from_slice(&hash);
            return token;
        }
        let mut token = b"stat ".to_vec();
        token.extend_from_slice(&stamp.bytes());
        token
    }

    /// Whether one more file of `size` bytes is inside this read's bounds;
    /// it then counts against them, read or kept, so that the same list
    /// always gives the same files a hash.
    fn within_bounds(&mut self, size: u64) -> bool {
        let bytes = self.bytes.saturating_add(size);
        if self.files >= MAX_FILES || size > MAX_FILE_BYTES || bytes > MAX_BYTES {
            return false;
        }
        self.files = self.files.saturating_add(1);
        self.bytes = bytes;
        true
    }

    /// The file's SHA-256: the kept one while the stat entry stays and the
    /// kept one is not racy, else from the file's bytes.
    fn hash(&mut self, path: &Path, entry: &Entry<'_>, stamp: Stamp) -> Option<[u8; 32]> {
        if let Some(kept) = cache().files.get_mut(path)
            && kept.stamp == stamp
            && kept.settled
        {
            kept.read = self.read;
            return Some(kept.hash);
        }
        let started = SystemTime::now();
        let (hash, bytes, stamp) = hash_file(entry)?;
        self.files_read = self.files_read.saturating_add(1);
        self.bytes_read = self.bytes_read.saturating_add(bytes);
        let kept = Kept { stamp, hash, settled: stamp.settled_at(started), read: self.read };
        cache().keep(path, kept, MAX_KEPT);
        Some(hash)
    }
}

/// The SHA-256 of a regular file's bytes, their count, and the stat entry of
/// the open file from before the read. It follows no link and waits on no
/// FIFO, and reads the file's extent at the open, so appends cannot keep it
/// running.
fn hash_file(entry: &Entry<'_>) -> Option<([u8; 32], u64, Stamp)> {
    let file = entry.open_file().ok()?;
    let (Kind::File, stamp) = seen(&stat_of(&file)?) else { return None };
    let mut file = file.take(stamp.size.min(MAX_FILE_BYTES));
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut bytes = 0_u64;
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                hasher.update(buffer.get(..count)?);
                bytes = bytes.saturating_add(u64::try_from(count).ok()?);
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
    Some((hasher.finalize().into(), bytes, stamp))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(read: u64) -> Kept {
        let stamp = Stamp { size: 1, modified: None, node: Node::default() };
        Kept { stamp, hash: [0; 32], settled: true, read }
    }

    /// Two work trees are checked in turn. Read 3 is of the second one: it used `a1` again,
    /// and it will come to `a2`, which its read before (2) hashed. `b1` and `b2` are of the
    /// other work tree's read (1), which is longer ago.
    #[test]
    fn git_fingerprint_drops_the_hashes_of_the_oldest_read_when_its_cache_is_full() {
        let mut cache = Cache::default();
        for (name, read) in [("b1", 1), ("b2", 1), ("a1", 3), ("a2", 2)] {
            cache.keep(Path::new(name), kept(read), 4);
        }
        cache.keep(Path::new("new"), kept(3), 4);
        let mut names: Vec<_> =
            cache.files.keys().map(|path| path.to_string_lossy().into_owned()).collect();
        names.sort();
        assert_eq!(
            names,
            ["a1", "a2", "new"],
            "a full cache must drop the read that is longest ago, and keep the hash that the \
             current read comes to next"
        );
    }
}
