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

pub(crate) fn write_json_private<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        owner_only_dir(dir)?;
    }
    let bytes = serde_json::to_vec(value).map_err(io::Error::other)?;
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
    file.write_all(&bytes)?;
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
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// The cache folder and file are owner-only whatever the umask: a folder an older build made
    /// with the umask (775 under 002) is narrowed, and a temporary file a crashed run left under
    /// the same pid (here 666) does not lend the new file its mode (ergo-walk2, 2026-10-25).
    #[test]
    fn the_cache_is_written_owner_only() {
        let root = std::env::temp_dir().join(format!(
            "chat-index-mode-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let dir = root.join("chat-index");
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o775)).unwrap();
        let path = dir.join("v1.json");
        let stale = path.with_extension(format!("tmp-{}", std::process::id()));
        fs::write(&stale, "{}").unwrap();
        fs::set_permissions(&stale, fs::Permissions::from_mode(0o666)).unwrap();
        write_json_private(&path, &serde_json::json!({"version": 1})).unwrap();
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&dir), 0o700);
        assert_eq!(mode(&path), 0o600);
        let _ = fs::remove_dir_all(&root);
    }
}
