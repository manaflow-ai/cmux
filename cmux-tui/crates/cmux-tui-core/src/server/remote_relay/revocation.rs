//! Revocation of a paired install (server-remote-conversations.md section 10).
//! A revoke from the cloud acts in one step; the offline limits act when the
//! recheck driver reports a check or calls [`Mux::enforce_remote_limits`].
//! Removing the install's `remote_<install>` participant
//! (`participants.remove_system`) and cancelling its remote-origin chains
//! (section 6) join this step when those exist.

use std::sync::Arc;
use std::sync::PoisonError;

use crate::remote_relay_state::{RevocationClock, StreamPolicy};

use super::super::{Mux, disconnect_client};

impl Mux {
    /// The control plane confirmed `install` (the 5-minute recheck or a new
    /// stream's check).
    pub fn record_remote_check(&self, install: &str) {
        self.remote_relay()
            .revocation
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .record_good_check(install);
    }

    /// Revoke `install` in one step: mark it revoked, delete its pairing
    /// record and close every stream it has open.
    pub fn revoke_remote_install(self: &Arc<Self>, install: &str) {
        // Mark revoked and collect the streams under the revocation lock
        // (then peers), so no new stream of the install can slip between.
        let clients = {
            let mut revocation =
                self.remote_relay().revocation.lock().unwrap_or_else(PoisonError::into_inner);
            revocation.record_revoked(install);
            self.remote_relay().clients_of(install)
        };
        let pairing =
            self.remote_relay().pairing.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(records) = pairing {
            records.delete(install);
        }
        self.close_remote_clients(clients);
    }

    /// Apply the offline limits now: close the streams of every install whose
    /// last good check is older than 72 hours (or that is revoked). Returns
    /// the installs it closed. An unreachable cloud records nothing, so it
    /// closes nothing before the limit.
    pub fn enforce_remote_limits(self: &Arc<Self>) -> Vec<String> {
        let (closing, clients) = {
            let revocation =
                self.remote_relay().revocation.lock().unwrap_or_else(PoisonError::into_inner);
            let peers = self.remote_relay().peers.lock().unwrap_or_else(PoisonError::into_inner);
            let mut closing: Vec<String> = peers
                .values()
                .filter(|peer| revocation.policy(&peer.install) == StreamPolicy::Close)
                .map(|peer| peer.install.clone())
                .collect();
            closing.sort();
            closing.dedup();
            let clients: Vec<u64> = peers
                .iter()
                .filter(|(_, peer)| closing.contains(&peer.install))
                .map(|(client, _)| *client)
                .collect();
            (closing, clients)
        };
        self.close_remote_clients(clients);
        closing
    }

    /// Replace the revocation clock (the recheck driver and tests).
    pub fn set_remote_revocation_clock(&self, clock: Arc<dyn RevocationClock>) {
        self.remote_relay()
            .revocation
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set_clock(clock);
    }

    fn close_remote_clients(self: &Arc<Self>, clients: Vec<u64>) {
        for client in clients {
            disconnect_client(self, client, false);
        }
    }
}
