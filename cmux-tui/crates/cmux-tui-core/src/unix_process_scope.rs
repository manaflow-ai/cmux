//! Bounded Unix process cleanup for short-lived child commands.
//!
//! A process group covers normal descendants. A private inherited pipe also
//! identifies descendants that call `setsid(2)` before cleanup. The cleanup
//! scan reads each process start identity immediately before `SIGKILL`, so a
//! reused PID cannot target an unrelated process.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::time::{Duration, Instant};

const CLEANUP_DEADLINE: Duration = Duration::from_millis(250);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ProcessIdentity {
    pid: u32,
    started: u128,
}

/// Owns one process group and the inherited marker used to find descendants
/// that leave that group.
pub struct UnixProcessScope {
    _marker_read: OwnedFd,
    marker_write: Option<OwnedFd>,
    marker: PipeMarker,
    root: Option<ProcessIdentity>,
    terminated: bool,
}

impl UnixProcessScope {
    /// Create the inherited marker before the command is spawned.
    pub fn prepare() -> io::Result<Self> {
        let mut fds = [0; 2];
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: pipe(2) returned two new descriptors owned by this scope.
        let marker_read = unsafe { OwnedFd::from_raw_fd(fds[0]) };
        // SAFETY: pipe(2) returned two new descriptors owned by this scope.
        let marker_write = unsafe { OwnedFd::from_raw_fd(fds[1]) };
        set_close_on_exec(marker_read.as_raw_fd(), true)?;
        // Keep the writer close-on-exec in the multithreaded parent. Only the
        // selected child clears this bit in its post-fork pre-exec callback,
        // so a concurrent unrelated spawn cannot inherit this marker.
        set_close_on_exec(marker_write.as_raw_fd(), true)?;
        let marker = pipe_marker_for_fd(marker_write.as_raw_fd())?;
        Ok(Self {
            _marker_read: marker_read,
            marker_write: Some(marker_write),
            marker,
            root: None,
            terminated: false,
        })
    }

    /// Select this command as the only child that keeps the marker across
    /// exec. Call this after `prepare` and before `Command::spawn`.
    pub fn configure(&self, command: &mut Command) {
        let marker = self
            .marker_write
            .as_ref()
            .expect("process scope command must be configured before bind")
            .as_raw_fd();
        // SAFETY: the closure calls only async-signal-safe fcntl(2) operations
        // between fork and exec and does not allocate.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(marker, libc::F_GETFD);
                if flags < 0 || libc::fcntl(marker, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    /// Close the parent's write endpoint after spawn and record the exact root
    /// identity. The child and every normal fork inherit the write endpoint.
    pub fn bind(&mut self, root: u32) {
        self.marker_write.take();
        self.root = process_identity(root);
    }

    /// Kill the original group when its root identity is still valid, then
    /// repeatedly kill exact-identity holders of the inherited marker.
    pub fn terminate(&mut self) {
        if self.terminated {
            return;
        }
        self.terminated = true;
        self.marker_write.take();

        if let Some(root) = self.root
            && process_identity(root.pid) == Some(root)
            && let Ok(group) = libc::pid_t::try_from(root.pid)
        {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }

        let deadline = Instant::now() + CLEANUP_DEADLINE;
        loop {
            let holders = marker_processes(self.marker);
            if holders.is_empty() {
                break;
            }
            for holder in holders {
                if holder.pid == std::process::id()
                    || process_identity(holder.pid) != Some(holder)
                {
                    continue;
                }
                if let Ok(pid) = libc::pid_t::try_from(holder.pid) {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                    }
                }
            }
            if Instant::now() >= deadline {
                break;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

}

impl Drop for UnixProcessScope {
    fn drop(&mut self) {
        self.terminate();
    }
}

fn set_close_on_exec(fd: RawFd, close_on_exec: bool) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let next = if close_on_exec { flags | libc::FD_CLOEXEC } else { flags & !libc::FD_CLOEXEC };
    if unsafe { libc::fcntl(fd, libc::F_SETFD, next) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
type PipeMarker = u64;

#[cfg(target_os = "linux")]
fn pipe_marker_for_fd(fd: RawFd) -> io::Result<PipeMarker> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::zeroed();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstat(2) initialized the structure after returning success.
    let stat = unsafe { stat.assume_init() };
    Ok(stat.st_ino)
}

#[cfg(target_os = "linux")]
fn marker_processes(marker: PipeMarker) -> Vec<ProcessIdentity> {
    let expected = format!("pipe:[{marker}]");
    let Ok(processes) = std::fs::read_dir("/proc") else { return Vec::new() };
    let mut identities = Vec::new();
    for process in processes.flatten() {
        let Some(pid) = process.file_name().to_str().and_then(|value| value.parse::<u32>().ok())
        else {
            continue;
        };
        let Ok(fds) = std::fs::read_dir(process.path().join("fd")) else { continue };
        if fds
            .flatten()
            .any(|fd| std::fs::read_link(fd.path()).ok().is_some_and(|path| path == expected.as_str()))
            && let Some(identity) = process_identity(pid)
        {
            identities.push(identity);
        }
    }
    identities
}

#[cfg(target_os = "linux")]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    linux_process_identity_from_stat(pid, &stat)
}

#[cfg(target_os = "linux")]
fn linux_process_identity_from_stat(pid: u32, stat: &str) -> Option<ProcessIdentity> {
    let fields = stat.get(stat.rfind(')')? + 1..)?.split_whitespace().collect::<Vec<_>>();
    // `fields[0]` is field 3 (`state`); process start time is field 22.
    let started = fields.get(19)?.parse::<u128>().ok()?;
    Some(ProcessIdentity { pid, started })
}

#[cfg(target_os = "macos")]
type PipeMarker = u64;

#[cfg(target_os = "macos")]
#[repr(C)]
struct ProcFileInfo {
    _open_flags: u32,
    _status: u32,
    _offset: libc::off_t,
    _file_type: i32,
    _guard_flags: u32,
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct PipeInfo {
    _stat: libc::vinfo_stat,
    handle: u64,
    peer_handle: u64,
    _status: i32,
    _reserved: i32,
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct PipeFdInfo {
    _file: ProcFileInfo,
    pipe: PipeInfo,
}

#[cfg(target_os = "macos")]
fn pipe_marker_for_fd(fd: RawFd) -> io::Result<PipeMarker> {
    pipe_info(std::process::id(), fd)
        .map(|info| info.pipe.handle)
        .ok_or_else(io::Error::last_os_error)
}

#[cfg(target_os = "macos")]
fn pipe_info(pid: u32, fd: RawFd) -> Option<PipeFdInfo> {
    const PROC_PIDFDPIPEINFO: libc::c_int = 6;
    let pid = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<PipeFdInfo>::zeroed();
    let size = libc::c_int::try_from(std::mem::size_of::<PipeFdInfo>()).ok()?;
    let written = unsafe {
        libc::proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidfdinfo initialized the full structure.
    Some(unsafe { info.assume_init() })
}

#[cfg(target_os = "macos")]
fn marker_processes(marker: PipeMarker) -> Vec<ProcessIdentity> {
    const PROC_ALL_PIDS: u32 = 1;
    let bytes = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return Vec::new() };
    let mut pids = vec![0 as libc::pid_t; bytes / std::mem::size_of::<libc::pid_t>() + 32];
    let Ok(capacity) = libc::c_int::try_from(pids.len() * std::mem::size_of::<libc::pid_t>())
    else {
        return Vec::new();
    };
    let written = unsafe {
        libc::proc_listpids(PROC_ALL_PIDS, 0, pids.as_mut_ptr().cast(), capacity)
    };
    let Ok(written) = usize::try_from(written) else { return Vec::new() };
    let mut identities = Vec::new();
    for pid in pids.into_iter().take(written / std::mem::size_of::<libc::pid_t>()) {
        let Ok(pid) = u32::try_from(pid) else { continue };
        if process_holds_marker(pid, marker)
            && let Some(identity) = process_identity(pid)
        {
            identities.push(identity);
        }
    }
    identities
}

#[cfg(target_os = "macos")]
fn process_holds_marker(pid: u32, marker: PipeMarker) -> bool {
    let Ok(pid_int) = libc::c_int::try_from(pid) else { return false };
    let bytes = unsafe {
        libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0)
    };
    let Ok(bytes) = usize::try_from(bytes) else { return false };
    let mut fds = Vec::<libc::proc_fdinfo>::with_capacity(
        bytes / std::mem::size_of::<libc::proc_fdinfo>() + 8,
    );
    let Ok(capacity) = libc::c_int::try_from(
        fds.capacity() * std::mem::size_of::<libc::proc_fdinfo>(),
    ) else {
        return false;
    };
    let written = unsafe {
        libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, fds.as_mut_ptr().cast(), capacity)
    };
    let Ok(written) = usize::try_from(written) else { return false };
    let count = written / std::mem::size_of::<libc::proc_fdinfo>();
    // SAFETY: proc_pidinfo initialized `count` entries within the allocation.
    unsafe {
        fds.set_len(count.min(fds.capacity()));
    }
    fds.into_iter().any(|fd| {
        fd.proc_fdtype == libc::PROX_FDTYPE_PIPE as u32
            && pipe_info(pid, fd.proc_fd)
                .is_some_and(|info| info.pipe.handle == marker || info.pipe.peer_handle == marker)
    })
}

#[cfg(target_os = "macos")]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    let pid_int = libc::c_int::try_from(pid).ok()?;
    let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
    let size = libc::c_int::try_from(std::mem::size_of::<libc::proc_bsdinfo>()).ok()?;
    let written = unsafe {
        libc::proc_pidinfo(pid_int, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
    };
    if written != size {
        return None;
    }
    // SAFETY: proc_pidinfo initialized the full structure.
    let info = unsafe { info.assume_init() };
    let started = (u128::from(info.pbi_start_tvsec) << 64) | u128::from(info.pbi_start_tvusec);
    Some(ProcessIdentity { pid, started })
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
type PipeMarker = ();

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn pipe_marker_for_fd(_fd: RawFd) -> io::Result<PipeMarker> {
    Ok(())
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn marker_processes(_marker: PipeMarker) -> Vec<ProcessIdentity> {
    Vec::new()
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    Some(ProcessIdentity { pid, started: 0 })
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn linux_process_identity_uses_start_time_after_a_parenthesized_name() {
        let stat = "12 (name with ) marker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 4242";
        assert_eq!(
            linux_process_identity_from_stat(12, stat),
            Some(ProcessIdentity { pid: 12, started: 4242 })
        );
    }
}
