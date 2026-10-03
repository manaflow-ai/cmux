//! File reads and atomic publishes (Swift `CmuxConfigFile.source` and
//! `publish`).

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::store::FileRead;

/// The file's text; `""` for a missing file.
pub fn read_source(path: &Path) -> FileRead {
    match fs::read(path) {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(text) => FileRead::Text(text),
            Err(_) => FileRead::Unreadable("cmux.json is not UTF-8".to_string()),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => FileRead::Text(String::new()),
        Err(error) => FileRead::Unreadable(error.to_string()),
    }
}

/// Writes `text` to `path` atomically (temp file + rename in the same
/// directory). A symlinked file (dotfile repos) is written through, so the
/// link stays; an existing file keeps its permission bits.
pub fn publish(path: &Path, text: &str) -> io::Result<()> {
    write_atomic(&resolve_symlinks(path), text.as_bytes())
}

/// Atomic write of `bytes` to `path` (no symlink resolution).
pub fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let directory =
        path.parent().filter(|dir| !dir.as_os_str().is_empty()).unwrap_or(Path::new("."));
    fs::create_dir_all(directory)?;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = directory.join(format!(".{name}.{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        if let Ok(existing) = fs::metadata(path) {
            fs::set_permissions(&temporary, existing.permissions())?;
        }
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// `path` with symlinks in its last component followed (at most 32 hops).
pub fn resolve_symlinks(path: &Path) -> PathBuf {
    let mut current = path.to_path_buf();
    for _ in 0..32 {
        let Ok(metadata) = fs::symlink_metadata(&current) else { break };
        if !metadata.file_type().is_symlink() {
            break;
        }
        let Ok(target) = fs::read_link(&current) else { break };
        current = match current.parent() {
            Some(parent) if !target.is_absolute() => parent.join(target),
            _ => target,
        };
    }
    current
}
