//! Persistent ownership survives inode reuse without claiming replacement files.

use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;

pub(crate) struct ImagePasteOwnership;

impl ImagePasteOwnership {
    pub(crate) fn mark(file: &File, token: &[u8; 16]) -> io::Result<()> {
        let name = Self::name();
        #[cfg(any(target_os = "linux", target_os = "android"))]
        // SAFETY: `file` owns the descriptor for the call, `name` is a NUL-terminated CString that
        // lives across it, and the value points to `token`, a live array of the length passed;
        // fsetxattr only reads.
        let result = unsafe {
            libc::fsetxattr(
                file.as_raw_fd(),
                name.as_ptr(),
                token.as_ptr().cast(),
                token.len(),
                libc::XATTR_CREATE,
            )
        };
        #[cfg(target_vendor = "apple")]
        // SAFETY: `file` owns the descriptor for the call, `name` is a NUL-terminated CString that
        // lives across it, and the value points to `token`, a live array of the length passed;
        // fsetxattr only reads.
        let result = unsafe {
            libc::fsetxattr(
                file.as_raw_fd(),
                name.as_ptr(),
                token.as_ptr().cast(),
                token.len(),
                0,
                libc::XATTR_CREATE,
            )
        };
        #[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
        {
            let _ = (file, token, name);
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "persistent image ownership is unavailable on this platform",
            ));
        }
        #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
        if result == 0 { file.sync_all() } else { Err(io::Error::last_os_error()) }
    }

    pub(crate) fn matches(file: &File, expected: &[u8; 16]) -> bool {
        let name = Self::name();
        let mut token = [0u8; 16];
        #[cfg(any(target_os = "linux", target_os = "android"))]
        // SAFETY: `file` owns the descriptor for the call, `name` is a NUL-terminated CString that
        // lives across it, and fgetxattr writes at most `token.len()` bytes into `token`, a live
        // local array.
        let size = unsafe {
            libc::fgetxattr(file.as_raw_fd(), name.as_ptr(), token.as_mut_ptr().cast(), token.len())
        };
        #[cfg(target_vendor = "apple")]
        // SAFETY: `file` owns the descriptor for the call, `name` is a NUL-terminated CString that
        // lives across it, and fgetxattr writes at most `token.len()` bytes into `token`, a live
        // local array.
        let size = unsafe {
            libc::fgetxattr(
                file.as_raw_fd(),
                name.as_ptr(),
                token.as_mut_ptr().cast(),
                token.len(),
                0,
                0,
            )
        };
        #[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
        let size = {
            let _ = (file, name);
            -1
        };
        size == token.len() as isize && token == *expected
    }

    fn name() -> CString {
        #[cfg(target_vendor = "apple")]
        let name = "com.cmux.image-paste";
        #[cfg(not(target_vendor = "apple"))]
        let name = "user.cmux.image-paste";
        CString::new(name).unwrap()
    }
}
