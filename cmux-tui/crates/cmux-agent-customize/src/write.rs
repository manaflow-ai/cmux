//! Writing an agent's own config file: atomically, under a lock, after a backup of what was there.

use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// cmux's private folder for what it keeps about an agent's files: the backups of each file it
/// edits and the lock each edit holds. It is outside every project (the person's state folder,
/// 0700), so a backup of a project's `.claude/settings.local.json`, which holds that file's
/// credentials verbatim, is never in a repo tree for `git add -A` to stage, and no lock file is
/// left beside a project's file.
///
/// Each file has its own entries, named by its file name and a stable hash of its absolute path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Store {
    dir: PathBuf,
}

/// How long an edit waits for another edit of the same file (a Settings save and a CLI edit).
/// A holder keeps the lock for one read, backup and rename; a stopped holder must not stall a
/// write forever.
const LOCK_WAIT: Duration = Duration::from_secs(15);

impl Store {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    /// The private folder itself.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The backup of `file` as it was before cmux first wrote to it. Later writes never replace
    /// it, so the user's own file can always be put back.
    pub fn backup_path(&self, file: &Path) -> PathBuf {
        self.dir.join("backups").join(format!("{}.cmux-backup", entry_name(file)))
    }

    /// The backup of `file` as it was just before cmux's latest write to it.
    pub fn last_backup_path(&self, file: &Path) -> PathBuf {
        self.dir.join("backups").join(format!("{}.cmux-backup-last", entry_name(file)))
    }

    fn lock_path(&self, file: &Path) -> PathBuf {
        self.dir.join("locks").join(format!("{}.lock", entry_name(file)))
    }

    /// Holds `file`'s edit lock until the returned file drops: an exclusive advisory lock (flock
    /// on Unix) every cmux edit of `file` takes across its read, modify, backup and rename, so two
    /// edits of different keys cannot both read the same original and drop each other's change.
    /// Keyed by where `file` is (its real folder and name), whether or not it exists yet. Fails
    /// after [`LOCK_WAIT`] instead of editing unlocked.
    pub fn lock(&self, file: &Path) -> io::Result<fs::File> {
        let path = self.lock_path(&resolved(file));
        create_private_dir(path.parent().unwrap_or(&self.dir))?;
        let mut options = fs::OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let lock = options.open(&path)?;
        let deadline = Instant::now().checked_add(LOCK_WAIT);
        loop {
            match lock.try_lock() {
                Ok(()) => return Ok(lock),
                Err(fs::TryLockError::WouldBlock)
                    if deadline.is_some_and(|d| Instant::now() < d) =>
                {
                    // Lock contention: flock has no wait-with-timeout, so retry to a deadline.
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(fs::TryLockError::WouldBlock) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "another edit of this file is still running",
                    ));
                }
                Err(fs::TryLockError::Error(error)) => return Err(error),
            }
        }
    }

    /// What `file` held just before cmux's latest write to it, when cmux has written it. An undo
    /// (a switch turned back on) reads it to put back the person's own form of what it touched:
    /// an empty object they wrote, a line they set by hand.
    pub fn before_last_write(&self, file: &Path) -> Option<String> {
        let target = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
        fs::read_to_string(self.last_backup_path(&target)).ok()
    }

    /// Replaces `file` with `text`: the prior file is copied to [`Store::last_backup_path`], and
    /// to [`Store::backup_path`] when that does not exist yet; the new text goes to a temporary
    /// file beside it and is renamed over it, so a reader never sees half a file. A symlinked file
    /// is written where it points (the link stays). The file's mode is kept. The caller holds
    /// [`Store::lock`] across its read of `file` and this call.
    ///
    /// Every file cmux creates here (backups and the temporary file) starts private (0600 on
    /// Unix) and is created exclusively, then renamed into place, so nothing is written through a
    /// symlink and the new text is never readable by others while it is written.
    pub fn replace(&self, file: &Path, text: &str) -> io::Result<()> {
        let target = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
        let dir = target.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
        fs::create_dir_all(dir)?;
        let prior = fs::metadata(&target).ok();
        if prior.is_some() {
            let original = fs::read(&target)?;
            let first = self.backup_path(&target);
            let backups = first.parent().unwrap_or(&self.dir).to_path_buf();
            create_private_dir(&backups)?;
            // The first backup is kept once it is a real file. Anything else there (a planted or
            // dangling symlink) is replaced by the rename, never written through.
            let kept = fs::symlink_metadata(&first).is_ok_and(|m| !m.file_type().is_symlink());
            if !kept {
                write_new(&backups, &first, &original, &first, None)?;
            }
            let last = self.last_backup_path(&target);
            write_new(&backups, &last, &original, &last, None)?;
        }
        write_new(dir, &target, text.as_bytes(), &target, prior.map(|p| p.permissions()))
    }
}

/// `file` with its folder resolved (the nearest existing ancestor, through symlinks), so one file
/// has one name before and after it is created.
fn resolved(file: &Path) -> PathBuf {
    if let Ok(real) = fs::canonicalize(file) {
        return real;
    }
    let mut rest = Vec::new();
    for dir in file.ancestors() {
        if let Ok(real) = fs::canonicalize(dir) {
            return rest.iter().rev().fold(real, |path: PathBuf, part| path.join(part));
        }
        if let Some(name) = dir.file_name() {
            rest.push(name.to_os_string());
        }
    }
    file.to_path_buf()
}

/// A file's entry name in the store: its file name (for a person reading the folder) and a stable
/// hash (FNV-1a 64) of its whole path, so two projects' `settings.json` never share an entry.
fn entry_name(file: &Path) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in file.as_os_str().as_encoded_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let name: String = file
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '_' })
        .take(64)
        .collect();
    format!("{name}-{hash:016x}")
}

/// Creates `dir` (and any missing parents) only its owner can enter (0700 on Unix), and makes an
/// existing one private too.
fn create_private_dir(dir: &Path) -> io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Writes `bytes` to a new private temporary file in `dir`, renames it over `dest` (which
/// replaces a symlink at `dest` rather than following it), then gives it `mode` if any.
fn write_new(
    dir: &Path,
    target: &Path,
    bytes: &[u8],
    dest: &Path,
    mode: Option<fs::Permissions>,
) -> io::Result<()> {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let mut tmp_name = target.file_name().unwrap_or_default().to_os_string();
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    tmp_name.push(format!(".cmux-tmp-{}-{n}", std::process::id()));
    let tmp = dir.join(tmp_name);
    let written = (|| {
        let mut out = create_private(&tmp)?;
        out.write_all(bytes)?;
        out.sync_all()?;
        fs::rename(&tmp, dest)?;
        // Widen to the original mode only once the file is complete and in place, through the
        // open handle: the temporary name stays private while the bytes are being written.
        if let Some(mode) = mode {
            out.set_permissions(mode)?;
        }
        Ok(())
    })();
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written
}

/// Creates `path` as a new file only it can read (0600 on Unix). Fails if anything, a symlink
/// included, is already there.
fn create_private(path: &Path) -> io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)
}

#[cfg(test)]
#[path = "write_tests.rs"]
mod tests;
