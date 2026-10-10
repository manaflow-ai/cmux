use std::fmt;
use std::fs;
use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::net::UnixListener;

use crate::owner_lock::{OwnerFileLock, sibling_lock_path};
use crate::secure_directory::{DirectoryAccess, ensure_secure_directory};

const SOCKET_PROBE_TIMEOUT: Duration = Duration::from_millis(250);
const ACCEPT_RETRY_INITIAL_DELAY: Duration = Duration::from_millis(10);
const ACCEPT_RETRY_MAX_DELAY: Duration = Duration::from_millis(250);

pub(crate) struct UnixAcceptBackoff {
    next_delay: Duration,
}

impl UnixAcceptBackoff {
    pub(crate) fn new() -> Self {
        Self { next_delay: ACCEPT_RETRY_INITIAL_DELAY }
    }

    pub(crate) fn retry_delay(&mut self, error: &io::Error) -> Option<Duration> {
        if !retryable_accept_error(error) {
            return None;
        }
        let delay = self.next_delay;
        self.next_delay = self.next_delay.saturating_mul(2).min(ACCEPT_RETRY_MAX_DELAY);
        Some(delay)
    }

    pub(crate) fn reset(&mut self) {
        self.next_delay = ACCEPT_RETRY_INITIAL_DELAY;
    }
}

fn retryable_accept_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::Interrupted
            | io::ErrorKind::WouldBlock
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::TimedOut
    ) || matches!(
        error.raw_os_error(),
        Some(libc::EMFILE) | Some(libc::ENFILE) | Some(libc::ENOBUFS) | Some(libc::ENOMEM)
    )
}

#[derive(Debug)]
pub(crate) enum UnixSocketError {
    Io(io::Error),
    Protocol(String),
}

impl fmt::Display for UnixSocketError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => error.fmt(formatter),
            Self::Protocol(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for UnixSocketError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Protocol(_) => None,
        }
    }
}

/// Owns the pathname for a bound Unix listener and removes it only while the
/// same socket inode is still published at that pathname.
///
/// The cleanup handle is shared with the server wrapper. This lets a wrapper
/// dropped before its accept task is polled remove the pathname synchronously,
/// while the listener's own drop remains a safe idempotent fallback.
#[derive(Debug)]
pub(crate) struct UnixSocketCleanup {
    path: PathBuf,
    device: u64,
    inode: u64,
    state: Mutex<UnixSocketCleanupState>,
}

#[derive(Debug)]
struct UnixSocketCleanupState {
    linked: bool,
    path_lock: Option<OwnerFileLock>,
}

#[derive(Debug)]
struct UnixSocketCleanupGuard(Arc<UnixSocketCleanup>);

impl Drop for UnixSocketCleanupGuard {
    fn drop(&mut self) {
        let _ = self.0.unlink_and_release();
    }
}

impl UnixSocketCleanup {
    fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn unlink(&self) -> io::Result<()> {
        self.unlink_inner(false)
    }

    fn unlink_and_release(&self) -> io::Result<()> {
        self.unlink_inner(true)
    }

    fn unlink_inner(&self, release_lock: bool) -> io::Result<()> {
        let mut state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !state.linked {
            if release_lock {
                drop(state.path_lock.take());
            }
            return Ok(());
        }
        let metadata = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                state.linked = false;
                if release_lock {
                    drop(state.path_lock.take());
                }
                return Ok(());
            }
            Err(error) => return Err(error),
        };
        if !metadata.file_type().is_socket()
            || metadata.dev() != self.device
            || metadata.ino() != self.inode
        {
            state.linked = false;
            if release_lock {
                drop(state.path_lock.take());
            }
            return Ok(());
        }
        fs::remove_file(&self.path)?;
        state.linked = false;
        if release_lock {
            drop(state.path_lock.take());
        }
        Ok(())
    }
}

#[derive(Debug)]
pub(crate) struct OwnedUnixListener {
    listener: UnixListener,
    cleanup: UnixSocketCleanupGuard,
}

impl OwnedUnixListener {
    pub(crate) async fn bind(path: PathBuf) -> Result<Self, UnixSocketError> {
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .ok_or_else(|| UnixSocketError::Protocol("Unix socket path has no parent".into()))?;
        ensure_secure_directory(parent, DirectoryAccess::OwnerControlled).map_err(|error| {
            contextual_io(
                error,
                format!("could not secure Unix socket directory {}", parent.display()),
            )
        })?;
        // The descriptor-based path walk verifies every ancestor and requires
        // the final directory to be owned by the effective user without group
        // or other write access. It creates missing directories but never
        // chmods an existing caller-owned directory. A pathname swap after this
        // point therefore requires the same OS identity (which already has full
        // daemon authority) or root.
        validate_socket_directory_for_uid(parent, unsafe { libc::geteuid() })?;

        let lock_path = sibling_lock_path(&path).map_err(UnixSocketError::Io)?;
        let path_lock = match OwnerFileLock::try_acquire(&lock_path) {
            Ok(lock) => lock,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                return Err(UnixSocketError::Protocol(format!(
                    "Unix socket path {} is already leased",
                    path.display()
                )));
            }
            Err(error) => {
                return Err(contextual_io(
                    error,
                    format!("could not lease Unix socket path {}", path.display()),
                ));
            }
        };
        remove_stale_socket(&path).await?;

        let listener = UnixListener::bind(&path).map_err(|error| {
            contextual_io(error, format!("could not bind Unix socket {}", path.display()))
        })?;
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) => {
                return Err(contextual_io(
                    error,
                    format!("could not inspect bound Unix socket {}", path.display()),
                ));
            }
        };
        if !metadata.file_type().is_socket() {
            return Err(UnixSocketError::Protocol(format!(
                "bound Unix socket path {} is not a socket",
                path.display()
            )));
        }
        let cleanup = Arc::new(UnixSocketCleanup {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
            state: Mutex::new(UnixSocketCleanupState { linked: true, path_lock: Some(path_lock) }),
        });
        let lease = Self { listener, cleanup: UnixSocketCleanupGuard(cleanup) };
        if let Err(error) =
            fs::set_permissions(lease.cleanup.0.path(), fs::Permissions::from_mode(0o600))
        {
            let _ = lease.cleanup.0.unlink_and_release();
            return Err(contextual_io(
                error,
                format!("could not secure Unix socket {}", lease.cleanup.0.path().display()),
            ));
        }
        Ok(lease)
    }

    pub(crate) fn listener(&self) -> &UnixListener {
        &self.listener
    }

    pub(crate) fn cleanup(&self) -> Arc<UnixSocketCleanup> {
        Arc::clone(&self.cleanup.0)
    }
}

pub(crate) fn validate_socket_directory_for_uid(
    parent: &Path,
    effective_uid: u32,
) -> Result<(), UnixSocketError> {
    let metadata = fs::symlink_metadata(parent).map_err(UnixSocketError::Io)?;
    if !metadata.file_type().is_dir() {
        return Err(UnixSocketError::Protocol(format!(
            "socket directory {} must be a non-symlink directory",
            parent.display()
        )));
    }
    if metadata.uid() != effective_uid {
        return Err(UnixSocketError::Protocol(format!(
            "socket directory {} is not owned by the effective user",
            parent.display()
        )));
    }
    if metadata.permissions().mode() & 0o022 != 0 {
        return Err(UnixSocketError::Protocol(format!(
            "socket directory {} is writable by the group or other users",
            parent.display()
        )));
    }
    Ok(())
}

async fn remove_stale_socket(path: &Path) -> Result<(), UnixSocketError> {
    let metadata = match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(contextual_io(
                error,
                format!("could not inspect Unix socket {}", path.display()),
            ));
        }
        Ok(metadata) => metadata,
    };
    if !metadata.file_type().is_socket() {
        return Err(UnixSocketError::Protocol(format!(
            "refusing to replace non-socket path {}",
            path.display()
        )));
    }
    match tokio::time::timeout(SOCKET_PROBE_TIMEOUT, tokio::net::UnixStream::connect(path)).await {
        Ok(Ok(_)) => Err(UnixSocketError::Protocol(format!(
            "another process is listening at {}",
            path.display()
        ))),
        Ok(Err(error)) if error.kind() == io::ErrorKind::ConnectionRefused => {
            remove_socket_if_unchanged(path, &metadata)
        }
        Ok(Err(error)) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Ok(Err(error)) => Err(contextual_io(
            error,
            format!("could not verify Unix socket ownership at {}", path.display()),
        )),
        Err(_) => Err(UnixSocketError::Protocol(format!(
            "timed out checking whether another process owns {}",
            path.display()
        ))),
    }
}

fn remove_socket_if_unchanged(path: &Path, expected: &fs::Metadata) -> Result<(), UnixSocketError> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(contextual_io(
            error,
            format!("could not recheck stale Unix socket {}", path.display()),
        )),
        Ok(current)
            if current.file_type().is_socket()
                && current.dev() == expected.dev()
                && current.ino() == expected.ino() =>
        {
            fs::remove_file(path).map_err(|error| {
                contextual_io(
                    error,
                    format!("could not remove stale Unix socket {}", path.display()),
                )
            })?;
            Ok(())
        }
        Ok(_) => Err(UnixSocketError::Protocol(format!(
            "Unix socket {} changed during stale-owner detection",
            path.display()
        ))),
    }
}

fn contextual_io(error: io::Error, context: String) -> UnixSocketError {
    UnixSocketError::Io(io::Error::new(error.kind(), format!("{context}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn bind_preserves_an_existing_owner_controlled_directory() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let socket = directory.path().join("daemon.sock");

        let listener = OwnedUnixListener::bind(socket.clone()).await.unwrap();

        assert_eq!(fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777, 0o755);
        assert_eq!(fs::metadata(&socket).unwrap().permissions().mode() & 0o777, 0o600);
        drop(listener);
    }
}
