//! Unix side of the terminal-host platform seams (cx-ko2e): today's code,
//! moved out of `mod unix` unchanged.

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io as std_io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Instant;

use super::super::{HOST_CONNECT_RETRY_INTERVAL, HOST_CONNECT_RETRY_WINDOW};
use super::{HostStream, LeaseProbe, PrivateOpen};

pub(crate) use super::super::unix::PtyCustody;
pub(crate) use super::super::unix::launch_terminal_host_from;
pub(crate) use super::super::unix::remove_released as remove_released_pty_lock;
pub(crate) use super::super::unix::serve_pty_custody;
pub(crate) use super::super::unix::{adopt_launch, host_signals};
mod barrier_sync;
mod lease;
mod listener;
mod process;
mod pty_readiness;
mod waker;
pub(crate) use crate::terminal_loss_log::remove_signals as remove_terminal_loss_signals;
pub(crate) use barrier_sync::{barrier_sync, barrier_sync_dir};
pub(crate) use lease::*;
pub(crate) use listener::HostListener;
pub(crate) use process::{
    kill_process_group, process_definitely_absent as process_definitely_gone,
};
pub(crate) use pty_readiness::wait_for_pty_readable_or_forced_drain;
pub(crate) use waker::AcceptWaker;

/// The session id of an adopted (non-child) process.
pub(crate) type SessionId = libc::pid_t;

/// The owner of a file: its uid.
pub(crate) type FileOwner = u32;

pub(crate) fn file_owner(path: &Path) -> std_io::Result<FileOwner> {
    Ok(fs::metadata(path)?.uid())
}

/// A regular file owned by `owner` that no group or other user can access.
pub(crate) fn is_private_file(metadata: &fs::Metadata, owner: FileOwner) -> bool {
    metadata.file_type().is_file() && metadata.uid() == owner && metadata.mode() & 0o077 == 0
}

pub(crate) fn has_single_link(metadata: &fs::Metadata) -> bool {
    metadata.nlink() == 1
}

/// The only endpoint a record of `owner`'s host may name.
pub(crate) fn canonical_endpoint(owner: FileOwner, terminal_id: &str) -> PathBuf {
    PathBuf::from("/tmp").join(format!("cmux-th-{owner}")).join(format!("{terminal_id}.sock"))
}

pub(crate) fn is_endpoint_file(metadata: &fs::Metadata) -> bool {
    metadata.file_type().is_socket()
}

pub(crate) fn open_private(path: &Path, how: PrivateOpen) -> std_io::Result<File> {
    match how {
        PrivateOpen::ExistingNoFollow => OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(path),
        PrivateOpen::CreateNew => {
            OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
        }
        PrivateOpen::CreateNewNoFollow => OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path),
        PrivateOpen::TruncateNoFollow => OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path),
    }
}

/// Try the exclusive lease on `file` without waiting, and drop it at once.
pub(crate) fn probe_lease(file: &File) -> LeaseProbe {
    loop {
        // SAFETY: flock only observes/changes the advisory lock associated
        // with this valid, owned file descriptor.
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            // SAFETY: same valid descriptor as above. Unlock before the
            // temporary probe descriptor is closed.
            let _ = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
            return LeaseProbe::Free;
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return if error
            .raw_os_error()
            .is_some_and(|code| code == libc::EWOULDBLOCK || code == libc::EAGAIN)
        {
            LeaseProbe::Held
        } else {
            LeaseProbe::Unknown
        };
    }
}

/// Make the directory entry changes in `dir` durable.
pub(crate) fn sync_dir(dir: &Path) -> std_io::Result<()> {
    File::open(dir)?.sync_all()
}

#[cfg(target_vendor = "apple")]
pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> std_io::Result<()> {
    let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| {
        std_io::Error::new(std_io::ErrorKind::InvalidInput, "temporary path has NUL")
    })?;
    let to = CString::new(to.as_os_str().as_bytes())
        .map_err(|_| std_io::Error::new(std_io::ErrorKind::InvalidInput, "exit path has NUL"))?;
    // SAFETY: both pointers reference live NUL-terminated path strings,
    // and RENAME_EXCL asks the kernel to leave an existing target intact.
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(std_io::Error::last_os_error())
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> std_io::Result<()> {
    let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| {
        std_io::Error::new(std_io::ErrorKind::InvalidInput, "temporary path has NUL")
    })?;
    let to = CString::new(to.as_os_str().as_bytes())
        .map_err(|_| std_io::Error::new(std_io::ErrorKind::InvalidInput, "exit path has NUL"))?;
    // SAFETY: both pointers reference live NUL-terminated path strings,
    // and RENAME_NOREPLACE asks the kernel to leave an existing target intact.
    // Call the syscall directly because musl does not export a `renameat2`
    // wrapper symbol.
    if unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(std_io::Error::last_os_error())
    }
}

pub(crate) fn prepare_private_dir(path: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

/// The shared `/tmp` directory that holds host sockets. Every user can
/// create names there, so the directory must be a real one this user owns.
pub(crate) fn prepare_endpoint_dir(path: &Path) -> anyhow::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            anyhow::bail!(
                "terminal host endpoint directory is not a directory: {}",
                path.display()
            );
        }
        Ok(_) => {}
        Err(error) if error.kind() == std_io::ErrorKind::NotFound => fs::create_dir_all(path)?,
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || metadata.uid() != crate::platform::effective_uid()
    {
        anyhow::bail!("terminal host endpoint directory is not this user's: {}", path.display());
    }
    if metadata.mode() & 0o077 != 0 {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        if fs::symlink_metadata(path)?.mode() & 0o077 != 0 {
            anyhow::bail!("terminal host endpoint directory is not private: {}", path.display());
        }
    }
    Ok(())
}

/// Connect to a host endpoint. Hosts run as this user, so a listener
/// owned by anyone else never receives the owner capability.
pub(crate) fn connect_with_retry(path: &Path) -> anyhow::Result<HostStream> {
    let deadline = Instant::now() + HOST_CONNECT_RETRY_WINDOW;
    loop {
        match HostStream::connect(path) {
            Ok(stream) => {
                crate::platform::require_unix_peer_uid(&stream, crate::platform::effective_uid())?;
                return Ok(stream);
            }
            Err(error) => {
                let now = Instant::now();
                if now >= deadline {
                    return Err(error.into());
                }
                std::thread::sleep(HOST_CONNECT_RETRY_INTERVAL.min(deadline - now));
            }
        }
    }
}
