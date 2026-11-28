//! Writes into files another program owns: read, change, and replace through a synced temporary
//! file and a rename, keeping the file before the change as `<name>.cmux-backup` beside it. The
//! agent may be writing the same file (Claude Code rewrites `~/.claude.json` while it runs), so
//! the change is made again on a fresh read when the file moved under it, and never lands over a
//! write it did not see.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The copy of the file before cmux's last change to it.
pub fn backup_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".cmux-backup");
    path.with_file_name(name)
}

/// What a file held when it was read: its text (None when there was no file) and its stamp.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub text: Option<String>,
    stamp: Option<(SystemTime, u64)>,
}

pub fn read(path: &Path) -> Result<Snapshot, String> {
    match fs::read(path) {
        Ok(bytes) => {
            let stamp = stamp(path);
            let text = String::from_utf8(bytes)
                .map_err(|_| format!("{} is not UTF-8 text", path.display()))?;
            Ok(Snapshot { text: Some(text), stamp })
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Ok(Snapshot { text: None, stamp: None })
        }
        Err(error) => Err(format!("read {}: {error}", path.display())),
    }
}

fn stamp(path: &Path) -> Option<(SystemTime, u64)> {
    let meta = fs::metadata(path).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

/// Applies `change` to the file's text (None: no file yet) and writes what it returns, when that
/// differs. Tries again on a fresh read when the file changed between the read and the rename,
/// up to a few times. The file's mode is kept (a new file gets 0600: these hold secrets). Returns
/// whether it wrote.
pub fn update(
    path: &Path,
    mut change: impl FnMut(Option<&str>) -> Result<String, String>,
) -> Result<bool, String> {
    for _ in 0..5 {
        let before = read(path)?;
        let after = change(before.text.as_deref())?;
        if before.text.as_deref() == Some(after.as_str()) {
            return Ok(false);
        }
        match replace(path, &before, &after)? {
            true => return Ok(true),
            false => continue,
        }
    }
    Err(format!("{} kept changing while cmux wrote it; nothing was written", path.display()))
}

/// Replaces `path` with `text` unless it changed since `before`; false when it did.
fn replace(path: &Path, before: &Snapshot, text: &str) -> Result<bool, String> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = parent.join(format!(".{name}.cmux-{}.tmp", std::process::id()));
    let mode = mode_of(path);
    let write = || -> std::io::Result<()> {
        let mut file = open_new(&temporary, mode)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()
    };
    if let Err(error) = write() {
        let _ = fs::remove_file(&temporary);
        return Err(format!("write {}: {error}", temporary.display()));
    }
    // The last look before the rename: a write the agent made since the read wins, and the
    // change is made again over it.
    let now = read(path)?;
    if now.text != before.text || (now.text.is_some() && now.stamp != before.stamp) {
        let _ = fs::remove_file(&temporary);
        return Ok(false);
    }
    if let Some(old) = &before.text {
        let backup = backup_path(path);
        if let Err(error) = write_private(&backup, old.as_bytes(), mode) {
            let _ = fs::remove_file(&temporary);
            return Err(format!("keep a copy at {}: {error}", backup.display()));
        }
    }
    // A link (a dotfiles checkout) is written through: its target is replaced, the link stays.
    let target = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    fs::rename(&temporary, &target).map_err(|e| {
        let _ = fs::remove_file(&temporary);
        format!("replace {}: {e}", target.display())
    })?;
    Ok(true)
}

fn write_private(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    let _ = fs::remove_file(path);
    let mut file = open_new(path, mode)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(unix)]
fn mode_of(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt as _;
    fs::metadata(path).map(|m| m.permissions().mode() & 0o777).unwrap_or(0o600)
}

#[cfg(not(unix))]
fn mode_of(_path: &Path) -> u32 {
    0o600
}

#[cfg(unix)]
fn open_new(path: &Path, mode: u32) -> std::io::Result<fs::File> {
    use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
    let file =
        fs::OpenOptions::new().write(true).create(true).truncate(true).mode(mode).open(path)?;
    // The umask may have narrowed the mode; the file keeps the original's.
    file.set_permissions(fs::Permissions::from_mode(mode))?;
    Ok(file)
}

#[cfg(not(unix))]
fn open_new(path: &Path, _mode: u32) -> std::io::Result<fs::File> {
    fs::OpenOptions::new().write(true).create(true).truncate(true).open(path)
}

#[cfg(test)]
#[path = "fsio_tests.rs"]
mod tests;
