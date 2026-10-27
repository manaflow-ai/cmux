//! Status segment command execution: bounded output capture with a deadline,
//! process-group job control (suspend, resume, kill), and escape stripping.

use std::time::Duration;

use crate::app::status_segments::StatusWorkerStop;

pub(super) const MAX_STATUS_OUTPUT_BYTES: usize = 64 * 1024;

/// What `StatusWorkerStop::raise` kills: a command's process group (Unix)
/// or its job handle (Windows).
#[cfg(unix)]
pub(super) type RunningStatusCommand = libc::pid_t;
#[cfg(windows)]
pub(super) type RunningStatusCommand = isize;

pub(super) fn kill_running_status_command(command: RunningStatusCommand) {
    #[cfg(unix)]
    // SAFETY: plain syscall on the group of a command whose leader is
    // still unreaped (`StatusWorkerStop::running`).
    unsafe {
        libc::kill(-command, libc::SIGKILL);
    }
    #[cfg(windows)]
    // SAFETY: the job handle stays open while it is tracked.
    unsafe {
        windows_sys::Win32::System::JobObjects::TerminateJobObject(
            command as windows_sys::Win32::Foundation::HANDLE,
            1,
        );
    }
}

/// Keep the last `MAX_STATUS_OUTPUT_BYTES` once `captured` holds `slack`
/// more, so a continuous writer costs one bounded copy per `slack` bytes.
fn keep_output_tail(captured: &mut Vec<u8>, slack: usize) {
    if captured.len() > MAX_STATUS_OUTPUT_BYTES + slack {
        let excess = captured.len() - MAX_STATUS_OUTPUT_BYTES;
        captured.drain(..excess);
    }
}

#[cfg(unix)]
pub(super) fn capture_status_output(
    argv: &[String],
    timeout: Duration,
    stop: &StatusWorkerStop,
) -> (Vec<u8>, Option<cmux_process::Child>) {
    use std::io::Read;

    let Some(program) = argv.first() else { return (Vec::new(), None) };
    let mut command = cmux_process::Command::new(program);
    command
        .args(&argv[1..])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .process_group(0);
    // Final unlocked stop check directly before the spawn. Holding the
    // raise lock across spawn would let a stalled filesystem block reload
    // and shutdown on the UI thread; a raise that lands during the spawn is
    // answered by `track` below.
    if stop.is_raised() {
        return (Vec::new(), None);
    }
    let Ok(mut child) = command.spawn() else { return (Vec::new(), None) };
    let group = child.id() as libc::pid_t;
    let mut stdout = child.stdout.take();
    let watch = match stdout.as_ref().map(|pipe| OutputWatch::new(pipe, &child)) {
        None => None,
        Some(Ok(watch)) => Some(watch),
        // Fail closed: a blocking pipe or no wakeup source would defeat the
        // deadline and stop checks, so never enter the capture loop.
        Some(Err(_)) => {
            let reaped = kill_status_command_group(&mut child);
            return (Vec::new(), (!reaped).then_some(child));
        }
    };
    if !stop.track(group) {
        let reaped = kill_status_command_group(&mut child);
        return (Vec::new(), (!reaped).then_some(child));
    }
    let mut child_reaped = false;
    let deadline = std::time::Instant::now() + timeout;
    let mut captured: Vec<u8> = Vec::new();
    let mut exited = false;
    loop {
        // Drain what is available, keeping only the bounded tail so the
        // final line survives even when a command writes more than the cap.
        if let Some(pipe) = stdout.as_mut() {
            // While the command runs, each pass reads a bounded amount so a
            // continuous writer cannot keep the loop away from the stop and
            // timeout checks. The final pass after exit drains what the pipe
            // buffered (kernels allow enlarged pipes) so the documented last
            // line is the real one; it stays finite so a lingering
            // descendant cannot pin this loop either.
            const EXIT_DRAIN_CAP: usize = 4 * 1024 * 1024;
            let pass_cap = if exited { EXIT_DRAIN_CAP } else { MAX_STATUS_OUTPUT_BYTES };
            let mut chunk = [0u8; 4096];
            let mut drained = 0usize;
            while drained < pass_cap {
                match pipe.read(&mut chunk) {
                    Ok(0) => {
                        stdout = None;
                        break;
                    }
                    Ok(read) => {
                        drained += read;
                        captured.extend_from_slice(&chunk[..read]);
                        keep_output_tail(&mut captured, MAX_STATUS_OUTPUT_BYTES);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => {
                        stdout = None;
                        break;
                    }
                }
            }
        }
        if exited {
            break;
        }
        // Checked after each wake (output, the exit, the deadline), never
        // on a timer of its own.
        // wakeup-allow: deadline reaps after the exit event, bounded by the command's timeout
        if matches!(child.try_wait(), Ok(Some(_))) {
            // One more drain pass picks up bytes written before exit.
            stop.untrack(group);
            child_reaped = true;
            exited = true;
            continue;
        }
        if stop.is_raised() || std::time::Instant::now() >= deadline {
            stop.untrack(group);
            child_reaped = kill_status_command_group(&mut child);
            exited = true;
            continue;
        }
        // Sleep until output, the exit, the deadline, or a raise (it kills
        // the group: the exit and the pipe's end).
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        match (stdout.as_ref(), watch.as_ref()) {
            (Some(_), Some(watch)) => watch.wait(left),
            // wakeup-allow: deadline the command's own timeout; the wait is its exit event
            _ => drop(child.wait_timeout(left)),
        }
    }
    stop.untrack(group);
    keep_output_tail(&mut captured, 0);
    // A status command must not outlive its collection: descendants that
    // detached from the exited command (for example `cmd &`) would
    // otherwise accumulate one per interval. Idempotent when the group is
    // already gone.
    // SAFETY: plain syscall on the spawned child's own process group id.
    unsafe {
        libc::kill(-group, libc::SIGKILL);
    }
    (captured, (!child_reaped).then_some(child))
}

/// Wakes the capture loop on the pipe's output or end and on the command's
/// exit (kqueue `EVFILT_READ` plus `EVFILT_PROC` `NOTE_EXIT`).
#[cfg(target_vendor = "apple")]
struct OutputWatch {
    queue: std::os::fd::OwnedFd,
}

#[cfg(target_vendor = "apple")]
impl OutputWatch {
    fn new(pipe: &std::process::ChildStdout, child: &cmux_process::Child) -> std::io::Result<Self> {
        use std::os::fd::{AsRawFd, FromRawFd};
        set_nonblocking(pipe.as_raw_fd())?;
        // SAFETY: kqueue returns a new descriptor or -1.
        let raw = unsafe { libc::kqueue() };
        if raw < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: a new descriptor this watch owns.
        let queue = unsafe { std::os::fd::OwnedFd::from_raw_fd(raw) };
        let watch = Self { queue };
        watch.register(pipe.as_raw_fd() as libc::uintptr_t, libc::EVFILT_READ, 0, 0)?;
        match watch.register(
            child.id() as libc::uintptr_t,
            libc::EVFILT_PROC,
            libc::EV_ONESHOT,
            libc::NOTE_EXIT,
        ) {
            // Exited before the registration: the loop's next check reaps it.
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
            other => other?,
        }
        Ok(watch)
    }

    fn register(
        &self,
        ident: libc::uintptr_t,
        filter: i16,
        flags: u16,
        fflags: u32,
    ) -> std::io::Result<()> {
        use std::os::fd::AsRawFd;
        let change = libc::kevent {
            ident,
            filter,
            flags: libc::EV_ADD | flags,
            fflags,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        loop {
            // SAFETY: one change in, no events out.
            let n = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    &change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            if n >= 0 {
                return Ok(());
            }
            let error = std::io::Error::last_os_error();
            if error.kind() != std::io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }

    /// Returns on an event or after `limit`; the caller checks what changed.
    fn wait(&self, limit: Duration) {
        use std::os::fd::AsRawFd;
        let timeout = libc::timespec {
            tv_sec: limit.as_secs() as libc::time_t,
            tv_nsec: limit.subsec_nanos() as libc::c_long,
        };
        // SAFETY: zeroed kevent is valid output storage.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: no changes, one event slot, a live timeout.
        // wakeup-allow: deadline the command's own timeout; the wait is its output and exit events
        unsafe {
            libc::kevent(self.queue.as_raw_fd(), std::ptr::null(), 0, &mut event, 1, &timeout);
        }
    }
}

/// Wakes the capture loop on the pipe's output or end and on the command's
/// exit (`poll` on the pipe and a pidfd). Without `pidfd_open` (before Linux
/// 5.3, a seccomp denial, other Unix systems) the exit shows as the pipe's
/// end or the deadline.
#[cfg(all(unix, not(target_vendor = "apple")))]
struct OutputWatch {
    pipe: std::os::fd::RawFd,
    exit: Option<std::os::fd::OwnedFd>,
}

#[cfg(all(unix, not(target_vendor = "apple")))]
impl OutputWatch {
    fn new(pipe: &std::process::ChildStdout, child: &cmux_process::Child) -> std::io::Result<Self> {
        use std::os::fd::AsRawFd;
        set_nonblocking(pipe.as_raw_fd())?;
        Ok(Self { pipe: pipe.as_raw_fd(), exit: pidfd(child.id()) })
    }

    /// Returns on an event or after `limit`; the caller checks what changed.
    fn wait(&self, limit: Duration) {
        use std::os::fd::AsRawFd;
        // poll skips a negative descriptor.
        let exit = self.exit.as_ref().map_or(-1, AsRawFd::as_raw_fd);
        let mut fds = [
            libc::pollfd { fd: self.pipe, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: exit, events: libc::POLLIN, revents: 0 },
        ];
        // Round up: a wait cut to whole milliseconds must not end before
        // the deadline and spin until it.
        let millis = limit.as_nanos().div_ceil(1_000_000).min(libc::c_int::MAX as u128);
        // SAFETY: two live pollfds.
        // wakeup-allow: deadline the command's own timeout; the wait is its output and exit events
        unsafe {
            libc::poll(fds.as_mut_ptr(), 2, millis as libc::c_int);
        }
    }
}

#[cfg(target_os = "linux")]
fn pidfd(pid: u32) -> Option<std::os::fd::OwnedFd> {
    use std::os::fd::FromRawFd;
    // SAFETY: pidfd_open returns a new descriptor or -1.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
    // SAFETY: a new descriptor the watch owns.
    (raw >= 0).then(|| unsafe { std::os::fd::OwnedFd::from_raw_fd(raw as libc::c_int) })
}

#[cfg(all(unix, not(target_vendor = "apple"), not(target_os = "linux")))]
fn pidfd(_pid: u32) -> Option<std::os::fd::OwnedFd> {
    None
}

#[cfg(unix)]
fn set_nonblocking(fd: std::os::fd::RawFd) -> std::io::Result<()> {
    // SAFETY: fcntl flag update on a pipe fd the capture owns.
    let set = unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        flags >= 0 && libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) == 0
    };
    if set { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(windows)]
pub(super) fn capture_status_output(
    argv: &[String],
    timeout: Duration,
    stop: &StatusWorkerStop,
) -> (Vec<u8>, Option<cmux_process::Child>) {
    let Some(program) = argv.first() else { return (Vec::new(), None) };
    let mut command = cmux_process::Command::new(program);
    command
        .args(&argv[1..])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null());
    // Start suspended so the job assignment below covers the process
    // before it can spawn any descendant; resume only after assignment.
    command.creation_flags(windows_sys::Win32::System::Threading::CREATE_SUSPENDED);
    // Final unlocked stop check; see the Unix path for the trade-off.
    if stop.is_raised() {
        return (Vec::new(), None);
    }
    let Ok(mut child) = command.spawn() else { return (Vec::new(), None) };
    let discard = |mut child: cmux_process::Child| -> (Vec<u8>, Option<cmux_process::Child>) {
        let _ = child.kill();
        let _ = child.wait();
        (Vec::new(), None)
    };
    // The job's kill-on-close limit terminates the whole descendant tree
    // when this function returns, mirroring the Unix process-group kill.
    // Fail closed: without a job there is no tree-kill guarantee, so the
    // suspended child is discarded before it ever runs.
    let Ok(job) = StatusCommandJob::assign(&child) else { return discard(child) };
    // The reader keeps the output's tail and ends at the pipe's end: the
    // command and every descendant gone, which the job guarantees.
    let reader = child.stdout.take().and_then(|stdout| {
        std::thread::Builder::new()
            .name("status-segment-output".into())
            .spawn(move || read_output_tail(stdout))
            .ok()
    });
    let Some(reader) = reader else {
        job.terminate();
        return discard(child);
    };
    let tracked = job.handle as RunningStatusCommand;
    if !stop.track(tracked) || resume_suspended_status_child(&child).is_err() {
        stop.untrack(tracked);
        job.terminate();
        let _ = child.kill();
        let _ = child.wait();
        drop(job);
        let _ = reader.join();
        return (Vec::new(), None);
    }
    // wakeup-allow: deadline the command's own timeout; the wait is its exit event
    let mut child_reaped = matches!(child.wait_timeout(timeout), Ok(Some(_)));
    stop.untrack(tracked);
    if !child_reaped {
        job.terminate();
        child_reaped = kill_status_command_group(&mut child);
    }
    // Kill-on-close ends the remaining descendants, so the pipe ends.
    drop(job);
    let captured = reader.join().unwrap_or_default();
    (captured, (!child_reaped).then_some(child))
}

#[cfg(windows)]
fn read_output_tail(mut stdout: std::process::ChildStdout) -> Vec<u8> {
    use std::io::Read;
    let mut captured = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match stdout.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                captured.extend_from_slice(&chunk[..read]);
                keep_output_tail(&mut captured, MAX_STATUS_OUTPUT_BYTES);
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    keep_output_tail(&mut captured, 0);
    captured
}

/// Windows job object with the kill-on-close limit, so every process a
/// status command started dies when the capture returns. Same pattern as
/// the journal hook runner in cmux-tui-core.
#[cfg(windows)]
pub(super) struct StatusCommandJob {
    pub(super) handle: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
impl StatusCommandJob {
    fn assign(child: &cmux_process::Child) -> std::io::Result<Self> {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        };
        use windows_sys::Win32::System::Threading::{
            OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
        };

        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let job = Self { handle };
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let information_size =
            u32::try_from(std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
                .expect("Windows job information fits in u32");
        if unsafe {
            SetInformationJobObject(
                job.handle,
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&information).cast(),
                information_size,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error());
        }
        let process = unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, child.id()) };
        if process.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        let assigned = unsafe { AssignProcessToJobObject(job.handle, process) };
        let assign_error = (assigned == 0).then(std::io::Error::last_os_error);
        unsafe {
            CloseHandle(process);
        }
        if let Some(error) = assign_error {
            return Err(error);
        }
        Ok(job)
    }

    fn terminate(&self) {
        use windows_sys::Win32::System::JobObjects::TerminateJobObject;
        unsafe {
            TerminateJobObject(self.handle, 1);
        }
    }
}

#[cfg(windows)]
impl Drop for StatusCommandJob {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        // Kill-on-close terminates any remaining descendants here.
        unsafe {
            CloseHandle(self.handle);
        }
    }
}

/// Resume the suspended status command after its job assignment, same
/// pattern as the journal hook runner in cmux-tui-core.
#[cfg(windows)]
pub(super) fn resume_suspended_status_child(child: &cmux_process::Child) -> std::io::Result<()> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};

    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error());
    }
    let result = (|| {
        let mut thread_entry = THREADENTRY32 {
            dwSize: u32::try_from(std::mem::size_of::<THREADENTRY32>())
                .expect("Windows thread entry size fits in u32"),
            ..THREADENTRY32::default()
        };
        if unsafe { Thread32First(snapshot, &mut thread_entry) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        loop {
            if thread_entry.th32OwnerProcessID == child.id() {
                let thread =
                    unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, thread_entry.th32ThreadID) };
                if thread.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                let resume_result = unsafe { ResumeThread(thread) };
                let resume_error = (resume_result == u32::MAX).then(std::io::Error::last_os_error);
                unsafe {
                    CloseHandle(thread);
                }
                return resume_error.map_or(Ok(()), Err);
            }
            if unsafe { Thread32Next(snapshot, &mut thread_entry) } == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "suspended status command has no thread to resume",
                ));
            }
        }
    })();
    unsafe {
        CloseHandle(snapshot);
    }
    result
}

/// Kill a status command and, on Unix, its whole process group so every
/// descendant exits with it. Reaping is bounded: a child stuck in
/// uninterruptible kernel I/O survives SIGKILL until the kernel releases
/// it, and blocking on it would transitively hang reload and shutdown.
/// Returns whether the child was reaped; the caller keeps an unreaped
/// child and refuses to start another command behind it.
pub(super) fn kill_status_command_group(child: &mut cmux_process::Child) -> bool {
    #[cfg(unix)]
    // SAFETY: plain syscall on the child's own process group id.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.kill();
    // wakeup-allow: deadline one bounded reap after SIGKILL; the wait is the exit event
    !matches!(child.wait_timeout(Duration::from_secs(2)), Ok(None))
}

/// Drop ESC-introduced sequences (CSI/OSC and two-byte escapes) and other
/// control characters so colored tool output degrades to its plain text.
/// Tabs become single spaces.
pub(super) fn strip_escape_sequences(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '\u{1b}' {
            match chars.next() {
                Some('[') => {
                    for terminator in chars.by_ref() {
                        if ('@'..='~').contains(&terminator) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    while let Some(next) = chars.next() {
                        if next == '\u{7}' {
                            break;
                        }
                        if next == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        if character == '\t' {
            result.push(' ');
        } else if !character.is_control() {
            result.push(character);
        }
    }
    result
}
