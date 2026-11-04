//! File access under one folder that never follows a link (unix).
//!
//! Every path component is opened relative to the folder before it, with `O_NOFOLLOW`, so a
//! link put in place at any moment (before or during the call) is refused, never followed.
//! Replacing a file is an atomic swap (`RENAME_EXCHANGE` on Linux, `RENAME_SWAP` on macOS)
//! followed by a check of what came out, so a file changed since the caller looked is put back.

use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

const DIR_FLAGS: libc::c_int =
    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;

fn cstr(bytes: &[u8]) -> io::Result<CString> {
    CString::new(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a path has a NUL byte"))
}

/// `r` as a result, from a call that returns -1 and sets errno on failure.
fn check(r: libc::c_int) -> io::Result<libc::c_int> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

/// The error for a link (or a file) where a folder or a plain file was expected.
pub(super) fn is_not_plain(e: &io::Error) -> bool {
    matches!(e.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR))
}

/// An open folder.
pub(super) struct Dir(OwnedFd);

impl Dir {
    fn adopt(fd: libc::c_int) -> Self {
        // SAFETY: `fd` was just returned by a successful open and nothing else owns it.
        Self(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// `root` itself, refused when it is a link or not a folder.
    pub(super) fn open_root(root: &Path) -> io::Result<Self> {
        let c = cstr(root.as_os_str().as_bytes())?;
        // SAFETY: `c` is a NUL-terminated string that outlives the call.
        let fd = check(unsafe { libc::open(c.as_ptr(), DIR_FLAGS) })?;
        Ok(Self::adopt(fd))
    }

    /// The folder `name` in this one: `None` when it is not there and `create` is off. A link
    /// or a file there is an error ([`is_not_plain`]). A folder it creates is durable in this
    /// one before it returns.
    pub(super) fn child(&self, name: &str, create: bool) -> io::Result<Option<Self>> {
        let c = cstr(name.as_bytes())?;
        for _ in 0..2 {
            // SAFETY: a valid folder fd and a NUL-terminated name.
            let fd = unsafe { libc::openat(self.0.as_raw_fd(), c.as_ptr(), DIR_FLAGS) };
            if fd >= 0 {
                return Ok(Some(Self::adopt(fd)));
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::NotFound {
                return Err(e);
            }
            if !create {
                return Ok(None);
            }
            // SAFETY: as above.
            if unsafe { libc::mkdirat(self.0.as_raw_fd(), c.as_ptr(), 0o777) } < 0 {
                let e = io::Error::last_os_error();
                if e.kind() != io::ErrorKind::AlreadyExists {
                    return Err(e);
                }
            } else {
                self.sync()?;
            }
        }
        Err(io::Error::other(format!("{name}: the folder keeps disappearing")))
    }

    /// The file `name` in this folder, opened for reading without following a link: `None`
    /// if absent. It may be any kind of file; the caller checks.
    pub(super) fn open_file(&self, name: &str) -> io::Result<Option<File>> {
        let c = cstr(name.as_bytes())?;
        // O_NONBLOCK: opening a FIFO must not wait for a writer.
        let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK;
        // SAFETY: a valid folder fd and a NUL-terminated name.
        let fd = unsafe { libc::openat(self.0.as_raw_fd(), c.as_ptr(), flags) };
        if fd < 0 {
            let e = io::Error::last_os_error();
            return if e.kind() == io::ErrorKind::NotFound { Ok(None) } else { Err(e) };
        }
        // SAFETY: as in `adopt`.
        Ok(Some(unsafe { File::from_raw_fd(fd) }))
    }

    /// The bytes of the plain file `name`, `None` if absent; anything else is an error.
    pub(super) fn read(&self, name: &str) -> io::Result<Option<Vec<u8>>> {
        let Some(mut f) = self.open_file(name)? else { return Ok(None) };
        if !f.metadata()?.is_file() {
            return Err(io::Error::other(format!("{name}: not a plain file")));
        }
        let mut out = Vec::new();
        f.read_to_end(&mut out)?;
        Ok(Some(out))
    }

    /// Creates the new, empty file `name` in this folder for writing (`AlreadyExists` if taken),
    /// with permission bits `mode` (less the umask).
    pub(super) fn create(&self, name: &str, mode: libc::c_uint) -> io::Result<File> {
        let c = cstr(name.as_bytes())?;
        let flags =
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a valid folder fd and a NUL-terminated name; the mode is a plain int.
        let fd = check(unsafe { libc::openat(self.0.as_raw_fd(), c.as_ptr(), flags, mode) })?;
        // SAFETY: as in `adopt`.
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    /// The permission bits of `name` (not following a link), if it is there.
    pub(super) fn mode(&self, name: &str) -> io::Result<Option<u32>> {
        let c = cstr(name.as_bytes())?;
        let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: `st` is written by a successful call before it is read.
        let r = unsafe {
            libc::fstatat(
                self.0.as_raw_fd(),
                c.as_ptr(),
                st.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if r < 0 {
            let e = io::Error::last_os_error();
            return if e.kind() == io::ErrorKind::NotFound { Ok(None) } else { Err(e) };
        }
        // SAFETY: the call succeeded, so `st` is initialized.
        let st = unsafe { st.assume_init() };
        // `st_mode` is u16 on macOS and u32 on Linux.
        #[allow(clippy::unnecessary_cast)]
        let mode = st.st_mode as u32;
        Ok(Some(mode & 0o7777))
    }

    pub(super) fn unlink(&self, name: &str) -> io::Result<()> {
        let c = cstr(name.as_bytes())?;
        // SAFETY: a valid folder fd and a NUL-terminated name.
        check(unsafe { libc::unlinkat(self.0.as_raw_fd(), c.as_ptr(), 0) }).map(drop)
    }

    /// A second name `to` for `from`; `AlreadyExists` when `to` is taken (never replaced).
    pub(super) fn link_noclobber(&self, from: &str, to: &str) -> io::Result<()> {
        let (a, b) = (cstr(from.as_bytes())?, cstr(to.as_bytes())?);
        let fd = self.0.as_raw_fd();
        // SAFETY: valid folder fds and NUL-terminated names.
        check(unsafe { libc::linkat(fd, a.as_ptr(), fd, b.as_ptr(), 0) }).map(drop)
    }

    /// Swaps the names `a` and `b` atomically; both must exist.
    pub(super) fn exchange(&self, a: &str, b: &str) -> io::Result<()> {
        self.rename_flags(a, b, Flag::Exchange)
    }

    /// Renames `from` to `to` only while `to` is free (`AlreadyExists` otherwise).
    pub(super) fn rename_noreplace(&self, from: &str, to: &str) -> io::Result<()> {
        self.rename_flags(from, to, Flag::NoReplace)
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    fn rename_flags(&self, a: &str, b: &str, flag: Flag) -> io::Result<()> {
        let (ca, cb) = (cstr(a.as_bytes())?, cstr(b.as_bytes())?);
        let flags = match flag {
            Flag::Exchange => libc::RENAME_EXCHANGE,
            Flag::NoReplace => libc::RENAME_NOREPLACE,
        };
        // The flags are c_int on Android and c_uint elsewhere.
        #[allow(clippy::unnecessary_cast)]
        let flags = flags as libc::c_uint;
        let fd = self.0.as_raw_fd();
        // The raw syscall: musl, which the Linux release binaries link, has no `renameat2`
        // wrapper.
        // SAFETY: valid folder fds and NUL-terminated names; renameat2 takes exactly these.
        let r =
            unsafe { libc::syscall(libc::SYS_renameat2, fd, ca.as_ptr(), fd, cb.as_ptr(), flags) };
        if r < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn rename_flags(&self, a: &str, b: &str, flag: Flag) -> io::Result<()> {
        let (ca, cb) = (cstr(a.as_bytes())?, cstr(b.as_bytes())?);
        let flags = match flag {
            Flag::Exchange => libc::RENAME_SWAP,
            Flag::NoReplace => libc::RENAME_EXCL,
        };
        let fd = self.0.as_raw_fd();
        // SAFETY: valid folder fds and NUL-terminated names.
        check(unsafe { libc::renameatx_np(fd, ca.as_ptr(), fd, cb.as_ptr(), flags) }).map(drop)
    }

    #[cfg(not(any(
        target_os = "linux",
        target_os = "android",
        target_os = "macos",
        target_os = "ios"
    )))]
    fn rename_flags(&self, _: &str, _: &str, _: Flag) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no atomic swap on this system"))
    }

    /// Makes this folder's entries durable.
    pub(super) fn sync(&self) -> io::Result<()> {
        // SAFETY: a valid fd.
        check(unsafe { libc::fsync(self.0.as_raw_fd()) }).map(drop)
    }
}

#[derive(Clone, Copy)]
enum Flag {
    Exchange,
    NoReplace,
}
