//! Part of `Peer` (`peer.rs`). A WireGuard route found for a plain `ssh://` machine, where
//! both ends run the Labs WireGuard transport (`wireguard_learned.rs`): no `peers.NAME.wireguard`
//! block, no `wgcfg.py`.
//!
//! The machine's `_acpmux/host_health` (asked every minute over the live link, `peer_health.rs`)
//! names its node key and, while its transport runs, its UDP port and service address
//! (`node.wireguard`). This daemon then:
//!
//! 1. asks it to admit this machine's key (`_acpmux/wireguard_admit`, the link already proved
//!    this daemon with the peer token),
//! 2. adds it to the mesh with the host ssh connects to (`ssh -G`'s `hostname`) as the UDP
//!    endpoint ([`crate::wireguard::Transport::learn`]),
//! 3. gives the peer `Via::Wireguard`, probed and raced like every path; ssh stays a path, so a
//!    route that does not carry changes nothing but a failed probe.
//!
//! The route is kept: the next start dials WireGuard first, before ssh is up
//! ([`Peer::recall_wireguard`]). Nothing is found for a peer whose config names a route, a peer
//! that is not `ssh://`, or where this machine's transport is off.

use super::Peer;
use crate::peer_paths::Via;
use crate::wireguard::{StaticPeer, Transport};
use serde_json::Value;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// The method a peer admits an origin's key with.
pub(crate) const ADMIT: &str = "_acpmux/wireguard_admit";

/// What a `host_health` reply says about the machine's transport: its key, UDP port and
/// service address. None without a running transport there.
pub(crate) fn advert_of(health: &Value) -> Option<(String, u16, SocketAddr)> {
    let wg = health.get("node")?.get("wireguard")?;
    let key = wg.get("publicKey")?.as_str()?.to_owned();
    let port = u16::try_from(wg.get("port")?.as_u64()?).ok().filter(|port| *port != 0)?;
    let address = wg.get("address")?.as_str()?.parse().ok()?;
    Some((key, port, address))
}

/// `host:port` for a UDP endpoint, with an IPv6 literal in brackets.
pub(crate) fn endpoint_of(host: &str, port: u16) -> String {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if bare.contains(':') { format!("[{bare}]:{port}") } else { format!("{bare}:{port}") }
}

impl Peer {
    /// The daemon's transport, for this peer to find a route with (`Hub::spawn_peer`, before
    /// the first dial). The route kept from an earlier run comes back at once.
    pub(crate) fn set_wireguard_learner(&self, transport: Arc<Transport>) {
        let _ = self.wg_learner.set(transport);
        self.recall_wireguard();
    }

    /// Whether a route may be found for this peer: a plain `ssh://` peer whose config names
    /// none, where this machine's transport runs. Later health replies refresh stale routes.
    fn wg_learn_wanted(&self) -> bool {
        !self.explicit_route.load(Ordering::SeqCst)
            && self.ssh_parts().is_some()
            && self.wg_learner.get().is_some()
    }

    /// The route kept for this peer on an earlier run, before the first dial.
    pub(crate) fn recall_wireguard(&self) {
        if !self.wg_learn_wanted() || self.wireguard_route().is_some() {
            return;
        }
        let Some(transport) = self.wg_learner.get() else { return };
        if let Some(route) = transport.learned_route(&self.name) {
            tracing::info!(peer = %self.name, "WireGuard route to this machine (kept from an earlier run)");
            self.set_wireguard(transport.clone(), route.address);
        }
    }

    /// Find the route from the machine's `host_health` reply (`peer_health.rs`). One find at a
    /// time; a failure is logged and tried again at the next reply.
    pub(super) fn learn_wireguard(self: &Arc<Self>, health: &Value) {
        if !self.wg_learn_wanted() {
            return;
        }
        let Some(advert) = advert_of(health) else { return };
        if self.wg_learning.swap(true, Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        self.scope.spawn_until_cancelled("peer-wireguard-learn", async move {
            if let Err(error) = me.learn_wireguard_now(advert).await {
                tracing::debug!(peer = %me.name, "no WireGuard route found yet: {error:#}");
            }
            me.wg_learning.store(false, Ordering::SeqCst);
        });
    }

    async fn learn_wireguard_now(
        self: &Arc<Self>,
        (key, port, address): (String, u16, SocketAddr),
    ) -> anyhow::Result<bool> {
        use anyhow::Context as _;
        let transport = self.wg_learner.get().context("no WireGuard transport")?.clone();
        let (destination, _) = self.ssh_parts().context("not an ssh peer")?;
        let host =
            destination.rsplit_once('@').map_or(destination.as_str(), |(_, host)| host).to_owned();
        let resolved = tokio::task::spawn_blocking(move || {
            let program = crate::cli::ssh_join::ssh_program();
            crate::cli::ssh_join::ssh_hostname(&program, &host).unwrap_or(host)
        })
        .await?;
        let route = StaticPeer { public_key: key, endpoint: endpoint_of(&resolved, port), address };
        // The peer admits this machine's key first, so the first handshake is answered.
        self.request(ADMIT, transport.advert()).await.map_err(|e| {
            anyhow::anyhow!("{} refused the WireGuard admit: {}", self.name, e.message)
        })?;
        let address = transport.learn(&self.name, route).await?;
        Ok(self.adopt_wireguard(transport, address))
    }

    /// Give this peer the learned route: `Via::Wireguard` joins its paths and is probed.
    pub(super) fn adopt_wireguard(
        self: &Arc<Self>,
        transport: Arc<Transport>,
        address: SocketAddr,
    ) -> bool {
        let unchanged = self.wireguard_route().is_some_and(|(current, current_address)| {
            Arc::ptr_eq(&current, &transport) && current_address == address
        });
        self.set_wireguard(transport, address);
        if unchanged {
            return true;
        }
        self.with_paths(|paths| paths.add(Via::Wireguard));
        tracing::info!(peer = %self.name, "WireGuard reaches this machine too: a path beside ssh");
        if self.link().is_ready() {
            if self.probing.load(Ordering::SeqCst) {
                self.scope.spawn_named("peer-wireguard-probe", self.clone().probe(Via::Wireguard));
            } else {
                self.start_probes();
            }
            self.note_ready_path();
        }
        true
    }
}

#[cfg(test)]
#[path = "peer_wg_learn_tests.rs"]
mod tests;
