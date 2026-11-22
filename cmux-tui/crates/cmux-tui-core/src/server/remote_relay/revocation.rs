//! Revocation of a paired install (server-remote-conversations.md section 10).
//! A revoke from the cloud acts in one step; the offline limits act when the
//! recheck driver reports a check or calls [`Mux::enforce_remote_limits`].
//! Removing the install's `remote_<install>` participant
//! (`participants.remove_system`) and cancelling its remote-origin chains
//! (section 6) join this step when those exist.
//!
//! Every step fails closed on a poisoned relay lock and returns
//! [`RelayStateError`]: a check is not recorded, and a revoke or a limit
//! check closes every remote stream, because the poisoned state cannot say
//! which streams belong to which install. New streams are refused too,
//! because `bind_remote_peer` refuses on the same poisoned lock.

use std::sync::Arc;
use std::sync::PoisonError;

use crate::remote_relay_state::{
    RelayLock, RelayStateError, RevocationClock, StreamPolicy, lock_checked,
};

use super::super::{ClientTransport, Mux, disconnect_client};

impl Mux {
    /// The control plane confirmed `install` (the 5-minute recheck or a new
    /// stream's check). A poisoned revocation lock records nothing.
    pub fn record_remote_check(&self, install: &str) -> Result<(), RelayStateError> {
        lock_checked(&self.remote_relay().revocation, RelayLock::Revocation)?
            .record_good_check(install);
        Ok(())
    }

    /// Revoke `install` in one step: mark it revoked, delete its pairing
    /// record and close every stream it has open. On a poisoned relay lock
    /// it closes every remote stream and still deletes the pairing record
    /// when it can.
    pub fn revoke_remote_install(self: &Arc<Self>, install: &str) -> Result<(), RelayStateError> {
        // Mark revoked and collect the streams under the revocation lock
        // (then peers), so no new stream of the install can slip between.
        let marked = lock_checked(&self.remote_relay().revocation, RelayLock::Revocation).and_then(
            |mut revocation| {
                revocation.record_revoked(install);
                self.remote_relay().clients_of(install)
            },
        );
        let pairing = lock_checked(&self.remote_relay().pairing, RelayLock::Pairing)
            .map(|pairing| pairing.clone());
        if let Ok(Some(records)) = &pairing {
            records.delete(install);
        }
        match marked {
            Ok(clients) => self.close_remote_clients(clients),
            Err(error) => {
                self.close_every_remote_client();
                return Err(error);
            }
        }
        pairing.map(|_| ())
    }

    /// Apply the offline limits now: close the streams of every install whose
    /// last good check is older than 72 hours (or that is revoked). Returns
    /// the installs it closed. An unreachable cloud records nothing, so it
    /// closes nothing before the limit. On a poisoned relay lock it closes
    /// every remote stream and returns the error.
    pub fn enforce_remote_limits(self: &Arc<Self>) -> Result<Vec<String>, RelayStateError> {
        let collected = (|| {
            let revocation = lock_checked(&self.remote_relay().revocation, RelayLock::Revocation)?;
            let peers = lock_checked(&self.remote_relay().peers, RelayLock::Peers)?;
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
            Ok((closing, clients))
        })();
        match collected {
            Ok((closing, clients)) => {
                self.close_remote_clients(clients);
                Ok(closing)
            }
            Err(error) => {
                self.close_every_remote_client();
                Err(error)
            }
        }
    }

    /// Replace the revocation clock (the recheck driver and tests). A
    /// poisoned revocation lock keeps the old clock.
    pub fn set_remote_revocation_clock(
        &self,
        clock: Arc<dyn RevocationClock>,
    ) -> Result<(), RelayStateError> {
        lock_checked(&self.remote_relay().revocation, RelayLock::Revocation)?.set_clock(clock);
        Ok(())
    }

    fn close_remote_clients(self: &Arc<Self>, clients: Vec<u64>) {
        for client in clients {
            disconnect_client(self, client, false);
        }
    }

    /// Close every remote stream: each client the registry lists as remote
    /// and each client with a peer record.
    fn close_every_remote_client(self: &Arc<Self>) {
        let mut clients: Vec<u64> = {
            // Safety: this list only closes streams; a stale id closes
            // nothing.
            let state = self.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
            state
                .clients
                .iter()
                .filter(|(_, record)| matches!(record.transport, ClientTransport::Remote))
                .map(|(client, _)| *client)
                .collect()
        };
        clients.extend(self.remote_relay().all_peer_clients());
        clients.sort_unstable();
        clients.dedup();
        self.close_remote_clients(clients);
    }
}
