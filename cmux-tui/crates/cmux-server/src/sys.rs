//! Thin wrappers over the few OS calls std does not have: user ids, user
//! name, `statvfs`, and fsync of a directory. Unix only; other platforms get
//! `Unsupported` errors (Windows is server.md step 8).

use std::io;
use std::path::Path;

#[cfg(unix)]
mod imp {
    use std::ffi::{CStr, CString};
    use std::io;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    pub fn euid() -> u32 {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() }
    }

    pub fn uid() -> u32 {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    }

    pub fn user_name(uid: u32) -> io::Result<String> {
        let mut buf = vec![0 as libc::c_char; 4096];
        // SAFETY: zeroed passwd is a valid out-parameter for getpwuid_r.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and buf outlives it.
        let rc =
            unsafe { libc::getpwuid_r(uid, &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result) };
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        if result.is_null() || pwd.pw_name.is_null() {
            return Err(io::Error::new(io::ErrorKind::NotFound, format!("no user for uid {uid}")));
        }
        // SAFETY: getpwuid_r returned a NUL-terminated name inside buf.
        let name = unsafe { CStr::from_ptr(pwd.pw_name) };
        Ok(name.to_string_lossy().into_owned())
    }

    pub fn uid_of(name: &str) -> io::Result<Option<u32>> {
        let c = CString::new(name)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "name has NUL"))?;
        let mut buf = vec![0 as libc::c_char; 4096];
        // SAFETY: zeroed passwd is a valid out-parameter for getpwnam_r.
        let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and buf outlives it.
        let rc = unsafe {
            libc::getpwnam_r(c.as_ptr(), &mut pwd, buf.as_mut_ptr(), buf.len(), &mut result)
        };
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        Ok((!result.is_null()).then_some(pwd.pw_uid))
    }

    pub fn owner_uid(meta: &std::fs::Metadata) -> u32 {
        use std::os::unix::fs::MetadataExt;
        meta.uid()
    }

    pub fn statvfs(path: &Path) -> io::Result<(u64, u64)> {
        let c = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path has NUL"))?;
        // SAFETY: zeroed statvfs is a valid out-parameter.
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: c is NUL-terminated and st is a valid out-parameter.
        if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let frsize = st.f_frsize as u64;
        #[allow(clippy::unnecessary_cast)]
        let (avail, blocks) = (st.f_bavail as u64, st.f_blocks as u64);
        Ok((avail.saturating_mul(frsize), blocks.saturating_mul(frsize)))
    }

    pub fn fsync_dir(path: &Path) -> io::Result<()> {
        std::fs::File::open(path)?.sync_all()
    }
}

#[cfg(not(unix))]
mod imp {
    use std::io;
    use std::path::Path;

    fn unsupported() -> io::Error {
        io::Error::new(io::ErrorKind::Unsupported, "not supported on this platform yet")
    }

    pub fn euid() -> u32 {
        u32::MAX
    }

    pub fn uid() -> u32 {
        u32::MAX
    }

    pub fn user_name(_uid: u32) -> io::Result<String> {
        std::env::var("USERNAME").map_err(|_| unsupported())
    }

    pub fn uid_of(_name: &str) -> io::Result<Option<u32>> {
        Err(unsupported())
    }

    pub fn owner_uid(_meta: &std::fs::Metadata) -> u32 {
        u32::MAX
    }

    pub fn statvfs(_path: &Path) -> io::Result<(u64, u64)> {
        Err(unsupported())
    }

    pub fn fsync_dir(_path: &Path) -> io::Result<()> {
        Ok(())
    }
}

/// The effective user id (`u32::MAX` where there is none).
pub fn euid() -> u32 {
    imp::euid()
}

/// The real user id.
pub fn uid() -> u32 {
    imp::uid()
}

pub fn is_root() -> bool {
    cfg!(unix) && euid() == 0
}

/// The login name of `uid` from the user database.
pub fn user_name(uid: u32) -> io::Result<String> {
    imp::user_name(uid)
}

/// The uid of the user `name`, `None` when there is no such user.
pub fn uid_of(name: &str) -> io::Result<Option<u32>> {
    imp::uid_of(name)
}

/// The owner uid of a file (`u32::MAX` where there is none).
pub fn owner_uid(meta: &std::fs::Metadata) -> u32 {
    imp::owner_uid(meta)
}

/// `(free bytes for unprivileged users, total bytes)` of the filesystem
/// holding `path`.
pub fn statvfs(path: &Path) -> io::Result<(u64, u64)> {
    imp::statvfs(path)
}

/// Makes a rename or a new entry in `path` durable.
pub fn fsync_dir(path: &Path) -> io::Result<()> {
    imp::fsync_dir(path)
}
