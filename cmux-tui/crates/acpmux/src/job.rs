//! A job object per agent on Windows: what the agent's own process group is
//! on Unix. Everything the agent starts (shells, tools, servers) is in its
//! job, so stopping the session stops all of it, and the job is closed with
//! kill-on-close, so nothing outlives the daemon's handle to it.
//!
//! The agent starts suspended (CREATE_SUSPENDED), joins its job, then
//! resumes: no process it starts can begin before it is in the job.

use std::io;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle};
use std::ptr::null;
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Threading::{CREATE_NEW_PROCESS_GROUP, CREATE_SUSPENDED};

/// The creation flags of an agent: suspended (`contain` resumes it in its
/// job) and the leader of its own process group, so Ctrl+Break reaches it
/// and what it starts, and nothing else.
pub(crate) const AGENT_FLAGS: u32 = CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP;

/// `CTRL_BREAK_EVENT`.
const CTRL_BREAK_EVENT: u32 = 1;

#[link(name = "ntdll")]
unsafe extern "system" {
    /// Resumes every thread of a process (ntdll; stable since Windows XP).
    /// std and tokio give the process handle only, not the main thread's.
    fn NtResumeProcess(process: HANDLE) -> i32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    /// Sends a console control event to a process group sharing our console.
    fn GenerateConsoleCtrlEvent(event: u32, group: u32) -> i32;
}

/// The polite stop (SIGTERM to the group on Unix): Ctrl+Break to the
/// agent's process group (`group` is its leader's pid). The daemon and its
/// agents share one console (hidden for a started daemon). False when no
/// event could be sent (no console); the caller ends the job after its
/// grace either way.
pub(crate) fn ctrl_break(group: u32) -> bool {
    // SAFETY: no pointers; an unknown group only fails.
    unsafe { GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, group) != 0 }
}

/// One agent's job.
pub(crate) struct Job(OwnedHandle);

impl Job {
    /// Puts the suspended `process` in a new kill-on-close job, then
    /// resumes it. On an error the caller kills the process.
    pub(crate) fn contain(process: RawHandle) -> io::Result<Self> {
        // SAFETY: no name, default security.
        let handle = unsafe { CreateJobObjectW(null(), null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a handle just created and owned here.
        let job = Job(unsafe { OwnedHandle::from_raw_handle(handle) });
        // SAFETY: plain data.
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: a job handle and a structure of the size passed.
        if unsafe {
            SetInformationJobObject(
                job.raw(),
                JobObjectExtendedLimitInformation,
                (&raw const limits).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: valid job and process handles.
        if unsafe { AssignProcessToJobObject(job.raw(), process) } == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a process handle with resume rights (the creator's).
        let status = unsafe { NtResumeProcess(process) };
        if status < 0 {
            return Err(io::Error::other(format!("NtResumeProcess: NTSTATUS {status:#x}")));
        }
        Ok(job)
    }

    /// Ends every process in the job (SIGKILL to the group on Unix).
    pub(crate) fn kill(&self) {
        // SAFETY: a job handle owned here.
        unsafe { TerminateJobObject(self.raw(), 1) };
    }

    fn raw(&self) -> HANDLE {
        self.0.as_raw_handle()
    }
}

// The job handle is used only through its own calls.
unsafe impl Send for Job {}
unsafe impl Sync for Job {}
