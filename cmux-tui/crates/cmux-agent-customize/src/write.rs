//! Writing an agent's own config file: atomically, after a backup of what was there.

use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

/// The backup of `file` as it was before cmux first wrote to it. Later writes never replace it,
/// so the user's own file can always be put back.
pub fn backup_path(file: &Path) -> PathBuf {
    with_suffix(file, ".cmux-backup")
}

/// The backup of `file` as it was just before cmux's latest write to it.
pub fn last_backup_path(file: &Path) -> PathBuf {
    with_suffix(file, ".cmux-backup-last")
}

fn with_suffix(file: &Path, suffix: &str) -> PathBuf {
    let mut name = file.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    file.with_file_name(name)
}

/// Replaces `file` with `text`: the prior file is copied to [`last_backup_path`], and to
/// [`backup_path`] when that does not exist yet; the new text goes to a temporary file beside it
/// and is renamed over it, so a reader never sees half a file. A symlinked file is written where
/// it points (the link stays). The file's mode is kept.
///
/// Every file cmux creates here (backups and the temporary file) starts private (0600 on Unix)
/// and is created exclusively, then renamed into place: a symlink a project ships at a backup
/// path is replaced, never written through, and the new text is never readable by others while
/// it is written. Backups stay private.
pub fn replace(file: &Path, text: &str) -> io::Result<()> {
    let target = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let dir = target.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    fs::create_dir_all(dir)?;
    let prior = fs::metadata(&target).ok();
    if prior.is_some() {
        let original = fs::read(&target)?;
        let first = backup_path(&target);
        // symlink_metadata: a link (even a dangling one) counts as there, so it is never written.
        if fs::symlink_metadata(&first).is_err() {
            write_new(dir, &target, &original, &first, None)?;
        }
        write_new(dir, &target, &original, &last_backup_path(&target), None)?;
    }
    write_new(dir, &target, text.as_bytes(), &target, prior.map(|p| p.permissions()))
}

/// Writes `bytes` to a new private temporary file in `dir`, gives it `mode` if any, and renames
/// it over `dest` (which replaces a symlink at `dest` rather than following it).
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
        if let Some(mode) = mode {
            fs::set_permissions(&tmp, mode)?;
        }
        fs::rename(&tmp, dest)
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

    #[test]
    fn replaces_with_a_backup_and_through_a_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real.json");
        fs::write(&real, "old").unwrap();
        #[cfg(unix)]
        {
            let link = dir.path().join("link.json");
            std::os::unix::fs::symlink(&real, &link).unwrap();
            replace(&link, "new").unwrap();
            assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        }
        #[cfg(not(unix))]
        replace(&real, "new").unwrap();
        assert_eq!(fs::read_to_string(&real).unwrap(), "new");
        assert_eq!(fs::read_to_string(backup_path(&real)).unwrap(), "old");
        // A second write keeps the original's backup and records the text it replaced.
        replace(&real, "newer").unwrap();
        assert_eq!(fs::read_to_string(backup_path(&real)).unwrap(), "old");
        assert_eq!(fs::read_to_string(last_backup_path(&real)).unwrap(), "new");
        let fresh = dir.path().join("sub/fresh.json");
        replace(&fresh, "{}").unwrap();
        assert_eq!(fs::read_to_string(&fresh).unwrap(), "{}");
        assert!(!backup_path(&fresh).exists());
    }

    /// A project can ship a symlink where a backup goes; writing a backup must replace the link,
    /// never write through it to the file it points at.
    #[cfg(unix)]
    #[test]
    fn backups_never_write_through_a_planted_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let outside = dir.path().join("outside.txt");
        fs::write(&outside, "keep me").unwrap();
        let project = dir.path().join("project");
        fs::create_dir(&project).unwrap();
        let settings = project.join("settings.json");
        fs::write(&settings, "old").unwrap();
        std::os::unix::fs::symlink(&outside, backup_path(&settings)).unwrap();
        std::os::unix::fs::symlink(&outside, last_backup_path(&settings)).unwrap();
        replace(&settings, "new").unwrap();
        assert_eq!(fs::read_to_string(&outside).unwrap(), "keep me");
        assert_eq!(fs::read_to_string(&settings).unwrap(), "new");
        let last = last_backup_path(&settings);
        assert!(!fs::symlink_metadata(&last).unwrap().file_type().is_symlink());
        assert_eq!(fs::read_to_string(&last).unwrap(), "old");
    }

    /// The new text of a private (0600) file is never readable by others, not even while it is
    /// being written, and neither are its backups.
    #[cfg(unix)]
    #[test]
    fn private_files_stay_private_through_a_write() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join("config.toml");
        fs::write(&secret, "token = \"s3cret\"").unwrap();
        fs::set_permissions(&secret, fs::Permissions::from_mode(0o600)).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let probe = dir.path().join("probe");
        create_private(&probe).unwrap();
        assert_eq!(mode(&probe), 0o600);
        // Exclusive: never opens what is already there, a symlink included.
        assert!(create_private(&probe).is_err());
        replace(&secret, "token = \"other\"").unwrap();
        assert_eq!(mode(&secret), 0o600);
        assert_eq!(mode(&backup_path(&secret)), 0o600);
        assert_eq!(mode(&last_backup_path(&secret)), 0o600);
    }
}
