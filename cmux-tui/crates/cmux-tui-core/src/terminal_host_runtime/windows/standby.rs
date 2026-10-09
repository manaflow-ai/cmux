//! Spawning a terminal-host process on Windows (design: "Breakaway and the
//! app's process tree"; the Windows side of `unix/standby.rs`
//! `StandbyTerminalHost::spawn`). The host leaves the daemon's Job Object
//! (`CREATE_BREAKAWAY_FROM_JOB`) so a job that kills its processes on close
//! (Task Scheduler, some terminals and IDEs) does not end the terminal with
//! the daemon. It inherits only its two bootstrap pipe ends and NUL for
//! stderr (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, the analog of
//! `isolate_terminal_host_process_fds`), has no console window and is the
//! root of its own process group.
//!
//! When the daemon's job does not allow breakaway, `CreateProcessW` fails
//! with `ERROR_ACCESS_DENIED`: [`HostSpawnError::BreakawayDenied`]. The
//! daemon then runs that terminal in its own ConPTY and marks it with
//! `TerminalHostFallback::BreakawayDenied` (tab JSON
//! `terminal_host_fallback`), so the user sees that it will not survive a
//! restart.

use std::ffi::OsStr;
use std::fs::OpenOptions;
use std::io::{self, PipeReader, PipeWriter};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr;

use windows_sys::Win32::Foundation::{
    ERROR_ACCESS_DENIED, HANDLE, HANDLE_FLAG_INHERIT, SetHandleInformation, WAIT_OBJECT_0,
    WAIT_TIMEOUT,
};
use windows_sys::Win32::System::JobObjects::{
    IsProcessInJob, JOB_OBJECT_LIMIT_BREAKAWAY_OK, JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK,
    JOBOBJECT_BASIC_LIMIT_INFORMATION, JobObjectBasicLimitInformation, QueryInformationJobObject,
};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, CreateProcessW,
    DeleteProcThreadAttributeList, EXTENDED_STARTUPINFO_PRESENT, GetCurrentProcess,
    InitializeProcThreadAttributeList, LPPROC_THREAD_ATTRIBUTE_LIST,
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, PROCESS_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOEXW,
    TerminateProcess, UpdateProcThreadAttribute, WaitForSingleObject,
};

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

/// A started host process and the daemon's ends of its bootstrap pipes.
/// Dropping it ends that exact process (a standby host is unused until
/// claimed) and waits for it.
#[derive(Debug)]
pub struct HostProcess {
    process: OwnedHandle,
    pid: u32,
    /// The host's stdin (bootstrap requests).
    pub stdin: Option<PipeWriter>,
    /// The host's stdout (bootstrap replies).
    pub stdout: Option<PipeReader>,
    detached: bool,
}

impl HostProcess {
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// False once the process has exited.
    pub fn is_alive(&self) -> bool {
        // SAFETY: the process handle this value owns.
        unsafe { WaitForSingleObject(self.process.as_raw_handle() as HANDLE, 0) == WAIT_TIMEOUT }
    }

    /// Wait up to `timeout` for the process to exit; true when it did.
    pub fn wait_timeout(&self, timeout: std::time::Duration) -> bool {
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
        // Close the pipes first: a host waiting on its bootstrap stdin exits.
        self.stdin.take();
        self.stdout.take();
        if self.detached || !self.is_alive() {
            return;
        }
        // SAFETY: the exact process this value started and still owns.
        unsafe { TerminateProcess(self.process.as_raw_handle() as HANDLE, 1) };
        self.wait_timeout(std::time::Duration::from_secs(5));
    }
}

/// Start `exe args...` as a terminal-host process: no window, its own
/// process group, outside the daemon's job, inheriting only its pipes.
pub fn spawn_host_process(exe: &Path, args: &[&str]) -> Result<HostProcess, HostSpawnError> {
    spawn_host_process_with(exe, args, Breakaway::Required)
}

/// Whether the host must leave the daemon's job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Breakaway {
    /// `CREATE_BREAKAWAY_FROM_JOB`; a job that forbids it gives
    /// [`HostSpawnError::BreakawayDenied`].
    Required,
    /// Stay in the daemon's job (tests on a runner whose job forbids
    /// breakaway).
    #[cfg_attr(not(test), allow(dead_code))]
    Stay,
}

fn spawn_host_process_with(
    exe: &Path,
    args: &[&str],
    breakaway: Breakaway,
) -> Result<HostProcess, HostSpawnError> {
    let (child_stdin, stdin) = io::pipe()?;
    let (stdout, child_stdout) = io::pipe()?;
    let child_stderr = OpenOptions::new().write(true).open("NUL")?;
    let inherited: [HANDLE; 3] = [
        child_stdin.as_raw_handle() as HANDLE,
        child_stdout.as_raw_handle() as HANDLE,
        child_stderr.as_raw_handle() as HANDLE,
    ];
    // The handle list needs inheritable handles. std's own spawns hold
    // their inheritable pipes only while they spawn; ours are inheritable
    // only until CreateProcessW returns and the child ends drop below.
    for handle in inherited {
        // SAFETY: handles this function owns.
        if unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) } == 0 {
            return Err(io::Error::last_os_error().into());
        }
    }
    let attributes = AttributeList::with_handles(&inherited)?;

    // SAFETY: a zeroed plain-data struct; the fields used are set below.
    let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
    startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = inherited[0];
    startup.StartupInfo.hStdOutput = inherited[1];
    startup.StartupInfo.hStdError = inherited[2];
    startup.lpAttributeList = attributes.as_ptr();

    let mut command_line = command_line(exe.as_os_str(), args);
    let application: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    // SAFETY: a zeroed plain-data out struct.
    let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: NUL-terminated application name and a mutable command line;
    // the attribute list outlives the call; inherited handles are the three
    // in the list (bInheritHandles must be TRUE for the list to apply).
    let created = unsafe {
        CreateProcessW(
            application.as_ptr(),
            command_line.as_mut_ptr(),
            ptr::null(),
            ptr::null(),
            1,
            CREATE_NO_WINDOW
                | CREATE_NEW_PROCESS_GROUP
                | EXTENDED_STARTUPINFO_PRESENT
                | if breakaway == Breakaway::Required { CREATE_BREAKAWAY_FROM_JOB } else { 0 },
            ptr::null(),
            ptr::null(),
            &startup.StartupInfo,
            &mut info,
        )
    };
    let error = (created == 0).then(io::Error::last_os_error);
    drop(attributes);
    drop((child_stdin, child_stdout, child_stderr));
    if let Some(error) = error {
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
    Ok(HostProcess {
        process,
        pid: info.dwProcessId,
        stdin: Some(stdin),
        stdout: Some(stdout),
        detached: false,
    })
}

/// A `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` attribute list. The handle array
/// is copied into the value, so it lives as long as the list.
struct AttributeList {
    buffer: Vec<u64>,
    _handles: Box<[HANDLE]>,
}

impl AttributeList {
    fn with_handles(handles: &[HANDLE]) -> io::Result<Self> {
        let mut size = 0usize;
        // SAFETY: the documented size query (fails with
        // ERROR_INSUFFICIENT_BUFFER and sets `size`).
        unsafe { InitializeProcThreadAttributeList(ptr::null_mut(), 1, 0, &mut size) };
        if size == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut list = Self {
            buffer: vec![0u64; size.div_ceil(8)],
            _handles: handles.to_vec().into_boxed_slice(),
        };
        // SAFETY: a buffer of at least `size` bytes, 8-aligned.
        if unsafe { InitializeProcThreadAttributeList(list.as_ptr(), 1, 0, &mut size) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: an initialized list; the handle array is owned by `list`
        // and does not move (boxed).
        let updated = unsafe {
            UpdateProcThreadAttribute(
                list.as_ptr(),
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                list._handles.as_ptr().cast(),
                size_of_val(&*list._handles),
                ptr::null_mut(),
                ptr::null(),
            )
        };
        if updated == 0 {
            let error = io::Error::last_os_error();
            // SAFETY: initialized above; deleted once (an empty buffer
            // tells Drop not to delete it again).
            unsafe { DeleteProcThreadAttributeList(list.as_ptr()) };
            list.buffer.clear();
            return Err(error);
        }
        Ok(list)
    }

    fn as_ptr(&self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.buffer.as_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST
    }
}

impl Drop for AttributeList {
    fn drop(&mut self) {
        if !self.buffer.is_empty() {
            // SAFETY: an initialized list, deleted once.
            unsafe { DeleteProcThreadAttributeList(self.as_ptr()) };
        }
    }
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
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::path::PathBuf;
    use std::time::Duration;

    fn system32(exe: &str) -> PathBuf {
        let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        PathBuf::from(root).join("System32").join(exe)
    }

    #[test]
    fn arguments_are_quoted_by_the_msvc_rules() {
        assert_eq!(quote_arg("--bootstrap-stdio"), "--bootstrap-stdio");
        assert_eq!(quote_arg(""), "\"\"");
        assert_eq!(quote_arg("a b"), "\"a b\"");
        assert_eq!(quote_arg(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(quote_arg(r"C:\dir with space\"), r#""C:\dir with space\\""#);
    }

    /// `sort.exe` as a stand-in host. The hosted Windows runner runs tests
    /// in a job that forbids breakaway (run 37935857605): there the spawn
    /// must say BreakawayDenied, and the rest of the test runs the host in
    /// the runner's job.
    fn stand_in_host() -> HostProcess {
        let sort = system32("sort.exe");
        if breakaway_allowed().unwrap() {
            return spawn_host_process(&sort, &[]).unwrap();
        }
        match spawn_host_process(&sort, &[]) {
            Err(HostSpawnError::BreakawayDenied) => {}
            other => panic!("expected BreakawayDenied in a job without breakaway: {other:?}"),
        }
        spawn_host_process_with(&sort, &[], Breakaway::Stay).unwrap()
    }

    /// A host gets its bootstrap pipes: `sort` reads stdin to EOF and
    /// writes the sorted lines to stdout, like a host answers its daemon.
    #[test]
    fn a_host_process_gets_its_bootstrap_pipes() {
        let mut host = stand_in_host();
        host.stdin.take().unwrap().write_all(b"b\r\na\r\n").unwrap();
        let mut output = String::new();
        host.stdout.take().unwrap().read_to_string(&mut output).unwrap();
        assert_eq!(output.lines().collect::<Vec<_>>(), ["a", "b"]);
        assert!(host.wait_timeout(Duration::from_secs(10)), "sort exits after EOF");
        assert!(!host.is_alive());
    }

    #[test]
    fn dropping_an_unused_host_ends_that_process() {
        // `sort` waits on stdin; the drop closes it and ends the process.
        let host = stand_in_host();
        let pid = host.pid();
        assert!(host.is_alive());
        drop(host);
        let exists = std::process::Command::new(system32("tasklist.exe"))
            .args(["/fi", &format!("PID eq {pid}"), "/nh"])
            .output()
            .unwrap();
        assert!(
            !String::from_utf8_lossy(&exists.stdout).contains(&pid.to_string()),
            "host {pid} still runs"
        );
    }

    const HELPER_ENV: &str = "CMUX_TEST_STANDBY_BREAKAWAY_HELPER";

    /// In a job without breakaway the spawn says so instead of starting a
    /// host that would die with the daemon's job. Runs in a child test
    /// process, which puts itself in such a job (the test runner stays out).
    #[test]
    fn a_job_without_breakaway_denies_the_host() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "terminal_host_runtime::windows::standby::tests::helper_in_a_job_without_breakaway",
                "--ignored",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(HELPER_ENV, "1")
            .output()
            .unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(output.status.success(), "{text}");
        assert!(text.contains("1 passed"), "the helper did not run: {text}");
    }

    #[test]
    #[ignore = "run by a_job_without_breakaway_denies_the_host in its own process"]
    fn helper_in_a_job_without_breakaway() {
        if std::env::var_os(HELPER_ENV).is_none() {
            return;
        }
        use windows_sys::Win32::System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW};
        // SAFETY: an unnamed job with default limits (no BREAKAWAY_OK); this
        // helper process puts itself in it and never closes it.
        unsafe {
            let job = CreateJobObjectW(ptr::null(), ptr::null());
            assert!(!job.is_null(), "{}", io::Error::last_os_error());
            assert_ne!(
                AssignProcessToJobObject(job, GetCurrentProcess()),
                0,
                "{}",
                io::Error::last_os_error()
            );
        }
        assert!(in_job().unwrap());
        assert!(!breakaway_allowed().unwrap());
        match spawn_host_process(&system32("sort.exe"), &[]) {
            Err(HostSpawnError::BreakawayDenied) => {}
            other => panic!("expected BreakawayDenied, got {other:?}"),
        }
    }
}
