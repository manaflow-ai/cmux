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
//!
//! An owned child ([`crate::Command::spawn_owned`]) runs in a job with the
//! kill-on-close limit ([`Job::owned`]): the kernel closes this process's
//! handle however it ends (an exit, a panic, a crash, `TerminateProcess`),
//! and that ends the child and its tree, as the watchdog does on Unix.
//!
//! Code that spawns with `std::process::Command` itself (the journal hooks
//! and plugins) uses the same pieces: spawn with [`CREATE_SUSPENDED`], put
//! the child in [`Job::owned`], then [`resume`] it.

use std::io;
use std::os::windows::io::AsRawHandle;

use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
use windows_sys::Win32::System::Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME};

/// The creation flag a child is spawned with before it goes in a job.
pub use windows_sys::Win32::System::Threading::CREATE_SUSPENDED;

/// The exit code of every process a terminated job ends (std's `kill` uses 1).
const TERMINATED: u32 = 1;

/// An anonymous job holding one child and what it starts; the handle closes
/// on drop (which ends the tree only for [`Job::owned`]: see the module docs).
#[derive(Debug)]
pub struct Job {
    /// The kernel handle as an integer, so [`crate::Child`] stays `Send` and
    /// `Sync` (handles are process-wide values, safe from any thread).
    handle: usize,
}

impl Job {
    /// Puts `child` (created suspended) in a new job its tree outlives once
    /// the handle closes.
    ///
    /// # Errors
    ///
    /// When the job cannot be made or the child cannot join it.
    pub fn contain(child: &std::process::Child) -> io::Result<Self> {
        Self::new(false)?.with(child)
    }

    /// Puts `child` (created suspended) in a new job that ends it and its
    /// tree when the handle closes: on drop, or when this process ends.
    ///
    /// # Errors
    ///
    /// As [`Job::contain`], or when the kill-on-close limit cannot be set.
    pub fn owned(child: &std::process::Child) -> io::Result<Self> {
        Self::new(true)?.with(child)
    }

    fn new(kill_on_close: bool) -> io::Result<Self> {
        // SAFETY: no attributes and no name: an anonymous job.
        let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let job = Self { handle: handle as usize };
        if kill_on_close {
            let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let size = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
                .unwrap_or(u32::MAX);
            // SAFETY: the job just made and a limit structure of the size given.
            if unsafe {
                SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    std::ptr::from_ref(&information).cast(),
                    size,
                )
            } == 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(job)
    }

    fn with(self, child: &std::process::Child) -> io::Result<Self> {
        // SAFETY: this job and the child's own process handle.
        if unsafe {
            AssignProcessToJobObject(self.handle as HANDLE, child.as_raw_handle() as HANDLE)
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(self)
    }

    /// Ends every process in the job: the child and what it started.
    ///
    /// # Errors
    ///
    /// When the kernel refuses (the job's handle is this value's own).
    pub fn terminate(&self) -> io::Result<()> {
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
///
/// # Errors
///
/// When the threads cannot be listed or resumed, or `pid` has none.
pub fn resume(pid: u32) -> io::Result<()> {
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
