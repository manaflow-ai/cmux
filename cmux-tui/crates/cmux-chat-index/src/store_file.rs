//! Private JSON files for the index's own state (mode 0600, written to a
//! temp file and renamed so a crash never leaves half a file).

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use serde::Serialize;
use serde::de::DeserializeOwned;

pub(crate) fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Like `read_json`, for a file another program owns: at most `max` bytes.
pub(crate) fn read_json_bounded<T: DeserializeOwned>(path: &Path, max: u64) -> Option<T> {
    if fs::metadata(path).ok()?.len() > max {
        return None;
    }
    read_json(path)
}

pub fn write_json_private<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    let bytes = serde_json::to_vec(value).map_err(io::Error::other)?;
    write_private(path, &bytes)
}

/// [`write_json_private`] for bytes already encoded: the shape of every write the index makes,
/// which a caller with its own way to write ([`crate::ChatIndex::save_with`]) takes as its writer.
pub fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        owner_only_dir(dir)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    // A file a crashed process left under a reused pid keeps its mode: start anew.
    let _ = fs::remove_file(&tmp);
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&tmp, path)
}

/// Makes `dir` (and missing parents) owner-only whatever the umask: under 002 it would be
/// group-writable. One an older build made with the umask is narrowed (only its owner may; a
/// folder of another user stays as it is), never through a link.
fn owner_only_dir(dir: &Path) -> io::Result<()> {
    let mut made = fs::DirBuilder::new();
    made.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut made, 0o700);
    made.create(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let meta = fs::symlink_metadata(dir)?;
        if meta.is_dir() && meta.mode() & 0o077 != 0 {
            let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
        }
    }
    Ok(())
}

#[cfg(all(test, unix))]
mod tests;
