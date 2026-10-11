//! The remote session's disconnect state and the wait on it.

use std::sync::{Condvar, LockResult, Mutex, MutexGuard};
use std::time::Duration;

use super::DisconnectState;

/// How long a request the daemon refused during a pending shutdown waits for
/// the shutdown notice. The daemon sends the notice to other clients after
/// it flushed the requester's acknowledgement, for up to 5 s.
pub(super) const SHUTDOWN_PENDING_GRACE: Duration = Duration::from_secs(7);

/// True for the daemon's refusal while its shutdown handoff is reserved: the
/// stable code, or the message of a daemon that predates the code.
pub(super) fn is_shutdown_pending_refusal(code: Option<&str>, error: &str) -> bool {
    match code {
        Some(code) => code == cmux_tui_core::server::DAEMON_SHUTDOWN_PENDING_CODE,
        None => error == "daemon shutdown is in progress; request was not executed",
    }
}

/// Record that a refused request waited the whole grace without a shutdown
/// notice or connection end: the daemon cancelled its shutdown, or it stalled.
pub(super) fn log_missing_shutdown_notice() {
    crate::client_log::log(
        "WARN",
        "remote",
        &format!(
            "daemon refused a request for a pending shutdown but sent no shutdown notice within {} s; the request stays refused",
            SHUTDOWN_PENDING_GRACE.as_secs()
        ),
    );
}

/// The first terminal state of the session, with a condition that wakes
/// waiters when it leaves `Active`.
#[derive(Default)]
pub(super) struct DisconnectCell {
    state: Mutex<DisconnectState>,
    changed: Condvar,
}

impl DisconnectCell {
    pub(super) fn lock(&self) -> LockResult<MutexGuard<'_, DisconnectState>> {
        self.state.lock()
    }

    /// Wake waiters after the state changed.
    pub(super) fn notify(&self) {
        self.changed.notify_all();
    }

    /// Wait until the state leaves `Active`, or `grace` passes.
    pub(super) fn wait_while_active(&self, grace: Duration) {
        let state = self.state.lock().unwrap_or_else(|poison| poison.into_inner());
        let _ = self
            .changed
            .wait_timeout_while(state, grace, |state| matches!(state, DisconnectState::Active));
    }
}
