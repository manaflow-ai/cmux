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
pub fn replace(file: &Path, text: &str) -> io::Result<()> {
    let target = fs::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let dir = target.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    fs::create_dir_all(dir)?;
    let prior = fs::metadata(&target).ok();
    if prior.is_some() {
        let first = backup_path(&target);
        if !first.exists() {
            fs::copy(&target, &first)?;
        }
        fs::copy(&target, last_backup_path(&target))?;
    }
    let mut tmp_name = target.file_name().unwrap_or_default().to_os_string();
    tmp_name.push(format!(".cmux-tmp-{}", std::process::id()));
    let tmp = dir.join(tmp_name);
    let written = (|| {
        let mut out = fs::File::create(&tmp)?;
        out.write_all(text.as_bytes())?;
        out.sync_all()?;
        if let Some(prior) = &prior {
            fs::set_permissions(&tmp, prior.permissions())?;
        }
        fs::rename(&tmp, &target)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written
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
}
