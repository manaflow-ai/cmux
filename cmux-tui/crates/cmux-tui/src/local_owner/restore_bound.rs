//! The bound on `server ensure`'s wait for a restoring owner: a stall bound,
//! not a fixed timer (`plans/cmux-next/long-jobs-DESIGN.md`).
//!
//! The owner publishes its long jobs to `long-jobs.json` in its session
//! directory while its socket still parks connections. The wait goes on as
//! long as a job that blocks `startup` reports progress (its `updated_ms`
//! changes, or a job starts or ends), and ends with `server.restore_timeout`
//! once [`restore_stall`] passes without any change. An owner that publishes
//! no job keeps the old bound: [`restore_stall`] from the start of the wait.
//! The file is read where the probe loops already look at the owner, at
//! their own cadence.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_tui_core::long_jobs::JobsStatus;
use cmux_tui_core::platform;
use serde_json::Value;

use super::{OwnerSpec, RESTORE_DEADLINE};

/// The restore bound: [`RESTORE_DEADLINE`], or a debug build's
/// `CMUX_TUI_TEST_RESTORE_DEADLINE_MS` (behavior tests of the stall bound).
pub(crate) fn restore_stall() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var("CMUX_TUI_TEST_RESTORE_DEADLINE_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_millis(ms);
    }
    RESTORE_DEADLINE
}

pub(crate) struct RestoreBound {
    status_dir: Option<PathBuf>,
    /// The bound without jobs: the wait's start plus the stall bound (or the
    /// caller's longer contact deadline).
    floor: Instant,
    last_change: Cell<Option<Instant>>,
    mark: RefCell<Vec<(String, u64)>>,
}

impl RestoreBound {
    pub(crate) fn new(spec: &OwnerSpec, deadline: Instant) -> Self {
        let status_dir = spec
            .state
            .clone()
            .or_else(platform::workspace_state_dir)
            .map(|root| cmux_tui_core::long_jobs::session_dir(&root, &spec.session));
        Self {
            status_dir,
            floor: deadline.max(Instant::now() + restore_stall()),
            last_change: Cell::new(None),
            mark: RefCell::new(Vec::new()),
        }
    }

    /// The owner's status file, when a live process wrote it.
    fn status(&self) -> Option<JobsStatus> {
        let status = JobsStatus::read(self.status_dir.as_deref()?)?;
        process_alive(status.pid).then_some(status)
    }

    /// The deadline now: the status file is read, and a change of its
    /// startup jobs moves the deadline to a full stall bound from now.
    pub(crate) fn deadline(&self) -> Instant {
        if let Some(status) = self.status() {
            let mark = status.startup_progress_mark();
            if !mark.is_empty() && *self.mark.borrow() != mark {
                *self.mark.borrow_mut() = mark;
                self.last_change.set(Some(Instant::now()));
            }
        }
        match self.last_change.get() {
            Some(changed) => self.floor.max(changed + restore_stall()),
            None => self.floor,
        }
    }

    pub(crate) fn expired(&self) -> bool {
        Instant::now() >= self.deadline()
    }

    /// The owner's published jobs, for a progress line.
    pub(crate) fn jobs(&self) -> Vec<Value> {
        self.status().map(|status| status.jobs).unwrap_or_default()
    }
}

#[cfg(unix)]
fn process_alive(pid: u64) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// No cheap check off Unix: the file's writer removes it when its jobs end,
/// and the owner's install removes a stale one.
#[cfg(not(unix))]
fn process_alive(_pid: u64) -> bool {
    true
}
