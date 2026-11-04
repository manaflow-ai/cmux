//! The file system seam. [`FsStorage`] is the real one; the `sim` feature adds `SimStorage`, which
//! can crash at any operation and then keep what a process crash, an OS crash or a power loss
//! keeps.

use std::io;
use std::path::Path;

/// How far a sync pushes a file's data toward the disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncLevel {
    /// macOS `F_BARRIERFSYNC` (an fsync, then a drive barrier: the data reaches the disk in write
    /// order), Linux `fdatasync`, Windows `FlushFileBuffers`. The data survives a crash of any
    /// process and a kernel panic. A power loss on macOS can take back a suffix written since
    /// the last [`SyncLevel::Full`].
    Barrier,
    /// macOS `F_FULLFSYNC` (the drive also flushes its cache), else `fsync`. The data survives a
    /// power loss.
    Full,
}

/// How [`Storage::open`] opens a file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMode {
    /// An existing file, read only.
    Read,
    /// An existing file, to read and append.
    Write,
    /// A new or emptied file (owner-only), to read and append.
    Create,
}

/// The file system operations the journal uses.
pub trait Storage: Send + Sync {
    /// Makes `dir` and its parents (owner-only).
    fn create_dir_all(&self, dir: &Path) -> io::Result<()>;
    /// The names of the entries in `dir`.
    fn list(&self, dir: &Path) -> io::Result<Vec<String>>;
    fn open(&self, path: &Path, mode: OpenMode) -> io::Result<Box<dyn StorageFile>>;
    fn rename(&self, from: &Path, to: &Path) -> io::Result<()>;
    /// Removes the file at `path` (`Journal::retire_through`, the journal's only delete).
    fn remove_file(&self, path: &Path) -> io::Result<()>;
    /// Makes the entries of `dir` (a create, rename or remove in it) durable.
    fn sync_dir(&self, dir: &Path) -> io::Result<()>;
    /// An exclusive lock of `path`, held until the returned value is dropped, or `None` while
    /// another holder has it.
    fn try_lock(&self, path: &Path) -> io::Result<Option<Box<dyn StorageLock>>>;
}

/// An open file.
pub trait StorageFile: Send {
    fn size(&self) -> io::Result<u64>;
    /// Fills `buf` from `offset`; a short file is an `UnexpectedEof` error.
    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()>;
    /// Writes `bytes` at the end of the file.
    fn append(&mut self, bytes: &[u8]) -> io::Result<()>;
    fn truncate(&mut self, size: u64) -> io::Result<()>;
    fn sync(&mut self, level: SyncLevel) -> io::Result<()>;
}

/// A held lock ([`Storage::try_lock`]).
pub trait StorageLock: Send + Sync {}

/// The real file system.
#[derive(Clone, Copy, Debug, Default)]
pub struct FsStorage;

impl Storage for FsStorage {
    fn create_dir_all(&self, dir: &Path) -> io::Result<()> {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(dir)
    }

    fn list(&self, dir: &Path) -> io::Result<Vec<String>> {
        let mut names = Vec::new();
        for entry in std::fs::read_dir(dir)? {
            if let Ok(name) = entry?.file_name().into_string() {
                names.push(name);
            }
        }
        Ok(names)
    }

    fn open(&self, path: &Path, mode: OpenMode) -> io::Result<Box<dyn StorageFile>> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        match mode {
            OpenMode::Read => {}
            OpenMode::Write => {
                options.write(true);
            }
            OpenMode::Create => {
                options.write(true).create(true).truncate(true);
                #[cfg(unix)]
                std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
            }
        }
        let file = options.open(path)?;
        let size = file.metadata()?.len();
        Ok(Box::new(FsFile { file, size }))
    }

    fn rename(&self, from: &Path, to: &Path) -> io::Result<()> {
        std::fs::rename(from, to)
    }

    fn remove_file(&self, path: &Path) -> io::Result<()> {
        std::fs::remove_file(path)
    }

    fn sync_dir(&self, dir: &Path) -> io::Result<()> {
        sync_directory(dir)
    }

    fn try_lock(&self, path: &Path) -> io::Result<Option<Box<dyn StorageLock>>> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let file = options.open(path)?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Box::new(FsLock { _file: file }))),
            Err(std::fs::TryLockError::WouldBlock) => Ok(None),
            Err(std::fs::TryLockError::Error(error)) => Err(error),
        }
    }
}

/// The lock file, locked; closing it releases the lock.
struct FsLock {
    _file: std::fs::File,
}

impl StorageLock for FsLock {}

/// A file and its size, so an append writes at a known offset with no seek.
struct FsFile {
    file: std::fs::File,
    size: u64,
}

impl StorageFile for FsFile {
    fn size(&self) -> io::Result<u64> {
        Ok(self.size)
    }

    fn read_at(&self, offset: u64, buf: &mut [u8]) -> io::Result<()> {
        read_exact_at(&self.file, offset, buf)
    }

    fn append(&mut self, bytes: &[u8]) -> io::Result<()> {
        write_all_at(&self.file, self.size, bytes)?;
        self.size = self.size.saturating_add(u64::try_from(bytes.len()).unwrap_or(u64::MAX));
        Ok(())
    }

    fn truncate(&mut self, size: u64) -> io::Result<()> {
        self.file.set_len(size)?;
        self.size = size;
        Ok(())
    }

    fn sync(&mut self, level: SyncLevel) -> io::Result<()> {
        sync_file(&self.file, level)
    }
}

#[cfg(unix)]
fn read_exact_at(file: &std::fs::File, offset: u64, buf: &mut [u8]) -> io::Result<()> {
    std::os::unix::fs::FileExt::read_exact_at(file, buf, offset)
}

#[cfg(unix)]
fn write_all_at(file: &std::fs::File, offset: u64, bytes: &[u8]) -> io::Result<()> {
    std::os::unix::fs::FileExt::write_all_at(file, bytes, offset)
}

#[cfg(windows)]
fn read_exact_at(file: &std::fs::File, mut offset: u64, mut buf: &mut [u8]) -> io::Result<()> {
    while !buf.is_empty() {
        match std::os::windows::fs::FileExt::seek_read(file, buf, offset) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => {
                buf = std::mem::take(&mut buf).get_mut(n..).unwrap_or_default();
                offset = offset.saturating_add(u64::try_from(n).unwrap_or(u64::MAX));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(windows)]
fn write_all_at(file: &std::fs::File, mut offset: u64, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        match std::os::windows::fs::FileExt::seek_write(file, bytes, offset) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => {
                bytes = bytes.get(n..).unwrap_or_default();
                offset = offset.saturating_add(u64::try_from(n).unwrap_or(u64::MAX));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// [`SyncLevel`] on macOS: `F_BARRIERFSYNC` or `F_FULLFSYNC`. A plain `fsync` is used only where
/// the file system does not support the call (a network, FAT or other volume that answers
/// ENOTSUP, EOPNOTSUPP, EINVAL or ENOTTY); there no stronger sync exists. Any other error (EIO) is
/// returned: the data is not known to be on the disk, and the caller must not count it as
/// durable. A call a signal interrupts (EINTR) is made again, as std does. std's `sync_data` and
/// `sync_all` are both `F_FULLFSYNC` here, so they are not used.
#[cfg(target_os = "macos")]
fn sync_file(file: &std::fs::File, level: SyncLevel) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let fd = file.as_raw_fd();
    let command = match level {
        SyncLevel::Barrier => libc::F_BARRIERFSYNC,
        SyncLevel::Full => libc::F_FULLFSYNC,
    };
    // SAFETY: fcntl on a descriptor that `file` owns for the whole call.
    let error = match retry_interrupted(|| unsafe { libc::fcntl(fd, command) }) {
        Ok(()) => return Ok(()),
        Err(error) => error,
    };
    let unsupported = matches!(
        error.raw_os_error(),
        Some(libc::ENOTSUP | libc::EOPNOTSUPP | libc::EINVAL | libc::ENOTTY)
    );
    if !unsupported {
        return Err(error);
    }
    // SAFETY: as above.
    retry_interrupted(|| unsafe { libc::fsync(fd) })
}

/// Calls `call` until it returns something other than -1 with EINTR.
#[cfg(target_os = "macos")]
fn retry_interrupted(call: impl Fn() -> libc::c_int) -> io::Result<()> {
    loop {
        if call() != -1 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// [`SyncLevel`] elsewhere: `fdatasync` (Linux; it also flushes a volatile drive cache) or `fsync`;
/// `FlushFileBuffers` on Windows for both.
#[cfg(not(target_os = "macos"))]
fn sync_file(file: &std::fs::File, level: SyncLevel) -> io::Result<()> {
    match level {
        SyncLevel::Barrier => file.sync_data(),
        SyncLevel::Full => file.sync_all(),
    }
}

/// Opens `dir` as a folder (`O_DIRECTORY`) and syncs it. A symlink in the path is followed:
/// the sync is for the folder that holds the entries, and a daemon's state folder, or the journal
/// folder itself, may be a symlink (GNU stow, state on another volume; review G3).
#[cfg(unix)]
fn sync_directory(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY).open(dir)?;
    sync_file(&file, SyncLevel::Full)
}

/// Windows has no directory sync: NTFS journals its directory changes.
#[cfg(not(unix))]
fn sync_directory(_dir: &Path) -> io::Result<()> {
    Ok(())
}
