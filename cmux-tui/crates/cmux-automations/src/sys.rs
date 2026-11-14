//! What differs between Unix and Windows, in one place.
//!
//! The store, the schedule and the runner bookkeeping work on both. Owner-only
//! modes (0700 folders, 0600 files) are Unix modes; on Windows a file gets the
//! ACL of its folder (the user's profile is owner-only by default), as
//! acpmux's state files do until owner-only ACLs land there. A folder cannot be
//! opened to fsync on Windows; NTFS journals the rename itself. Running a body
//! is Unix only for now: its timeout must stop the whole process tree, which is
//! a process group on Unix and a job object on Windows (not built yet), so on
//! Windows a run ends with [`UNSUPPORTED_ON_WINDOWS`] instead of running
//! without a timeout.

use std::fs::{self, OpenOptions};
use std::path::Path;

/// The reason a run gives on Windows, where bodies do not run yet.
#[cfg(windows)]
pub(crate) const UNSUPPORTED_ON_WINDOWS: &str = "running an automation is not supported on \
     Windows yet (its timeout needs a job object to stop the whole process tree)";

/// `options`, with the new file readable and writable by its owner only.
pub(crate) fn private_file(options: &mut OpenOptions) -> &mut OpenOptions {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600)
    }
    #[cfg(not(unix))]
    {
        options
    }
}

/// Make `path` and its parents, the new folders open to their owner only.
pub(crate) fn create_private_dir(path: &Path) -> std::io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}

/// Make a rename or a new entry in the folder `dir` durable.
pub(crate) fn sync_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        fs::File::open(dir)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(())
    }
}

/// Whether a process with this id exists.
#[cfg(unix)]
pub(crate) fn pid_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists.
    let rc = unsafe { libc::kill(pid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Whether a process with this id exists and has not exited.
#[cfg(windows)]
pub(crate) fn pid_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    // SAFETY: OpenProcess takes no pointers; a null handle is its failure.
    let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if process.is_null() {
        // Access denied: the process exists under another user (as EPERM).
        return std::io::Error::last_os_error().raw_os_error() == Some(ERROR_ACCESS_DENIED as i32);
    }
    let mut code = 0u32;
    // SAFETY: `process` is the open handle from above and `code` outlives the call.
    let read = unsafe { GetExitCodeProcess(process, &mut code) } != 0;
    // SAFETY: closes the handle this function opened, once.
    unsafe { CloseHandle(process) };
    read && code == STILL_ACTIVE as u32
}

/// This machine's name, for the run row's `runner`.
#[cfg(unix)]
pub(crate) fn hostname() -> Option<String> {
    let mut buf = [0u8; 256];
    // SAFETY: gethostname writes at most `buf.len()` bytes into `buf`.
    if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } != 0 {
        return None;
    }
    // The name ends at the first NUL, or fills the buffer.
    let name = buf.split(|&b| b == 0).next()?;
    String::from_utf8(name.to_vec()).ok()
}

/// This machine's name, for the run row's `runner`.
#[cfg(windows)]
pub(crate) fn hostname() -> Option<String> {
    std::env::var("COMPUTERNAME").ok().filter(|n| !n.is_empty())
}

#[cfg(test)]
mod tests;
