//! macOS: `sandbox_init` with a deny-default profile. Reads and writes on
//! descriptors the process already holds (fd 3) keep working; opening files,
//! sockets and processes is refused.

use std::ffi::{CStr, CString, c_char, c_int};

use super::Report;

const PROFILE: &str =
    "(version 1)\n(deny default)\n(allow sysctl-read)\n(allow process-info* (target self))\n";

unsafe extern "C" {
    fn sandbox_init(profile: *const c_char, flags: u64, errorbuf: *mut *mut c_char) -> c_int;
    fn sandbox_free_error(errorbuf: *mut c_char);
}

pub(super) fn apply() -> Result<Report, String> {
    let profile = CString::new(PROFILE).expect("profile has no NUL");
    let mut error: *mut c_char = std::ptr::null_mut();
    // SAFETY: `profile` is a valid C string for the call; flags 0 means
    // "profile text"; `error` receives a string we free below.
    let rc = unsafe { sandbox_init(profile.as_ptr(), 0, &mut error) };
    if rc != 0 {
        let message = if error.is_null() {
            "sandbox_init failed".to_string()
        } else {
            // SAFETY: a non-null error is a NUL-terminated string owned by the sandbox library.
            let text = unsafe { CStr::from_ptr(error) }.to_string_lossy().into_owned();
            // SAFETY: freeing the error string the call returned.
            unsafe { sandbox_free_error(error) };
            text
        };
        return Err(message);
    }
    Ok(Report { mechanism: "sandbox_init", landlock_abi: None })
}
