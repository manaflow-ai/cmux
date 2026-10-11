//! Descriptor-relative system calls for the `fs-v1` owner. Every call that
//! names a file takes a directory descriptor and ONE file name (never a
//! path with `/`), so the kernel never resolves a path the resolver did not
//! check. Nothing here follows a symlink unless the caller asks for it.

use std::ffi::{CStr, CString};
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Most names one directory read collects before it stops.
pub(super) const MAX_DIRECTORY_NAMES: usize = 100_000;

fn c_name(name: &str) -> io::Result<CString> {
    if name.is_empty() || name.contains('/') {
        return Err(io::Error::from_raw_os_error(libc::EINVAL));
    }
    CString::new(name).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))
}

fn check(rc: libc::c_int) -> io::Result<libc::c_int> {
    if rc < 0 { Err(io::Error::last_os_error()) } else { Ok(rc) }
}

fn owned(fd: libc::c_int) -> OwnedFd {
    // SAFETY: `fd` was just returned by a successful open call and nothing
    // else owns it.
    unsafe { OwnedFd::from_raw_fd(fd) }
}

/// Opens the directory at the absolute `path` (a canonical root), refusing
/// a symlink as its last component.
pub(super) fn open_root(path: &Path) -> io::Result<OwnedFd> {
    let path = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `path` is a valid NUL-terminated string for the call.
    check(unsafe { libc::open(path.as_ptr(), flags) }).map(owned)
}

/// `openat(dir, name, flags | O_NOFOLLOW | O_CLOEXEC, mode)`.
pub(super) fn open_at(
    dir: BorrowedFd<'_>,
    name: &str,
    flags: libc::c_int,
    mode: u32,
) -> io::Result<OwnedFd> {
    let name = c_name(name)?;
    let flags = flags | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `dir` is an open descriptor and `name` a NUL-terminated name.
    check(unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags, mode as libc::c_uint) })
        .map(owned)
}

/// Opens the subdirectory `name` of `dir` without following a symlink.
pub(super) fn open_dir_at(dir: BorrowedFd<'_>, name: &str) -> io::Result<OwnedFd> {
    open_at(dir, name, libc::O_RDONLY | libc::O_DIRECTORY, 0)
}

/// `fstatat(dir, name, AT_SYMLINK_NOFOLLOW)`.
pub(super) fn lstat_at(dir: BorrowedFd<'_>, name: &str) -> io::Result<libc::stat> {
    let name = c_name(name)?;
    let mut stat = MaybeUninit::<libc::stat>::uninit();
    // SAFETY: valid descriptor, NUL-terminated name, writable stat buffer.
    check(unsafe {
        libc::fstatat(dir.as_raw_fd(), name.as_ptr(), stat.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
    })?;
    // SAFETY: fstatat succeeded, so it filled the buffer.
    Ok(unsafe { stat.assume_init() })
}

/// `fstat(fd)`.
pub(super) fn stat_fd(fd: BorrowedFd<'_>) -> io::Result<libc::stat> {
    let mut stat = MaybeUninit::<libc::stat>::uninit();
    // SAFETY: valid descriptor and writable stat buffer.
    check(unsafe { libc::fstat(fd.as_raw_fd(), stat.as_mut_ptr()) })?;
    // SAFETY: fstat succeeded, so it filled the buffer.
    Ok(unsafe { stat.assume_init() })
}

/// The target of the symlink `name` in `dir`.
pub(super) fn read_link_at(dir: BorrowedFd<'_>, name: &str) -> io::Result<Vec<u8>> {
    let name = c_name(name)?;
    let mut buffer = vec![0u8; 4096];
    // SAFETY: valid descriptor, NUL-terminated name, writable buffer of the
    // given length.
    let read = unsafe {
        libc::readlinkat(dir.as_raw_fd(), name.as_ptr(), buffer.as_mut_ptr().cast(), buffer.len())
    };
    let read = usize::try_from(read).map_err(|_| io::Error::last_os_error())?;
    if read >= buffer.len() {
        return Err(io::Error::from_raw_os_error(libc::ENAMETOOLONG));
    }
    buffer.truncate(read);
    Ok(buffer)
}

pub(super) fn mkdir_at(dir: BorrowedFd<'_>, name: &str, mode: u32) -> io::Result<()> {
    let name = c_name(name)?;
    // SAFETY: valid descriptor and NUL-terminated name.
    check(unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), mode as libc::mode_t) }).map(drop)
}

/// `unlinkat(dir, name)`; `directory` removes an empty directory.
pub(super) fn unlink_at(dir: BorrowedFd<'_>, name: &str, directory: bool) -> io::Result<()> {
    let name = c_name(name)?;
    let flags = if directory { libc::AT_REMOVEDIR } else { 0 };
    // SAFETY: valid descriptor and NUL-terminated name.
    check(unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), flags) }).map(drop)
}

/// Renames `from` to `to` inside `dir`, replacing `to`.
pub(super) fn rename_at(dir: BorrowedFd<'_>, from: &str, to: &str) -> io::Result<()> {
    let (from, to) = (c_name(from)?, c_name(to)?);
    let fd = dir.as_raw_fd();
    // SAFETY: valid descriptor and NUL-terminated names.
    check(unsafe { libc::renameat(fd, from.as_ptr(), fd, to.as_ptr()) }).map(drop)
}

/// Renames `from` to `to` inside `dir`; fails with `EEXIST` when `to`
/// exists, atomically where the kernel offers it.
pub(super) fn rename_no_replace(dir: BorrowedFd<'_>, from: &str, to: &str) -> io::Result<()> {
    let (from_c, to_c) = (c_name(from)?, c_name(to)?);
    let fd = dir.as_raw_fd();
    #[cfg(target_os = "linux")]
    {
        // The raw syscall, so musl builds (the release binaries) get the
        // atomic no-replace rename too. 1 = RENAME_NOREPLACE.
        // SAFETY: valid descriptor and NUL-terminated names; renameat2
        // takes (int, const char *, int, const char *, unsigned int).
        let rc = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                libc::c_long::from(fd),
                from_c.as_ptr(),
                libc::c_long::from(fd),
                to_c.as_ptr(),
                1 as libc::c_long,
            )
        };
        let rc = libc::c_int::try_from(rc).unwrap_or(-1);
        match check(rc) {
            Ok(_) => return Ok(()),
            Err(error) if !matches!(error.raw_os_error(), Some(libc::EINVAL | libc::ENOSYS)) => {
                return Err(error);
            }
            Err(_) => {}
        }
    }
    #[cfg(target_vendor = "apple")]
    {
        // SAFETY: valid descriptor and NUL-terminated names.
        let rc = unsafe {
            libc::renameatx_np(fd, from_c.as_ptr(), fd, to_c.as_ptr(), libc::RENAME_EXCL)
        };
        match check(rc) {
            Ok(_) => return Ok(()),
            Err(error) if !matches!(error.raw_os_error(), Some(libc::EINVAL | libc::ENOTSUP)) => {
                return Err(error);
            }
            Err(_) => {}
        }
    }
    // The file system has no atomic no-replace rename: check, then rename.
    // A file created between the two is replaced (documented window).
    match lstat_at(dir, to) {
        Ok(_) => Err(io::Error::from_raw_os_error(libc::EEXIST)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            // SAFETY: valid descriptor and NUL-terminated names.
            check(unsafe { libc::renameat(fd, from_c.as_ptr(), fd, to_c.as_ptr()) }).map(drop)
        }
        Err(error) => Err(error),
    }
}

pub(super) fn fsync(fd: BorrowedFd<'_>) -> io::Result<()> {
    // SAFETY: valid descriptor.
    check(unsafe { libc::fsync(fd.as_raw_fd()) }).map(drop)
}

pub(super) fn fchmod(fd: BorrowedFd<'_>, mode: u32) -> io::Result<()> {
    // SAFETY: valid descriptor.
    check(unsafe { libc::fchmod(fd.as_raw_fd(), mode as libc::mode_t) }).map(drop)
}

/// Bytes an unprivileged writer may still use on the file system of `fd`.
pub(super) fn available_bytes(fd: BorrowedFd<'_>) -> io::Result<u64> {
    let mut stat = MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: valid descriptor and writable statvfs buffer.
    check(unsafe { libc::fstatvfs(fd.as_raw_fd(), stat.as_mut_ptr()) })?;
    // SAFETY: fstatvfs succeeded, so it filled the buffer.
    let stat = unsafe { stat.assume_init() };
    #[allow(clippy::useless_conversion)]
    Ok(u64::from(stat.f_bavail).saturating_mul(u64::from(stat.f_frsize)))
}

/// Why a directory read stopped early.
#[derive(Debug)]
pub(super) enum ReadDirError {
    Io(io::Error),
    /// More than [`MAX_DIRECTORY_NAMES`] names.
    TooMany,
}

/// The names in the directory `dir` (not `.` and `..`), in the order the
/// file system returns them.
pub(super) fn read_dir_names(dir: BorrowedFd<'_>) -> Result<Vec<Vec<u8>>, ReadDirError> {
    // SAFETY: valid descriptor; F_DUPFD_CLOEXEC returns a new descriptor.
    let copy = check(unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) })
        .map_err(ReadDirError::Io)?;
    // SAFETY: `copy` is an open directory descriptor that fdopendir takes
    // ownership of on success.
    let stream = unsafe { libc::fdopendir(copy) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        drop(owned(copy));
        return Err(ReadDirError::Io(error));
    }
    let _close = CloseDir(stream);
    // SAFETY: `stream` is a valid directory stream.
    unsafe { libc::rewinddir(stream) };
    let mut names = Vec::new();
    loop {
        // SAFETY: `stream` is a valid directory stream.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            return Ok(names);
        }
        // SAFETY: readdir returned a valid entry whose d_name is
        // NUL-terminated and lives until the next readdir call.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        if names.len() >= MAX_DIRECTORY_NAMES {
            return Err(ReadDirError::TooMany);
        }
        names.push(name.to_vec());
    }
}

struct CloseDir(*mut libc::DIR);

impl Drop for CloseDir {
    fn drop(&mut self) {
        // SAFETY: the stream is open and closed only here.
        unsafe { libc::closedir(self.0) };
    }
}

/// The login name of `uid`, if the user database knows it.
pub(super) fn user_name(uid: u32) -> Option<String> {
    let mut buffer = vec![0 as libc::c_char; 4096];
    let mut record = MaybeUninit::<libc::passwd>::uninit();
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call and the buffer length is
    // the buffer's length.
    let rc = unsafe {
        libc::getpwuid_r(
            uid as libc::uid_t,
            record.as_mut_ptr(),
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut found,
        )
    };
    if rc != 0 || found.is_null() {
        return None;
    }
    // SAFETY: getpwuid_r succeeded, so pw_name points into `buffer`.
    let name = unsafe { CStr::from_ptr((*found).pw_name) };
    name.to_str().ok().map(str::to_owned)
}

/// Random lowercase hex of `bytes` bytes (temporary names, listing ids).
pub(super) fn random_hex(bytes: usize) -> String {
    let mut random = vec![0u8; bytes];
    if getrandom::fill(&mut random).is_err() {
        // A unique fallback: O_EXCL still refuses a collision.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        return format!("{nanos:x}{:x}", std::process::id());
    }
    random.iter().map(|byte| format!("{byte:02x}")).collect()
}
