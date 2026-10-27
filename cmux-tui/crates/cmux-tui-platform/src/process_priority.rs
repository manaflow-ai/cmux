//! Process priority of idle helpers (p14-energy-038): a process nobody waits
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
//!   leader. A process forked while it is on inherits it.
//! - Linux: nice [`BEST_EFFORT_NICE`], back to 0. Nice is per thread there:
//!   [`set_self`] changes each thread of this process, [`set_group`] every
//!   thread of every process in the group (`PRIO_PGRP`, in the kernel). Only
//!   where the process may raise it again (root or an `RLIMIT_NICE` that
//!   allows nice 0, Chromium's `CanReraisePriority`); elsewhere nothing
//!   changes and [`PriorityError::NotReversible`] says so.
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

/// True when a [`ProcessPriority::BestEffort`] change can be taken back.
pub fn reversible() -> bool {
    imp::reversible()
}

/// Changes this process, every thread of it.
pub fn set_self(priority: ProcessPriority) -> Result<(), PriorityError> {
    imp::set_self(priority)
}

/// Changes the process group `leader` leads (a child started with `setsid`
/// or in its own process group, same user): on Linux every process and
/// thread in it, on macOS the leader.
pub fn set_group(leader: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
    imp::set_group(leader, priority)
}

/// Whether `pid` runs best-effort now (the read-back of [`set_group`]; on
/// Linux its main thread).
pub fn is_background(pid: u32) -> Result<bool, PriorityError> {
    imp::is_background(pid)
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{PriorityError, ProcessPriority, errno};

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

    pub(super) fn set_self(priority: ProcessPriority) -> Result<(), PriorityError> {
        set(0, priority)
    }

    pub(super) fn set_group(leader: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
        if leader == 0 {
            return Err(PriorityError::Os { pid: leader, errno: libc::ESRCH });
        }
        set(leader, priority)
    }

    pub(super) fn is_background(pid: u32) -> Result<bool, PriorityError> {
        // getpriority answers -1 for an error and for a value alike: errno tells.
        // SAFETY: __error returns this thread's errno slot.
        unsafe { *libc::__error() = 0 };
        // SAFETY: plain syscall with integer arguments.
        let value = unsafe { libc::getpriority(libc::PRIO_DARWIN_PROCESS, libc::id_t::from(pid)) };
        match errno() {
            errno if value == -1 && errno != 0 => Err(PriorityError::Os { pid, errno }),
            _ => Ok(value > 0),
        }
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{BEST_EFFORT_NICE, PriorityError, ProcessPriority, errno};

    pub(super) fn reversible() -> bool {
        cmux_threads::reversible(cmux_threads::ThreadQos::Background)
    }

    fn nice(priority: ProcessPriority) -> i32 {
        match priority {
            ProcessPriority::BestEffort => BEST_EFFORT_NICE,
            ProcessPriority::UserVisible => 0,
        }
    }

    fn get(which: libc::__priority_which_t, who: u32) -> Result<i32, PriorityError> {
        // SAFETY: __errno_location returns this thread's errno slot.
        unsafe { *libc::__errno_location() = 0 };
        // SAFETY: plain syscall with integer arguments.
        let value = unsafe { libc::getpriority(which, libc::id_t::from(who)) };
        match errno() {
            errno if value == -1 && errno != 0 => Err(PriorityError::Os { pid: who, errno }),
            _ => Ok(value),
        }
    }

    fn set(which: libc::__priority_which_t, who: u32, nice: i32) -> Result<(), PriorityError> {
        // SAFETY: plain syscall with integer arguments.
        if unsafe { libc::setpriority(which, libc::id_t::from(who), nice) } == 0 {
            Ok(())
        } else {
            Err(PriorityError::Os { pid: who, errno: errno() })
        }
    }

    /// Each thread of this process: below [`BEST_EFFORT_NICE`] to it, and
    /// for UserVisible, at it back to 0 (a thread at another nice of its
    /// own, a QoS class, keeps it). A thread that ended meanwhile is skipped.
    pub(super) fn set_self(priority: ProcessPriority) -> Result<(), PriorityError> {
        if !reversible() {
            return Err(PriorityError::NotReversible);
        }
        let pid = std::process::id();
        let tasks = std::fs::read_dir("/proc/self/task")
            .map_err(|e| PriorityError::Os { pid, errno: e.raw_os_error().unwrap_or(libc::EIO) })?;
        let tids = tasks.flatten().filter_map(|t| t.file_name().to_str()?.parse::<u32>().ok());
        for tid in tids {
            let Ok(current) = get(libc::PRIO_PROCESS, tid) else { continue };
            let change = match priority {
                ProcessPriority::BestEffort => current < BEST_EFFORT_NICE,
                ProcessPriority::UserVisible => current == BEST_EFFORT_NICE,
            };
            if !change {
                continue;
            }
            match set(libc::PRIO_PROCESS, tid, nice(priority)) {
                Err(e) if e.is_gone() => {}
                other => other?,
            }
        }
        Ok(())
    }

    pub(super) fn set_group(leader: u32, priority: ProcessPriority) -> Result<(), PriorityError> {
        if !reversible() {
            return Err(PriorityError::NotReversible);
        }
        if leader == 0 {
            return Err(PriorityError::Os { pid: leader, errno: libc::ESRCH });
        }
        set(libc::PRIO_PGRP, leader, nice(priority))
    }

    pub(super) fn is_background(pid: u32) -> Result<bool, PriorityError> {
        Ok(get(libc::PRIO_PROCESS, pid)? >= BEST_EFFORT_NICE)
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::{PriorityError, ProcessPriority};

    pub(super) fn reversible() -> bool {
        false
    }

    pub(super) fn set_self(_priority: ProcessPriority) -> Result<(), PriorityError> {
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
