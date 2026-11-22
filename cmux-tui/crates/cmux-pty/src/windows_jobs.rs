//! Windows: every terminal's child tree runs in a Job Object this process
//! made for that terminal (children inherit it), so the daemon can tell the
//! processes it started from every other process (`contains`): it reads a
//! process's memory (cwd) or reports its usage only when the process is in
//! one of these jobs (plans/cmux-next/windows-daemon.md, section 2).
//!
//! The job only groups: it sets no limits (no kill on close), so terminals
//! behave as before. The child is assigned right after it is created; a
//! process it started in that instant is outside the job and is not read.

use std::ffi::c_void;
use std::sync::Mutex;

use portable_pty::{Child, ChildKiller, ExitStatus};
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob,
};

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
    fn assign(process: HANDLE) -> Option<Self> {
        // SAFETY: plain call; null is failure.
        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
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

/// A spawned child and its job.
#[derive(Debug)]
pub(crate) struct JobChild {
    child: Box<dyn Child + Send + Sync>,
    _job: Option<Job>,
}

impl JobChild {
    pub(crate) fn new(child: Box<dyn Child + Send + Sync>) -> Self {
        let job = child.as_raw_handle().and_then(|handle| Job::assign(handle as HANDLE));
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
