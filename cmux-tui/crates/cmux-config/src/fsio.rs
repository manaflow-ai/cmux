//! File reads and atomic publishes (Swift `CmuxConfigFile.source` and
//! `publish`).

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use cmux_important_file::{Mode, Options, write_important_with};

use crate::store::FileRead;

/// The file's text; `""` for a missing file.
pub fn read_source(path: &Path) -> FileRead {
    match fs::read(path) {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(text) => FileRead::Text(text),
            Err(_) => FileRead::Unreadable(format!("{} is not UTF-8", path.display())),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => FileRead::Text(String::new()),
        Err(error) => FileRead::Unreadable(error.to_string()),
    }
}

/// Writes `text` to `path` atomically and durably (`cmux_important_file`). A
/// symlinked file (dotfile repos) is written through, so the link stays; an
/// existing file keeps its permission bits.
pub fn publish(path: &Path, text: &str) -> io::Result<()> {
    write_state(&resolve_symlinks(path), text.as_bytes())
}

/// An owner state file (no symlink resolution): atomic and durable, missing
/// folders created, an existing file's permission bits kept.
pub fn write_state(path: &Path, bytes: &[u8]) -> io::Result<()> {
    Ok(write_important_with(path, bytes, &Options::new(Mode::Keep).create_parent())?)
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
