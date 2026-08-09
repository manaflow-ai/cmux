//! Bounded Unix process cleanup for short-lived child commands.
//!
//! A process group covers normal descendants. A command-local environment
//! identity also finds descendants that call `setsid(2)` or close inherited
//! file descriptors. The marker is installed only in the selected `Command`,
//! so a concurrent unrelated spawn cannot inherit it from the cmux process.

use std::io;
#[cfg(target_os = "linux")]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::process::Command;
use std::time::{Duration, Instant};

const CLEANUP_DEADLINE: Duration = Duration::from_millis(250);
const PROCESS_SCOPE_ENV: &str = "CMUX_TUI_PROCESS_SCOPE";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ProcessIdentity {
    pid: u32,
    started: u128,
}

/// Owns one process group and the private identity used to find descendants
/// that leave that group.
pub struct UnixProcessScope {
    marker: String,
    root: Option<ProcessIdentity>,
    #[cfg(target_os = "linux")]
    root_pidfd: Option<OwnedFd>,
    terminated: bool,
}

impl UnixProcessScope {
    /// Allocate a command-local identity before the command is spawned.
    pub fn prepare() -> io::Result<Self> {
        let mut random = [0_u8; 16];
        getrandom::fill(&mut random)
            .map_err(|error| io::Error::other(format!("allocate process scope: {error}")))?;
        let marker = random.iter().map(|byte| format!("{byte:02x}")).collect();
        Ok(Self {
            marker,
            root: None,
            #[cfg(target_os = "linux")]
            root_pidfd: None,
            terminated: false,
        })
    }

    /// Select this command as the only child that receives the scope identity.
    pub fn configure(&self, command: &mut Command) {
        command.env(PROCESS_SCOPE_ENV, &self.marker);
    }

    /// Record the exact root identity after spawn.
    pub fn bind(&mut self, root: u32) {
        self.root = process_identity(root);
        #[cfg(target_os = "linux")]
        {
            self.root_pidfd = pidfd_open(root).ok();
        }
    }

    /// Kill the original group and every marked descendant within the default
    /// cleanup interval.
    pub fn terminate(&mut self) {
        self.terminate_until(Instant::now() + CLEANUP_DEADLINE);
    }

    /// Kill the original group and every marked descendant without extending
    /// the caller's absolute deadline.
    pub fn terminate_until(&mut self, deadline: Instant) {
        if self.terminated {
            return;
        }
        self.terminated = true;
        self.terminate_root_group();

        loop {
            let holders = marker_processes(&self.marker);
            if holders.is_empty() {
                break;
            }
            for holder in holders {
                if holder.pid == std::process::id() {
                    continue;
                }
                signal_process(holder);
            }
            if Instant::now() >= deadline {
                break;
            }
            // macOS has no completion signal for this cross-process marker scan.
            // Keep the probe bounded by the final deadline above.
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[cfg(target_os = "linux")]
    fn terminate_root_group(&self) {
        let (Some(root), Some(pidfd)) = (self.root, self.root_pidfd.as_ref()) else { return };
        if process_identity(root.pid) != Some(root) {
            return;
        }
        // Stop the exact pidfd-owned root before addressing its numeric process
        // group. While that root is stopped and alive, its PID/PGID cannot be
        // reused by an unrelated process between verification and killpg(2).
        if pidfd_send_signal(pidfd, libc::SIGSTOP).is_err() {
            return;
        }
        if let Ok(group) = libc::pid_t::try_from(root.pid) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
        let _ = pidfd_send_signal(pidfd, libc::SIGKILL);
    }

    #[cfg(not(target_os = "linux"))]
    fn terminate_root_group(&self) {
        let Some(root) = self.root else { return };
        if process_identity(root.pid) != Some(root) {
            return;
        }
        if let Ok(group) = libc::pid_t::try_from(root.pid) {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
        }
    }
}

impl Drop for UnixProcessScope {
    fn drop(&mut self) {
        self.terminate();
    }
}

#[cfg(target_os = "linux")]
fn pidfd_open(pid: u32) -> io::Result<OwnedFd> {
    let pid = libc::pid_t::try_from(pid)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "process id is out of range"))?;
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0_u32) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = i32::try_from(fd).map_err(|_| io::Error::other("pidfd is out of range"))?;
    // SAFETY: pidfd_open returned a new descriptor owned by this scope.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

#[cfg(target_os = "linux")]
fn pidfd_send_signal(pidfd: &OwnedFd, signal: libc::c_int) -> io::Result<()> {
    let result = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            pidfd.as_raw_fd(),
            signal,
            std::ptr::null::<libc::siginfo_t>(),
            0_u32,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn signal_process(identity: ProcessIdentity) {
    let Ok(pidfd) = pidfd_open(identity.pid) else { return };
    if process_identity(identity.pid) != Some(identity) {
        return;
    }
    let _ = pidfd_send_signal(&pidfd, libc::SIGKILL);
}

#[cfg(not(target_os = "linux"))]
fn signal_process(identity: ProcessIdentity) {
    if process_identity(identity.pid) != Some(identity) {
        return;
    }
    if let Ok(pid) = libc::pid_t::try_from(identity.pid) {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
}

fn marker_environment_entry(marker: &str) -> Vec<u8> {
    format!("{PROCESS_SCOPE_ENV}={marker}").into_bytes()
}

#[cfg(target_os = "linux")]
fn marker_processes(marker: &str) -> Vec<ProcessIdentity> {
    let expected = marker_environment_entry(marker);
    let Ok(processes) = std::fs::read_dir("/proc") else { return Vec::new() };
    let mut identities = Vec::new();
    for process in processes.flatten() {
        let Some(pid) = process.file_name().to_str().and_then(|value| value.parse::<u32>().ok())
        else {
            continue;
        };
        let Ok(environment) = std::fs::read(process.path().join("environ")) else { continue };
        if environment.split(|byte| *byte == 0).any(|entry| entry == expected)
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
fn marker_processes(marker: &str) -> Vec<ProcessIdentity> {
    const PROC_ALL_PIDS: u32 = 1;
    let bytes = unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return Vec::new() };
    let mut pids = vec![0 as libc::pid_t; bytes / std::mem::size_of::<libc::pid_t>() + 32];
    let Ok(capacity) = libc::c_int::try_from(pids.len() * std::mem::size_of::<libc::pid_t>())
    else {
        return Vec::new();
    };
    let written =
        unsafe { libc::proc_listpids(PROC_ALL_PIDS, 0, pids.as_mut_ptr().cast(), capacity) };
    let Ok(written) = usize::try_from(written) else { return Vec::new() };
    let Some(mut arguments) = mac_process_argument_buffer() else { return Vec::new() };
    let expected = marker_environment_entry(marker);
    let mut identities = Vec::new();
    for pid in pids.into_iter().take(written / std::mem::size_of::<libc::pid_t>()) {
        let Ok(pid) = u32::try_from(pid) else { continue };
        if mac_process_has_environment_entry(pid, &expected, &mut arguments)
            && let Some(identity) = process_identity(pid)
        {
            identities.push(identity);
        }
    }
    identities
}

#[cfg(target_os = "macos")]
fn mac_process_argument_buffer() -> Option<Vec<u8>> {
    let mut mib = [libc::CTL_KERN, libc::KERN_ARGMAX];
    let mut argmax = 0 as libc::c_int;
    let mut size = std::mem::size_of::<libc::c_int>();
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            (&mut argmax as *mut libc::c_int).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 || argmax <= 0 {
        return None;
    }
    let argmax = usize::try_from(argmax).ok()?;
    (argmax <= 16 * 1024 * 1024).then(|| vec![0; argmax])
}

#[cfg(target_os = "macos")]
fn mac_process_has_environment_entry(pid: u32, expected: &[u8], buffer: &mut [u8]) -> bool {
    let Ok(pid) = libc::c_int::try_from(pid) else { return false };
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut size = buffer.len();
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            mib.len() as libc::c_uint,
            buffer.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    result == 0 && mac_environment_contains(&buffer[..size.min(buffer.len())], expected)
}

#[cfg(target_os = "macos")]
fn mac_environment_contains(arguments: &[u8], expected: &[u8]) -> bool {
    let Some(argc) = arguments.get(..4) else { return false };
    let argc = i32::from_ne_bytes(argc.try_into().expect("four-byte argc"));
    let Ok(argc) = usize::try_from(argc) else { return false };
    let mut cursor = 4;
    let Some(path_end) = arguments[cursor..].iter().position(|byte| *byte == 0) else {
        return false;
    };
    cursor += path_end + 1;
    while arguments.get(cursor) == Some(&0) {
        cursor += 1;
    }
    for _ in 0..argc {
        let Some(end) = arguments[cursor..].iter().position(|byte| *byte == 0) else {
            return false;
        };
        cursor += end + 1;
    }
    while arguments.get(cursor) == Some(&0) {
        cursor += 1;
    }
    arguments[cursor..].split(|byte| *byte == 0).any(|entry| entry == expected)
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
fn marker_processes(_marker: &str) -> Vec<ProcessIdentity> {
    Vec::new()
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "macos"))))]
fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    Some(ProcessIdentity { pid, started: 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_process_identity_uses_start_time_after_a_parenthesized_name() {
        let stat = "12 (name with ) marker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 4242";
        assert_eq!(
            linux_process_identity_from_stat(12, stat),
            Some(ProcessIdentity { pid: 12, started: 4242 })
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_argument_parser_finds_only_environment_entries() {
        let expected = b"CMUX_TUI_PROCESS_SCOPE=abc";
        let mut arguments = 2_i32.to_ne_bytes().to_vec();
        arguments.extend_from_slice(b"/bin/tool\0\0tool\0--flag\0A=1\0");
        arguments.extend_from_slice(expected);
        arguments.push(0);
        assert!(mac_environment_contains(&arguments, expected));

        let mut argv_only = 1_i32.to_ne_bytes().to_vec();
        argv_only.extend_from_slice(b"/bin/tool\0\0CMUX_TUI_PROCESS_SCOPE=abc\0A=1\0");
        assert!(!mac_environment_contains(&argv_only, expected));
    }
}
