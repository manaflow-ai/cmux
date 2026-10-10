//! Windows: every terminal's child tree runs in a Job Object this process
//! made for that terminal (children inherit it), so the daemon can tell the
//! processes it started from every other process (`contains`): it reads a
//! process's memory (cwd) or reports its usage only when the process is in
//! one of these jobs (plans/cmux-next/windows-daemon.md, section 2).
//!
//! The job only groups: it sets no limits (no kill on close), so terminals
//! behave as before. The child is assigned right after it is created; a
//! process it started in that instant is outside the job and is not read.
//!
//! Each job is named after its terminal's first process
//! ([`job_name`], `Local\cmux-pty-job-<pid>`), so another process of the
//! same user (a daemon reading the processes of a terminal that runs in a
//! terminal-host process, also after a daemon restart) can open it for
//! queries and ask whether a process runs in it ([`named_job_contains`]).
//! A name that already exists is never joined: that terminal gets an
//! unnamed job, as before.

use std::ffi::c_void;
use std::sync::Mutex;

use portable_pty::{Child, ChildKiller, ExitStatus};
use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob, OpenJobObjectW, TerminateJobObject,
};

/// `JOB_OBJECT_QUERY`: enough for `IsProcessInJob`.
const JOB_OBJECT_QUERY: u32 = 0x0004;

/// The name of the job whose first process is `pid`.
pub fn job_name(pid: u32) -> String {
    format!("Local\\cmux-pty-job-{pid}")
}

fn wide(name: &str) -> Vec<u16> {
    name.encode_utf16().chain(std::iter::once(0)).collect()
}

/// A new job named after `pid`; an unnamed one when that name exists
/// already (never another process's job) or no pid is known.
fn create_job(pid: Option<u32>) -> HANDLE {
    if let Some(pid) = pid {
        let name = wide(&job_name(pid));
        // SAFETY: plain call; a NUL-terminated name; null is failure.
        let job = unsafe { CreateJobObjectW(std::ptr::null(), name.as_ptr()) };
        // SAFETY: read right after the call that set it.
        let existed = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
        if !job.is_null() && !existed {
            return job;
        }
        if !job.is_null() {
            // SAFETY: the handle this call opened; the job is not ours.
            unsafe { CloseHandle(job) };
        }
    }
    // SAFETY: plain call; null is failure.
    unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) }
}

/// Whether `process` (a handle with PROCESS_QUERY_LIMITED_INFORMATION) runs
/// in the job named after `root_pid` ([`job_name`]), made by any process of
/// this user.
pub fn named_job_contains(process: *mut c_void, root_pid: u32) -> bool {
    let name = wide(&job_name(root_pid));
    // SAFETY: plain call; a NUL-terminated name; null is failure.
    let job = unsafe { OpenJobObjectW(JOB_OBJECT_QUERY, 0, name.as_ptr()) };
    if job.is_null() {
        return false;
    }
    let mut result = 0;
    // SAFETY: valid handles; `result` is written on success.
    let inside = unsafe { IsProcessInJob(process as HANDLE, job, &mut result) != 0 && result != 0 };
    // SAFETY: the handle opened above.
    unsafe { CloseHandle(job) };
    inside
}

/// The open job handles, as integers (a HANDLE is a pointer).
static JOBS: Mutex<Vec<usize>> = Mutex::new(Vec::new());

fn jobs() -> std::sync::MutexGuard<'static, Vec<usize>> {
    JOBS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// One terminal's job; closed and forgotten when its child is dropped.
#[derive(Debug)]
struct Job(usize);

impl Job {
    /// A new job with `process` in it, or None (the child then runs outside
    /// any job and the daemon reads nothing of it).
    fn assign(process: HANDLE, pid: Option<u32>) -> Option<Self> {
        let job = create_job(pid);
        if job.is_null() {
            return None;
        }
        // SAFETY: valid job and process handles.
        if unsafe { AssignProcessToJobObject(job, process) } == 0 {
            // SAFETY: the job handle this call created.
            unsafe { CloseHandle(job) };
            return None;
        }
        jobs().push(job as usize);
        Some(Self(job as usize))
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        jobs().retain(|job| *job != self.0);
        // SAFETY: the job handle this value owns.
        unsafe { CloseHandle(self.0 as HANDLE) };
    }
}

/// Whether `process` (a handle with PROCESS_QUERY_LIMITED_INFORMATION) runs
/// in a terminal job of this process.
pub fn contains(process: *mut c_void) -> bool {
    let jobs = jobs();
    jobs.iter().any(|&job| {
        let mut result = 0;
        // SAFETY: valid handles; `result` is written on success.
        unsafe { IsProcessInJob(process as HANDLE, job as HANDLE, &mut result) != 0 && result != 0 }
    })
}

/// Ends every process in every terminal job of this process with
/// `exit_code` (`TerminateJobObject`) and returns how many jobs it ended.
/// For a terminal-host process, which runs one terminal: the Windows side of
/// the host's final process-group kill (cx-ko2e). A daemon that runs several
/// terminals in-process must not call it.
pub fn terminate_every_job(exit_code: u32) -> usize {
    let jobs = jobs();
    jobs.iter()
        // SAFETY: open job handles this process created (full access).
        .filter(|&&job| unsafe { TerminateJobObject(job as HANDLE, exit_code) } != 0)
        .count()
}

/// A spawned child and its job.
#[derive(Debug)]
pub(crate) struct JobChild {
    child: Box<dyn Child + Send + Sync>,
    _job: Option<Job>,
}

impl JobChild {
    pub(crate) fn new(child: Box<dyn Child + Send + Sync>) -> Self {
        let pid = child.process_id();
        let job = child.as_raw_handle().and_then(|handle| Job::assign(handle as HANDLE, pid));
        Self { child, _job: job }
    }
}

impl ChildKiller for JobChild {
    fn kill(&mut self) -> std::io::Result<()> {
        self.child.kill()
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        self.child.clone_killer()
    }
}

impl Child for JobChild {
    fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    fn wait(&mut self) -> std::io::Result<ExitStatus> {
        self.child.wait()
    }

    fn process_id(&self) -> Option<u32> {
        self.child.process_id()
    }

    fn as_raw_handle(&self) -> Option<std::os::windows::io::RawHandle> {
        self.child.as_raw_handle()
    }
}
