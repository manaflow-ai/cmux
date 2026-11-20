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
mod tests {
    use super::*;

    fn store(dir: &Path) -> Store {
        Store::new(dir.join("state/agent-config"))
    }

    #[test]
    fn replaces_with_a_backup_and_through_a_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let real = fs::canonicalize(dir.path()).unwrap().join("real.json");
        fs::write(&real, "old").unwrap();
        #[cfg(unix)]
        {
            let link = dir.path().join("link.json");
            std::os::unix::fs::symlink(&real, &link).unwrap();
            store.replace(&link, "new").unwrap();
            assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        }
        #[cfg(not(unix))]
        store.replace(&real, "new").unwrap();
        assert_eq!(fs::read_to_string(&real).unwrap(), "new");
        assert_eq!(fs::read_to_string(store.backup_path(&real)).unwrap(), "old");
        // A second write keeps the original's backup and records the text it replaced.
        store.replace(&real, "newer").unwrap();
        assert_eq!(fs::read_to_string(store.backup_path(&real)).unwrap(), "old");
        assert_eq!(fs::read_to_string(store.last_backup_path(&real)).unwrap(), "new");
        let fresh = dir.path().join("sub/fresh.json");
        store.replace(&fresh, "{}").unwrap();
        assert_eq!(fs::read_to_string(&fresh).unwrap(), "{}");
        assert!(!store.backup_path(&fresh).exists());
        // Two folders' files of the same name never share a backup.
        assert_ne!(store.backup_path(&real), store.backup_path(&dir.path().join("x/real.json")));
        // Nothing but the files themselves is left beside them.
        let mut names: Vec<String> = fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        let mut expected = vec!["real.json", "state", "sub"];
        if cfg!(unix) {
            expected.insert(0, "link.json");
        }
        assert_eq!(names, expected);
    }

    /// Something may already sit where a backup goes; writing a backup must replace a link there,
    /// never write through it to the file it points at.
    #[cfg(unix)]
    #[test]
    fn backups_never_write_through_a_planted_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let outside = dir.path().join("outside.txt");
        fs::write(&outside, "keep me").unwrap();
        let project = fs::canonicalize(dir.path()).unwrap().join("project");
        fs::create_dir(&project).unwrap();
        let settings = project.join("settings.json");
        fs::write(&settings, "old").unwrap();
        fs::create_dir_all(store.dir().join("backups")).unwrap();
        std::os::unix::fs::symlink(&outside, store.backup_path(&settings)).unwrap();
        std::os::unix::fs::symlink(&outside, store.last_backup_path(&settings)).unwrap();
        store.replace(&settings, "new").unwrap();
        assert_eq!(fs::read_to_string(&outside).unwrap(), "keep me");
        assert_eq!(fs::read_to_string(&settings).unwrap(), "new");
        // Both backups are real files holding the prior text: a planted link is replaced, never
        // followed and never left standing in place of the first restore point.
        for backup in [store.backup_path(&settings), store.last_backup_path(&settings)] {
            assert!(!fs::symlink_metadata(&backup).unwrap().file_type().is_symlink());
            assert_eq!(fs::read_to_string(&backup).unwrap(), "old");
        }
    }

    /// A world-readable file stays world-readable after a write: its mode is put back once the new
    /// text is in place.
    #[cfg(unix)]
    #[test]
    fn a_shared_file_keeps_its_mode_through_a_write() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let shared = fs::canonicalize(dir.path()).unwrap().join("settings.json");
        fs::write(&shared, "{}").unwrap();
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o644)).unwrap();
        store.replace(&shared, "{\"a\":1}").unwrap();
        assert_eq!(fs::metadata(&shared).unwrap().permissions().mode() & 0o777, 0o644);
        assert_eq!(fs::read_to_string(&shared).unwrap(), "{\"a\":1}");
    }

    /// The new text of a private (0600) file is never readable by others, not even while it is
    /// being written, and neither are its backups or their folder.
    #[cfg(unix)]
    #[test]
    fn private_files_stay_private_through_a_write() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let secret = fs::canonicalize(dir.path()).unwrap().join("config.toml");
        fs::write(&secret, "token = \"s3cret\"").unwrap();
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let probe = dir.path().join("probe");
        create_private(&probe).unwrap();
        assert_eq!(mode(&probe), 0o600);
        // Exclusive: never opens what is already there, a symlink included.
        assert!(create_private(&probe).is_err());
        store.replace(&secret, "token = \"other\"").unwrap();
        assert_eq!(mode(&secret), 0o600);
        assert_eq!(mode(&store.backup_path(&secret)), 0o600);
        assert_eq!(mode(&store.last_backup_path(&secret)), 0o600);
        assert_eq!(mode(&store.dir().join("backups")), 0o700);
    }

    /// A file's lock is the same before and after the file exists, and a second holder waits.
    #[test]
    fn one_file_has_one_lock() {
        let dir = tempfile::tempdir().unwrap();
        let store = store(dir.path());
        let missing = dir.path().join("a/b/settings.json");
        let before = store.lock_path(&resolved(&missing));
        fs::create_dir_all(missing.parent().unwrap()).unwrap();
        fs::write(&missing, "{}").unwrap();
        assert_eq!(store.lock_path(&resolved(&missing)), before);
        let held = store.lock(&missing).unwrap();
        let other = fs::OpenOptions::new().append(true).open(&before).unwrap();
        assert!(matches!(other.try_lock(), Err(fs::TryLockError::WouldBlock)));
        drop(held);
        assert!(other.try_lock().is_ok());
    }
}
