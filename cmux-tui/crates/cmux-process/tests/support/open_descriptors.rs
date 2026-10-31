//! The descriptors a child has open, read from the system (macOS:
//! `proc_pidinfo(PROC_PIDLISTFDS)`; Linux: `/proc/<pid>/fd`), so a spawn test
//! checks what the child inherited, not what the child reports. Test code
//! only (the daemon never scans processes). Included by path from the
//! cmux-process and cmux-holder spawn tests.

use std::io;

/// The descriptor numbers process `pid` has open now, in order.
///
/// # Errors
///
/// When the system does not say (no such process, or another user's).
#[allow(dead_code)] // each including test uses it on its own systems
pub fn open_descriptors(pid: u32) -> io::Result<Vec<i32>> {
    #[cfg(target_vendor = "apple")]
    {
        let pid = libc::pid_t::try_from(pid).map_err(io::Error::other)?;
        // SAFETY: a null buffer asks only for the size the list needs.
        let bytes =
            unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
        if bytes <= 0 {
            return Err(io::Error::last_os_error());
        }
        let entry = size_of::<libc::proc_fdinfo>();
        let mut list =
            vec![libc::proc_fdinfo { proc_fd: -1, proc_fdtype: 0 }; bytes as usize / entry + 16];
        // SAFETY: `list` has room for `list.len()` entries.
        let filled = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDLISTFDS,
                0,
                list.as_mut_ptr().cast(),
                (list.len() * entry) as libc::c_int,
            )
        };
        if filled <= 0 {
            return Err(io::Error::last_os_error());
        }
        let mut fds: Vec<i32> =
            list[..filled as usize / entry].iter().map(|info| info.proc_fd).collect();
        fds.sort_unstable();
        Ok(fds)
    }
    #[cfg(target_os = "linux")]
    {
        let mut fds = Vec::new();
        for entry in std::fs::read_dir(format!("/proc/{pid}/fd"))? {
            if let Some(fd) = entry?.file_name().to_str().and_then(|name| name.parse().ok()) {
                fds.push(fd);
            }
        }
        fds.sort_unstable();
        Ok(fds)
    }
    #[cfg(all(not(target_vendor = "apple"), not(target_os = "linux")))]
    {
        let _ = pid;
        Err(io::Error::new(io::ErrorKind::Unsupported, "open_descriptors"))
    }
}
