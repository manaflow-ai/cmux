//! Reading a listed file of this Mac as the file listed (local.rs lists them).

use std::path::Path;

use anyhow::{Context as _, bail};

use super::local::{LocalFile, Source, permissions_of};

impl LocalFile {
    /// The regular file at `path`, as `meta` (its `symlink_metadata`) found it.
    pub(super) fn listed(path: &Path, meta: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        Self {
            source: Source::File(path.to_path_buf()),
            permissions: permissions_of(meta.permissions().mode()),
            id: Some((meta.dev(), meta.ino())),
        }
    }
}

/// Opens the file at `path` without following a symlink or blocking on a FIFO
/// swapped in since it was listed; anything but a regular file is refused, and
/// so is a file other than the one listed as `id` (a folder above it swapped for
/// a symlink that leads out of the folder copied).
pub(super) fn open_listed(path: &Path, id: Option<(u64, u64)>) -> anyhow::Result<std::fs::File> {
    use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
    let opened = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| format!("cannot read {}", path.display()))?;
    let meta = opened.metadata()?;
    if !meta.is_file() {
        bail!("{} is no longer a regular file", path.display());
    }
    if id.is_some_and(|id| id != (meta.dev(), meta.ino())) {
        bail!("{} is not the file listed there (a folder above it changed)", path.display());
    }
    Ok(opened)
}
