//! The current user's home directory, without the `dirs` crate. `dirs` pulls
//! `option-ext` (MPL-2.0) into whatever links it, and the macOS app links this
//! crate (cmux-app-ffi), whose crates must be GPL-compatible permissive or
//! first-party GPL (scripts/cmux-next/check_app_crate_licenses.py).
//!
//! Unix keeps `dirs::home_dir`'s rule (dirs-sys 0.5) exactly: `$HOME` when it
//! is set and not empty, else the home directory in the passwd entry of the
//! real user (`getuid`, `getpwuid_r`), else none; Android, iOS and Emscripten
//! read no passwd entry. Other platforms use `std::env::home_dir`.

#[cfg(unix)]
use std::ffi::OsString;
use std::path::PathBuf;

/// The current user's home directory (module docs).
pub fn home_dir() -> Option<PathBuf> {
    #[cfg(unix)]
    {
        home_from(std::env::var_os("HOME"), passwd_home)
    }
    #[cfg(not(unix))]
    {
        std::env::home_dir()
    }
}

/// `$HOME` when set and not empty, else what `passwd` finds.
#[cfg(unix)]
pub(crate) fn home_from(
    home: Option<OsString>,
    passwd: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    home.filter(|h| !h.is_empty()).map(PathBuf::from).or_else(passwd)
}

/// The home directory of the real user's passwd entry, as `dirs-sys` reads it:
/// `getuid`, a buffer of `_SC_GETPW_R_SIZE_MAX` bytes (512 when the system
/// gives no size), no retry; none on an error, a missing entry or an empty
/// directory.
#[cfg(all(unix, not(any(target_os = "android", target_os = "ios", target_os = "emscripten"))))]
pub(crate) fn passwd_home() -> Option<PathBuf> {
    use std::ffi::CStr;
    use std::os::unix::ffi::OsStringExt;

    // SAFETY: sysconf has no preconditions.
    let size = unsafe { libc::sysconf(libc::_SC_GETPW_R_SIZE_MAX) };
    let size = usize::try_from(size).unwrap_or(512);
    let mut buf: Vec<libc::c_char> = vec![0; size];
    // SAFETY: an all-zero passwd is a valid value of this plain C struct.
    let mut passwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: `passwd`, `buf` (of `buf.len()` bytes) and `result` are valid
    // storage for the call; getuid has no preconditions.
    let rc = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &raw mut passwd,
            buf.as_mut_ptr(),
            buf.len(),
            &raw mut result,
        )
    };
    if rc != 0 || result.is_null() || passwd.pw_dir.is_null() {
        return None;
    }
    // SAFETY: on success `pw_dir` points to a NUL-terminated string inside `buf`, which lives
    // to the end of this function.
    let dir = unsafe { CStr::from_ptr(passwd.pw_dir) }.to_bytes();
    (!dir.is_empty()).then(|| PathBuf::from(OsString::from_vec(dir.to_vec())))
}

/// Android, iOS and Emscripten: no passwd entry, as dirs-sys.
#[cfg(all(unix, any(target_os = "android", target_os = "ios", target_os = "emscripten")))]
pub(crate) fn passwd_home() -> Option<PathBuf> {
    None
}

#[cfg(all(test, unix))]
#[path = "home_tests.rs"]
mod tests;
