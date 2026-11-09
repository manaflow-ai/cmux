//! Which process holds this machine's WireGuard key.
//!
//! A WireGuard key carries one live session per peer: two processes that
//! run a tunnel with the same key, or with two keys that answer for one
//! machine, each take the other's handshakes and traffic. One lock decides
//! which process holds the key. The paired-peer link (`cmux link serve`)
//! and acpmux's Labs WireGuard transport both take it before they read a
//! private key for a session; the second taker gets
//! [`KeyHolderError::KeyHeld`] with the holder's pid and runs without
//! WireGuard (acpmux's peers go on over ssh and the relay).
//!
//! The lock is `flock` (the OS lock of [`File::try_lock`]) on `wg-key.lock`
//! in one directory, plus `wg-key.pid`, the holder's pid. The OS drops the
//! lock when its holder exits, crash and `kill -9` included, so a pid record
//! whose lock is not held is stale and never counts as held.
//!
//! Where the lock lives: the build's acpmux home, where the key that becomes
//! the one key (`node.wg.key`) is kept. `ACPMUX_HOME` wins; otherwise a
//! release or channel build uses `~/.acpmux` and a tagged DEV build its own
//! `~/.acpmux/builds/<key>` (cmux-agent-pane-policy `acpmux_home`). So a
//! DEV build's link and acpmux contend with each other and never with the
//! release app's, the same isolation as the keys themselves.
//!
//! Only this module opens a key file: [`KeyHolder::open`] for a session
//! (the lock must be held), [`open_for_public_key`] for a caller that only
//! derives the public half (a join, a status line). The file names are
//! spelled only here; `tests/key_files_only_in_key_holder.rs` checks it.

use std::fs::{File, OpenOptions, TryLockError};
use std::io;
use std::path::{Path, PathBuf};

/// The lock file, in the lock directory.
pub const LOCK_FILE: &str = "wg-key.lock";
/// The holder's pid, written once the lock is taken.
pub const PID_FILE: &str = "wg-key.pid";

/// A WireGuard private key file this module guards.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyFile {
    /// The paired-peer link's key, base64, in the link state directory.
    Link,
    /// acpmux's node key, 32 raw bytes, in the acpmux home.
    Node,
    /// A node key a rekey sent the platform and has not put in place yet, 32 raw bytes, next
    /// to [`Self::Node`]. It stays until the platform's answer settles it.
    NodePending,
}

impl KeyFile {
    pub fn file_name(self) -> &'static str {
        match self {
            Self::Link => "private.key",
            Self::Node => "node.wg.key",
            Self::NodePending => "node.wg.pending",
        }
    }

    /// The key's path in `dir`, for creating, moving or removing it. Reads go
    /// through [`KeyHolder::open`] or [`open_for_public_key`].
    pub fn path_in(self, dir: &Path) -> PathBuf {
        dir.join(self.file_name())
    }
}

#[derive(Debug)]
pub enum KeyHolderError {
    /// Another live process holds the key; `pid` is its record, `None` when
    /// it has not written one yet or the record is unreadable.
    KeyHeld {
        pid: Option<u32>,
    },
    Io(io::Error),
}

impl std::fmt::Display for KeyHolderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::KeyHeld { pid: Some(pid) } => {
                write!(f, "process {pid} holds this machine's WireGuard key")
            }
            Self::KeyHeld { pid: None } => {
                write!(f, "another process holds this machine's WireGuard key")
            }
            Self::Io(error) => write!(f, "WireGuard key lock: {error}"),
        }
    }
}

impl std::error::Error for KeyHolderError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::KeyHeld { .. } => None,
        }
    }
}

impl From<io::Error> for KeyHolderError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// The held lock. Dropping it (or the process exiting) releases the key.
#[derive(Debug)]
pub struct KeyHolder {
    dir: PathBuf,
    // Held for the holder's life: the OS lock goes with this descriptor.
    _lock: File,
}

impl KeyHolder {
    /// Take the key lock in `dir` (created owner-only when missing), never
    /// blocking.
    pub fn acquire(dir: &Path) -> Result<Self, KeyHolderError> {
        create_private_dir(dir)?;
        let lock = open_private(&dir.join(LOCK_FILE), true)?;
        match lock.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => {
                return Err(KeyHolderError::KeyHeld { pid: recorded_pid(dir) });
            }
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        write_pid(dir, std::process::id())?;
        Ok(Self { dir: dir.to_path_buf(), _lock: lock })
    }

    /// The directory the lock is in: the key files it guards sit next to it.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Open `key` in `dir` for a session with `open` (the owner's own
    /// opener, with its permission checks).
    pub fn open<T, E>(
        &self,
        key: KeyFile,
        dir: &Path,
        open: impl FnOnce(&Path) -> Result<T, E>,
    ) -> Result<T, E> {
        open(&key.path_in(dir))
    }
}

impl Drop for KeyHolder {
    fn drop(&mut self) {
        // Before the lock goes: a later holder's record is never removed.
        if recorded_pid(&self.dir) == Some(std::process::id()) {
            let _ = std::fs::remove_file(self.dir.join(PID_FILE));
        }
    }
}

/// Open `key` in `dir` with `open` to derive only its public half. No lock:
/// the caller never runs a session with what it reads.
pub fn open_for_public_key<T, E>(
    key: KeyFile,
    dir: &Path,
    open: impl FnOnce(&Path) -> Result<T, E>,
) -> Result<T, E> {
    open(&key.path_in(dir))
}

/// The pid of the process that holds the lock in `dir`, if one does.
pub fn holder(dir: &Path) -> io::Result<Option<Option<u32>>> {
    let lock = match open_private(&dir.join(LOCK_FILE), false) {
        Ok(lock) => lock,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    match lock.try_lock() {
        Ok(()) => Ok(None),
        Err(TryLockError::WouldBlock) => Ok(Some(recorded_pid(dir))),
        Err(TryLockError::Error(error)) => Err(error),
    }
}

fn recorded_pid(dir: &Path) -> Option<u32> {
    let text = std::fs::read_to_string(dir.join(PID_FILE)).ok()?;
    text.lines().next()?.trim().parse().ok()
}

/// Written in place, under the lock: no other holder writes it, and a stale
/// record left by a killed holder is overwritten on every OS (a rename onto
/// it is not portable). The new record goes over the old one before the rest
/// is cut, so a reader, which takes the first line, never sees an empty file.
fn write_pid(dir: &Path, pid: u32) -> io::Result<()> {
    use std::io::Write as _;
    let record = format!("{pid}\n");
    let mut file = open_private(&dir.join(PID_FILE), true)?;
    file.write_all(record.as_bytes())?;
    file.set_len(record.len() as u64)
}

fn open_private(path: &Path, create: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(create);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}

fn create_private_dir(dir: &Path) -> io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_holder_in_this_process_is_refused_until_the_first_drops() {
        let dir = tempfile_dir("in-process");
        let first = KeyHolder::acquire(&dir).unwrap();
        let pid = std::process::id();
        assert!(matches!(
            KeyHolder::acquire(&dir),
            Err(KeyHolderError::KeyHeld { pid: Some(held) }) if held == pid
        ));
        assert_eq!(holder(&dir).unwrap(), Some(Some(pid)));
        drop(first);
        assert!(!dir.join(PID_FILE).exists(), "the record outlived its holder");
        assert_eq!(holder(&dir).unwrap(), None);
        let _again = KeyHolder::acquire(&dir).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A killed holder leaves its record behind (no `Drop`): the next holder
    /// takes the lock and replaces the record, on every OS, also when the
    /// stale record is longer than the new one.
    #[test]
    fn a_stale_pid_record_is_replaced_by_the_next_holder() {
        let dir = tempfile_dir("stale-record");
        create_private_dir(&dir).unwrap();
        std::fs::write(dir.join(PID_FILE), "4294967295\nleftover\n").unwrap();
        let holder = KeyHolder::acquire(&dir).expect("a stale record never blocks the lock");
        let record = std::fs::read_to_string(dir.join(PID_FILE)).unwrap();
        assert_eq!(record, format!("{}\n", std::process::id()));
        drop(holder);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn key_files_resolve_in_their_directory() {
        let dir = Path::new("/state");
        assert_eq!(KeyFile::Node.path_in(dir), dir.join("node.wg.key"));
        assert_eq!(KeyFile::Link.path_in(dir), dir.join("private.key"));
        let opened: Result<PathBuf, ()> =
            open_for_public_key(KeyFile::Node, dir, |path| Ok(path.to_path_buf()));
        assert_eq!(opened.unwrap(), dir.join("node.wg.key"));
    }

    fn tempfile_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cmux-key-holder-{name}-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }
}
