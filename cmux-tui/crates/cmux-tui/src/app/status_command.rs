//! Status segment command execution: bounded output capture with a deadline,
//! process-group job control (suspend, resume, kill), and escape stripping.

#[cfg(windows)]
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use crate::app::status_segments::StatusWorkerStop;

pub(super) const MAX_STATUS_OUTPUT_BYTES: usize = 64 * 1024;
pub(super) const STATUS_POLL_TICK: Duration = Duration::from_millis(25);

#[cfg(unix)]
pub(super) fn capture_status_output(
    argv: &[String],
    timeout: Duration,
    stop: &StatusWorkerStop,
) -> (Vec<u8>, Option<std::process::Child>) {
    use std::io::Read;

    let Some(program) = argv.first() else { return (Vec::new(), None) };
    let mut command = std::process::Command::new(program);
    command
        .args(&argv[1..])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    // Final unlocked stop check directly before the spawn. Holding the
    // raise lock across spawn would let a stalled filesystem block reload
    // and shutdown on the UI thread, so the residual race is resolved the
    // other way: a command that spawns against a concurrent raise is
    // killed at the first poll tick below.
    if stop.is_raised() {
        return (Vec::new(), None);
    }
    let Ok(mut child) = command.spawn() else { return (Vec::new(), None) };
    let mut child_reaped = false;
    let mut stdout = child.stdout.take();
    if let Some(pipe) = stdout.as_ref() {
        use std::os::fd::AsRawFd;
        // SAFETY: fcntl flag update on a pipe fd this function owns.
        let nonblocking = unsafe {
            let fd = pipe.as_raw_fd();
            let flags = libc::fcntl(fd, libc::F_GETFL);
            flags >= 0 && libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) == 0
        };
        if !nonblocking {
            // Fail closed: a blocking pipe would defeat the deadline and
            // stop checks, so never enter the capture loop with one.
            let reaped = kill_status_command_group(&mut child);
            return (Vec::new(), (!reaped).then_some(child));
        }
    }
    let group = child.id() as i32;
    let deadline = Instant::now() + timeout;
    let mut captured: Vec<u8> = Vec::new();
    let mut exited = false;
    loop {
        // Drain what is available, keeping only the bounded tail so the
        // final line survives even when a command writes more than the cap.
        // Each poll pass reads a bounded amount, so a command that writes
        // continuously cannot keep this loop away from the stop, timeout,
        // and exit checks below.
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
            loop {
                if drained >= pass_cap {
                    break;
                }
                match pipe.read(&mut chunk) {
                    Ok(0) => {
                        stdout = None;
                        break;
                    }
                    Ok(read) => {
                        drained += read;
                        captured.extend_from_slice(&chunk[..read]);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(_) => {
                        stdout = None;
                        break;
                    }
                }
            }
            // Compact to the tail once per pass, not per chunk, so a
            // continuously writing command costs one bounded copy here.
            if captured.len() > MAX_STATUS_OUTPUT_BYTES {
                let excess = captured.len() - MAX_STATUS_OUTPUT_BYTES;
                captured.drain(..excess);
            }
        }
        if exited {
            break;
        }
        if matches!(child.try_wait(), Ok(Some(_))) {
            // One more drain pass picks up bytes written before exit.
            child_reaped = true;
            exited = true;
            continue;
        }
        if stop.is_raised() || Instant::now() >= deadline {
            child_reaped = kill_status_command_group(&mut child);
            exited = true;
            continue;
        }
        std::thread::sleep(STATUS_POLL_TICK);
    }
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

#[cfg(windows)]
pub(super) fn capture_status_output(
    argv: &[String],
    timeout: Duration,
    stop: &StatusWorkerStop,
) -> (Vec<u8>, Option<std::process::Child>) {
    use std::io::{Read, Seek, SeekFrom};
    use std::sync::atomic::AtomicU64;

    static CAPTURE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let Some(program) = argv.first() else { return (Vec::new(), None) };
    let path = std::env::temp_dir().join(format!(
        "cmux-status-{}-{}.out",
        std::process::id(),
        CAPTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let Ok(file) = std::fs::File::create(&path) else { return (Vec::new(), None) };
    let mut command = std::process::Command::new(program);
    command
        .args(&argv[1..])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::from(file))
        .stderr(std::process::Stdio::null());
    // Start suspended so the job assignment below covers the process
    // before it can spawn any descendant; resume only after assignment.
    {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;
        command.creation_flags(CREATE_SUSPENDED);
    }
    // Final unlocked stop check; see the Unix path for the trade-off.
    if stop.is_raised() {
        let _ = std::fs::remove_file(&path);
        return (Vec::new(), None);
    }
    let Ok(mut child) = command.spawn() else {
        let _ = std::fs::remove_file(&path);
        return (Vec::new(), None);
    };
    // The job's kill-on-close limit terminates the whole descendant tree
    // when this function returns, mirroring the Unix process-group kill.
    // Fail closed: without a job there is no tree-kill guarantee, so the
    // suspended child is discarded before it ever runs.
    let job = match StatusCommandJob::assign(&child) {
        Ok(job) => job,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = std::fs::remove_file(&path);
            return (Vec::new(), None);
        }
    };
    if resume_suspended_status_child(&child).is_err() {
        job.terminate();
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_file(&path);
        return (Vec::new(), None);
    }
    let mut child_reaped = false;
    let deadline = Instant::now() + timeout;
    loop {
        if matches!(child.try_wait(), Ok(Some(_))) {
            child_reaped = true;
            break;
        }
        // Bound the file while the command runs: a spewing command is
        // killed once the file passes the cap, so it cannot fill the
        // temporary volume for the rest of the timeout. The bound is
        // enforced per poll tick, so up to one tick of disk throughput can
        // land past the cap before the kill; the file is removed below
        // either way.
        let oversized = std::fs::metadata(&path)
            .is_ok_and(|metadata| metadata.len() > MAX_STATUS_OUTPUT_BYTES as u64);
        if oversized || stop.is_raised() || Instant::now() >= deadline {
            job.terminate();
            child_reaped = kill_status_command_group(&mut child);
            break;
        }
        std::thread::sleep(STATUS_POLL_TICK);
    }
    drop(job);
    // A file read never blocks on writers, so lingering descendants cannot
    // pin this call open. Read the bounded tail so the final line survives
    // a command that writes more than the cap.
    let mut captured = Vec::new();
    if let Ok(mut file) = std::fs::File::open(&path) {
        if let Ok(metadata) = file.metadata() {
            let length = metadata.len();
            let cap = MAX_STATUS_OUTPUT_BYTES as u64;
            if length > cap {
                let _ = file.seek(SeekFrom::Start(length - cap));
            }
        }
        let _ = file.take(MAX_STATUS_OUTPUT_BYTES as u64).read_to_end(&mut captured);
    }
    let _ = std::fs::remove_file(&path);
    (captured, (!child_reaped).then_some(child))
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
    fn assign(child: &std::process::Child) -> std::io::Result<Self> {
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
pub(super) fn resume_suspended_status_child(child: &std::process::Child) -> std::io::Result<()> {
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
pub(super) fn kill_status_command_group(child: &mut std::process::Child) -> bool {
    #[cfg(unix)]
    // SAFETY: plain syscall on the child's own process group id.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.kill();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match child.try_wait() {
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(None) => return false,
            _ => return true,
        }
    }
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
