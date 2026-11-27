//! The process an owner was started for: its pid and kernel start time
//! (moved out of server/starter_exit.rs, behavior unchanged). Lives below
//! `server` (RFD 0174 slice 5): `test_owner` uses it without reaching into
//! `server`; `server` re-exports it, so its callers are unchanged.

/// The process an owner was started for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Starter {
    pub pid: u32,
    /// Kernel start time in milliseconds since the epoch. 0 only for an
    /// owner started by hand with a bare pid: then the pid alone names it.
    pub started_ms: u64,
}

impl Starter {
    /// The running process `pid` with its known start time; `None` when no
    /// process runs under it or its start time cannot be read (a process
    /// that exits while it is read), so `server ensure` never hands an owner
    /// an identity that any later process under the pid would match.
    pub fn current(pid: u32) -> Option<Self> {
        let started_ms =
            crate::process_identity::started_ms(pid).filter(|started| *started != 0)?;
        crate::state::status_owners::process_is_running(pid).then_some(Self { pid, started_ms })
    }

    /// Whether `pid` still names this process (not a later one that reused
    /// the pid).
    pub(crate) fn still_running(self) -> bool {
        crate::state::status_owners::process_is_running(self.pid)
            && same_process(self.started_ms, crate::process_identity::started_ms(self.pid))
    }
}

/// Whether a process now under the pid, started at `current` (`None` when
/// unreadable), is the one recorded as started at `recorded`. A known start
/// time matches only itself: an unreadable one never stands in for it.
pub(crate) fn same_process(recorded: u64, current: Option<u64>) -> bool {
    recorded == 0 || current == Some(recorded)
}
