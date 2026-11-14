//! Part of `Hub`; see `hub/mod.rs`. A leased peer: a peer that lasts only as
//! long as the unix socket connection that leased it (`_acpmux/peer_lease`).
//!
//! The Cloud link reaches a Cloud VM's acpmux through a local port forward
//! of its remote tunnel (`ws://127.0.0.1:<ephemeral>`), which is gone once
//! the link process ends. A saved peer (`peer_add`) would keep reconnecting
//! to that port after the tunnel closed, and any local process that later
//! bound the port would receive the VM's dashboard and peer tokens. So a
//! lease is never written to config.json, leaves no last-known sessions on
//! disk (`peer_cache.rs`), and stops with its connection
//! (`Conn::end_peer_leases` in `server/mod.rs`).
//!
//! A peer Arc is looked up briefly before taking the rows writer lock (`remote_sessions`) or a
//! writer gate; never hold `peers` across another shared lock. A peer leaves the `peers` registry before its rows
//! are dropped, and a notice changes rows only while its instance is still
//! registered (`apply_peer_notice` checks while holding peers then rows), so a late
//! notice of a replaced or removed peer never adds rows back.

use super::*;

/// One lease a connection holds: the peer it started, by name and
/// generation. Ending it stops that peer only while it is still the one
/// registered under the name (a newer lease or a saved peer took it over
/// otherwise).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerLease {
    pub name: String,
    pub generation: u64,
}

impl Hub {
    /// Lease peer `name` at `url`: a `wss://` URL, or `ws://` to a loopback
    /// host (the only transports that may carry the peer token,
    /// `peer::carries_peer_token`). Refused for the name of a saved peer.
    /// A lease of a name already leased replaces that peer (the caller
    /// renews it with fresh tokens). Returns the lease and the peer's
    /// settled receiver. `vm_boundary`: the caller's own opt-out for this
    /// peer's remote chains (`vm_boundary.rs`), held with the lease only.
    pub fn lease_peer(
        &self,
        name: &str,
        url: &str,
        token: String,
        peer_token: Option<String>,
        vm_boundary: bool,
        saved: &crate::config::Config,
    ) -> Result<(PeerLease, tokio::sync::watch::Receiver<u64>), RpcError> {
        crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
        if !(url.starts_with("ws://") || url.starts_with("wss://"))
            || !crate::peer::carries_peer_token(url)
        {
            return Err(RpcError::invalid_params(
                "a leased peer's url must be wss:// or ws:// to a loopback host",
            ));
        }
        if saved.peers.contains_key(name) {
            return Err(RpcError::invalid_params(format!(
                "{name:?} is a saved peer; a lease takes a name of its own"
            )));
        }
        let pc = crate::config::PeerConfig {
            link_host: None,
            wireguard: None,
            url: url.to_owned(),
            token: Some(token),
            peer_token,
            vm_boundary,
            // A Cloud VM gets its own GitHub App token; the Mac's login is not lent to it.
            github_broker: false,
        };
        // Held while the peer starts, so none of its notices finds it unleased
        // and saves its sessions (`save_peer_cache`).
        let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
        let (generation, settled) = self.spawn_peer(name, &pc, false);
        leases.insert(name.to_owned(), generation);
        drop(leases);
        tracing::info!(peer = %name, "peer leased");
        Ok((PeerLease { name: name.to_owned(), generation }, settled))
    }

    /// End `lease`: stop its peer and drop its rows, unless the name now
    /// belongs to another peer. Idempotent.
    pub fn end_peer_lease(&self, lease: &PeerLease) {
        // Both under the lease lock, the peer first: a notice of the peer
        // finds it leased or gone, never unleased (`save_peer_cache`).
        let peer = {
            let mut leases = self.peer_leases.lock().unwrap_or_else(|e| e.into_inner());
            let peer = {
                let mut peers = self.peers.lock().unwrap_or_else(|e| e.into_inner());
                match peers.get(&lease.name) {
                    Some(p) if p.generation == lease.generation => peers.remove(&lease.name),
                    _ => None,
                }
            };
            if leases.get(&lease.name) == Some(&lease.generation) {
                leases.remove(&lease.name);
            }
            peer
        };
        let Some(peer) = peer else { return };
        peer.stop();
        self.note_peer_removed(&peer);
        self.purge_peer_rows(&lease.name);
        if !peer.cache_write_pending.load(std::sync::atomic::Ordering::Acquire) {
            self.peer_cache_writers.lock().unwrap_or_else(|e| e.into_inner()).remove(&lease.name);
        }
        tracing::info!(peer = %lease.name, "peer lease ended");
    }

    /// Whether `name` is a leased peer now.
    pub fn is_leased(&self, name: &str) -> bool {
        self.peer_leases.lock().unwrap_or_else(|e| e.into_inner()).contains_key(name)
    }
}

#[cfg(test)]
mod tests;
