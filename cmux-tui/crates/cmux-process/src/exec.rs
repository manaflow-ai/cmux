//! Replacing the current process image, the one exec the spawn rule allows.
//!
//! A process that restarts itself in place (the cmux-tui client after a hang
//! it could not recover from) must not hand the new image a descriptor the
//! old one held, for the same reason [`crate::Command`] passes only 0-2: every
//! descriptor past stdio is marked close-on-exec before the `execve`.

use std::ffi::{CString, OsStr, OsString};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Replaces this process with `program`, given `args` (after argv\[0\], which
/// is `program`) and exactly the environment `env`. Descriptors 0-2 carry
/// over; every other one is closed by the exec. Returns only on failure, with
/// the error; the process then runs on unchanged, apart from descriptors past
/// stdio now being close-on-exec.
pub fn exec_replace<A, E, K, V>(program: &Path, args: A, env: E) -> io::Error
where
    A: IntoIterator,
    A::Item: AsRef<OsStr>,
    E: IntoIterator<Item = (K, V)>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let c = |bytes: &[u8]| {
        CString::new(bytes).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    };
    let path = match c(program.as_os_str().as_bytes()) {
        Ok(path) => path,
        Err(error) => return error,
    };
    let mut argv_owned = vec![path.clone()];
    for arg in args {
        match c(arg.as_ref().as_bytes()) {
            Ok(arg) => argv_owned.push(arg),
            Err(error) => return error,
        }
    }
    let mut env_owned = Vec::new();
    for (key, value) in env {
        let mut pair = OsString::from(key.as_ref());
        pair.push("=");
        pair.push(value.as_ref());
        match c(pair.as_bytes()) {
            Ok(pair) => env_owned.push(pair),
            Err(error) => return error,
        }
    }
    let argv: Vec<*const libc::c_char> = argv_owned
        .iter()
        .map(|arg| arg.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    let envp: Vec<*const libc::c_char> = env_owned
        .iter()
        .map(|pair| pair.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    // SAFETY: getdtablesize and fcntl on descriptor numbers only; execve with
    // NUL-terminated arrays of valid C strings that outlive the call.
    unsafe {
        let limit = libc::getdtablesize().clamp(3, 65_536);
        for fd in 3..limit {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags >= 0 && flags & libc::FD_CLOEXEC == 0 {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
        libc::execve(path.as_ptr(), argv.as_ptr(), envp.as_ptr());
    }
    io::Error::last_os_error()
}

#[cfg(test)]
#[path = "exec_tests.rs"]
mod tests;
