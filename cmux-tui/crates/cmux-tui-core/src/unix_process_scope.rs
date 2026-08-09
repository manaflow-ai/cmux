//! Bounded Unix process cleanup for short-lived child commands.
//!
//! A process group covers normal descendants. Two command-local identities
//! cover common daemon detach behavior: an environment marker survives
//! `closefrom(2)`, and an inherited file marker survives environment
//! replacement. A background tracker records holders before cleanup so an
//! expired command deadline never starts a blocking process-table scan.

#[cfg(target_os = "linux")]
use std::collections::HashMap;
#[cfg(not(target_os = "linux"))]
use std::collections::HashSet;
use std::fs::OpenOptions;
use std::io;
#[cfg(target_os = "linux")]
use std::os::fd::FromRawFd;
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const CLEANUP_DEADLINE: Duration = Duration::from_millis(250);
const TRACK_INTERVAL: Duration = Duration::from_millis(2);
const TRACK_SETTLE: Duration = Duration::from_millis(10);
const MAX_TRACKED_PROCESSES: usize = 256;
const PROCESS_SCOPE_ENV: &str = "CMUX_TUI_PROCESS_SCOPE";

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
struct ProcessIdentity {
    pid: u32,
    started: u128,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileMarker {
    device: u64,
    inode: u64,
}

struct ScopeTracker {
    stop: SyncSender<()>,
}

/// Owns one process group and the private identities used to find descendants
/// that leave that group.
pub struct UnixProcessScope {
    marker: String,
    _marker_fd: OwnedFd,
    file_marker: FileMarker,
    root: Option<ProcessIdentity>,
    #[cfg(target_os = "linux")]
    root_pidfd: Option<OwnedFd>,
    #[cfg(target_os = "linux")]
    tracked: Arc<Mutex<HashMap<ProcessIdentity, OwnedFd>>>,
    #[cfg(not(target_os = "linux"))]
    tracked: Arc<Mutex<HashSet<ProcessIdentity>>>,
    tracked_changed: Arc<Condvar>,
    tracker: Option<ScopeTracker>,
    terminated: bool,
}

impl UnixProcessScope {
    /// Allocate command-local identities before the command is spawned.
    pub fn prepare() -> io::Result<Self> {
        let mut random = [0_u8; 16];
        getrandom::fill(&mut random)
            .map_err(|error| io::Error::other(format!("allocate process scope: {error}")))?;
        let marker = random.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let (marker_fd, file_marker) = create_file_marker(&marker)?;
        Ok(Self {
            marker,
            _marker_fd: marker_fd,
            file_marker,
            root: None,
            #[cfg(target_os = "linux")]
            root_pidfd: None,
            #[cfg(target_os = "linux")]
            tracked: Arc::new(Mutex::new(HashMap::new())),
            #[cfg(not(target_os = "linux"))]
            tracked: Arc::new(Mutex::new(HashSet::new())),
            tracked_changed: Arc::new(Condvar::new()),
            tracker: None,
            terminated: false,
        })
    }

    /// Select this command as the only child that receives the scope
    /// identities. The file was opened with `O_CLOEXEC`, so unrelated
    /// concurrent spawns cannot inherit it.
    pub fn configure(&self, command: &mut Command) {
        command.env(PROCESS_SCOPE_ENV, &self.marker);
        let marker_fd = self._marker_fd.as_raw_fd();
        // SAFETY: the closure calls only async-signal-safe fcntl(2) operations
        // between fork and exec and does not allocate.
        unsafe {
            command.pre_exec(move || {
                let flags = libc::fcntl(marker_fd, libc::F_GETFD);
                if flags < 0 || libc::fcntl(marker_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0
                {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }

    /// Record the exact root identity and start holder discovery while the
    /// command still owns its execution budget.
    pub fn bind(&mut self, root: u32) -> io::Result<()> {
        self.root = Some(process_identity(root).ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "process scope root is unavailable")
        })?);
        #[cfg(target_os = "linux")]
        {
            self.root_pidfd = Some(pidfd_open(root)?);
        }
        self.start_tracker()
    }

    /// Kill the original group and every recorded descendant within the
    /// default cleanup interval.
    pub fn terminate(&mut self) {
        self.terminate_until(Instant::now() + CLEANUP_DEADLINE);
    }

    /// Kill the original group and every recorded descendant without starting
    /// process discovery after the caller's absolute deadline.
    pub fn terminate_until(&mut self, deadline: Instant) {
        if self.terminated {
            return;
        }
        self.terminated = true;
        self.terminate_root_group();

        // Give the already-running tracker a short in-budget window to record
        // a child that detached immediately before cleanup. When the deadline
        // is already expired, this loop performs one bounded signal pass only.
        let settle_deadline = deadline.min(Instant::now() + TRACK_SETTLE);
        loop {
            self.signal_tracked();
            let remaining = settle_deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            std::thread::sleep(remaining.min(TRACK_INTERVAL));
        }
        if let Some(tracker) = self.tracker.take() {
            let _ = tracker.stop.try_send(());
        }
    }

    fn start_tracker(&mut self) -> io::Result<()> {
        let marker = self.marker.clone();
        let file_marker = self.file_marker;
        let tracked = self.tracked.clone();
        let tracked_changed = self.tracked_changed.clone();
        let (stop, stopped) = sync_channel(1);
        std::thread::Builder::new().name("cmux-process-scope".into()).spawn(move || {
            loop {
                let holders = marker_processes(&marker, file_marker);
                #[cfg(target_os = "linux")]
                {
                    let mut tracked = tracked.lock().unwrap();
                    let mut inserted = false;
                    for identity in holders {
                        if tracked.len() >= MAX_TRACKED_PROCESSES {
                            break;
                        }
                        if tracked.contains_key(&identity) {
                            continue;
                        }
                        let Ok(pidfd) = pidfd_open(identity.pid) else { continue };
                        if process_identity(identity.pid) == Some(identity) {
                            tracked.insert(identity, pidfd);
                            inserted = true;
                        }
                    }
                    if inserted {
                        tracked_changed.notify_all();
                    }
                }
                #[cfg(not(target_os = "linux"))]
                {
                    let mut tracked = tracked.lock().unwrap();
                    let mut inserted = false;
                    for identity in holders {
                        if tracked.len() >= MAX_TRACKED_PROCESSES {
                            break;
                        }
                        inserted |= tracked.insert(identity);
                    }
                    if inserted {
                        tracked_changed.notify_all();
                    }
                }
                // macOS has no completion signal for cross-process marker
                // changes. Keep this cancellable probe within the command's
                // final deadline through the scope stop signal.
                match stopped.recv_timeout(TRACK_INTERVAL) {
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
        })?;
        self.tracker = Some(ScopeTracker { stop });
        Ok(())
    }

    #[cfg(all(test, target_os = "linux"))]
    pub(crate) fn wait_until_tracked_for_test(&self, pid: u32, deadline: Instant) -> bool {
        let mut tracked = self.tracked.lock().unwrap();
        loop {
            if tracked.keys().any(|identity| identity.pid == pid) {
                return true;
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.tracked_changed.wait_timeout(tracked, remaining).unwrap();
            tracked = next;
            if timeout.timed_out() && !tracked.keys().any(|identity| identity.pid == pid) {
                return false;
            }
        }
    }

    #[cfg(all(test, not(target_os = "linux")))]
    pub(crate) fn wait_until_tracked_for_test(&self, pid: u32, deadline: Instant) -> bool {
        let mut tracked = self.tracked.lock().unwrap();
        loop {
            if tracked.iter().any(|identity| identity.pid == pid) {
                return true;
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.tracked_changed.wait_timeout(tracked, remaining).unwrap();
            tracked = next;
            if timeout.timed_out() && !tracked.iter().any(|identity| identity.pid == pid) {
                return false;
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn signal_tracked(&self) {
        let Ok(tracked) = self.tracked.try_lock() else { return };
        for (identity, pidfd) in tracked.iter() {
            if identity.pid != std::process::id() && Some(*identity) != self.root {
                let _ = pidfd_send_signal(pidfd, libc::SIGKILL);
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    fn signal_tracked(&self) {
        let Ok(tracked) = self.tracked.try_lock() else { return };
        for identity in tracked.iter().copied() {
            if identity.pid != std::process::id() && Some(identity) != self.root {
                signal_process(identity);
            }
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

fn create_file_marker(marker: &str) -> io::Result<(OwnedFd, FileMarker)> {
    let path = std::env::temp_dir().join(format!("cmux-tui-process-scope-{marker}"));
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&path)?;
    let identity = file_marker_for_fd(file.as_raw_fd());
    let unlink = std::fs::remove_file(&path);
    let identity = identity?;
    unlink?;
    Ok((file.into(), identity))
}

fn file_marker_for_fd(fd: libc::c_int) -> io::Result<FileMarker> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::zeroed();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fstat(2) initialized the structure after returning success.
    let stat = unsafe { stat.assume_init() };
    Ok(FileMarker { device: stat.st_dev as u64, inode: stat.st_ino as u64 })
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
fn marker_processes(marker: &str, file_marker: FileMarker) -> Vec<ProcessIdentity> {
    use std::os::unix::fs::MetadataExt as _;

    let expected = marker_environment_entry(marker);
    let Ok(processes) = std::fs::read_dir("/proc") else { return Vec::new() };
    let mut identities = Vec::new();
    for process in processes.flatten() {
        let Some(pid) = process.file_name().to_str().and_then(|value| value.parse::<u32>().ok())
        else {
            continue;
        };
        let environment_match =
            std::fs::read(process.path().join("environ")).ok().is_some_and(|environment| {
                environment.split(|byte| *byte == 0).any(|entry| entry == expected)
            });
        let file_match = std::fs::read_dir(process.path().join("fd")).ok().is_some_and(|fds| {
            fds.flatten().any(|fd| {
                std::fs::metadata(fd.path()).ok().is_some_and(|metadata| {
                    metadata.dev() == file_marker.device && metadata.ino() == file_marker.inode
                })
            })
        });
        if (environment_match || file_match)
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
fn marker_processes(marker: &str, file_marker: FileMarker) -> Vec<ProcessIdentity> {
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
        if (mac_process_has_environment_entry(pid, &expected, &mut arguments)
            || mac_process_holds_file_marker(pid, file_marker))
            && let Some(identity) = process_identity(pid)
        {
            identities.push(identity);
        }
    }
    identities
}

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
struct VnodeFdInfo {
    _file: ProcFileInfo,
    vnode: libc::vnode_info,
}

#[cfg(target_os = "macos")]
fn mac_process_holds_file_marker(pid: u32, marker: FileMarker) -> bool {
    const PROC_PIDFDVNODEINFO: libc::c_int = 1;
    let Ok(pid_int) = libc::c_int::try_from(pid) else { return false };
    let bytes =
        unsafe { libc::proc_pidinfo(pid_int, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    let Ok(bytes) = usize::try_from(bytes) else { return false };
    let mut fds = Vec::<libc::proc_fdinfo>::with_capacity(
        bytes / std::mem::size_of::<libc::proc_fdinfo>() + 8,
    );
    let Ok(capacity) =
        libc::c_int::try_from(fds.capacity() * std::mem::size_of::<libc::proc_fdinfo>())
    else {
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
        if fd.proc_fdtype != libc::PROX_FDTYPE_VNODE as u32 {
            return false;
        }
        let mut info = std::mem::MaybeUninit::<VnodeFdInfo>::zeroed();
        let Ok(size) = libc::c_int::try_from(std::mem::size_of::<VnodeFdInfo>()) else {
            return false;
        };
        let written = unsafe {
            libc::proc_pidfdinfo(
                pid_int,
                fd.proc_fd,
                PROC_PIDFDVNODEINFO,
                info.as_mut_ptr().cast(),
                size,
            )
        };
        if written != size {
            return false;
        }
        // SAFETY: proc_pidfdinfo initialized the full structure.
        let info = unsafe { info.assume_init() };
        u64::from(info.vnode.vi_stat.vst_dev) == marker.device
            && info.vnode.vi_stat.vst_ino == marker.inode
    })
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
fn marker_processes(_marker: &str, _file_marker: FileMarker) -> Vec<ProcessIdentity> {
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
