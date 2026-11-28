//! The Unix child of a terminal host (cx-ko2e `HostChild` seam, Unix side):
//! one the host spawned ([`HostChild::Spawned`]) or a running session it
//! adopted from a dead host ([`HostChild::Adopted`], cx-6so.49 L1), which it
//! does not parent and cannot reap. `shared/host_start.rs` runs the host on
//! it.

use super::adopted_child::AdoptedChild;
use super::*;

/// The process a host's PTY runs.
pub(crate) enum HostChild {
    /// Spawned by this host: it waits on and reaps it.
    Spawned(SpawnedPtyChild),
    /// A running session of an earlier host of this terminal.
    Adopted(AdoptedChild),
}

impl HostChild {
    pub(crate) fn process_id(&self) -> Option<u32> {
        match self {
            Self::Spawned(child) => child.child().process_id(),
            Self::Adopted(child) => Some(child.pid()),
        }
    }

    pub(crate) fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        match self {
            Self::Spawned(child) => child.child().clone_killer(),
            Self::Adopted(child) => child.killer(),
        }
    }

    pub(crate) fn adopted_session(&self) -> Option<libc::pid_t> {
        match self {
            Self::Spawned(_) => None,
            Self::Adopted(child) => Some(child.session_id()),
        }
    }

    /// Block until the child ended, without reaping it. False when that
    /// cannot be observed (the caller then waits and reaps directly).
    pub(crate) fn wait_exit_observed(&self) -> bool {
        match self {
            Self::Spawned(child) => child
                .child()
                .process_id()
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .is_some_and(|pid| wait_for_child_exit_without_reaping(pid).is_ok()),
            Self::Adopted(child) => {
                child.wait_for_exit();
                true
            }
        }
    }

    pub(crate) fn wait_and_disarm(&mut self) -> TerminalExit {
        match self {
            Self::Spawned(child) => child.wait_and_disarm(),
            // Not this host's child: its status went to its real parent.
            Self::Adopted(_) => TerminalExit::unknown(crate::terminal_end::EXIT_UNOBSERVED),
        }
    }
}

fn wait_for_child_exit_without_reaping(pid: libc::pid_t) -> std::io::Result<()> {
    loop {
        let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::uninit();
        // SAFETY: status points to writable siginfo storage. WNOWAIT
        // observes this owned child becoming waitable without releasing
        // its PID/PGID for reuse; the portable Child handle reaps it after
        // acquiring child_signal_lock.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                status.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
