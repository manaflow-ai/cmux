//! A JSON file written whole or not at all, and the plain ids that name the files: the transfer
//! markers (`transfer.rs`, `transfer_in.rs`).

use super::*;

/// Writes `value` to `path` through a fresh temporary file, synced and renamed into place,
/// then syncs the directory.
pub(super) fn write_json_atomic(path: &Path, value: &Value) -> Result<()> {
    let tmp = path.with_extension(format!(
        "{}.importing",
        path.extension().and_then(|e| e.to_str()).unwrap_or("json")
    ));
    if std::fs::symlink_metadata(&tmp).is_ok() {
        return Err(anyhow::anyhow!("transaction marker temporary path is occupied"));
    }
    let bytes = serde_json::to_vec(value)?;
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp)?;
    // The temporary file is this call's own (`create_new`): a failure before the rename takes it
    // away, so the next write of `path` is not refused as occupied.
    let written = (|| -> std::io::Result<()> {
        use std::io::Write;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    if let Some(parent) = path.parent() {
        std::fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

/// True when `id` is a single plain path component, so it can name a file or directory under a
/// root (no separator, `.`, `..` or root).
pub(super) fn is_plain_id(id: &str) -> bool {
    let mut parts = Path::new(id).components();
    matches!(
        (parts.next(), parts.next()),
        (Some(std::path::Component::Normal(c)), None) if c.to_str() == Some(id)
    )
}
