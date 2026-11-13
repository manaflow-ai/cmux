//! Replace one private file atomically: its new bytes go to a fresh 0600
//! file beside it, written and synced, which is then renamed over it, so a
//! reader sees the old file or the new one, never a mix.
//!
//! Each folder below `home` is opened relative to the one above it with
//! `O_NOFOLLOW` (made 0700 when missing, its parent synced), must be a
//! folder this user owns, and the last is set to 0700. The rename goes by
//! the folder's descriptor, so no path is resolved twice and nothing is
//! written through a symlink. A failure before the rename removes the new
//! file and leaves the live one as it was. When the rename has happened but
//! syncing the folder fails, the new bytes are in place but may not survive
//! a crash: that is answered as a failure too, and sending the same bytes
//! again writes them again. The caller holds the request lock
//! ([`super::Lock`]).

use std::ffi::{CString, OsStr};
use std::io::{self, Write as _};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};

#[cfg(test)]
thread_local! {
    /// Tests only: fail the step with this index (0: staging the new file,
    /// 1: the rename, 2: syncing the folder).
    pub(super) static FAIL_AT: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

/// Replace `home/relative` with `bytes`, mode 0600 (see the module doc).
pub fn replace(home: &Path, relative: &Path, bytes: &[u8]) -> io::Result<()> {
    replace_with(home, relative, bytes, true)
}

/// [`replace`] for the daemon's own state: no test fault applies.
pub fn replace_state(home: &Path, relative: &Path, bytes: &[u8]) -> io::Result<()> {
    replace_with(home, relative, bytes, false)
}

fn replace_with(home: &Path, relative: &Path, bytes: &[u8], faults: bool) -> io::Result<()> {
    let fault = |step: usize| if faults { injected(step) } else { Ok(()) };
    let mut names = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => names.push(c_name(name)?),
            _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a plain path")),
        }
    }
    let file_name =
        names.pop().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    let directory = open_folders(home, &names)?;
    let temporary = sibling(&file_name, "tmp")?;
    let staged = fault(0).and_then(|()| write_new(&directory, &temporary, bytes)).and_then(|()| {
        fault(1)?;
        // SAFETY: both names are NUL-terminated and relative to the same open folder.
        check(unsafe {
            libc::renameat(
                directory.as_raw_fd(),
                temporary.as_ptr(),
                directory.as_raw_fd(),
                file_name.as_ptr(),
            )
        })
        .map(|_| ())
    });
    if let Err(error) = staged {
        // SAFETY: `temporary` is NUL-terminated and relative to the open
        // folder; it is ours (created with `O_EXCL`), or not there at all.
        unsafe { libc::unlinkat(directory.as_raw_fd(), temporary.as_ptr(), 0) };
        return Err(error);
    }
    fault(2)?;
    sync_dir(&directory)
}

#[cfg(test)]
fn injected(step: usize) -> io::Result<()> {
    if FAIL_AT.with(std::cell::Cell::get) == Some(step) {
        return Err(io::Error::other("injected failure"));
    }
    Ok(())
}

#[cfg(not(test))]
fn injected(_: usize) -> io::Result<()> {
    Ok(())
}

/// Open (making) `names` below `home`, folder by folder.
fn open_folders(home: &Path, names: &[CString]) -> io::Result<OwnedFd> {
    let home = c_name(home.as_os_str())?;
    let mut directory = open_dir_at(libc::AT_FDCWD, &home)?;
    owned_by_us(&directory)?;
    for name in names {
        // SAFETY: `name` is NUL-terminated and `directory` is an open folder.
        let made = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
        if made < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        } else {
            // A new folder's entry is durable only once its parent is synced.
            sync_dir(&directory)?;
        }
        directory = open_dir_at(directory.as_raw_fd(), name)?;
        owned_by_us(&directory)?;
    }
    // SAFETY: `directory` is an open folder this user owns.
    check(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;
    Ok(directory)
}

/// Write and sync `bytes` to the fresh 0600 file `name` in `directory`.
fn write_new(directory: &OwnedFd, name: &CString, bytes: &[u8]) -> io::Result<()> {
    let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated; mode is passed as the variadic third argument.
    let fd = check(unsafe {
        libc::openat(directory.as_raw_fd(), name.as_ptr(), flags, 0o600 as libc::c_uint)
    })?;
    // SAFETY: `fd` was just opened and is owned by nobody else.
    let mut file = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    file.write_all(bytes)?;
    file.sync_all()
}

fn c_name(name: &OsStr) -> io::Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

fn check(result: libc::c_int) -> io::Result<libc::c_int> {
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(result) }
}

fn open_dir_at(parent: libc::c_int, name: &CString) -> io::Result<OwnedFd> {
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated; a non-negative result is an owned fd.
    let fd = check(unsafe { libc::openat(parent, name.as_ptr(), flags) })?;
    // SAFETY: `fd` was just opened and is owned by nobody else.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn owned_by_us(fd: &OwnedFd) -> io::Result<()> {
    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: `status` is a valid out pointer for fstat.
    check(unsafe { libc::fstat(fd.as_raw_fd(), status.as_mut_ptr()) })?;
    // SAFETY: fstat succeeded, so `status` is initialized.
    let status = unsafe { status.assume_init() };
    // SAFETY: geteuid has no preconditions and cannot fail.
    if status.st_uid != unsafe { libc::geteuid() } {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "folder is not ours"));
    }
    Ok(())
}

fn sync_dir(directory: &OwnedFd) -> io::Result<()> {
    // SAFETY: `directory` is an open folder.
    check(unsafe { libc::fsync(directory.as_raw_fd()) }).map(|_| ())
}

/// A name for a sibling of `file_name`: `.NAME.<random>.<kind>`.
fn sibling(file_name: &CString, kind: &str) -> io::Result<CString> {
    let suffix =
        super::seal::fresh_nonce().map_err(|_| io::Error::other("no system random source"))?;
    let mut name = b".".to_vec();
    name.extend_from_slice(file_name.as_bytes());
    name.extend_from_slice(format!(".{suffix}.{kind}").as_bytes());
    CString::new(name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}
