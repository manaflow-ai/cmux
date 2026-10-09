//! The Windows side of the terminal-host seams in `sys.rs` (cx-ko2e;
//! design: "Records and paths", "Windows design" table). Each item here
//! replaces a fail-closed stub of `windows_stubs`.
//!
//! Ownership: Windows files have no mode bits, so a record is private when it
//! lies in a directory that is ours and owner-only (protected DACL granting
//! only our token user; `cmux::local_socket::private_directory` makes such a
//! directory). [`FileOwner`] is the proof that a directory passed that check;
//! files created in it inherit its DACL, so nobody else can create, replace,
//! read or hard-link them.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    ERROR_INVALID_PARAMETER, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, MOVEFILE_WRITE_THROUGH, MoveFileExW,
};
use windows_sys::Win32::System::Threading::{
    CreateEventW, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, ResetEvent,
    SetEvent, WaitForSingleObject,
};

use super::super::super::{HOST_CONNECT_RETRY_INTERVAL, HOST_CONNECT_RETRY_WINDOW};
use super::super::{HostStream, LeaseProbe, PrivateOpen};
use super::endpoint;
use super::liveness::{LeaseKind, lock_file, unlock_file};

/// Proof that a directory is ours and owner-only ([`file_owner`]).
#[derive(Clone, Copy, Debug)]
pub(crate) struct FileOwner {
    _proven: (),
}

/// The directory `path` is owned by our token user and its DACL allows only
/// that user; otherwise `PermissionDenied`.
pub(crate) fn file_owner(path: &Path) -> io::Result<FileOwner> {
    let me = cmux::local_socket::win::current_identity()?;
    let owner = cmux::local_socket::win::owner_of(path)?;
    if owner != me.user_sid
        || !cmux::local_socket::win::directory_is_owner_only(path, &me.user_sid)?
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("not an owner-only directory of this user: {}", path.display()),
        ));
    }
    Ok(FileOwner { _proven: () })
}

fn is_reparse_point(metadata: &fs::Metadata) -> bool {
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

/// A regular file (not a link or other reparse point) in a directory that
/// [`file_owner`] proved ours and owner-only.
pub(crate) fn is_private_file(metadata: &fs::Metadata, _owner: FileOwner) -> bool {
    metadata.file_type().is_file() && !is_reparse_point(metadata)
}

/// Always true: a hard link needs write-attributes access to the file, which
/// the owner-only DACL gives nobody else, and we never link records.
pub(crate) fn has_single_link(_metadata: &fs::Metadata) -> bool {
    true
}

/// The only endpoint a record of ours may name: this user's endpoint
/// directory (`endpoint.rs`).
pub(crate) fn canonical_endpoint(_owner: FileOwner, terminal_id: &str) -> PathBuf {
    endpoint::endpoint_dir().join(format!("{terminal_id}.sock"))
}

/// An AF_UNIX socket file is a reparse point (`IO_REPARSE_TAG_AF_UNIX`);
/// std does not expose the tag, so any non-directory reparse point counts.
/// Callers only remove such an entry inside our owner-only directory.
pub(crate) fn is_endpoint_file(metadata: &fs::Metadata) -> bool {
    !metadata.is_dir() && is_reparse_point(metadata)
}

/// Opens a record file. The `NoFollow` kinds open a link itself
/// (`FILE_FLAG_OPEN_REPARSE_POINT`) and refuse it, as `O_NOFOLLOW` does.
/// New files inherit the owner-only DACL of their directory.
pub(crate) fn open_private(path: &Path, how: PrivateOpen) -> io::Result<File> {
    let mut options = OpenOptions::new();
    let no_follow = match how {
        PrivateOpen::ExistingNoFollow => {
            options.read(true).write(true);
            true
        }
        PrivateOpen::CreateNew => {
            options.write(true).create_new(true);
            false
        }
        PrivateOpen::CreateNewNoFollow => {
            options.write(true).create_new(true);
            true
        }
        PrivateOpen::TruncateNoFollow => {
            options.write(true).create(true).truncate(true);
            true
        }
    };
    if no_follow {
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path)?;
    if no_follow && is_reparse_point(&file.metadata()?) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("refusing a link at {}", path.display()),
        ));
    }
    Ok(file)
}

/// Try the exclusive lease on `file` without waiting, and drop it at once.
pub(crate) fn probe_lease(file: &File) -> LeaseProbe {
    match lock_file(file, LeaseKind::Exclusive, false) {
        Ok(true) => {
            unlock_file(file);
            LeaseProbe::Free
        }
        Ok(false) => LeaseProbe::Held,
        Err(_) => LeaseProbe::Unknown,
    }
}

/// True when the exclusive lease on `file` was free (then released at once).
pub(crate) fn lease_was_free(file: &File) -> bool {
    probe_lease(file) == LeaseProbe::Free
}

/// Block until the exclusive lease on `file` is ours; held until it closes.
pub(crate) fn wait_lease_exclusive(file: &File) -> io::Result<()> {
    lock_file(file, LeaseKind::Exclusive, true).map(|_| ())
}

/// The host's process-lifetime liveness lease: an exclusive lock on a new
/// `.live` file, released by the kernel when the host's handle closes or
/// the host ends.
pub(crate) struct HostLivenessLease {
    pub(crate) file: File,
    pub(crate) path: PathBuf,
}

impl HostLivenessLease {
    pub(crate) fn acquire(path: PathBuf) -> anyhow::Result<Self> {
        let file = open_private(&path, PrivateOpen::CreateNewNoFollow)?;
        if !lock_file(&file, LeaseKind::Exclusive, false)? {
            let _ = fs::remove_file(&path);
            anyhow::bail!("liveness lease {} is held", path.display());
        }
        file.sync_all()?;
        Ok(Self { file, path })
    }
}

impl Drop for HostLivenessLease {
    fn drop(&mut self) {
        unlock_file(&self.file);
    }
}

/// Positive proof that no live process has `pid`: no such process, or one
/// that has exited. Access errors and live processes are not proof.
pub(crate) fn process_definitely_gone(pid: u32) -> bool {
    // SAFETY: plain call; a null handle is failure.
    let process =
        unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        return io::Error::last_os_error().raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32);
    }
    // SAFETY: the handle opened above, closed by OwnedHandle.
    let process = unsafe {
        <std::os::windows::io::OwnedHandle as std::os::windows::io::FromRawHandle>::from_raw_handle(
            process,
        )
    };
    // SAFETY: a valid process handle with SYNCHRONIZE.
    unsafe { WaitForSingleObject(process.as_raw_handle() as HANDLE, 0) == WAIT_OBJECT_0 }
}

/// NTFS journals directory changes; there is no directory flush to call.
pub(crate) fn sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

/// `FlushFileBuffers`: data reaches the disk before the rename that
/// publishes it.
pub(crate) fn barrier_sync(file: &File) -> io::Result<()> {
    file.sync_all()
}

pub(crate) fn barrier_sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

fn wide(path: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

/// `MoveFileExW` without `MOVEFILE_REPLACE_EXISTING`: an existing `to` stays
/// and the error kind is `AlreadyExists`.
pub(crate) fn rename_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    let (from, to) = (wide(from), wide(to));
    // SAFETY: two NUL-terminated paths.
    if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } != 0 {
        return Ok(());
    }
    // std maps ERROR_ALREADY_EXISTS and ERROR_FILE_EXISTS to AlreadyExists.
    Err(io::Error::last_os_error())
}

/// Makes `path` an owner-only directory of ours, or checks an existing one
/// (a wider one is refused).
pub(crate) fn prepare_private_dir(path: &Path) -> anyhow::Result<()> {
    cmux::local_socket::private_directory(path)?;
    Ok(())
}

/// The endpoint directory is per user under the per-user temp folder; it is
/// made and checked like any private directory.
pub(crate) fn prepare_endpoint_dir(path: &Path) -> anyhow::Result<()> {
    prepare_private_dir(path)
}

/// Connect to a host endpoint whose socket file is owned by our token user
/// (`connect_same_user`), retrying a host still starting.
pub(crate) fn connect_with_retry(path: &Path) -> anyhow::Result<HostStream> {
    Ok(cmux::local_socket::connect_with_deadline(
        path,
        HOST_CONNECT_RETRY_WINDOW,
        HOST_CONNECT_RETRY_INTERVAL,
        || Ok(()),
    )?)
}

/// The host's accept-loop waker: a manual-reset event.
pub(crate) struct AcceptWaker {
    event: std::os::windows::io::OwnedHandle,
}

// SAFETY: an event handle; Set/Reset/Wait are thread-safe.
unsafe impl Send for AcceptWaker {}
unsafe impl Sync for AcceptWaker {}

impl AcceptWaker {
    pub(crate) fn new() -> io::Result<Self> {
        // SAFETY: an unnamed manual-reset event, initially unset.
        let event = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
        if event.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a new handle owned here.
        let event = unsafe {
            <std::os::windows::io::OwnedHandle as std::os::windows::io::FromRawHandle>::from_raw_handle(
                event,
            )
        };
        Ok(Self { event })
    }

    fn raw(&self) -> HANDLE {
        self.event.as_raw_handle() as HANDLE
    }

    pub(crate) fn wake(&self) {
        // SAFETY: the event this value owns.
        unsafe { SetEvent(self.raw()) };
    }

    pub(crate) fn drain(&self) {
        // SAFETY: the event this value owns.
        unsafe { ResetEvent(self.raw()) };
    }

    /// Wait up to `timeout` (at least 1 ms) for a wake. Ok(false) on timeout.
    pub(crate) fn wait_readable(&self, timeout: Duration) -> io::Result<bool> {
        let millis = u32::try_from(timeout.as_millis().max(1)).unwrap_or(u32::MAX - 1);
        // SAFETY: the event this value owns.
        match unsafe { WaitForSingleObject(self.raw(), millis) } {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err(io::Error::last_os_error()),
        }
    }
}

#[cfg(test)]
#[path = "seams_tests.rs"]
mod tests;
