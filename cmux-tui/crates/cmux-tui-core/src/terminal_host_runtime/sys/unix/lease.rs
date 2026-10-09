//! Leases on terminal-host files (cx-ko2e `Lease` seam, Unix side): the
//! host's process-lifetime liveness lease and the publication/reset lock
//! of a host record root. Moved from `mod unix` unchanged.

use std::fs::{self, File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use anyhow::Context;

use super::super::super::TERMINAL_HOST_PUBLICATION_LOCK_FILE;
use super::barrier_sync::{barrier_sync, open_lock_file, sync_new_lock_file};
use super::prepare_private_dir;

pub(crate) struct HostLivenessLease {
    pub(crate) file: File,
    pub(crate) path: PathBuf,
}

impl HostLivenessLease {
    pub(crate) fn acquire(path: PathBuf) -> anyhow::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)?;
        // SAFETY: flock only changes the advisory lock on this newly
        // created, valid file descriptor.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = std::io::Error::last_os_error();
            let _ = fs::remove_file(&path);
            return Err(error.into());
        }
        barrier_sync(&file)?; // why no full sync: barrier_sync.rs
        Ok(Self { file, path })
    }
}

impl Drop for HostLivenessLease {
    fn drop(&mut self) {
        // Closing the owner's descriptor does not release flock while a
        // concurrently forked child still holds an inherited duplicate.
        // The lease lifetime belongs to this owner, so end it explicitly
        // before closing the descriptor.
        // SAFETY: flock only changes the advisory lock associated with
        // this valid, owned file descriptor.
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

pub(crate) struct TerminalHostResetLock {
    file: File,
}

pub(crate) struct TerminalHostPublicationLock {
    file: File,
}

pub(crate) fn prepare_terminal_host_publication_lock(root: &Path) -> anyhow::Result<()> {
    prepare_private_dir(root)?;
    let path = terminal_host_publication_lock_path(root);
    let (file, existed) = open_lock_file(&path)
        .with_context(|| format!("create terminal-host publication lock {}", path.display()))?;
    validate_terminal_host_publication_lock(root, &path, &file)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    sync_new_lock_file(&file, root, existed)?;
    Ok(())
}

pub(crate) fn reserve_terminal_host_publication(
    root: &Path,
) -> anyhow::Result<TerminalHostPublicationLock> {
    prepare_terminal_host_publication_lock(root)?;
    acquire_terminal_host_publication_lock(root)
}

pub(crate) fn acquire_terminal_host_reset_lock(
    root: &Path,
) -> anyhow::Result<Option<TerminalHostResetLock>> {
    prepare_terminal_host_publication_lock(root)?;
    let path = terminal_host_publication_lock_path(root);
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)
        .with_context(|| format!("open terminal-host publication lock {}", path.display()))?;
    validate_terminal_host_publication_lock(root, &path, &file)?;
    lock_terminal_host_publication_file(&file, libc::LOCK_EX | libc::LOCK_NB).with_context(
        || format!("terminal host state has live or unverified hosts: {}", root.display()),
    )?;
    validate_terminal_host_publication_lock(root, &path, &file)?;
    Ok(Some(TerminalHostResetLock { file }))
}

pub(crate) fn acquire_terminal_host_publication_lock(
    root: &Path,
) -> anyhow::Result<TerminalHostPublicationLock> {
    let path = terminal_host_publication_lock_path(root);
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)
        .with_context(|| format!("open terminal-host publication lock {}", path.display()))?;
    validate_terminal_host_publication_lock(root, &path, &file)?;
    lock_terminal_host_publication_file(&file, libc::LOCK_SH)
        .with_context(|| format!("lock terminal-host publication lock {}", path.display()))?;
    validate_terminal_host_publication_lock(root, &path, &file)?;
    Ok(TerminalHostPublicationLock { file })
}

pub(crate) fn terminal_host_publication_lock_path(root: &Path) -> PathBuf {
    crate::platform::normalize_filesystem_path(root.join(TERMINAL_HOST_PUBLICATION_LOCK_FILE))
}

pub(crate) fn validate_terminal_host_publication_lock(
    root: &Path,
    path: &Path,
    file: &File,
) -> anyhow::Result<()> {
    let root_metadata = fs::metadata(root)
        .with_context(|| format!("inspect terminal-host root {}", root.display()))?;
    let path_metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect terminal-host publication lock {}", path.display()))?;
    if !path_metadata.file_type().is_file()
        || path_metadata.uid() != root_metadata.uid()
        || path_metadata.mode() & 0o077 != 0
        || path_metadata.nlink() != 1
    {
        anyhow::bail!("terminal-host publication lock is unsafe: {}", path.display());
    }
    let file_metadata = file.metadata()?;
    if path_metadata.dev() != file_metadata.dev() || path_metadata.ino() != file_metadata.ino() {
        anyhow::bail!("terminal-host publication lock changed while opening: {}", path.display());
    }
    Ok(())
}

pub(crate) fn lock_terminal_host_publication_file(
    file: &File,
    operation: libc::c_int,
) -> anyhow::Result<()> {
    loop {
        // SAFETY: flock only observes or changes the advisory lock on this
        // valid descriptor.
        if unsafe { libc::flock(file.as_raw_fd(), operation) } == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error.into());
    }
}

impl Drop for TerminalHostResetLock {
    fn drop(&mut self) {
        // SAFETY: flock only changes the advisory lock on this valid descriptor.
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

impl Drop for TerminalHostPublicationLock {
    fn drop(&mut self) {
        // SAFETY: flock only changes the advisory lock on this valid descriptor.
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}
