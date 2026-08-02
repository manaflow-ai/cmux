//! Cross-process ownership for publishing one durable filesystem identity.

#[cfg(unix)]
use std::collections::HashSet;
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use fs4::FileExt;

pub(crate) fn publication_lock_path(path: &Path) -> std::io::Result<PathBuf> {
    let parent = path.parent().ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "publication target has no parent directory",
        )
    })?;
    let file_name = path.file_name().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "publication target has no file name")
    })?;
    let mut lock_name = std::ffi::OsString::from(".");
    lock_name.push(file_name);
    lock_name.push(".publish.lock");
    Ok(parent.join(lock_name))
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct PublicationLockIdentity {
    device: u64,
    inode: u64,
}

#[cfg(unix)]
static PUBLICATION_LOCAL_STATE: OnceLock<(Mutex<HashSet<PublicationLockIdentity>>, Condvar)> =
    OnceLock::new();

#[cfg(unix)]
struct PublicationLocalGuard {
    identity: PublicationLockIdentity,
}

#[cfg(unix)]
impl PublicationLocalGuard {
    fn acquire(
        identity: PublicationLockIdentity,
        path: &Path,
        deadline: Instant,
    ) -> std::io::Result<Self> {
        let (held, changed) = PUBLICATION_LOCAL_STATE.get_or_init(Default::default);
        let mut held = held.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        loop {
            if held.insert(identity) {
                return Ok(Self { identity });
            }
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero())
                .ok_or_else(|| publication_timeout(path))?;
            held = match changed.wait_timeout(held, remaining) {
                Ok((held, _)) => held,
                Err(error) => error.into_inner().0,
            };
        }
    }
}

#[cfg(unix)]
impl Drop for PublicationLocalGuard {
    fn drop(&mut self) {
        let (held, changed) = PUBLICATION_LOCAL_STATE.get_or_init(Default::default);
        held.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&self.identity);
        changed.notify_all();
    }
}

fn publication_timeout(path: &Path) -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::TimedOut,
        format!("timed out waiting to publish {}", path.display()),
    )
}

/// Exclusive authority to mutate one durable filesystem publication.
///
/// The lock is released by closing its file descriptor. On Unix, callers can
/// deliberately inherit that descriptor into a helper process so ownership
/// survives a parent-process exit without an unlocked interval.
#[must_use = "dropping the guard releases publication ownership"]
pub struct PublicationGuard {
    // Rust drops fields in declaration order. Close this process's file-lock
    // reference before reopening local admission for another thread.
    file: std::fs::File,
    target: PathBuf,
    #[cfg(unix)]
    _local: PublicationLocalGuard,
}

impl PublicationGuard {
    pub fn acquire(path: &Path, deadline: Instant) -> std::io::Result<Self> {
        let lock_path = publication_lock_path(path)?;
        let mut options = std::fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;

            options.mode(0o600).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
        }
        let file = options.open(&lock_path)?;
        #[cfg(unix)]
        let local = {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};

            let metadata = file.metadata()?;
            if !metadata.file_type().is_file() || metadata.nlink() != 1 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "publication lock is not a single regular file",
                ));
            }
            // SAFETY: geteuid has no preconditions and returns the effective
            // user that owns files created by this process.
            let current_user = unsafe { libc::geteuid() };
            if metadata.uid() != current_user {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "publication lock is owned by another user",
                ));
            }
            file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            PublicationLocalGuard::acquire(
                PublicationLockIdentity { device: metadata.dev(), inode: metadata.ino() },
                path,
                deadline,
            )?
        };
        #[cfg(not(unix))]
        crate::platform::restrict_file(&lock_path)?;
        loop {
            match FileExt::try_lock(&file) {
                Ok(()) => {
                    return Ok(Self {
                        file,
                        target: path.to_path_buf(),
                        #[cfg(unix)]
                        _local: local,
                    });
                }
                Err(fs4::TryLockError::WouldBlock) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(fs4::TryLockError::WouldBlock) => return Err(publication_timeout(path)),
                Err(fs4::TryLockError::Error(error)) => return Err(error),
            }
        }
    }

    pub fn target(&self) -> &Path {
        &self.target
    }

    /// Arrange for this guard's lock descriptor to survive `exec` in `command`.
    ///
    /// The returned descriptor number must be passed to the child, which
    /// should validate and adopt it with [`Self::adopt_inherited`]. The parent
    /// descriptor remains close-on-exec and continues to own the same lock.
    #[cfg(unix)]
    pub fn inherit_into(&self, command: &mut std::process::Command) -> std::os::fd::RawFd {
        use std::os::fd::AsRawFd as _;
        use std::os::unix::process::CommandExt as _;

        let descriptor = self.file.as_raw_fd();
        // SAFETY: fcntl is async-signal-safe, and this only clears
        // close-on-exec on the guard-owned descriptor in the child between
        // fork and exec. The parent descriptor remains close-on-exec.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(descriptor, libc::F_GETFD);
                if flags == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::fcntl(descriptor, libc::F_SETFD, flags & !libc::FD_CLOEXEC) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        descriptor
    }

    /// Validate and adopt a publication descriptor inherited across `exec`.
    ///
    /// # Safety
    ///
    /// `descriptor` must be a valid, uniquely owned child-process descriptor
    /// produced by [`Self::inherit_into`]. The caller must not use or close it
    /// after this function takes ownership.
    #[cfg(unix)]
    pub unsafe fn adopt_inherited(
        path: &Path,
        descriptor: std::os::fd::RawFd,
        deadline: Instant,
    ) -> std::io::Result<Self> {
        use std::os::fd::{AsRawFd as _, FromRawFd as _};
        use std::os::unix::fs::MetadataExt as _;

        if descriptor <= libc::STDERR_FILENO {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "publication descriptor is invalid",
            ));
        }
        // SAFETY: F_GETFD only validates the caller-owned descriptor.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
        if flags == -1 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: the function contract transfers unique ownership of this
        // inherited child descriptor into the returned guard.
        let file = unsafe { std::fs::File::from_raw_fd(descriptor) };
        // Do not leak publication ownership into any subprocess the helper
        // might launch after adoption.
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, flags | libc::FD_CLOEXEC) } == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let metadata = file.metadata()?;
        let lock_path = publication_lock_path(path)?;
        let published_metadata = std::fs::symlink_metadata(&lock_path)?;
        if !metadata.file_type().is_file()
            || metadata.nlink() != 1
            || metadata.dev() != published_metadata.dev()
            || metadata.ino() != published_metadata.ino()
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "inherited publication descriptor has the wrong identity",
            ));
        }
        let local = PublicationLocalGuard::acquire(
            PublicationLockIdentity { device: metadata.dev(), inode: metadata.ino() },
            path,
            deadline,
        )?;
        // An inherited duplicate shares the already-locked open file
        // description. A separately opened descriptor conflicts while the
        // legitimate owner is alive, so this also proves lock ownership.
        match FileExt::try_lock(&file) {
            Ok(()) => Ok(Self { file, target: path.to_path_buf(), _local: local }),
            Err(fs4::TryLockError::WouldBlock) => Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "inherited publication descriptor does not own the lock",
            )),
            Err(fs4::TryLockError::Error(error)) => Err(error),
        }
    }
}
