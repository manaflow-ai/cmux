//! The sessions' temporary folders (`agent/session_tmp.rs`): the start sweep and a purged
//! session's removal, each off the caller's thread under the process's supervisor.

use super::Hub;
use crate::store::SessionStatus;
use crate::supervised::{Fatal, ShutdownBehavior};

impl Hub {
    /// Lists the temporary folders of sessions this daemon no longer has
    /// (`agent/session_tmp.rs`) and removes them on a thread of their own.
    /// The daemon calls it before its socket serves, so no session starts
    /// between the list and the store it is checked against.
    #[cfg(unix)]
    pub fn sweep_session_tmp(&self) {
        let metas = match self.store.list() {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("session tmp sweep skipped, the store did not list: {e}");
                return;
            }
        };
        let known: std::collections::HashSet<&str> = metas.iter().map(|m| m.id.as_str()).collect();
        let closed: std::collections::HashSet<&str> = metas
            .iter()
            .filter(|m| m.status == SessionStatus::Closed)
            .map(|m| m.id.as_str())
            .collect();
        // A session whose record did not list still has its folder.
        let stored = |id: &str| {
            known.contains(id)
                || self
                    .store
                    .session_dir(id)
                    .is_some_and(|d| cmux_blocking::fs::metadata(d).is_ok())
        };
        let stale = crate::agent::session_tmp::stale_for_daemon(&stored, &|id| closed.contains(id));
        if stale.is_empty() {
            return;
        }
        tracing::info!(count = stale.len(), "removing temporary folders of forgotten sessions");
        let sweep = crate::supervised::thread(
            &self.supervisor,
            "acpmux-session-tmp-sweep",
            cmux_threads::ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move |_stop| crate::agent::session_tmp::remove_all(&stale),
        );
        if let Err(e) = sweep {
            tracing::warn!("session tmp sweep did not start: {e}");
        }
    }

    /// Removes purged session `id`'s temporary folder on the blocking pool.
    #[cfg(unix)]
    pub(super) fn remove_session_tmp(&self, id: String) {
        crate::supervised::blocking(
            &self.supervisor,
            "hub.session-tmp-remove",
            Fatal,
            ShutdownBehavior::Continue,
            move || crate::agent::session_tmp::remove_session(&id),
        );
    }
}
