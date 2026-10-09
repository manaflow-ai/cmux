//! Spawning a terminal-host process on Windows (design: "Breakaway and the
//! app's process tree"; the Windows side of `unix/standby.rs`
//! `StandbyTerminalHost::spawn`). The host leaves the daemon's Job Object
//! (`CREATE_BREAKAWAY_FROM_JOB`) so a job that kills its processes on close
//! (Task Scheduler, some terminals and IDEs) does not end the terminal with
//! the daemon. It has no console window and is the root of its own process
//! group.
//!
//! Handles: the host inherits no handle (`bInheritHandles` FALSE), and the
//! daemon never makes a handle inheritable for it. Its two bootstrap
//! streams are named pipes the daemon creates before the spawn:
//! `\\.\pipe\cmux-th-boot-<128 random bits>.in` (daemon to host) and `.out`
//! (host to daemon), first instance only (`FILE_FLAG_FIRST_PIPE_INSTANCE`,
//! one instance, so nobody can create the name before or beside us), local
//! clients only, and a protected DACL that gives only our token user access.
//! The host opens both by name (the base name is its last argument;
//! [`open_bootstrap_pipes`]). The daemon accepts each connection only when
//! `GetNamedPipeClientProcessId` is the host's pid. An inheritable handle
//! would reach every other process the daemon starts while it exists (std's
//! `Command` inherits every inheritable handle of the process), so pipes
//! made inheritable for a `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` are not used.
//!
//! When the daemon's job does not allow breakaway, `CreateProcessW` fails
//! with `ERROR_ACCESS_DENIED`. The spawn then starts the host inside the
//! daemon's job (coordinator decision, 2026-10-09): the host still outlives a
//! daemon restart, and ends only when that job closes. [`HostProcess::
//! ends_with_daemon_job`] says whether the job kills its processes on close
//! (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`); only then does the daemon mark the
//! terminal with `TerminalHostFallback::BreakawayDenied` (tab JSON
//! `terminal_host_fallback`). The in-process ConPTY fallback
//! (`TerminalHostFallback::HostStartFailed`) is for a start that fails.

use std::ffi::OsStr;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr;
use std::time::Duration;

use windows_sys::Win32::Foundation::{
    ERROR_ACCESS_DENIED, ERROR_PIPE_CONNECTED, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
    LocalFree, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_INBOUND, PIPE_ACCESS_OUTBOUND,
};
use windows_sys::Win32::System::JobObjects::{
    IsProcessInJob, JOB_OBJECT_LIMIT_BREAKAWAY_OK, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK, JOBOBJECT_BASIC_LIMIT_INFORMATION,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectBasicLimitInformation,
    JobObjectExtendedLimitInformation, QueryInformationJobObject,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE,
    PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, CreateEventW,
    CreateProcessW, GetCurrentProcess, PROCESS_INFORMATION, STARTUPINFOW, SetEvent,
    TerminateProcess, WaitForMultipleObjects, WaitForSingleObject,
};

const SDDL_REVISION_1: u32 = 1;
/// winnt.h SECURITY_IDENTIFICATION << 16 (the SQOS level of `CreateFile`):
/// the pipe's server can identify the host, not impersonate it.
const SECURITY_IDENTIFICATION: u32 = 1 << 16;
/// How long a host has to open its bootstrap pipes.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const PIPE_BUFFER: u32 = 64 * 1024;

/// Why a host process did not start.
#[derive(Debug)]
pub enum HostSpawnError {
    /// The daemon runs in a Job Object that does not allow breakaway: a host
    /// would end with the daemon's job. Run the terminal in-process.
    BreakawayDenied,
    Io(io::Error),
}

impl std::fmt::Display for HostSpawnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BreakawayDenied => {
                f.write_str("the daemon's job does not allow a terminal host to break away")
            }
            Self::Io(error) => write!(f, "spawn terminal-host process: {error}"),
        }
    }
}

impl std::error::Error for HostSpawnError {}

impl From<io::Error> for HostSpawnError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Whether this process runs in a Job Object.
pub fn in_job() -> io::Result<bool> {
    let mut result = 0;
    // SAFETY: the current-process pseudo handle; a null job means "any job".
    if unsafe { IsProcessInJob(GetCurrentProcess(), ptr::null_mut(), &mut result) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(result != 0)
}

/// Whether a child of this process can leave its job: no job, or the
/// innermost job allows breakaway (`BREAKAWAY_OK`, or `SILENT_BREAKAWAY_OK`,
/// which puts every child outside the job anyway). An outer job of a nested
/// chain can still refuse; the spawn reports that as
/// [`HostSpawnError::BreakawayDenied`].
pub fn breakaway_allowed() -> io::Result<bool> {
    if !in_job()? {
        return Ok(true);
    }
    // SAFETY: a zeroed plain-data struct is a valid out buffer.
    let mut limits: JOBOBJECT_BASIC_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: a null job handle queries the job of the calling process.
    let ok = unsafe {
        QueryInformationJobObject(
            ptr::null_mut(),
            JobObjectBasicLimitInformation,
            (&raw mut limits).cast(),
            size_of::<JOBOBJECT_BASIC_LIMIT_INFORMATION>() as u32,
            ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(limits.LimitFlags & (JOB_OBJECT_LIMIT_BREAKAWAY_OK | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK)
        != 0)
}

/// Whether this process's innermost job kills its processes when its last
/// handle closes (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`). False outside a job.
/// An outer job of a nested chain is not visible here.
pub fn job_kills_on_close() -> io::Result<bool> {
    if !in_job()? {
        return Ok(false);
    }
    // SAFETY: a zeroed plain-data struct is a valid out buffer.
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: a null job handle queries the job of the calling process.
    let ok = unsafe {
        QueryInformationJobObject(
            ptr::null_mut(),
            JobObjectExtendedLimitInformation,
            (&raw mut limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE != 0)
}

/// A started host process and the daemon's ends of its bootstrap pipes.
/// Dropping it ends that exact process (a standby host is unused until
/// claimed) and waits for it.
#[derive(Debug)]
pub struct HostProcess {
    process: OwnedHandle,
    pid: u32,
    /// The daemon's end of the host's input (bootstrap requests).
    pub stdin: Option<File>,
    /// The daemon's end of the host's output (bootstrap replies).
    pub stdout: Option<File>,
    detached: bool,
    ends_with_daemon_job: bool,
}

impl HostProcess {
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// The host could not leave the daemon's job and that job kills its
    /// processes on close: the terminal ends when the program that started
    /// the daemon closes the job (show the notice).
    pub fn ends_with_daemon_job(&self) -> bool {
        self.ends_with_daemon_job
    }

    /// False once the process has exited.
    pub fn is_alive(&self) -> bool {
        // SAFETY: the process handle this value owns.
        unsafe { WaitForSingleObject(self.process.as_raw_handle() as HANDLE, 0) == WAIT_TIMEOUT }
    }

    /// Wait up to `timeout` for the process to exit; true when it did.
    pub fn wait_timeout(&self, timeout: Duration) -> bool {
        let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX - 1);
        // SAFETY: the process handle this value owns.
        unsafe {
            WaitForSingleObject(self.process.as_raw_handle() as HANDLE, millis) == WAIT_OBJECT_0
        }
    }

    /// Keep the process running when this value drops (a published host
    /// lives on its own).
    pub fn detach(mut self) -> u32 {
        self.detached = true;
        self.pid
    }
}

impl Drop for HostProcess {
    fn drop(&mut self) {
        // Close the pipes first: a host waiting on its bootstrap input exits.
        self.stdin.take();
        self.stdout.take();
        if self.detached || !self.is_alive() {
            return;
        }
        // SAFETY: the exact process this value started and still owns.
        unsafe { TerminateProcess(self.process.as_raw_handle() as HANDLE, 1) };
        self.wait_timeout(Duration::from_secs(5));
    }
}

/// Start `exe args... <pipe base name>` as a terminal-host process: no
/// window, its own process group, no inherited handle; outside the daemon's
/// job, or inside it when the job forbids breakaway (then
/// [`HostProcess::ends_with_daemon_job`] tells whether the job kills it on
/// close). Returns once the host has opened both bootstrap pipes. An error
/// means no host: run the terminal in-process.
pub fn spawn_host_process(exe: &Path, args: &[&str]) -> Result<HostProcess, HostSpawnError> {
    match spawn_host_process_with(exe, args, Breakaway::Required, |_| {}) {
        Err(HostSpawnError::BreakawayDenied) => {
            let kills_on_close = job_kills_on_close().unwrap_or(true);
            let mut host = spawn_host_process_with(exe, args, Breakaway::Stay, |_| {})?;
            host.ends_with_daemon_job = kills_on_close;
            Ok(host)
        }
        other => other,
    }
}

/// Whether the host must leave the daemon's job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Breakaway {
    /// `CREATE_BREAKAWAY_FROM_JOB`; a job that forbids it gives
    /// [`HostSpawnError::BreakawayDenied`].
    Required,
    /// Stay in the daemon's job (its job forbids breakaway).
    Stay,
}

/// The host's side: open the bootstrap pipes named by `base` (the host's
/// last argument). Returns (input from the daemon, output to the daemon).
/// Identification-level SQOS: whoever serves the name cannot act as the
/// host's user.
pub fn open_bootstrap_pipes(base: &str) -> io::Result<(File, File)> {
    if !valid_base_name(base) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a bootstrap pipe name"));
    }
    let input = OpenOptions::new()
        .read(true)
        .security_qos_flags(SECURITY_IDENTIFICATION)
        .open(format!("{base}.in"))?;
    let output = OpenOptions::new()
        .write(true)
        .security_qos_flags(SECURITY_IDENTIFICATION)
        .open(format!("{base}.out"))?;
    Ok((input, output))
}

const PIPE_PREFIX: &str = r"\\.\pipe\cmux-th-boot-";

fn valid_base_name(base: &str) -> bool {
    base.strip_prefix(PIPE_PREFIX)
        .is_some_and(|hex| hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

fn random_base_name() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| io::Error::other("no OS randomness"))?;
    Ok(format!("{PIPE_PREFIX}{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()))
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// One bootstrap pipe's server end: first instance, one instance, byte
/// mode, blocking, local clients only, only our token user may open it.
/// Not inheritable.
fn create_server(name: &str, access: u32) -> io::Result<OwnedHandle> {
    let sid = super::jobs::current_user_sid_string()?;
    let sddl = wide(&format!("O:{sid}D:P(A;;GA;;;{sid})"));
    let mut descriptor: PSECURITY_DESCRIPTOR = ptr::null_mut();
    // SAFETY: a NUL-terminated SDDL string; the descriptor is freed below.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            &mut descriptor,
            ptr::null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor,
        bInheritHandle: 0,
    };
    let wname = wide(name);
    // SAFETY: valid name and attributes for the call.
    let handle = unsafe {
        CreateNamedPipeW(
            wname.as_ptr(),
            access | FILE_FLAG_FIRST_PIPE_INSTANCE,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            PIPE_BUFFER,
            PIPE_BUFFER,
            0,
            &attributes,
        )
    };
    let error = io::Error::last_os_error();
    // SAFETY: the descriptor the conversion allocated.
    unsafe { LocalFree(descriptor as _) };
    if handle == INVALID_HANDLE_VALUE {
        return Err(error);
    }
    // SAFETY: a new handle this function owns.
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

/// Wait for a client on `server` and accept it only when it is `pid`.
fn accept_from(server: &OwnedHandle, pid: u32) -> io::Result<()> {
    // SAFETY: a blocking pipe server handle; no OVERLAPPED.
    if unsafe { ConnectNamedPipe(server.as_raw_handle() as HANDLE, ptr::null_mut()) } == 0 {
        // SAFETY: reads this thread's last error.
        let error = unsafe { GetLastError() };
        if error != ERROR_PIPE_CONNECTED {
            return Err(io::Error::from_raw_os_error(error as i32));
        }
    }
    let mut client = 0u32;
    // SAFETY: a connected pipe server handle and an out pointer.
    if unsafe { GetNamedPipeClientProcessId(server.as_raw_handle() as HANDLE, &mut client) } == 0 {
        return Err(io::Error::last_os_error());
    }
    if client != pid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("bootstrap pipe opened by pid {client}, not the host {pid}"),
        ));
    }
    Ok(())
}

/// Runs `connect` (which blocks in `ConnectNamedPipe`) and unblocks it when
/// the host ends or [`CONNECT_TIMEOUT`] passes without both connections:
/// this thread then opens each still-waiting pipe itself, which the pid
/// check refuses.
fn with_connect_watchdog<R>(
    process: HANDLE,
    names: [String; 2],
    connect: impl FnOnce() -> R,
) -> io::Result<R> {
    // SAFETY: an unnamed manual-reset event, closed by OwnedHandle.
    let done = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
    if done.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new handle owned here.
    let done = unsafe { OwnedHandle::from_raw_handle(done) };
    let (process_raw, done_raw) = (process as usize, done.as_raw_handle() as usize);
    std::thread::scope(|scope| {
        scope.spawn(move || {
            let handles = [process_raw as HANDLE, done_raw as HANDLE];
            let millis = CONNECT_TIMEOUT.as_millis() as u32;
            // SAFETY: both handles outlive this scope.
            let woke = unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, millis) };
            if woke == WAIT_OBJECT_0 + 1 {
                return;
            }
            // The host ended or is too slow: release the waiting connects.
            // A pipe that is already connected refuses this (busy).
            // `.in` is outbound from us (the client reads), `.out` inbound.
            let _ = OpenOptions::new().read(true).open(&names[0]);
            let _ = OpenOptions::new().write(true).open(&names[1]);
        });
        let result = connect();
        // SAFETY: the event owned above.
        unsafe { SetEvent(done.as_raw_handle() as HANDLE) };
        Ok(result)
    })
}

fn spawn_host_process_with(
    exe: &Path,
    args: &[&str],
    breakaway: Breakaway,
    before_spawn: impl FnOnce(&str),
) -> Result<HostProcess, HostSpawnError> {
    let base = random_base_name()?;
    let (in_name, out_name) = (format!("{base}.in"), format!("{base}.out"));
    let to_host = create_server(&in_name, PIPE_ACCESS_OUTBOUND)?;
    let from_host = create_server(&out_name, PIPE_ACCESS_INBOUND)?;
    before_spawn(&base);

    let mut all_args: Vec<&str> = args.to_vec();
    all_args.push(&base);
    let mut command_line = command_line(exe.as_os_str(), &all_args);
    let application: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    // SAFETY: a zeroed plain-data struct; no std handles are passed.
    let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
    startup.cb = size_of::<STARTUPINFOW>() as u32;
    // SAFETY: a zeroed plain-data out struct.
    let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    let flags = CREATE_NO_WINDOW
        | CREATE_NEW_PROCESS_GROUP
        | if breakaway == Breakaway::Required { CREATE_BREAKAWAY_FROM_JOB } else { 0 };
    // SAFETY: NUL-terminated application name and a mutable command line;
    // bInheritHandles FALSE: the host gets no handle of ours.
    let created = unsafe {
        CreateProcessW(
            application.as_ptr(),
            command_line.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            0,
            flags,
            ptr::null(),
            ptr::null(),
            &startup,
            &mut info,
        )
    };
    if created == 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) && in_job().unwrap_or(false) {
            return Err(HostSpawnError::BreakawayDenied);
        }
        return Err(error.into());
    }
    // SAFETY: CreateProcessW returned these handles to us; each is owned once.
    let (process, thread) = unsafe {
        (OwnedHandle::from_raw_handle(info.hProcess), OwnedHandle::from_raw_handle(info.hThread))
    };
    drop(thread);
    let mut host = HostProcess {
        process,
        pid: info.dwProcessId,
        stdin: None,
        stdout: None,
        detached: false,
        ends_with_daemon_job: false,
    };
    let pid = host.pid;
    let connected =
        with_connect_watchdog(host.process.as_raw_handle() as HANDLE, [in_name, out_name], || {
            accept_from(&to_host, pid).and_then(|()| accept_from(&from_host, pid))
        })?;
    // On error `host` drops here and ends the exact process it started.
    connected?;
    host.stdin = Some(File::from(to_host));
    host.stdout = Some(File::from(from_host));
    Ok(host)
}

/// `"exe" arg...` with each argument quoted by the MSVC rules.
fn command_line(exe: &OsStr, args: &[&str]) -> Vec<u16> {
    let mut line: Vec<u16> = Vec::new();
    // A Windows path cannot contain `"`, so plain quotes are exact.
    line.push(u16::from(b'"'));
    line.extend(exe.encode_wide());
    line.push(u16::from(b'"'));
    for arg in args {
        line.push(u16::from(b' '));
        line.extend(quote_arg(arg).encode_utf16());
    }
    line.push(0);
    line
}

fn quote_arg(arg: &str) -> String {
    if !arg.is_empty() && !arg.contains([' ', '\t', '\n', '\x0b', '"']) {
        return arg.to_owned();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0usize;
    for c in arg.chars() {
        match c {
            '\\' => backslashes += 1,
            '"' => {
                quoted.extend(std::iter::repeat_n('\\', backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.extend(std::iter::repeat_n('\\', backslashes));
                quoted.push(c);
                backslashes = 0;
            }
        }
    }
    quoted.extend(std::iter::repeat_n('\\', backslashes * 2));
    quoted.push('"');
    quoted
}

#[cfg(test)]
#[path = "standby_tests.rs"]
mod tests;
