//! Replacing the current process image, the one exec the spawn rule allows.
//!
//! A process that restarts itself in place (the cmux-tui client after a hang
//! it could not recover from) must not hand the new image a descriptor the
//! old one held, for the same reason [`crate::Command`] passes only 0-2. A
//! daemon that hands its own lock and listeners to its next image must name
//! them explicitly with [`exec_replace_inheriting`].

use std::ffi::{CString, OsStr, OsString};
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// A child must never fork while exec temporarily clears CLOEXEC on its handoff descriptors.
/// Hold through spawn's exec and through failed replacement's flag restoration.
pub(crate) static SPAWN_EXEC_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
    exec_replace_inheriting(program, args, env, &[])
}

/// [`exec_replace`], preserving `inherit` at their existing descriptor numbers.
/// Every descriptor above stderr that is not listed is closed by exec. The
/// caller must quiesce code that opens or changes descriptors before calling.
/// [`crate::Command::spawn`] is serialized with this operation; any direct process-spawn
/// APIs outside this crate must also be quiesced. The borrowed descriptors remain owned
/// by the caller until exec succeeds.
///
/// Returns only on failure. The listed descriptors' original close-on-exec
/// flags are restored before returning; other descriptors remain close-on-exec.
/// The new image should call [`set_cloexec`] immediately after adopting these
/// descriptors, before starting children.
pub fn exec_replace_inheriting<A, E, K, V>(
    program: &Path,
    args: A,
    env: E,
    inherit: &[BorrowedFd<'_>],
) -> io::Error
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
    let _spawn_guard = SPAWN_EXEC_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let original = match inherit
        .iter()
        .map(|fd| flags(fd.as_raw_fd()).map(|flags| (fd.as_raw_fd(), flags)))
        .collect::<io::Result<Vec<_>>>()
    {
        Ok(original) => original,
        Err(error) => return error,
    };
    let attempt = || -> io::Error {
        if let Err(error) = mark_other_descriptors() {
            return error;
        }
        for &(fd, flags) in &original {
            if let Err(error) = set_flags(fd, flags & !libc::FD_CLOEXEC) {
                return error;
            }
        }
        // SAFETY: NUL-terminated arrays of valid C strings that outlive the call.
        unsafe { libc::execve(path.as_ptr(), argv.as_ptr(), envp.as_ptr()) };
        io::Error::last_os_error()
    };
    let error = attempt();
    // No listed descriptor is closed, and no original flag bit is lost on failure.
    for (fd, flags) in original {
        let _ = set_flags(fd, flags);
    }
    error
}

/// Prevent adopted descriptors from reaching any subsequently executed child.
/// Call before spawning children after [`exec_replace_inheriting`].
pub fn set_cloexec(fds: &[BorrowedFd<'_>]) -> io::Result<()> {
    for fd in fds {
        let fd = fd.as_raw_fd();
        set_flags(fd, flags(fd)? | libc::FD_CLOEXEC)?;
    }
    Ok(())
}

fn flags(fd: RawFd) -> io::Result<libc::c_int> {
    // SAFETY: F_GETFD only reads the descriptor flags.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 { Err(io::Error::last_os_error()) } else { Ok(flags) }
}

fn set_flags(fd: RawFd, flags: libc::c_int) -> io::Result<()> {
    // SAFETY: F_SETFD changes flags on this descriptor without dereferencing memory.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn mark_other_descriptors() -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        // Linux 5.11+: one operation covers all descriptors, including those above a
        // subsequently lowered soft limit. CLOSE_RANGE_CLOEXEC leaves them open if exec fails.
        const CLOSE_RANGE_CLOEXEC: libc::c_uint = 1 << 2;
        // SAFETY: close_range operates on descriptor numbers only.
        if unsafe {
            libc::syscall(libc::SYS_close_range, 3_u32, libc::c_uint::MAX, CLOSE_RANGE_CLOEXEC)
        } == 0
        {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(libc::ENOSYS | libc::EINVAL | libc::EPERM)) {
            return Err(error);
        }
    }
    mark_open_descriptors()
}

fn mark_open_descriptors() -> io::Result<()> {
    // Enumerate actual descriptors, not RLIMIT_NOFILE: lowering the soft limit leaves
    // existing higher-numbered descriptors open. If the table cannot be read, refuse exec.
    let directory = if cfg!(target_os = "linux") { "/proc/self/fd" } else { "/dev/fd" };
    for entry in std::fs::read_dir(directory)? {
        let name = entry?.file_name();
        let fd: RawFd = name.to_str().and_then(|name| name.parse().ok()).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "invalid descriptor table entry")
        })?;
        if fd <= 2 {
            continue;
        }
        match flags(fd) {
            Ok(flags) if flags & libc::FD_CLOEXEC == 0 => {
                set_flags(fd, flags | libc::FD_CLOEXEC)?;
            }
            Ok(_) => {}
            Err(error) if error.raw_os_error() == Some(libc::EBADF) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "exec_tests.rs"]
mod tests;
