//! The publication and reset locks of a host record root (the Lease seam,
//! Windows side of `sys/unix/lease.rs`): `<root>/.publication.lock` in the
//! owner-only root, locked shared by every launch and host publication and
//! exclusive (without waiting) by a session reset, with `LockFileEx`.

use std::fs::{File, OpenOptions};
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use anyhow::Context;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT,
};

use super::super::super::TERMINAL_HOST_PUBLICATION_LOCK_FILE;
use super::liveness::{LeaseKind, lock_file, unlock_file};
use super::seams::{file_owner, prepare_private_dir};

pub(crate) struct TerminalHostPublicationLock {
    file: File,
}

pub(crate) struct TerminalHostResetLock {
    file: File,
}

impl Drop for TerminalHostPublicationLock {
    fn drop(&mut self) {
        unlock_file(&self.file);
    }
}

impl Drop for TerminalHostResetLock {
    fn drop(&mut self) {
        unlock_file(&self.file);
    }
}

pub(crate) fn terminal_host_publication_lock_path(root: &Path) -> PathBuf {
    crate::platform::normalize_filesystem_path(root.join(TERMINAL_HOST_PUBLICATION_LOCK_FILE))
}

/// Open the lock file of `root` (created when `create`): a regular file,
/// not a link, in a root that is ours and owner-only.
fn open_lock(root: &Path, create: bool) -> anyhow::Result<File> {
    let path = terminal_host_publication_lock_path(root);
    file_owner(root)
        .with_context(|| format!("terminal-host root is not private: {}", root.display()))?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(&path)
        .with_context(|| format!("open terminal-host publication lock {}", path.display()))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        anyhow::bail!("terminal-host publication lock is unsafe: {}", path.display());
    }
    Ok(file)
}

pub(crate) fn prepare_terminal_host_publication_lock(root: &Path) -> anyhow::Result<()> {
    prepare_private_dir(root)?;
    open_lock(root, true).map(drop)
}

pub(crate) fn reserve_terminal_host_publication(
    root: &Path,
) -> anyhow::Result<TerminalHostPublicationLock> {
    prepare_terminal_host_publication_lock(root)?;
    acquire_terminal_host_publication_lock(root)
}

pub(crate) fn acquire_terminal_host_publication_lock(
    root: &Path,
) -> anyhow::Result<TerminalHostPublicationLock> {
    let file = open_lock(root, false)?;
    lock_file(&file, LeaseKind::Shared, true)
        .with_context(|| format!("lock terminal-host publication lock in {}", root.display()))?;
    Ok(TerminalHostPublicationLock { file })
}

pub(crate) fn acquire_terminal_host_reset_lock(
    root: &Path,
) -> anyhow::Result<Option<TerminalHostResetLock>> {
    prepare_private_dir(root)?;
    let file = open_lock(root, true)?;
    if !lock_file(&file, LeaseKind::Exclusive, false)? {
        anyhow::bail!("terminal host state has live or unverified hosts: {}", root.display());
    }
    Ok(Some(TerminalHostResetLock { file }))
}
