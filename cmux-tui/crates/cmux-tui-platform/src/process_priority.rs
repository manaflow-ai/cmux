//! Process priority of idle helpers: a process nobody waits
//! for runs best-effort until it is needed, and is put back before it is.
//!
//! Chromium does the same for hidden and spare renderers
//! (`RenderProcessHostImpl::UpdateProcessPriority`,
//! `content/browser/renderer_host/render_process_host_impl.cc`) through
//! `Process::SetPriority` (`base/process/process_mac.cc`,
//! `base/process/process_linux.cc`): one call per process it knows, never a
//! walk of their descendants. Here too: cmux never scans processes
//! (`scripts/cmux-next/check-no-process-scan.py`).
//!
//! - macOS: `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`, the
//!   task's darwin-background policy (lowest CPU priority, throttled disk and
//!   network, coalesced timers); [`ProcessPriority::UserVisible`] takes it off
//!   again. It has no process-group form, so [`set_group`] changes the
//!   leader. A process forked while it is on inherits it, and a change by
//!   another process cannot take off the one a process set itself: start
//!   children at the normal priority.
//! - Linux: nice [`BEST_EFFORT_NICE`], back to 0. Nice is per thread there:
//!   [`set_self`] lowers each thread of this process below it and records
//!   the nice each had ([`SelfLowered`]) to put back exactly that, so a
//!   thread's own QoS nice (`cmux_threads::ThreadQos::linux_nice`) survives
//!   a round trip; [`set_group`] changes every thread of every process in
//!   the group (`PRIO_PGRP`, in the kernel). Only where the process may
//!   raise it again (root or an `RLIMIT_NICE` that allows nice 0, Chromium's
//!   `CanReraisePriority`); elsewhere nothing changes and
//!   [`PriorityError::NotReversible`] says so.
//! - Other platforms: [`PriorityError::Unsupported`].
//!
//! Never for terminal hosts or holders: a hidden terminal still runs a
//! person's build.

use std::fmt;

/// The nice value of a best-effort process on Linux.
pub const BEST_EFFORT_NICE: i32 = 10;

/// How much a person waits for a process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessPriority {
    /// Nobody waits for it (Chromium `Process::Priority::kBestEffort`).
    BestEffort,
    /// Its normal priority (on Mac without a task role, Chromium's
    /// `kUserVisible` and `kUserBlocking`: the darwin-background policy off).
    UserVisible,
}

/// Why a priority was not changed or read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PriorityError {
    /// This platform has no process priority here.
    Unsupported,
    /// The process could lower the priority but not raise it again.
    NotReversible,
    /// The kernel refused the call for `pid` (a process or group id).
    Os { pid: u32, errno: i32 },
}

impl fmt::Display for PriorityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => f.write_str("process priority is not supported on this platform"),
            Self::NotReversible => {
                f.write_str("this process could not raise a lowered priority again")
            }
            Self::Os { pid, errno } => write!(
                f,
                "process priority of {pid}: {}",
                std::io::Error::from_raw_os_error(*errno)
            ),
        }
    }
}

impl std::error::Error for PriorityError {}

impl PriorityError {
    /// The process or group ended before the call.
    pub fn is_gone(&self) -> bool {
        matches!(self, Self::Os { errno, .. } if *errno == libc::ESRCH)
    }
}

/// What [`set_self`] lowered, so [`ProcessPriority::UserVisible`] puts back
/// exactly that (Linux: each thread and the nice it had; empty elsewhere,
/// where the change is one per task).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SelfLowered {
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    threads: Vec<SeenThread>,
}

impl SelfLowered {
    /// Whether nothing is recorded (nothing to put back).
    pub fn is_empty(&self) -> bool {
        self.threads.is_empty()
    }
}

/// One thread [`set_self`] saw when it lowered this process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
struct SeenThread {
    tid: u32,
    /// Its nice before the change.
    nice: i32,
    /// Whether the change lowered it (false: it was at the best-effort nice
    /// or above already, and is left as it is).
    lowered: bool,
}

/// True when a [`ProcessPriority::BestEffort`] change can be taken back.
pub fn reversible() -> bool {
    imp::reversible()
}

/// Changes this process, every thread of it. `lowered` records what a
/// best-effort change did and is what the change back reads (and empties):
/// keep the same value between the two calls. A best-effort change that
/// fails part-way takes back what it did before it returns the error.
pub fn set_self(priority: ProcessPriority, lowered: &mut SelfLowered) -> Result<(), PriorityError> {
    imp::set_self(priority, lowered)
}

/// Changes the process group `leader` leads (a child started with `setsid`
/// or in its own process group, same user): on Linux every process and
/// thread in it, on macOS the leader.
pub fn set_group(leader: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
    imp::set_group(leader, priority)
}

/// Whether `pid` runs best-effort now (the read-back of [`set_group`] and
/// [`set_self`]): on Linux its main thread at [`BEST_EFFORT_NICE`] or above,
/// on macOS its darwin-background policy, whoever set it.
pub fn is_background(pid: u32) -> Result<bool, PriorityError> {
    imp::is_background(pid)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{PriorityError, ProcessPriority, SelfLowered, errno};

    /// `pbi_flags` bits of the darwin-background policy: the one the task set
    /// itself and the one another process set (xnu
    /// bsd/sys/proc_info_private.h; filled by `proc_get_darwinbgstate`,
    /// osfmk/kern/task_policy.c).
    const PROC_FLAG_DARWINBG: u32 = 0x8000;
    const PROC_FLAG_EXT_DARWINBG: u32 = 0x10000;

    pub(super) fn reversible() -> bool {
        true
    }

    fn set(who: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
        let prio = match priority {
            ProcessPriority::BestEffort => libc::PRIO_DARWIN_BG,
            ProcessPriority::UserVisible => 0,
        };
        // SAFETY: plain syscall with integer arguments.
        if unsafe { libc::setpriority(libc::PRIO_DARWIN_PROCESS, libc::id_t::from(who), prio) } == 0
        {
            Ok(())
        } else {
            let pid = if who == 0 { std::process::id() } else { who };
            Err(PriorityError::Os { pid, errno: errno() })
        }
    }

    /// The darwin-background policy is one per task: nothing to record.
    pub(super) fn set_self(
        priority: ProcessPriority,
        _lowered: &mut SelfLowered,
    ) -> Result<(), PriorityError> {
        set(0, priority)
    }

    pub(super) fn set_group(leader: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
        if leader == 0 {
            return Err(PriorityError::Os { pid: leader, errno: libc::ESRCH });
        }
        set(leader, priority)
    }

    /// Read through the process's BSD info, both policy bits:
    /// `getpriority(PRIO_DARWIN_PROCESS, pid)` reads the caller's own task,
    /// not `pid`'s (xnu bsd/kern/kern_resource.c `get_background_proc`).
    pub(super) fn is_background(pid: u32) -> Result<bool, PriorityError> {
        let gone = PriorityError::Os { pid, errno: libc::ESRCH };
        let Ok(raw) = libc::c_int::try_from(pid) else { return Err(gone) };
        let Ok(size) = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()) else {
            return Err(PriorityError::Unsupported);
        };
        // SAFETY: proc_bsdinfo is a plain C struct of integers and char arrays: all-zero
        // bytes are a valid value.
        let mut info = unsafe { std::mem::zeroed::<libc::proc_bsdinfo>() };
        // SAFETY: `info` is a live proc_bsdinfo of exactly `size` bytes; proc_pidinfo writes at
        // most that many bytes into it.
        let written = unsafe {
            libc::proc_pidinfo(
                raw,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast(),
                size,
            )
        };
        if written != size {
            return match errno() {
                0 => Err(gone),
                errno => Err(PriorityError::Os { pid, errno }),
            };
        }
        Ok(info.pbi_flags & (PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG) != 0)
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{BEST_EFFORT_NICE, PriorityError, ProcessPriority, SeenThread, SelfLowered, errno};

    pub(super) fn reversible() -> bool {
        cmux_threads::reversible(cmux_threads::ThreadQos::Background)
    }

    /// What a `setpriority` names. The libc constants go to the call as they
    /// are: their type differs between glibc and musl.
    #[derive(Clone, Copy)]
    enum Who {
        Thread(u32),
        Group(u32),
    }

    /// The nice of thread (or process) `tid`.
    fn get(tid: u32) -> Result<i32, PriorityError> {
        // getpriority answers -1 for an error and for a value alike: errno tells.
        // SAFETY: __errno_location returns this thread's errno slot.
        unsafe { *libc::__errno_location() = 0 };
        // SAFETY: plain syscall with integer arguments.
        let value = unsafe { libc::getpriority(libc::PRIO_PROCESS, libc::id_t::from(tid)) };
        match errno() {
            errno if value == -1 && errno != 0 => Err(PriorityError::Os { pid: tid, errno }),
            _ => Ok(value),
        }
    }

    fn set(who: Who, nice: i32) -> Result<(), PriorityError> {
        let (id, result) = match who {
            // SAFETY: plain syscall with integer arguments.
            Who::Thread(tid) => {
                (tid, unsafe { libc::setpriority(libc::PRIO_PROCESS, libc::id_t::from(tid), nice) })
            }
            // SAFETY: plain syscall with integer arguments.
            Who::Group(leader) => (leader, unsafe {
                libc::setpriority(libc::PRIO_PGRP, libc::id_t::from(leader), nice)
            }),
        };
        if result == 0 { Ok(()) } else { Err(PriorityError::Os { pid: id, errno: errno() }) }
    }

    /// Thread `tid` to `nice`; one that ended since it was listed is skipped.
    fn set_thread(tid: u32, nice: i32) -> Result<(), PriorityError> {
        match set(Who::Thread(tid), nice) {
            Err(e) if e.is_gone() => Ok(()),
            other => other,
        }
    }

    /// The threads of this process now.
    fn threads() -> Result<Vec<u32>, PriorityError> {
        let pid = std::process::id();
        let tasks = std::fs::read_dir("/proc/self/task")
            .map_err(|e| PriorityError::Os { pid, errno: e.raw_os_error().unwrap_or(libc::EIO) })?;
        Ok(tasks.flatten().filter_map(|t| t.file_name().to_str()?.parse::<u32>().ok()).collect())
    }

    pub(super) fn set_self(
        priority: ProcessPriority,
        lowered: &mut SelfLowered,
    ) -> Result<(), PriorityError> {
        if !reversible() {
            return Err(PriorityError::NotReversible);
        }
        match priority {
            ProcessPriority::BestEffort => lower(lowered),
            ProcessPriority::UserVisible => restore(lowered),
        }
    }

    /// Each thread below [`BEST_EFFORT_NICE`] to it, recorded with the nice
    /// it had; a thread at it or above is recorded and left. A failure puts
    /// back what this call changed.
    fn lower(lowered: &mut SelfLowered) -> Result<(), PriorityError> {
        let mut seen = Vec::new();
        for tid in threads()? {
            if lowered.threads.iter().any(|t| t.tid == tid) {
                continue;
            }
            let Ok(nice) = get(tid) else { continue };
            let lower = nice < BEST_EFFORT_NICE;
            if lower && let Err(e) = set_thread(tid, BEST_EFFORT_NICE) {
                let _ = put_back(&seen);
                return Err(e);
            }
            seen.push(SeenThread { tid, nice, lowered: lower });
        }
        lowered.threads.extend(seen);
        Ok(())
    }

    /// Each thread in `seen` that was lowered back to its own nice, when it
    /// is still at [`BEST_EFFORT_NICE`] (one that changed its nice since
    /// keeps the new one).
    fn put_back(seen: &[SeenThread]) -> Result<(), PriorityError> {
        for t in seen.iter().filter(|t| t.lowered) {
            if get(t.tid).is_ok_and(|now| now == BEST_EFFORT_NICE) {
                set_thread(t.tid, t.nice)?;
            }
        }
        Ok(())
    }

    /// [`put_back`] the record. A thread started while lowered inherited the
    /// best-effort nice from its creator: it gets the nice the main thread
    /// had before the change. On a failure the record stays for the next call.
    fn restore(lowered: &mut SelfLowered) -> Result<(), PriorityError> {
        put_back(&lowered.threads)?;
        let pid = std::process::id();
        let base = lowered.threads.iter().find(|t| t.tid == pid).map(|t| t.nice);
        if let Some(base) = base.filter(|base| *base < BEST_EFFORT_NICE) {
            for tid in threads()? {
                if !lowered.threads.iter().any(|t| t.tid == tid)
                    && get(tid).is_ok_and(|now| now == BEST_EFFORT_NICE)
                {
                    set_thread(tid, base)?;
                }
            }
        }
        lowered.threads.clear();
        Ok(())
    }

    pub(super) fn set_group(leader: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
        if !reversible() {
            return Err(PriorityError::NotReversible);
        }
        if leader == 0 {
            return Err(PriorityError::Os { pid: leader, errno: libc::ESRCH });
        }
        let nice = match priority {
            ProcessPriority::BestEffort => BEST_EFFORT_NICE,
            ProcessPriority::UserVisible => 0,
        };
        set(Who::Group(leader), nice)
    }

    pub(super) fn is_background(pid: u32) -> Result<bool, PriorityError> {
        Ok(get(pid)? >= BEST_EFFORT_NICE)
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::{PriorityError, ProcessPriority, SelfLowered};

    pub(super) fn reversible() -> bool {
        false
    }

    pub(super) fn set_self(
        _priority: ProcessPriority,
        _lowered: &mut SelfLowered,
    ) -> Result<(), PriorityError> {
        Err(PriorityError::Unsupported)
    }

    pub(super) fn set_group(_leader: u32, _priority: ProcessPriority) -> Result<(), PriorityError> {
        Err(PriorityError::Unsupported)
    }

    pub(super) fn is_background(_pid: u32) -> Result<bool, PriorityError> {
        Err(PriorityError::Unsupported)
    }
}

#[cfg(all(test, unix))]
#[path = "process_priority_tests.rs"]
mod process_priority_tests;
