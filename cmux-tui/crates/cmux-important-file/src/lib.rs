//! `write_important`: the one atomic and durable write of a state file that a
//! cmux daemon reads back (Chrome's `base/files/important_file_writer.cc`,
//! `WriteFileAtomicallyImpl`).
//!
//! The steps are Chrome's: a new temporary file in the same folder, write,
//! flush to disk, then rename over the target. A reader sees the old file or
//! the new one, never a part, and a power loss never leaves an empty file.
//! cmux adds two steps Chrome leaves to `ReplaceFile`: the folder is flushed
//! after the rename (on Unix), so the rename itself survives a power loss,
//! and the temporary file gets its final permission bits before any byte is
//! written, so a secret is never readable by others.
//!
//! Every failure names its step ([`Step`], Chrome's `TempFileFailure`), and a
//! full disk or quota is its own [`WriteError::DiskFull`]. A failed write
//! removes its temporary file and leaves the target as it was.
//!
//! The call blocks on the file system; it checks the thread's blocking policy
//! at the caller's location (`cmux_threads::assert_blocking_allowed`, Chrome's
//! `ScopedBlockingCall` in the same function).

#![forbid(unsafe_code)]

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use cmux_threads::{BlockingKind, assert_blocking_allowed};

/// The permission bits of the written file (Unix; other systems ignore them).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// As `File::create` makes it: 0o666 less the umask.
    Default,
    /// Exactly these bits, from the moment the temporary file exists.
    Exact(u32),
    /// The bits of the file it replaces; a new file is made as [`Mode::Default`].
    Keep,
}

/// The step that failed (Chrome's `TempFileFailure`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    CreateParent,
    CreateTemp,
    SetMode,
    Write,
    Sync,
    Check,
    Rename,
    SyncDir,
}

impl Step {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CreateParent => "create the folder",
            Self::CreateTemp => "create the temporary file",
            Self::SetMode => "set the permissions",
            Self::Write => "write",
            Self::Sync => "flush to disk",
            Self::Check => "check the new contents",
            Self::Rename => "replace the file",
            Self::SyncDir => "flush the folder",
        }
    }
}

impl fmt::Display for Step {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Why a [`write_important`] failed. The target is unchanged unless the step
/// is [`Step::SyncDir`] (the new contents are in place; only the flush of
/// the rename failed).
#[derive(Debug)]
pub enum WriteError {
    /// The disk or the user's quota is full (`ENOSPC`, `EDQUOT`,
    /// `ERROR_DISK_FULL`).
    DiskFull { path: PathBuf, step: Step, source: io::Error },
    /// The [`Options::check`] refused the written temporary file.
    Refused { path: PathBuf, reason: String },
    /// Any other I/O failure.
    Io { path: PathBuf, step: Step, source: io::Error },
}

impl WriteError {
    fn from_io(path: &Path, step: Step, source: io::Error) -> Self {
        let path = path.to_path_buf();
        if is_disk_full(&source) {
            Self::DiskFull { path, step, source }
        } else {
            Self::Io { path, step, source }
        }
    }

    /// The file that was being written.
    pub fn path(&self) -> &Path {
        match self {
            Self::DiskFull { path, .. } | Self::Refused { path, .. } | Self::Io { path, .. } => {
                path
            }
        }
    }

    pub fn step(&self) -> Step {
        match self {
            Self::DiskFull { step, .. } | Self::Io { step, .. } => *step,
            Self::Refused { .. } => Step::Check,
        }
    }

    pub fn is_disk_full(&self) -> bool {
        matches!(self, Self::DiskFull { .. })
    }

    /// The `io::ErrorKind` this maps to (`InvalidData` for a refusal).
    pub fn kind(&self) -> io::ErrorKind {
        match self {
            Self::DiskFull { source, .. } | Self::Io { source, .. } => source.kind(),
            Self::Refused { .. } => io::ErrorKind::InvalidData,
        }
    }
}

impl fmt::Display for WriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DiskFull { path, step, source } => {
                write!(f, "{}: the disk is full ({step}): {source}", path.display())
            }
            Self::Refused { path, reason } => {
                write!(f, "{}: the new contents were refused: {reason}", path.display())
            }
            Self::Io { path, step, source } => write!(f, "{}: {step}: {source}", path.display()),
        }
    }
}

impl std::error::Error for WriteError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::DiskFull { source, .. } | Self::Io { source, .. } => Some(source),
            Self::Refused { .. } => None,
        }
    }
}

/// Keeps the kind (`StorageFull` for a full disk), so `?` into an
/// `io::Result` still lets the caller tell a full disk apart.
impl From<WriteError> for io::Error {
    fn from(error: WriteError) -> Self {
        io::Error::new(error.kind(), error)
    }
}

/// Whether `error` is a full disk or quota.
pub fn is_disk_full(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::StorageFull | io::ErrorKind::QuotaExceeded)
}

/// Runs on the flushed temporary file before the rename; an `Err` refuses it
/// (team_ssh: `ssh-keygen` must parse a KRL before sshd sees it).
pub type TempCheck<'a> = &'a dyn Fn(&Path) -> Result<(), String>;

/// Creates the temporary file at the given path in place of the default
/// `create_new` open. It must create a new file, never open an existing one
/// (acpmux on Windows: an owner-only access list from creation).
pub type TempOpen<'a> = &'a dyn Fn(&Path) -> io::Result<File>;

/// How [`write_important_with`] writes. [`Options::new`] creates no folder
/// and runs no check.
#[derive(Clone, Copy)]
pub struct Options<'a> {
    mode: Mode,
    create_parent: bool,
    check: Option<TempCheck<'a>>,
    open_temp: Option<TempOpen<'a>>,
}

impl<'a> Options<'a> {
    pub fn new(mode: Mode) -> Self {
        Self { mode, create_parent: false, check: None, open_temp: None }
    }

    /// Creates missing parent folders (0o777 less the umask) first.
    pub fn create_parent(mut self) -> Self {
        self.create_parent = true;
        self
    }

    pub fn check(mut self, check: TempCheck<'a>) -> Self {
        self.check = Some(check);
        self
    }

    pub fn open_temp(mut self, open: TempOpen<'a>) -> Self {
        self.open_temp = Some(open);
        self
    }
}

/// Replaces `path` with `bytes` atomically and durably, with `mode`.
#[track_caller]
pub fn write_important(path: &Path, bytes: &[u8], mode: Mode) -> Result<(), WriteError> {
    write_important_with(path, bytes, &Options::new(mode))
}

/// [`write_important`] with a check, a folder create or a custom temp open.
/// A target that is a symlink is replaced by the file (the link's target is
/// untouched); resolve the link first to write through it.
#[track_caller]
pub fn write_important_with(
    path: &Path,
    bytes: &[u8],
    options: &Options<'_>,
) -> Result<(), WriteError> {
    assert_blocking_allowed(BlockingKind::Fs);
    let fail = |step, source| WriteError::from_io(path, step, source);
    let dir = path.parent().filter(|dir| !dir.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = path.file_name().ok_or_else(|| {
        fail(Step::CreateTemp, io::Error::new(io::ErrorKind::InvalidInput, "no file name"))
    })?;
    if options.create_parent {
        fs::create_dir_all(dir).map_err(|e| fail(Step::CreateParent, e))?;
    }
    let mode = resolve_mode(path, options.mode);
    let (temp, file) = create_temp(dir, &name.to_string_lossy(), mode, options.open_temp)
        .map_err(|e| fail(Step::CreateTemp, e))?;
    let written = fill(file, bytes, mode).map_err(|(step, e)| fail(step, e)).and_then(|()| {
        match options.check {
            Some(check) => check(&temp)
                .map_err(|reason| WriteError::Refused { path: path.to_path_buf(), reason }),
            None => Ok(()),
        }
    });
    let replaced =
        written.and_then(|()| fs::rename(&temp, path).map_err(|e| fail(Step::Rename, e)));
    if let Err(error) = replaced {
        let _ = fs::remove_file(&temp);
        return Err(error);
    }
    sync_dir(dir).map_err(|e| fail(Step::SyncDir, e))
}

/// The exact bits to set, or `None` to leave what the create made.
fn resolve_mode(path: &Path, mode: Mode) -> Option<u32> {
    match mode {
        Mode::Default => None,
        Mode::Exact(bits) => Some(bits),
        #[cfg(unix)]
        Mode::Keep => {
            use std::os::unix::fs::PermissionsExt;
            fs::metadata(path).ok().map(|meta| meta.permissions().mode() & 0o7777)
        }
        #[cfg(not(unix))]
        Mode::Keep => {
            let _ = path;
            None
        }
    }
}

/// The temporary names of this process: pid and a sequence, so two writers
/// of one file never share a temp; a name a crashed process left under a
/// reused pid is skipped.
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);
const TEMP_ATTEMPTS: usize = 16;

fn create_temp(
    dir: &Path,
    name: &str,
    mode: Option<u32>,
    open_temp: Option<TempOpen<'_>>,
) -> io::Result<(PathBuf, File)> {
    let pid = std::process::id();
    let mut last = None;
    for _ in 0..TEMP_ATTEMPTS {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp = dir.join(format!(".{name}.{pid}-{sequence}.tmp"));
        let opened = match open_temp {
            Some(open) => open(&temp),
            None => open_new(&temp, mode),
        };
        match opened {
            Ok(file) => return Ok((temp, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => last = Some(e),
            Err(e) => return Err(e),
        }
    }
    Err(last.unwrap_or_else(|| io::Error::from(io::ErrorKind::AlreadyExists)))
}

/// A new file only: `create_new` never opens a planted file or follows a
/// planted symlink.
fn open_new(temp: &Path, mode: Option<u32>) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    if let Some(bits) = mode {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(bits);
    }
    #[cfg(not(unix))]
    let _ = mode;
    options.open(temp)
}

fn fill(mut file: File, bytes: &[u8], mode: Option<u32>) -> Result<(), (Step, io::Error)> {
    // The create's mode is masked by the umask; set the bits exactly before
    // the first byte.
    #[cfg(unix)]
    if let Some(bits) = mode {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(bits)).map_err(|e| (Step::SetMode, e))?;
    }
    #[cfg(not(unix))]
    let _ = mode;
    file.write_all(bytes).map_err(|e| (Step::Write, e))?;
    file.sync_all().map_err(|e| (Step::Sync, e))
}

/// Flushes the folder entry the rename changed. A file system that cannot
/// flush a folder answers `EINVAL`; it is ignored there, as SQLite's
/// `unixSync` does.
fn sync_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    match File::open(dir).and_then(|dir| dir.sync_all()) {
        Err(e) if e.kind() == io::ErrorKind::InvalidInput => Ok(()),
        other => other,
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(())
    }
}
