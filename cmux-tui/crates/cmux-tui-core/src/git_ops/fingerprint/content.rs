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

use std::collections::HashMap;
use std::fs::{Metadata, OpenOptions};
use std::io::{ErrorKind, Read as _};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use sha2::{Digest as _, Sha256};

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
    fn of(metadata: &Metadata) -> Self {
        Self { size: metadata.len(), modified: metadata.modified().ok(), node: node(metadata) }
    }

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

#[cfg(unix)]
fn node(metadata: &Metadata) -> Node {
    use std::os::unix::fs::MetadataExt as _;
    Node {
        changed_seconds: metadata.ctime(),
        changed_nanoseconds: metadata.ctime_nsec(),
        inode: metadata.ino(),
        device: metadata.dev(),
        mode: metadata.mode(),
    }
}

#[cfg(not(unix))]
fn node(_metadata: &Metadata) -> Node {
    Node::default()
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

    /// What stands for the content at `path`. A link is never followed.
    pub(super) fn token(&mut self, path: &Path) -> Vec<u8> {
        let Ok(metadata) = std::fs::symlink_metadata(path) else { return b"none".to_vec() };
        let kind = metadata.file_type();
        if kind.is_symlink() {
            let target = std::fs::read_link(path).unwrap_or_default();
            let mut token = b"link ".to_vec();
            token.extend_from_slice(&Sha256::digest(target.as_os_str().as_encoded_bytes()));
            return token;
        }
        if kind.is_dir() {
            return b"folder".to_vec();
        }
        if !kind.is_file() {
            return b"special".to_vec();
        }
        let stamp = Stamp::of(&metadata);
        if let Some(hash) = self.within_bounds(stamp.size).then(|| self.hash(path, stamp)).flatten()
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
    fn hash(&mut self, path: &Path, stamp: Stamp) -> Option<[u8; 32]> {
        if let Some(kept) = cache().files.get_mut(path)
            && kept.stamp == stamp
            && kept.settled
        {
            kept.read = self.read;
            return Some(kept.hash);
        }
        let started = SystemTime::now();
        let (hash, bytes, stamp) = hash_file(path)?;
        self.files_read = self.files_read.saturating_add(1);
        self.bytes_read = self.bytes_read.saturating_add(bytes);
        let kept = Kept { stamp, hash, settled: stamp.settled_at(started), read: self.read };
        let mut cache = cache();
        if cache.files.len() >= MAX_KEPT && !cache.files.contains_key(path) {
            // Keep what this read uses: at most MAX_FILES entries.
            let read = self.read;
            cache.files.retain(|_, kept| kept.read == read);
        }
        if cache.files.len() < MAX_KEPT || cache.files.contains_key(path) {
            cache.files.insert(path.to_path_buf(), kept);
        }
        Some(hash)
    }
}

/// The SHA-256 of a regular file's bytes, their count, and the stat entry of
/// the open file from before the read. It follows no link and waits on no
/// FIFO, and reads the file's extent at the open, so appends cannot keep it
/// running.
fn hash_file(path: &Path) -> Option<([u8; 32], u64, Stamp)> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW);
    }
    let file = options.open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    let stamp = Stamp::of(&metadata);
    let mut file = file.take(metadata.len().min(MAX_FILE_BYTES));
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
