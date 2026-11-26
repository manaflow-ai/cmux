//! Windows: a child that leads its own group ([`crate::Command::new_session`],
//! `process_group(0)`) runs in a Job Object of its own, the Windows form of a
//! process group. What it starts joins the job, so ending the job ends them
//! too, as SIGKILL to a group does on Unix.
//!
//! The child is created suspended and runs only once it is in the job: no
//! process it starts can leave before the job holds it. The job has no
//! kill-on-close limit, so a detached child ([`crate::Child::detach`]) and
//! its tree outlive the handle; a child that is dropped or killed ends with
//! its tree because [`Job::terminate`] is called first.

use std::io;
use std::os::windows::io::AsRawHandle;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject,
};
use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};

pub(crate) use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;

/// The exit code of every process a terminated job ends (std's `kill` uses 1).
const TERMINATED: u32 = 1;

/// An anonymous job holding one child and what it starts; the handle closes
/// on drop (which ends nothing: see the module docs).
#[derive(Debug)]
pub(crate) struct Job {
    /// The kernel handle as an integer, so [`crate::Child`] stays `Send` and
    /// `Sync` (handles are process-wide values, safe from any thread).
    handle: usize,
}

impl Job {
    /// Puts `child` (created suspended) in a new job.
    pub(crate) fn contain(child: &std::process::Child) -> io::Result<Self> {
        // SAFETY: no attributes and no name: an anonymous job.
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self { handle: handle as usize };
        // SAFETY: the job just made and the child's own process handle.
        if unsafe { AssignProcessToJobObject(handle, child.as_raw_handle() as HANDLE) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(job)
    }

    /// Ends every process in the job: the child and what it started.
    pub(crate) fn terminate(&self) -> io::Result<()> {
        // SAFETY: the handle this value owns.
        if unsafe { TerminateJobObject(self.handle as HANDLE, TERMINATED) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        // SAFETY: the handle this value owns, closed once.
        unsafe { CloseHandle(self.handle as HANDLE) };
    }
}

/// Lets a child created suspended run: resumes the threads of `pid` (a
/// suspended new process has one, its main thread).
pub(crate) fn resume(pid: u32) -> io::Result<()> {
    // SAFETY: a snapshot of every thread; closed below.
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
    if snapshot == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let result = resume_in(snapshot, pid);
    // SAFETY: the snapshot opened above.
    unsafe { CloseHandle(snapshot) };
    result
}

fn resume_in(snapshot: HANDLE, pid: u32) -> io::Result<()> {
    let mut entry = THREADENTRY32 {
        dwSize: u32::try_from(size_of::<THREADENTRY32>()).unwrap_or(u32::MAX),
        ..THREADENTRY32::default()
    };
    let mut resumed = false;
    // SAFETY: a live snapshot and an entry whose size field is set.
    let mut more = unsafe { Thread32First(snapshot, &mut entry) } != 0;
    while more {
        if entry.th32OwnerProcessID == pid {
            // SAFETY: a thread id the snapshot listed; the handle is closed below.
            let thread = unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
            if thread.is_null() {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: the thread handle just opened.
            let count = unsafe { ResumeThread(thread) };
            let error = (count == u32::MAX).then(io::Error::last_os_error);
            // SAFETY: as above, closed once.
            unsafe { CloseHandle(thread) };
            if let Some(error) = error {
                return Err(error);
            }
            resumed = true;
        }
        // SAFETY: as for Thread32First.
        more = unsafe { Thread32Next(snapshot, &mut entry) } != 0;
    }
    if resumed {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::NotFound, "the suspended child has no thread to resume"))
    }
}
