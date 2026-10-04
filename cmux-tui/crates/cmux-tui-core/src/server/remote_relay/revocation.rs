//! Revocation of a paired install (server-remote-conversations.md section 10).
//! A revoke from the cloud acts in one step; the offline limits act when the
//! recheck driver reports a check or calls [`Mux::enforce_remote_limits`].
//! Removing the install's `remote_<install>` participant
//! (`participants.remove_system`) and cancelling its remote-origin chains
//! (section 6) join this step when those exist.

use std::sync::Arc;

use crate::remote_relay_state::{RevocationClock, StreamPolicy};

use super::super::{Mux, disconnect_client};

impl Mux {
    /// The control plane confirmed `install` (the 5-minute recheck or a new
    /// stream's check).
    pub fn record_remote_check(&self, install: &str) {
        let _ = install;
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    /// Revoke `install` in one step: mark it revoked, delete its pairing
    /// record and close every stream it has open.
    pub fn revoke_remote_install(self: &Arc<Self>, install: &str) {
        let _ = install;
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    /// Apply the offline limits now: close the streams of every install whose
    /// last good check is older than 72 hours (or that is revoked). Returns
    /// the installs it closed. An unreachable cloud records nothing, so it
    /// closes nothing before the limit.
    pub fn enforce_remote_limits(self: &Arc<Self>) -> Vec<String> {
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    /// Replace the revocation clock (the recheck driver and tests).
    pub fn set_remote_revocation_clock(&self, clock: Arc<dyn RevocationClock>) {
        let _ = clock;
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    fn close_remote_streams(self: &Arc<Self>, install: &str) {
        let _ = install;
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }
}
